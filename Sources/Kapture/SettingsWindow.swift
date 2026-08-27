// Settings window (SwiftUI in NSWindow): General + Overlay panes.
import SwiftUI
import AppKit
import ServiceManagement
import KaptureCore

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
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

    func show() {
        if let window {
            // re-show must re-acquire — the willClose observer releases on every close,
            // so skipping acquire here underflows the hold count and leaves the app .accessory
            ActivationPolicy.acquire()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Kapture Settings"
        w.contentViewController = NSHostingController(rootView: SettingsView())
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
    // @AppStorage binds straight to the UserDefaults keys the Settings facade reads;
    // defaults mirror the facade's fallbacks.
    @AppStorage("copyAfterCapture") private var copyAfterCapture = true
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
    // Not @AppStorage: this key's default depends on whether an API key is set, so a plain
    // `= false` default would show the toggle off while ingest was busy renaming captures.
    @State private var aiNaming = Settings.shared.aiNamingEnabled
    // The stored key is never shown; the field starts empty and only what the user types is
    // committed, so an untouched field can't wipe a key that's already there.
    @State private var anthropicKey = ""
    @State private var hasStoredKey = Keychain.anthropicKey?.isEmpty == false
    // A Keychain write is a SecItemDelete + SecItemAdd pair of blocking XPC calls, so it can't
    // ride every keystroke — an `sk-ant-…` key is ~100 of them. Debounce, and flush on the way
    // out so a key typed and immediately dismissed still lands.
    @State private var keyCommit: Task<Void, Never>?
    @State private var keyEdited = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            overlay.tabItem { Label("Overlay", systemImage: "rectangle.bottomright.filled.and.rectangle") }
            recording.tabItem { Label("Recording", systemImage: "record.circle") }
            intelligence.tabItem { Label("Library", systemImage: "sparkles") }
        }
        .frame(width: 420)
        .padding(.bottom, 12)
    }

    var general: some View {
        Form {
            Toggle("Copy capture to clipboard", isOn: $copyAfterCapture)
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
            Toggle("Hover shortcuts on overlay cards", isOn: $hoverShortcuts)
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
            Text("⌘W · ⌘C · ⌘S · ⌘⌫ · space act on the card under the cursor without clicking. Needs Accessibility access.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
