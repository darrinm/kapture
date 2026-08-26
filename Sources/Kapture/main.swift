import AppKit
import KaptureCore
import KaptureCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try KaptureCore.Database()
            let library = try Library(db: db)
            CaptureCoordinator.shared.library = library
            OverlayController.shared.library = library
        } catch {
            Log.shell.error("store init failed: \(error)")
        }

        Task { await ContentCache.shared.startWarming() }
        HotkeyCenter.shared.handler = { action in
            switch action {
            case .area: CaptureCoordinator.shared.captureArea()
            case .fullscreen: CaptureCoordinator.shared.captureFullscreen()
            case .record: break   // M3
            }
        }
        HotkeyCenter.shared.install()
        installStatusItem()
        Onboarding.shared.showIfNeeded()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kapture")
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Area", action: #selector(menuArea), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Capture Fullscreen", action: #selector(menuFullscreen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Library Folder", action: #selector(menuLibrary), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kapture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuArea() { CaptureCoordinator.shared.captureArea() }
    @objc private func menuFullscreen() { CaptureCoordinator.shared.captureFullscreen() }
    @objc private func menuLibrary() { NSWorkspace.shared.open(Settings.shared.libraryRoot) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
    withExtendedLifetime(delegate) { app.run() }
}
