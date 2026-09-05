import AppKit
import SwiftUI
import KaptureCore
import KaptureCapture
import KaptureDesign
import KaptureEditor
import KaptureRecording
import KaptureIntelligence

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try KaptureCore.Database()
            let library = try Library(db: db, exclusive: true)
            CaptureCoordinator.shared.library = library
            OverlayController.shared.library = library
            EditorController.shared.library = library
            TrimmerController.shared.library = library
            LibraryWindowController.shared.library = library
            ShareCoordinator.shared.library = library
            Task {
                await IngestQueue.shared.configure(library: library)
                await IngestQueue.shared.resume()   // pick up jobs left by a previous run
            }
            EditorController.shared.onFlattened = { id in
                OverlayController.shared.showCard(recordID: id)
            }
            EditorController.shared.onSaveFailed = { _, error in Toast.show(error, while: "Saving the edit") }
            EditorController.shared.onWindowOpened = { ActivationPolicy.acquire() }
            EditorController.shared.onWindowClosed = { ActivationPolicy.release() }
        } catch {
            Log.shell.error("store init failed: \(error)")
            // Without a library every capture is dropped on the floor. That cannot be silent —
            // least of all for "another Kapture already has it open", which is the one the user
            // can fix.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Kapture can't open its library"
            alert.informativeText = error.localizedDescription
            alert.runModal()
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
            case .library: LibraryWindowController.shared.show()
            case .captureText: CaptureCoordinator.shared.captureText()
            }
        }
        RecordingCoordinator.shared.library = CaptureCoordinator.shared.library
        RecordingCoordinator.shared.onStatusChanged = { [weak self] status in
            self?.renderStatusItem(status)
        }
        HotkeyCenter.shared.onBindingsChanged = { [weak self] in self?.refreshMenuShortcuts() }
        HotkeyCenter.shared.install()
        EventTapCenter.shared.startIfPossible()   // silent no-op without the Accessibility grant
        installStatusItem()
        Onboarding.shared.showIfNeeded()
        ShortcutConflictWatch.shared.start()

        // trash sweep at launch + every 6h (7-day retention)
        let library = CaptureCoordinator.shared.library
        Task.detached(priority: .utility) { library?.sweepTrash() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task.detached(priority: .utility) { library?.sweepTrash() }
        }
    }

    /// The one place the menu-bar item is drawn: every recording-state change arrives here as a
    /// RecordingStatus and is rendered top to bottom, so the glyph, the timer text and the
    /// click behavior can never be updated by three callbacks that disagree.
    private func renderStatusItem(_ status: RecordingStatus) {
        guard let button = statusItem.button else { return }
        switch status {
        case .idle:
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kapture")
            button.contentTintColor = nil
            button.title = ""
            button.toolTip = nil
            button.target = nil
            button.action = nil
            statusItem.menu = statusMenu
        case .active(let elapsed, let paused):
            button.image = recordingSymbol(paused ? "pause.circle.fill" : "stop.circle.fill",
                                           label: paused ? "Paused" : "Stop recording")
            button.imagePosition = .imageLeft
            button.title = paused ? " ⏸ " + elapsed : " " + elapsed
            button.toolTip = "Click to stop recording (\(HotkeyCenter.shared.binding(for: .record).display)) · right-click for more"
            // while recording the item is a stop BUTTON, not a menu opener
            statusItem.menu = nil
            button.target = self
            button.action = #selector(AppDelegate.statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Accent-tinted, non-template so the red survives the menu bar's template tinting.
    private func recordingSymbol(_ name: String, label: String) -> NSImage? {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(paletteColors: [Tokens.accent]))
        symbol?.isTemplate = false
        return symbol
    }

    private func installStatusItem() {
        // variableLength: the item widens for the recording timer (squareLength clips it away)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kapture")
        // key equivalents derive from the hotkey table, so the menu can never disagree with it.
        // The action is kept on the item so a rebind can refresh the equivalent in place.
        func item(_ title: String, _ action: Selector,
                  hotkey: HotkeyCenter.Action? = nil) -> NSMenuItem {
            let binding = hotkey.map { HotkeyCenter.shared.binding(for: $0) }
            let i = NSMenuItem(title: title, action: action, keyEquivalent: binding?.keyEquivalent ?? "")
            i.keyEquivalentModifierMask = binding?.cocoaModifiers ?? []
            i.representedObject = hotkey
            i.target = self
            return i
        }
        let menu = NSMenu()
        menu.addItem(item("Capture Area", #selector(menuArea), hotkey: .area))
        menu.addItem(item("Capture Window", #selector(menuWindow)))
        menu.addItem(item("Capture Fullscreen", #selector(menuFullscreen), hotkey: .fullscreen))
        menu.addItem(item("Capture All Displays", #selector(menuAllDisplays)))
        menu.addItem(item("Capture Previous Area", #selector(menuPreviousArea), hotkey: .previousArea))
        menu.addItem(item("Capture Text", #selector(menuCaptureText), hotkey: .captureText))
        menu.addItem(.separator())
        // one item, title swapped by validateMenuItem — same idiom as Pause/Resume below
        menu.addItem(item("Record Area or Window", #selector(menuRecord), hotkey: .record))
        menu.addItem(item("Pause Recording", #selector(menuPauseRecording)))
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
        menu.addItem(item("Library…", #selector(menuLibraryWindow), hotkey: .library))
        menu.addItem(withTitle: "Open Library Folder", action: #selector(menuLibrary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kapture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu = menu
        statusItem.menu = menu
    }

    /// Re-reads the hotkey table into the menu after a rebind, so the menu never advertises a
    /// shortcut that no longer works.
    private func refreshMenuShortcuts() {
        guard let statusMenu else { return }
        for item in statusMenu.items {
            guard let action = item.representedObject as? HotkeyCenter.Action else { continue }
            let binding = HotkeyCenter.shared.binding(for: action)
            item.keyEquivalent = binding.keyEquivalent
            item.keyEquivalentModifierMask = binding.cocoaModifiers
        }
    }

    @objc private func menuRecord() { RecordingCoordinator.shared.toggle() }
    @objc private func menuPauseRecording() { RecordingCoordinator.shared.togglePause() }

    /// While recording, a left click on the status item stops; a right click opens the menu.
    @objc func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)   // modal: returns once the menu closes
            // back to stop-button behavior — but only if we're still recording. Picking
            // "Stop Recording" from that menu already restored the normal menu, and clearing
            // it here would leave the item with neither a menu nor an action.
            if RecordingCoordinator.shared.isRecording { statusItem.menu = nil }
        } else {
            RecordingCoordinator.shared.stop()
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuRecord) {
            item.title = RecordingCoordinator.shared.isRecording ? "Stop Recording" : "Record Area or Window"
            return true
        }
        if item.action == #selector(menuPauseRecording) {
            item.title = RecordingCoordinator.shared.isPaused ? "Resume Recording" : "Pause Recording"
            return RecordingCoordinator.shared.isRecording
        }
        if item.action == #selector(menuShowOverlays) {
            return OverlayController.shared.tucked   // the tab is the usual way back; this is the other
        }
        if item.action == #selector(menuCheckForUpdates) {
            return UpdaterController.shared.canCheckNow
        }
        return true
    }

    @objc private func menuCheckForUpdates() { UpdaterController.shared.checkForUpdates() }
    @objc private func menuPinClipboard() { PinController.shared.pinFromClipboard() }
    @objc private func menuRestore() {
        guard let library = CaptureCoordinator.shared.library else { return }
        let restored: CaptureRecord?
        do { restored = try library.restoreLastDiscarded() }
        catch { Toast.show(error, while: "Restore"); return }
        guard let restored else { return }
        Sounds.play("Pop")
        // discard cancelled its ingest job; an unnamed capture needs another pass
        if restored.aiState.acceptsName {
            Task { await IngestQueue.shared.enqueue(restored.id, after: 0) }
        }
    }
    @objc private func menuShowOverlays() { OverlayController.shared.untuck() }
    @objc private func menuCloseOverlays() { OverlayController.shared.closeAllKeeping() }
    @objc private func menuClosePins() { PinController.shared.closeAll() }

    @objc private func menuArea() { CaptureCoordinator.shared.captureArea() }
    @objc private func menuWindow() { CaptureCoordinator.shared.captureWindow() }
    @objc private func menuFullscreen() { CaptureCoordinator.shared.captureFullscreen() }
    @objc private func menuAllDisplays() { CaptureCoordinator.shared.captureFullscreen(allDisplays: true) }
    @objc private func menuPreviousArea() { CaptureCoordinator.shared.capturePreviousArea() }
    @objc private func menuTimer(_ sender: NSMenuItem) { CaptureCoordinator.shared.captureAreaAfter(seconds: sender.tag) }
    @objc private func menuCaptureText() { CaptureCoordinator.shared.captureText() }
    @objc private func menuLibraryWindow() { LibraryWindowController.shared.show() }
    @objc private func menuLibrary() { NSWorkspace.shared.open(Settings.shared.libraryRoot) }
    @objc private func menuSettings() { SettingsWindowController.shared.show() }
}

// TCC helper mode: a fresh process gets a fresh Screen Recording evaluation, unlike the
// long-running app (TCC evaluates at launch). Onboarding polls this to detect the grant.
if CommandLine.arguments.contains("--tcc-check") {
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
}

// Ingest smoke mode: OCRs every un-indexed capture immediately (no debounce) and reports, or
// with --dry-run previews the names naming would produce. Driven by scripts/test-ingest.command.
if CommandLine.arguments.contains("--ingest-now") {
    Diagnostics.runIngestNow()
}

// GIF-exporter smoke mode: converts the given movie and prints the result.
// Driven by scripts/gif-test.command — that script is the entry point, this is the harness.
if let i = CommandLine.arguments.firstIndex(of: "--gif-test"), CommandLine.arguments.count > i + 1 {
    let path = CommandLine.arguments[i + 1]
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let r = try await GIFExporter.export(movie: URL(fileURLWithPath: path))
            print("gif-ok \(r.url.path) \(r.width)x\(r.height) \(r.duration)s \(Library.byteSize(of: r.url)) bytes")
        } catch {
            print("gif-failed: \(error)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Settings screenshot mode: renders each Settings pane to a PNG so the window can be reviewed
// as it actually lays out. Renders offscreen through NSHostingView rather than capturing the
// screen: no Screen Recording round trip, nothing appears on the user's display, and it still
// works while the screen is locked (ScreenCaptureKit blocks there).
//
// The sidebar comes out as a blank white block here. `cacheDisplay` draws the view tree without
// the window server, and the sidebar is a vibrant material that only the compositor can paint —
// this tells you about the panes, not about the list beside them. Use `--real` for that.
//   Kapture.app/Contents/MacOS/Kapture --settings-shot /tmp/settings
if let i = CommandLine.arguments.firstIndex(of: "--settings-shot"), CommandLine.arguments.count > i + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // --real opens the window the menu item opens and checks it came up at its intended size.
    // This is the regression it exists for: the hosting controller takes the SwiftUI view's
    // ideal size, and when that view had no definite height the window opened as an 84-point
    // sliver with every pane clipped out of sight.
    if CommandLine.arguments.contains("--real") {
        Task { @MainActor in
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .milliseconds(1200))
            guard let window = NSApp.windows.first(where: {
                      $0.identifier == SettingsWindowController.windowIdentifier
                  }),
                  let content = window.contentView else {
                print("settings-probe: no window"); exit(1)
            }
            let expected = SettingsView.windowSize
            print("settings-probe: content \(content.frame.size), expected \(expected)")
            // The pane's own width is this minus the sidebar's fixed slice, so there is nothing
            // separate to check: a window this size always leaves the panes room, and one that
            // doesn't fails here first.
            let ok = content.frame.height >= expected.height - 60
                && content.frame.width >= expected.width - 60
            print("settings-probe: \(ok ? "ok" : "COLLAPSED")")
            exit(ok ? 0 : 1)
        }
        app.run()
    }

    let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Derived from the enum rather than listed again, so a pane added to Settings is a pane that
    // gets shot. The numbers only order the files on disk.
    let panes = SettingsView.Tab.allCases.enumerated().map {
        ("\($0.offset + 1)-\($0.element.title.lowercased())", $0.element)
    }

    Task { @MainActor in
        let selection = SettingsSelection()
        let host = NSHostingView(rootView: SettingsView(selection: selection))
        // the size the window actually opens at, sidebar included, so what is rendered here is
        // what a person sees rather than a differently-proportioned rehearsal of it
        host.frame = NSRect(origin: .zero, size: SettingsView.windowSize)
        // a window parked off the side of every display: SwiftUI needs one to lay out properly,
        // and nobody ever sees this one
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Kapture Settings"
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)

        for (name, tab) in panes {
            selection.tab = tab
            try? await Task.sleep(for: .milliseconds(500))   // let SwiftUI lay the pane out
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                print("no bitmap: \(name)"); continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                print("no png: \(name)"); continue
            }
            let url = directory.appendingPathComponent("\(name).png")
            try? data.write(to: url)
            print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        exit(0)
    }
    app.run()
}

// Stores the share token, read from stdin so it never lands in argv or a shell history. The app
// must write this item itself: a Keychain entry created by another tool (say /usr/bin/security)
// has an ACL that doesn't include Kapture, and every read then waits on a permission dialog.
//   printf %s "$TOKEN" | Kapture.app/Contents/MacOS/Kapture --set-share-token
if CommandLine.arguments.contains("--set-share-token") {
    let token = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    guard !token.isEmpty else {
        print("no token on stdin")
        exit(1)
    }
    Keychain.shareToken = token
    print(Keychain.shareToken == token ? "share token stored" : "keychain write failed")
    exit(Keychain.shareToken == token ? 0 : 1)
}

// Where this build keeps its secrets. "iCloud Keychain" means they reach the user's other Macs
// on their own; "this Mac only" means this copy is unentitled — a local build, or a release whose
// provisioning profile went missing.
if CommandLine.arguments.contains("--secrets-status") {
    print("share token:   \(Keychain.shareTokenStorage.rawValue)")
    print("anthropic key: \(Keychain.anthropicKeyStorage.rawValue)")
    exit(0)
}

// Share smoke mode: uploads a file through the real path — Keychain token, ShareService, the
// live endpoint — and prints the link, so sharing can be verified without driving the UI.
// `--share-test <file> [--delete]` deletes the link again afterwards.
if let i = CommandLine.arguments.firstIndex(of: "--share-test"), CommandLine.arguments.count > i + 1 {
    let path = CommandLine.arguments[i + 1]
    let cleanUp = CommandLine.arguments.contains("--delete")
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let link = try await ShareService.upload(fileURL: URL(fileURLWithPath: path))
            print("share-ok \(link.url.absoluteString) (\(link.bytes) bytes)")
            if cleanUp {
                try await ShareService.delete(id: link.id)
                print("share-deleted \(link.id)")
            }
        } catch {
            print("share-failed: \(error)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
    withExtendedLifetime(delegate) { app.run() }
}
