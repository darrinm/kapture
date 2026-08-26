import AppKit
import KaptureCore
import KaptureCapture
import KaptureEditor

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try KaptureCore.Database()
            let library = try Library(db: db)
            CaptureCoordinator.shared.library = library
            OverlayController.shared.library = library
            EditorController.shared.library = library
            TrimmerController.shared.library = library
            EditorController.shared.onFlattened = { id in
                OverlayController.shared.showCard(recordID: id)
            }
            EditorController.shared.onWindowOpened = { ActivationPolicy.acquire() }
            EditorController.shared.onWindowClosed = { ActivationPolicy.release() }
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
            case .record: RecordingCoordinator.shared.toggle()
            }
        }
        RecordingCoordinator.shared.library = CaptureCoordinator.shared.library
        RecordingCoordinator.shared.onStateChanged = { [weak self] recording in
            guard let button = self?.statusItem.button else { return }
            if recording {
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
                button.contentTintColor = NSColor(srgbRed: 0.78, green: 0.26, blue: 0.23, alpha: 1)
            } else {
                button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kapture")
                button.contentTintColor = nil
                button.title = ""
            }
        }
        RecordingCoordinator.shared.onTick = { [weak self] elapsed in
            guard let button = self?.statusItem.button else { return }
            button.title = " " + elapsed
            button.imagePosition = .imageLeft
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
        // key equivalents derive from the hotkey table, so the menu can never disagree with it
        func item(_ title: String, _ action: Selector,
                  hotkey: HotkeyCenter.Action? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: hotkey?.keyEquivalent ?? "")
            i.keyEquivalentModifierMask = hotkey?.cocoaModifiers ?? []
            i.target = self
            return i
        }
        let menu = NSMenu()
        menu.addItem(item("Capture Area", #selector(menuArea), hotkey: .area))
        menu.addItem(item("Capture Window", #selector(menuWindow)))
        menu.addItem(item("Capture Fullscreen", #selector(menuFullscreen), hotkey: .fullscreen))
        menu.addItem(item("Capture All Displays", #selector(menuAllDisplays)))
        menu.addItem(item("Capture Previous Area", #selector(menuPreviousArea), hotkey: .previousArea))
        menu.addItem(.separator())
        menu.addItem(item("Record Area or Window", #selector(menuRecord), hotkey: .record))
        menu.addItem(item("Stop Recording", #selector(menuStopRecording), hotkey: .record))
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
        menu.addItem(item("Pin from Clipboard", #selector(menuPinClipboard), hotkey: .pinClipboard))
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

    @objc private func menuRecord() { if !RecordingCoordinator.shared.isRecording { RecordingCoordinator.shared.start() } }
    @objc private func menuStopRecording() { RecordingCoordinator.shared.stop() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuRecord) { return !RecordingCoordinator.shared.isRecording }
        if item.action == #selector(menuStopRecording) { return RecordingCoordinator.shared.isRecording }
        return true
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
