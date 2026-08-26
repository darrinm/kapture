// Quick Access Overlay (M1): stacked capture panels in the bottom corner with hover chrome.
// Keep and discard are distinct one-gesture actions (product spec §2.0): × / ⌘W keeps,
// trash / ⌘⌫ / swipe-toward-edge discards into the 7-day trash. space = Quick Look.
// Beyond 5 the pile collapses into a "+n" card. Right-click menu on every card.
import AppKit
import Quartz
import KaptureCore
import KaptureDesign

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panels: [OverlayPanel] = []
    private var collapseChip: CollapseChip?
    private var fannedOut = false
    var library: Library?

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
        let size = Tokens.overlaySizes[Settings.shared.overlaySizeIndex]
        let x = Settings.shared.overlayOnLeftEdge
            ? screen.visibleFrame.minX + Tokens.cornerMargin
            : screen.visibleFrame.maxX - size.width - Tokens.cornerMargin
        let target = NSRect(x: x, y: screen.visibleFrame.minY + Tokens.cornerMargin,
                            width: size.width, height: size.height)

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
        }, completionHandler: {
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            flight.orderOut(nil)
        })
    }

    func hideAll() {
        for panel in panels { Tokens.animate(0.2) { panel.animator().alphaValue = 0 } }
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

    private func layout(animated: Bool = true) {
        guard let screen = NSScreen.main else { return }
        let size = Tokens.overlaySizes[Settings.shared.overlaySizeIndex]
        let onLeft = Settings.shared.overlayOnLeftEdge
        let x = onLeft ? screen.visibleFrame.minX + Tokens.cornerMargin
                       : screen.visibleFrame.maxX - size.width - Tokens.cornerMargin
        var y = screen.visibleFrame.minY + Tokens.cornerMargin

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

        collapseChip?.orderOut(nil)
        collapseChip = nil
        if !hidden.isEmpty {
            let chip = CollapseChip(count: hidden.count) { [weak self] in self?.fanOut() }
            chip.setFrame(NSRect(x: x, y: y, width: size.width, height: 36), display: true)
            chip.orderFrontRegardless()
            collapseChip = chip
        }
    }
}

final class CollapseChip: NSPanel {
    init(count: Int, onClick: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear
        level = .statusBar; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ChipView(text: "+\(count) more", onClick: onClick)
        contentView = view
    }
}

final class ChipView: NSView {
    let text: String
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
    let onClose: (OverlayPanel) -> Void
    var placed = false   // set on first layout; first placement never animates

    init(record: CaptureRecord, fileURL: URL, image: CGImage, onClose: @escaping (OverlayPanel) -> Void) {
        self.record = record; self.fileURL = fileURL; self.onClose = onClose
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
    }

    // MARK: keep / discard
    func keepAndClose() {
        try? OverlayController.shared.library?.setStatus(record.id, .kept)
        fadeOut()
    }

    func discard() {
        if let library = OverlayController.shared.library,
           let fresh = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: record.id) }) {
            try? library.discard(fresh)
        }
        NSSound(named: "Bottle")?.play()
        slideOff()
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([fileURL as NSURL])
        if let img = NSImage(contentsOf: fileURL) { NSPasteboard.general.writeObjects([img]) }
        keepAndClose()
    }

    func saveToExportLocation() {
        let dest = Settings.shared.exportLocation.appendingPathComponent(fileURL.lastPathComponent)
        try? FileManager.default.copyItem(at: fileURL, to: dest)
        keepAndClose()
    }

    func saveAs() {
        try? OverlayController.shared.library?.setStatus(record.id, .kept)
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

    func quickLook() {
        makeKey()
        guard let ql = QLPreviewPanel.shared() else { return }
        ql.dataSource = self
        ql.makeKeyAndOrderFront(nil)
        ql.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { fileURL as NSURL }

    private func fadeOut() {
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
    var hovering = false { didSet { needsDisplay = true; chrome.isHidden = !hovering; trashButton.isHidden = !hovering } }
    let chrome = NSStackView()
    let trashButton = NSButton()
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0

    init(panel: OverlayPanel, image: CGImage) {
        self.panel = panel; self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.radiusOverlay
        layer?.masksToBounds = true

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
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
        chrome.orientation = .horizontal
        chrome.spacing = 4
        chrome.addArrangedSubview(button("xmark", "Keep & close (⌘W)", #selector(closeTapped)))
        chrome.addArrangedSubview(NSView())
        chrome.addArrangedSubview(button("doc.on.doc", "Copy (⌘C)", #selector(copyTapped)))
        chrome.addArrangedSubview(button("square.and.arrow.down", "Save (⌘S)", #selector(saveTapped)))
        chrome.addArrangedSubview(button("pin", "Pin to screen", #selector(pinTapped)))
        chrome.isHidden = true
        addSubview(chrome)
        chrome.translatesAutoresizingMaskIntoConstraints = false

        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Discard")!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!
        trashButton.isBordered = false
        trashButton.contentTintColor = .white
        trashButton.toolTip = "Discard (⌘⌫) — recoverable for 7 days"
        trashButton.target = self
        trashButton.action = #selector(discardTapped)
        trashButton.isHidden = true
        addSubview(trashButton)
        trashButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chrome.heightAnchor.constraint(equalToConstant: 22),
            trashButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trashButton.widthAnchor.constraint(equalToConstant: 22),
            trashButton.heightAnchor.constraint(equalToConstant: 22),
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
    @objc func discardTapped() { panel.discard() }

    // MARK: keyboard (click-to-key tier)
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        panel.makeKey()
        panel.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if event.keyCode == 49 { panel.quickLook(); return }                    // space
        if cmd && event.keyCode == 51 { panel.discard(); return }              // ⌘⌫
        switch (cmd, event.charactersIgnoringModifiers) {
        case (true, "w"): panel.keepAndClose()
        case (true, "c"): panel.copyToClipboard()
        case (true, "s"): panel.saveToExportLocation()
        default: super.keyDown(with: event)
        }
    }

    // MARK: right-click
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
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
        try? OverlayController.shared.library?.setStatus(panel.record.id, .kept)
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
        item.setDraggingFrame(bounds, contents: NSImage(contentsOf: panel.fileURL))
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
        let imgAspect = CGFloat(image.width) / CGFloat(image.height)
        let viewAspect = bounds.width / bounds.height
        var r = bounds
        if imgAspect > viewAspect {
            let w = bounds.height * imgAspect
            r = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        } else {
            let h = bounds.width / imgAspect
            r = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        }
        ctx.draw(image, in: r)
        if hovering {
            // scrim bands sized to the 22pt button rows + 5pt insets
            ctx.setFillColor(Tokens.overlayScrim.cgColor)
            ctx.fill(CGRect(x: 0, y: bounds.height - 32, width: bounds.width, height: 32))
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 32))
        }
    }
}
