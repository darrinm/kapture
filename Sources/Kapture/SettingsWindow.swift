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
    static let windowIdentifier = NSUserInterfaceItemIdentifier("kapture.settings")
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
        // The split view's `navigationTitle` renames the window to the pane, which is what System
        // Settings does and what we want — but it means the title is no longer a stable way to
        // find this window, and `--settings-shot --real` has to. Hence a fixed identifier.
        w.identifier = SettingsWindowController.windowIdentifier
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

/// A Keychain-backed secret: shown only as "stored", never read back into the field.
///
/// Both secrets Kapture holds — the Anthropic key and the share token — need the same three
/// rules, and had two copies of them. A Keychain write is a SecItemDelete + SecItemAdd pair of
/// blocking XPC calls, so it cannot ride every keystroke; committing only on submit lost the
/// value whenever the user clicked away instead; and an untouched field must never commit,
/// because it starts empty by design and would wipe a secret that is already there.
struct SecretField: View {
    let title: String
    let emptyPrompt: String
    /// Written on commit. nil clears the secret.
    let write: (String?) -> Void

    @Binding var isStored: Bool
    @State private var typed = ""
    @State private var edited = false
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        SecureField(title, text: $typed,
                    prompt: Text(isStored ? "stored — type to replace" : emptyPrompt))
            .textFieldStyle(.roundedBorder)
            .onChange(of: typed) { _, value in
                isStored = !value.isEmpty
                edited = true
                commitTask?.cancel()
                commitTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    commit()
                }
            }
            .onDisappear {
                commitTask?.cancel()
                commit()
            }
    }

    private func commit() {
        guard edited else { return }
        write(typed.isEmpty ? nil : typed)
    }
}

struct SettingsView: View {
    enum Tab: Hashable, CaseIterable, Identifiable {
        case general, overlay, recording, library, shortcuts, sharing
        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .overlay: "Overlay"
            case .recording: "Recording"
            case .library: "Library"
            case .shortcuts: "Shortcuts"
            case .sharing: "Sharing"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .overlay: "rectangle.bottomright.filled.and.rectangle"
            case .recording: "record.circle"
            case .library: "sparkles"
            case .shortcuts: "command"
            case .sharing: "link"
            }
        }
    }

    /// Fixed. The sidebar takes a fixed slice, so the width is that plus a pane wide enough for
    /// the widest row (Shortcuts' recorders, Sharing's token field). Tall enough for the longest
    /// pane without scrolling; the short panes are why the list is beside the pane rather than
    /// above it, since a tab bar over a two-row pane leaves most of the window empty.
    static let windowSize = NSSize(width: 760, height: 580)

    /// How much of that is the list.
    static let sidebarWidth: CGFloat = 190

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
    // Sparkle reads this key itself, preferring the user default over the Info.plist value, so
    // a plain toggle is the whole control
    @AppStorage("SUEnableAutomaticChecks") private var automaticUpdates = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var exportPath = Settings.shared.exportLocation.path
    // Not @AppStorage: this key's default depends on whether an API key is set. Seeded in
    // `refreshKeychainState()` rather than here — see the note on hasStoredKey.
    @State private var aiNaming = false
    // Seeded asynchronously: even the attribute-only existence check is a blocking XPC call,
    // and three of them during view construction stall the main thread every time this window
    // opens — and hang outright when the Keychain can't be reached (a locked screen).
    @State private var hasStoredKey = false
    @AppStorage("copyShareLink") private var copyShareLink = true
    @State private var hasShareToken = false
    // not @AppStorage: the value is an ordered array behind a Settings accessor that also
    // migrates the old single copy-after-capture flag
    @State private var afterCapture = Set(Settings.shared.afterCaptureActions.map(\.rawValue))
    @State private var bindings: [UInt32: HotkeyBinding] = [:]
    @State private var shortcutError = ""
    @State private var shareStatus = ""
    @State private var shareStatusIsError = false
    @State private var checkingShare = false

    var body: some View {
        // Pinned open. A split view offers to collapse its sidebar, which is right for a document
        // window with a browsable source list and wrong here: the list is the only way to reach
        // five of the six panes, so hiding it strands you on whichever one you were looking at.
        // System Settings does not offer it either.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // The list can deselect (a ⌘-click on the selected row) but a pane is always showing,
            // so nil means "keep the one we have" — and it has to be written back rather than
            // ignored, or the row loses its highlight with nothing to redraw it.
            List(Tab.allCases, selection: Binding(
                get: { Optional(selection.tab) },
                set: { selection.tab = $0 ?? selection.tab })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(SettingsView.sidebarWidth)
            .toolbar(removing: .sidebarToggle)   // and no button offering to do it
        } detail: {
            pane(for: selection.tab)
                .navigationTitle(selection.tab.title)
        }
        // the split view has no opinion about its own size, and the hosting controller takes
        // whatever it says — see the note on the window's preferredContentSize
        .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
        .task { await refreshKeychainState() }
    }

    @ViewBuilder
    private func pane(for tab: Tab) -> some View {
        switch tab {
        case .general: general
        case .overlay: overlay
        case .recording: recording
        case .library: intelligence
        case .shortcuts: shortcuts
        case .sharing: sharing
        }
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
            Toggle("Check for updates automatically", isOn: $automaticUpdates)
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
            SecretField(title: "Anthropic API key",
                        emptyPrompt: "sk-ant-… (optional)",
                        write: { Keychain.anthropicKey = $0 },
                        isStored: $hasStoredKey)
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
            SecretField(title: "Share token",
                        emptyPrompt: "paste your kapture.sh token",
                        write: { Keychain.shareToken = $0 },
                        isStored: $hasShareToken)
            LabeledContent("Server") {
                HStack {
                    Text(Settings.shared.shareEndpoint.host ?? "kapture.sh")
                        .foregroundStyle(.secondary)
                    Button("Check") { checkShareToken() }
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
