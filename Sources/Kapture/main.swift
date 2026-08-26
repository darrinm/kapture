import AppKit
import KaptureCore
import KaptureCapture
import KaptureEditor

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try KaptureCore.Database()
            let library = try Library(db: db)
            CaptureCoordinator.shared.library = library
            OverlayController.shared.library = library
            EditorController.shared.library = library
        } catch {
            Log.shell.error("store init failed: \(error)")
        }

        // Only warm the content cache once permission exists — an unauthorized SCShareableContent
        // call at launch triggers the OS permission dialog on top of our onboarding.
        if ScreenshotService.hasPermission {
            Task { await ContentCache.shared.startWarming() }
        }
        HotkeyCenter.shared.handler = { action in
            switch action {
            case .area: CaptureCoordinator.shared.captureArea()
            case .fullscreen: CaptureCoordinator.shared.captureFullscreen()
            case .previousArea: CaptureCoordinator.shared.capturePreviousArea()
            case .pinClipboard: PinController.shared.pinFromClipboard()
            case .record: break   // M3
            }
        }
        HotkeyCenter.shared.install()
        EventTapCenter.shared.startIfPossible()   // silent no-op without the Accessibility grant
        installStatusItem()
        Onboarding.shared.showIfNeeded()
        CompetitorWatch.shared.start()

        // trash sweep at launch + every 6h (7-day retention)
        let library = CaptureCoordinator.shared.library
        Task.detached(priority: .utility) { library?.sweepTrash() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task.detached(priority: .utility) { library?.sweepTrash() }
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kapture")
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Area", action: #selector(menuArea), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Capture Window", action: #selector(menuWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Capture Fullscreen", action: #selector(menuFullscreen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Capture All Displays", action: #selector(menuAllDisplays), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Capture Previous Area", action: #selector(menuPreviousArea), keyEquivalent: "").target = self
        let timerMenu = NSMenu()
        for s in [3, 5, 10] {
            let item = NSMenuItem(title: "Capture Area in \(s)s", action: #selector(menuTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = s
            timerMenu.addItem(item)
        }
        let timerItem = NSMenuItem(title: "Self-Timer", action: nil, keyEquivalent: "")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pin from Clipboard", action: #selector(menuPinClipboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restore Last Discarded", action: #selector(menuRestore), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Overlays", action: #selector(menuShowOverlays), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close All Overlays (keep)", action: #selector(menuCloseOverlays), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close All Pins", action: #selector(menuClosePins), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Library Folder", action: #selector(menuLibrary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kapture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuPinClipboard() { PinController.shared.pinFromClipboard() }
    @objc private func menuRestore() {
        guard let library = CaptureCoordinator.shared.library else { return }
        if (try? library.restoreLastDiscarded()) != nil {
            Sounds.play("Pop")
        }
    }
    @objc private func menuShowOverlays() { OverlayController.shared.showAll() }
    @objc private func menuCloseOverlays() { OverlayController.shared.closeAllKeeping() }
    @objc private func menuClosePins() { PinController.shared.closeAll() }

    @objc private func menuArea() { CaptureCoordinator.shared.captureArea() }
    @objc private func menuWindow() { CaptureCoordinator.shared.captureWindow() }
    @objc private func menuFullscreen() { CaptureCoordinator.shared.captureFullscreen() }
    @objc private func menuAllDisplays() { CaptureCoordinator.shared.captureFullscreen(allDisplays: true) }
    @objc private func menuPreviousArea() { CaptureCoordinator.shared.capturePreviousArea() }
    @objc private func menuTimer(_ sender: NSMenuItem) { CaptureCoordinator.shared.captureAreaAfter(seconds: sender.tag) }
    @objc private func menuLibrary() { NSWorkspace.shared.open(Settings.shared.libraryRoot) }
    @objc private func menuSettings() { SettingsWindowController.shared.show() }
}

// TCC helper mode: a fresh process gets a fresh Screen Recording evaluation, unlike the
// long-running app (TCC evaluates at launch). Onboarding polls this to detect the grant.
if CommandLine.arguments.contains("--tcc-check") {
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
    withExtendedLifetime(delegate) { app.run() }
}
