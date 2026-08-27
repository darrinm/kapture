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
    @AppStorage("aiNamingEnabled") private var aiNaming = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var exportPath = Settings.shared.exportLocation.path

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
            Toggle("Name captures automatically (experimental)", isOn: $aiNaming)
            Text("Every capture is read on your Mac and its text indexed for search — that always "
                 + "happens and nothing leaves the machine. This option additionally renames files "
                 + "from what was read. The on-device namer is rough (it often latches onto menu-bar "
                 + "text), so it is off by default; captures keep their timestamp names.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.top, 4)
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
