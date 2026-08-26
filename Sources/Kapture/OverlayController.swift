// Quick Access Overlay (M1): stacked capture panels in the bottom corner with hover chrome.
// Keep and discard are distinct one-gesture actions (product spec §2.0): × / ⌘W keeps,
// trash / ⌘⌫ / swipe-toward-edge discards into the 7-day trash. space = Quick Look.
// Beyond 5 the pile collapses into a "+n" card. Right-click menu on every card.
import AppKit
import Quartz
import KaptureCore
import KaptureDesign
import KaptureEditor

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panels: [OverlayPanel] = []
    private var collapseChip: CollapseChip?
    private var fannedOut = false
    var library: Library?
    weak var hoveredPanel: OverlayPanel?   // consulted by the event-tap tier

    func show(record: CaptureRecord, fileURL: URL, image: CGImage, from sourceRect: NSRect? = nil) {
        let panel = OverlayPanel(record: record, fileURL: fileURL, image: image) { [weak self] panel in
            self?.remove(panel)
        }
        panels.append(panel)
        fannedOut = false

        guard let source = sourceRect, !Tokens.reduceMotion, let screen = NSScreen.main else {
            layout()
            panel.present()
            return
        }
        // fly the capture from its on-screen rect down into the corner slot
        let target = cornerSlotFrame(on: screen)

        let flight = NSWindow(contentRect: source, styleMask: .borderless, backing: .buffered, defer: false)
        flight.isOpaque = false
        flight.backgroundColor = .clear
        flight.level = .statusBar
        flight.hasShadow = true
        flight.ignoresMouseEvents = true
        let iv = NSImageView(frame: .zero)
        iv.image = NSImage(cgImage: image, size: .zero)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = Tokens.radiusOverlay
        iv.layer?.masksToBounds = true
        flight.contentView = iv
        flight.orderFrontRegardless()

        panel.alphaValue = 0   // occupies its slot invisibly until the flight lands
        layout()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            flight.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // NSAnimationContext completions run on main
                panel.alphaValue = 1
                // re-derive the slot at landing time — the stack may have moved mid-flight
                self?.layout(animated: false)
                panel.orderFrontRegardless()
                panel.scheduleAutoClose()
                flight.orderOut(nil)
            }
        })
    }

    /// Re-show a capture as a card (e.g. returning from the editor with fresh pixels).
    func showCard(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) }),
              record.status != .trashed else { return }
        let url = library.root.appendingPathComponent(record.relPath)
        // decoding the flattened PNG is slow for big captures — keep it off the main actor
        Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            await MainActor.run {
                OverlayController.shared.show(record: record, fileURL: url, image: image)
            }
        }
    }

    func hideAll() {
        // order the panels out — an alpha-0 panel left ordered in still owns tracking areas,
        // which would keep feeding hoveredPanel and let the event tap swallow keys invisibly
        for panel in panels {
            Tokens.animate(0.2, { panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
        }
        hoveredPanel = nil
        collapseChip?.orderOut(nil)
    }

    func showAll() {
        layout()
        for panel in panels { Tokens.animate(0.2) { panel.animator().alphaValue = 1 } }
    }

    func fanOut() { fannedOut = true; layout() }

    func closeAllKeeping() {
        panels.forEach { $0.keepAndClose() }
    }

    private func remove(_ panel: OverlayPanel) {
        panels.removeAll { $0 === panel }
        layout()
    }

    /// The first (corner) stack slot — single source of the corner geometry for
    /// both the stack layout and the flight animation's landing target.
    private func cornerSlotFrame(on screen: NSScreen) -> NSRect {
        let size = Tokens.overlaySizes[Settings.shared.overlaySizeIndex]
        let x = Settings.shared.overlayOnLeftEdge
            ? screen.visibleFrame.minX + Tokens.cornerMargin
            : screen.visibleFrame.maxX - size.width - Tokens.cornerMargin
        return NSRect(x: x, y: screen.visibleFrame.minY + Tokens.cornerMargin,
                      width: size.width, height: size.height)
    }

    private func layout(animated: Bool = true) {
        guard let screen = NSScreen.main else { return }
        let slot = cornerSlotFrame(on: screen)
        let size = slot.size
        let x = slot.minX
        var y = slot.minY

        let visibleLimit = 5
        let showAll = fannedOut || panels.count <= visibleLimit
        let visible = showAll ? panels : Array(panels.suffix(visibleLimit))
        let hidden = showAll ? [] : Array(panels.prefix(panels.count - visibleLimit))

        for panel in visible.reversed() {   // newest nearest the corner
            let frame = NSRect(origin: CGPoint(x: x, y: y), size: size)
            if !panel.placed {
                // first placement is instant — a fresh panel must never slide in from its
                // initial (0,0) frame; it appears in place (flight or fade handles entrance)
                panel.setFrame(frame, display: true)
                panel.placed = true
            } else if animated {
                Tokens.animate(0.25) {
                    panel.animator().setFrame(frame, display: true)
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.setFrame(frame, display: true)
                panel.alphaValue = 1
            }
            panel.orderFrontRegardless()
            y += size.height + Tokens.stackGap
        }
        hidden.forEach { $0.orderOut(nil) }

        if hidden.isEmpty {
            collapseChip?.orderOut(nil)
        } else {
            let chip = collapseChip ?? CollapseChip { [weak self] in self?.fanOut() }
            collapseChip = chip
            chip.update(count: hidden.count)
            chip.setFrame(NSRect(x: x, y: y, width: size.width, height: 36), display: true)
            chip.orderFrontRegardless()
        }
    }
}

final class CollapseChip: NSPanel {
    init(onClick: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear
        level = .statusBar; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = ChipView(text: "", onClick: onClick)
    }

    func update(count: Int) {
        (contentView as? ChipView)?.text = "+\(count) more"
    }
}

final class ChipView: NSView {
    var text: String { didSet { needsDisplay = true } }
    let onClick: () -> Void
    init(text: String, onClick: @escaping () -> Void) {
        self.text = text; self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.radiusOverlay
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.radiusOverlay, yRadius: Tokens.radiusOverlay).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

final class OverlayPanel: NSPanel, QLPreviewPanelDataSource {
    let record: CaptureRecord
    let fileURL: URL
    let image: CGImage   // decoded pixels — reused for clipboard/drag instead of re-reading disk
    let onClose: (OverlayPanel) -> Void
    var placed = false   // set on first layout; first placement never animates
    private var autoCloseTimer: Timer?

    init(record: CaptureRecord, fileURL: URL, image: CGImage, onClose: @escaping (OverlayPanel) -> Void) {
        self.record = record; self.fileURL = fileURL; self.image = image; self.onClose = onClose
        let size = Tokens.overlaySizes[Settings.shared.overlaySizeIndex]
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = OverlayView(panel: self, image: image)
    }
    override var canBecomeKey: Bool { true }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        Tokens.animate(0.25) { self.animator().alphaValue = 1 }
        scheduleAutoClose()
    }

    // MARK: auto-close (paused while hovered)
    func scheduleAutoClose() {
        guard Settings.shared.autoCloseEnabled else { return }
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: Double(Settings.shared.autoCloseInterval),
                                              repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Settings.shared.autoCloseSaves ? self.saveToExportLocation() : self.keepAndClose()
            }
        }
    }

    func hoverChanged(_ hovering: Bool) {
        if hovering {
            autoCloseTimer?.invalidate(); autoCloseTimer = nil
            OverlayController.shared.hoveredPanel = self
        } else {
            scheduleAutoClose()
            if OverlayController.shared.hoveredPanel === self { OverlayController.shared.hoveredPanel = nil }
        }
    }

    // MARK: keep / discard
    /// Mark the capture kept in the library — every "walk away with it" gesture funnels here.
    func markKept() {
        try? OverlayController.shared.library?.setStatus(record.id, .kept)
    }

    func keepAndClose() {
        markKept()
        fadeOut()
    }

    func discard() {
        var discarded = false
        if let library = OverlayController.shared.library,
           let fresh = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: record.id) }) {
            do {
                try library.discard(fresh)
                discarded = true
            } catch { Log.store.error("discard failed: \(error)") }
        }
        guard discarded else { fadeOut(); return }   // no false discard feedback
        Sounds.play("Bottle")
        slideOff()
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([fileURL as NSURL, NSImage(cgImage: image, size: .zero)])
        keepAndClose()
    }

    func saveToExportLocation() {
        let dest = Library.uniqueURL(in: Settings.shared.exportLocation,
                                     base: fileURL.deletingPathExtension().lastPathComponent,
                                     ext: fileURL.pathExtension)
        do { try FileManager.default.copyItem(at: fileURL, to: dest) }
        catch { Log.store.error("export failed: \(error)") }
        keepAndClose()
    }

    func saveAs() {
        markKept()
        let save = NSSavePanel()
        save.nameFieldStringValue = fileURL.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        save.begin { [weak self] response in
            guard let self, response == .OK, let url = save.url else { return }
            try? FileManager.default.copyItem(at: self.fileURL, to: url)
            Task { @MainActor in self.fadeOut() }
        }
    }

    func pin() {
        PinController.shared.pin(fileURL: fileURL)
        keepAndClose()
    }

    func edit() {
        markKept()
        EditorController.shared.open(recordID: record.id)
        fadeOut()
    }

    /// The one overlay shortcut table (used by both the click-to-key tier and the AX event
    /// tap): space → Quick Look; ⌘⌫ discard; ⌘W keep; ⌘C copy; ⌘S save; ⌘E edit.
    /// Strict modifiers: space with none, letters/delete with command only.
    @discardableResult
    func performShortcut(command: Bool, keyCode: UInt16, characters: String?, plainSpace: Bool) -> Bool {
        if plainSpace && keyCode == 49 { quickLook(); return true }        // space
        guard command else { return false }
        if keyCode == 51 { discard(); return true }                        // ⌘⌫
        switch characters {
        case "w": keepAndClose(); return true
        case "c": copyToClipboard(); return true
        case "s": saveToExportLocation(); return true
        case "e": edit(); return true
        default: return false
        }
    }

    func quickLook() {
        makeKey()
        guard let ql = QLPreviewPanel.shared() else { return }
        ql.dataSource = self
        ql.makeKeyAndOrderFront(nil)
        ql.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { fileURL as NSURL }

    func fadeOut() {
        Tokens.animate(0.2, { self.animator().alphaValue = 0 }) {
            self.orderOut(nil)
            self.onClose(self)
        }
    }

    func slideOff() {
        let dx: CGFloat = Settings.shared.overlayOnLeftEdge ? -(frame.width + 40) : frame.width + 40
        Tokens.animate(0.25, {
            self.animator().setFrame(self.frame.offsetBy(dx: dx, dy: 0), display: true)
            self.animator().alphaValue = 0
        }) {
            self.orderOut(nil)
            self.onClose(self)
        }
    }
}

