// Settings window (SwiftUI in NSWindow): General + Overlay panes.
import SwiftUI
import AppKit
import ServiceManagement
import KaptureCore

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Kapture Settings"
        w.contentViewController = NSHostingController(rootView: SettingsView())
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var copyAfterCapture = Settings.shared.copyToClipboardAfterCapture
    @State private var sounds = Settings.shared.soundsEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var exportPath = Settings.shared.exportLocation.path
    @State private var overlayLeft = Settings.shared.overlayOnLeftEdge
    @State private var overlaySize = Settings.shared.overlaySizeIndex
    @State private var autoClose = Settings.shared.autoCloseEnabled
    @State private var autoCloseInterval = Settings.shared.autoCloseInterval
    @State private var autoCloseSaves = Settings.shared.autoCloseSaves

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            overlay.tabItem { Label("Overlay", systemImage: "rectangle.bottomright.filled.and.rectangle") }
        }
        .frame(width: 420)
        .padding(.bottom, 12)
    }

    var general: some View {
        Form {
            Toggle("Copy capture to clipboard", isOn: $copyAfterCapture)
                .onChange(of: copyAfterCapture) { _, v in Settings.shared.copyToClipboardAfterCapture = v }
            Toggle("Sounds", isOn: $sounds)
                .onChange(of: sounds) { _, v in Settings.shared.soundsEnabled = v }
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
            .onChange(of: overlayLeft) { _, v in Settings.shared.overlayOnLeftEdge = v }
            Picker("Size", selection: $overlaySize) {
                Text("Small").tag(0); Text("Medium").tag(1); Text("Large").tag(2)
            }
            .onChange(of: overlaySize) { _, v in Settings.shared.overlaySizeIndex = v }
            Toggle("Auto-close", isOn: $autoClose)
                .onChange(of: autoClose) { _, v in Settings.shared.autoCloseEnabled = v }
            if autoClose {
                Picker("After", selection: $autoCloseInterval) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .onChange(of: autoCloseInterval) { _, v in Settings.shared.autoCloseInterval = v }
                Picker("Action", selection: $autoCloseSaves) {
                    Text("Close (keep in library)").tag(false)
                    Text("Save and close").tag(true)
                }
                .onChange(of: autoCloseSaves) { _, v in Settings.shared.autoCloseSaves = v }
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
