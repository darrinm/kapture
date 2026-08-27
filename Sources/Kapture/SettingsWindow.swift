// Settings window (SwiftUI in NSWindow): General + Overlay panes.
import SwiftUI
import AppKit
import ServiceManagement
import KaptureCore

/// Which pane the window is showing. Held outside the view so callers can open the window
/// straight to the pane the user needs — a failed share should land on Sharing, not on General
/// with the real setting two clicks away.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsView.Tab = .general
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    let selection = SettingsSelection()
    private var window: NSWindow?
    private var axPollTimer: Timer?
    private var axPollTicks = 0

    /// Poll for the Accessibility grant after sending the user to System Settings.
    /// One poller at a time; gives up after ~2 minutes.
    func pollForAccessibility() {
        axPollTimer?.invalidate()
        axPollTicks = 0
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            Task { @MainActor in
                let c = SettingsWindowController.shared
                c.axPollTicks += 1
                if EventTapCenter.hasAccessibility {
                    timer.invalidate()
                    c.axPollTimer = nil
                    EventTapCenter.shared.startIfPossible()
                } else if c.axPollTicks >= 80 {   // ~2 min: the user isn't granting it now
                    timer.invalidate()
                    c.axPollTimer = nil
                }
            }
        }
    }

    func show(tab: SettingsView.Tab? = nil) {
        if let tab { selection.tab = tab }
        if let window {
            // re-show must re-acquire — the willClose observer releases on every close,
            // so skipping acquire here underflows the hold count and leaves the app .accessory
            ActivationPolicy.acquire()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Kapture Settings"
        let host = NSHostingController(rootView: SettingsView(selection: selection))
        // A hosting controller hands the window its view's *ideal* size, and a TabView full of
        // scrollable Forms has no definite height to offer — it reported 84 points and the
        // window opened as an empty sliver. SettingsView now pins its own frame, which makes
        // that ideal size definite. Setting preferredContentSize here as well puts two
        // authorities on the same number and AppKit loops updating constraints forever.
        w.contentViewController = host
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                               queue: .main) { _ in
            Task { @MainActor in ActivationPolicy.release() }
        }
        ActivationPolicy.acquire()
        w.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    enum Tab: Hashable { case general, overlay, recording, library, shortcuts, sharing }

    /// Fixed, and tall enough for the longest pane (Shortcuts) without scrolling.
    static let windowSize = NSSize(width: 520, height: 600)

    @ObservedObject var selection: SettingsSelection

    // @AppStorage binds straight to the UserDefaults keys the Settings facade reads;
    // defaults mirror the facade's fallbacks.
    @AppStorage("soundsEnabled") private var sounds = true
    @AppStorage("overlayOnLeftEdge") private var overlayLeft = false
    @AppStorage("overlaySizeIndex") private var overlaySize = 1
    @AppStorage("autoCloseEnabled") private var autoClose = false
    @AppStorage("autoCloseInterval") private var autoCloseInterval = 10
    @AppStorage("autoCloseSaves") private var autoCloseSaves = false
    @AppStorage("hoverShortcutsEnabled") private var hoverShortcuts = true
    @AppStorage("recordSystemAudio") private var recordSystemAudio = true
    @AppStorage("recordMicrophone") private var recordMicrophone = false
    @AppStorage("showClicksWhileRecording") private var showClicks = true
    @AppStorage("showKeysWhileRecording") private var showKeys = false
    @AppStorage("filenameTemplate") private var filenameTemplate = "%n %Y-%m-%d at %H.%M.%S"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var exportPath = Settings.shared.exportLocation.path
    // Not @AppStorage: this key's default depends on whether an API key is set. Seeded in
    // `refreshKeychainState()` rather than here — see the note on hasStoredKey.
    @State private var aiNaming = false
    // The stored key is never shown; the field starts empty and only what the user types is
    // committed, so an untouched field can't wipe a key that's already there.
    @State private var anthropicKey = ""
    // Seeded asynchronously: even the attribute-only existence check is a blocking XPC call,
    // and three of them during view construction stall the main thread every time this window
    // opens — and hang outright when the Keychain can't be reached (a locked screen).
    @State private var hasStoredKey = false
    // A Keychain write is a SecItemDelete + SecItemAdd pair of blocking XPC calls, so it can't
    // ride every keystroke — an `sk-ant-…` key is ~100 of them. Debounce, and flush on the way
    // out so a key typed and immediately dismissed still lands.
    @State private var keyCommit: Task<Void, Never>?
    @State private var keyEdited = false
    @AppStorage("copyShareLink") private var copyShareLink = true
    @State private var shareToken = ""
    @State private var hasShareToken = false
    @State private var shareCommit: Task<Void, Never>?
    @State private var shareTokenEdited = false
    // not @AppStorage: the value is an ordered array behind a Settings accessor that also
    // migrates the old single copy-after-capture flag
    @State private var afterCapture = Set(Settings.shared.afterCaptureActions.map(\.rawValue))
    @State private var bindings: [UInt32: HotkeyBinding] = [:]
    @State private var shortcutError = ""
    @State private var shareStatus = ""
    @State private var shareStatusIsError = false
    @State private var checkingShare = false

    var body: some View {
        TabView(selection: $selection.tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            overlay.tabItem { Label("Overlay", systemImage: "rectangle.bottomright.filled.and.rectangle") }
                .tag(Tab.overlay)
            recording.tabItem { Label("Recording", systemImage: "record.circle") }.tag(Tab.recording)
            intelligence.tabItem { Label("Library", systemImage: "sparkles") }.tag(Tab.library)
            shortcuts.tabItem { Label("Shortcuts", systemImage: "command") }.tag(Tab.shortcuts)
            sharing.tabItem { Label("Sharing", systemImage: "link") }.tag(Tab.sharing)
        }
        .frame(width: SettingsView.windowSize.width - 20,
               height: SettingsView.windowSize.height - 24)
        .padding(.bottom, 12)
        .task { await refreshKeychainState() }
    }

    /// Reads what the Keychain holds off the main thread, then reflects it in the UI. Only
    /// whether a secret exists is read here; the secrets themselves are never shown.
    private func refreshKeychainState() async {
        let state = await Task.detached {
            (anthropic: Keychain.hasAnthropicKey,
             share: Keychain.hasShareToken,
             naming: Settings.shared.aiNamingEnabled)
        }.value
        hasStoredKey = state.anthropic
        hasShareToken = state.share
        aiNaming = state.naming
    }

    var general: some View {
        Form {
            Section("After a capture") {
                ForEach(CaptureAction.allCases, id: \.rawValue) { action in
                    Toggle(isOn: Binding(
                        get: { afterCapture.contains(action.rawValue) },
                        set: { enabled in
                            Settings.shared.setAfterCaptureAction(action, enabled: enabled)
                            afterCapture = Set(Settings.shared.afterCaptureActions.map(\.rawValue))
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title)
                            if let detail = action.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Applies to screenshots. Recordings always land on a card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Sounds", isOn: $sounds)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            LabeledContent("Filename") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("", text: $filenameTemplate)
                    Text("%Y %m %d · %H %M %S · %n (capture/recording)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            LabeledContent("Export location") {
                HStack {
                    Text((exportPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseExportLocation() }
                }
            }
            Section {
                Button("Uninstall Kapture…", role: .destructive) { uninstall() }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Kapture?"
        alert.informativeText = "Removes the login item and moves the app to the Trash. Your library in \((Settings.shared.libraryRoot.path as NSString).abbreviatingWithTildeInPath) is kept — delete it in Finder if you want it gone too. System screenshot shortcuts work again the moment Kapture quits."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? SMAppService.mainApp.unregister()
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    var intelligence: some View {
        Form {
            Toggle("Name captures automatically", isOn: $aiNaming)
                .onChange(of: aiNaming) { _, v in Settings.shared.aiNamingEnabled = v }
            SecureField("Anthropic API key", text: $anthropicKey,
                        prompt: Text(hasStoredKey ? "stored — type to replace" : "sk-ant-… (optional)"))
                .textFieldStyle(.roundedBorder)
                // commit as typed: onSubmit alone lost the key whenever the user clicked away
                // or closed the window instead of pressing Return
                .onChange(of: anthropicKey) { _, v in
                    hasStoredKey = !v.isEmpty
                    keyEdited = true
                    keyCommit?.cancel()
                    keyCommit = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        commitKey()
                    }
                }
            Text(!hasStoredKey
                 ? "Without a key, names come from an on-device heuristic that is rough — it often "
                   + "latches onto menu-bar text. With your own Anthropic key, each capture (image "
                   + "plus its recognized text) is named by Claude; that is the only path where "
                   + "image content leaves this Mac, and macOS will ask once to unlock the key."
                 : "Named by Claude using your key. The image and its recognized text are sent to "
                   + "the Anthropic API for naming only. Clear the field to go back on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Every capture is read on your Mac and its text indexed for search — that always "
                 + "happens and nothing leaves the machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onDisappear {
            keyCommit?.cancel()
            commitKey()
        }
    }

    /// Write the typed key to the Keychain. Never runs for an untouched field: the field starts
    /// empty by design, so committing "" without an edit would wipe a key that is already there.
    private func commitKey() {
        guard keyEdited else { return }
        Keychain.anthropicKey = anthropicKey.isEmpty ? nil : anthropicKey
    }

    var shortcuts: some View {
        Form {
            ForEach(HotkeyCenter.Action.allCases, id: \.rawValue) { action in
                // a plain row rather than LabeledContent: the recorder plus its reset button is
                // wide enough that LabeledContent stacked the label above the control
                HStack(spacing: 8) {
                    Text(action.title)
                    Spacer(minLength: 8)
                    HotkeyRecorder(
                        binding: bindings[action.rawValue] ?? action.defaultBinding,
                        onRecord: { record($0, for: action) },
                        onReset: {
                            HotkeyCenter.shared.resetToDefault(action)
                            reloadBindings()
                        })
                    .frame(width: 100, height: 24)
                    Button {
                        HotkeyCenter.shared.resetToDefault(action)
                        reloadBindings()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(action.defaultBinding.display)")
                    .opacity(HotkeyCenter.shared.isDefault(action) ? 0 : 1)
                    .disabled(HotkeyCenter.shared.isDefault(action))
                }
            }
            if !shortcutError.isEmpty {
                Text(shortcutError).font(.caption).foregroundStyle(.red)
            }
            Text("Click a shortcut and type a new one. Esc cancels, Delete restores the default. "
                 + "⇧⌘3 / ⇧⌘4 / ⇧⌘5 take over the system screenshot shortcuts while Kapture is "
                 + "running; another app that claimed them first still wins, and Kapture says so "
                 + "when it notices one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Restore all defaults") {
                HotkeyCenter.shared.resetAllToDefaults()
                shortcutError = ""
                reloadBindings()
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onAppear { reloadBindings() }
    }

    private func record(_ binding: HotkeyBinding, for action: HotkeyCenter.Action) {
        do {
            try HotkeyCenter.shared.setBinding(binding, for: action)
            shortcutError = ""
        } catch HotkeyCenter.BindingError.takenBy(let other) {
            shortcutError = "\(binding.display) is already used by “\(other.title)”."
        } catch HotkeyCenter.BindingError.registrationFailed(let status) {
            shortcutError = "macOS refused \(binding.display) (error \(status)). It kept the previous shortcut."
        } catch {
            shortcutError = "\(error)"
        }
        reloadBindings()
    }

    /// The recorders read from this snapshot: HotkeyCenter is the source of truth, but SwiftUI
    /// needs a value that changes to redraw.
    private func reloadBindings() {
        bindings = Dictionary(uniqueKeysWithValues: HotkeyCenter.Action.allCases.map {
            ($0.rawValue, HotkeyCenter.shared.binding(for: $0))
        })
    }

    var sharing: some View {
        Form {
            SecureField("Share token", text: $shareToken,
                        prompt: Text(hasShareToken ? "stored — type to replace" : "paste your kapture.sh token"))
                .textFieldStyle(.roundedBorder)
                // same debounce as the API key: a Keychain write is two blocking XPC calls
                .onChange(of: shareToken) { _, v in
                    hasShareToken = !v.isEmpty
                    shareTokenEdited = true
                    shareStatus = ""
                    shareCommit?.cancel()
                    shareCommit = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        commitShareToken()
                    }
                }
            LabeledContent("Server") {
                HStack {
                    Text(Settings.shared.shareEndpoint.host ?? "kapture.sh")
                        .foregroundStyle(.secondary)
                    Button("Check") {
                        commitShareToken()
                        checkShareToken()
                    }
                    .disabled(!hasShareToken || checkingShare)
                }
            }
            if !shareStatus.isEmpty {
                Text(shareStatus)
                    .font(.caption)
                    .foregroundStyle(shareStatusIsError ? .red : .secondary)
            }
            Toggle("Copy the link after sharing", isOn: $copyShareLink)
            Text(hasShareToken
                 ? "⌘U on a capture uploads it and copies a permanent link. Links stay up until "
                   + "you delete them from the library's right-click menu. Editing a shared "
                   + "capture marks its link out of date — sharing again replaces it."
                 : "Sharing is off until a token is set. Kapture uploads only when you ask it to, "
                   + "and the link is the only way to reach the file — there is no listing page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onDisappear {
            shareCommit?.cancel()
            commitShareToken()
        }
    }

    private func commitShareToken() {
        guard shareTokenEdited else { return }
        Keychain.shareToken = shareToken.isEmpty ? nil : shareToken
    }

    /// One real request, so "connected" means the token actually authorizes rather than merely
    /// being non-empty. A typo'd token otherwise only surfaces at the moment of a share.
    private func checkShareToken() {
        checkingShare = true
        shareStatus = "Checking…"
        shareStatusIsError = false
        Task { @MainActor in
            defer { checkingShare = false }
            do {
                try await ShareService.verifyToken()
                shareStatus = "Connected to \(Settings.shared.shareEndpoint.host ?? "kapture.sh")"
            } catch let failure as ShareFailure {
                shareStatus = failure.description
                shareStatusIsError = true
            } catch {
                shareStatus = error.localizedDescription
                shareStatusIsError = true
            }
        }
    }

    var recording: some View {
        Form {
            Toggle("Record system audio", isOn: $recordSystemAudio)
            Toggle("Record microphone", isOn: $recordMicrophone)
            Toggle("Show clicks", isOn: $showClicks)
            Toggle("Show keystrokes", isOn: $showKeys)
            Text("Applies to the next recording. Click and keystroke visuals are drawn into the movie and need Accessibility access; the microphone permission is requested the first time a recording starts with it on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    var overlay: some View {
        Form {
            Picker("Position", selection: $overlayLeft) {
                Text("Bottom right").tag(false)
                Text("Bottom left").tag(true)
            }
            Picker("Size", selection: $overlaySize) {
                Text("Small").tag(0); Text("Medium").tag(1); Text("Large").tag(2)
            }
            Toggle("Hover shortcuts on cards", isOn: $hoverShortcuts)
                .onChange(of: hoverShortcuts) { _, v in
                    // @AppStorage persists the value; this hook only manages the event tap
                    if v {
                        if EventTapCenter.hasAccessibility {
                            EventTapCenter.shared.startIfPossible()
                        } else {
                            EventTapCenter.requestAccessibility()
                            SettingsWindowController.shared.pollForAccessibility()
                        }
                    } else {
                        EventTapCenter.shared.stop()
                    }
                }
            Text("⌘W · ⌘C · ⌘S · ⌘⌫ · space act on the card under the cursor without clicking. "
                 + "Needs Accessibility access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Auto-close", isOn: $autoClose)
            if autoClose {
                Picker("After", selection: $autoCloseInterval) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Action", selection: $autoCloseSaves) {
                    Text("Close (keep in library)").tag(false)
                    Text("Save and close").tag(true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    private func chooseExportLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.exportLocation
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.exportLocation = url
            exportPath = url.path
        }
    }
}