final class OverlayView: NSView, NSDraggingSource {
    unowned let panel: OverlayPanel
    let image: CGImage
    var hovering = false {
        didSet {
            needsDisplay = true
            chrome.isHidden = !hovering
            trashButton.isHidden = !hovering
            panel.hoverChanged(hovering)
        }
    }
    let chrome = NSStackView()
    private var trashButton: NSButton!
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 22),
            b.heightAnchor.constraint(equalToConstant: 22),
        ])
        return b
    }

    init(panel: OverlayPanel, image: CGImage) {
        self.panel = panel; self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.radiusOverlay
        layer?.masksToBounds = true

        chrome.orientation = .horizontal
        chrome.spacing = 4
        chrome.addArrangedSubview(button("xmark", "Keep & close (⌘W)", #selector(closeTapped)))
        chrome.addArrangedSubview(NSView())
        chrome.addArrangedSubview(button("doc.on.doc", "Copy (⌘C)", #selector(copyTapped)))
        chrome.addArrangedSubview(button("square.and.arrow.down", "Save (⌘S)", #selector(saveTapped)))
        chrome.addArrangedSubview(button("pencil", "Edit (⌘E)", #selector(editTapped)))
        chrome.addArrangedSubview(button("pin", "Pin to screen", #selector(pinTapped)))
        chrome.isHidden = true
        addSubview(chrome)
        chrome.translatesAutoresizingMaskIntoConstraints = false

        trashButton = button("trash", "Discard (⌘⌫) — recoverable for 7 days", #selector(discardTapped))
        trashButton.isHidden = true
        addSubview(trashButton)

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chrome.heightAnchor.constraint(equalToConstant: 22),
            trashButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func closeTapped() { panel.keepAndClose() }
    @objc func copyTapped() { panel.copyToClipboard() }
    @objc func saveTapped() { panel.saveToExportLocation() }
    @objc func pinTapped() { panel.pin() }
    @objc func editTapped() { panel.edit() }
    @objc func discardTapped() { panel.discard() }

    // MARK: keyboard (click-to-key tier)
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { panel.edit(); return }
        panel.makeKey()
        panel.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        // caps lock is a latched state, not a chord — ignore it so shortcuts keep working
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if !panel.performShortcut(command: mods == .command, keyCode: event.keyCode,
                                  characters: event.charactersIgnoringModifiers,
                                  plainSpace: mods.isEmpty) {
            super.keyDown(with: event)
        }
    }

    // MARK: right-click
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit…", action: #selector(editTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pin to Screen", action: #selector(pinTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save As…", action: #selector(saveAsTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Discard", action: #selector(discardTapped), keyEquivalent: "").target = self
        return menu
    }
    @objc func saveAsTapped() { panel.saveAs() }
    @objc func revealTapped() {
        panel.markKept()
        NSWorkspace.shared.activateFileViewerSelecting([panel.fileURL])
    }

    // MARK: two-finger swipes — toward edge = discard, down = hide all
    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began: swipeX = 0; swipeY = 0
        case .changed:
            swipeX += event.scrollingDeltaX
            swipeY += event.scrollingDeltaY
        case .ended:
            let towardEdge = Settings.shared.overlayOnLeftEdge ? swipeX > 60 : swipeX < -60
            // natural scrolling: swiping content left gives positive deltaX; check both signs safely
            let horizontal = abs(swipeX) > 60 && abs(swipeX) > abs(swipeY)
            let down = swipeY < -40 && abs(swipeY) > abs(swipeX)
            if horizontal && (towardEdge || abs(swipeX) > 100) { panel.discard() }
            else if down { OverlayController.shared.hideAll() }
        default: break
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: panel.fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(cgImage: image, size: bounds.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { panel.keepAndClose() }   // close-after-drag default
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        // aspect-fill: the layer's masksToBounds crops the overflow
        let r = Tokens.aspectFill(CGSize(width: image.width, height: image.height), in: bounds)
        ctx.draw(image, in: r)
        if hovering {
            // scrim bands sized to the 22pt button rows + 5pt insets
            ctx.setFillColor(Tokens.overlayScrim.cgColor)
            ctx.fill(CGRect(x: 0, y: bounds.height - 32, width: bounds.width, height: 32))
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 32))
        }
    }
}
