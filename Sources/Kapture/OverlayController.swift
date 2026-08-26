// Quick Access Overlay (M0 subset): single-capture panel in the bottom corner with hover chrome —
// close (keep), copy, save, discard-to-trash placeholder — and drag-out of the concrete file.
// Stacking, swipes, Quick Look, auto-close, and event-tap shortcuts land in M1.
import AppKit
import KaptureCore
import KaptureDesign

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panels: [OverlayPanel] = []
    var library: Library?

    func show(record: CaptureRecord, fileURL: URL, image: CGImage) {
        let panel = OverlayPanel(record: record, fileURL: fileURL, image: image) { [weak self] panel in
            self?.remove(panel)
        }
        panels.append(panel)
        layout()
        panel.present()
    }

    private func remove(_ panel: OverlayPanel) {
        panels.removeAll { $0 === panel }
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let size = Tokens.overlaySizes[Settings.shared.overlaySizeIndex]
        var y = screen.visibleFrame.minY + Tokens.cornerMargin
        for panel in panels.reversed() {   // newest nearest the corner
            let x = Settings.shared.overlayOnLeftEdge
                ? screen.visibleFrame.minX + Tokens.cornerMargin
                : screen.visibleFrame.maxX - size.width - Tokens.cornerMargin
            Tokens.animate(0.25) {
                panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
            }
            y += size.height + Tokens.stackGap
        }
    }
}

final class OverlayPanel: NSPanel {
    let record: CaptureRecord
    let fileURL: URL
    let onClose: (OverlayPanel) -> Void

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
        isMovableByWindowBackground = false
        contentView = OverlayView(panel: self, image: image)
    }
    override var canBecomeKey: Bool { true }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        Tokens.animate(0.25) { self.animator().alphaValue = 1 }
    }

    func keepAndClose() {
        try? OverlayController.shared.library?.setStatus(record.id, .kept)
        fadeOut()
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

    private func fadeOut() {
        Tokens.animate(0.2, { self.animator().alphaValue = 0 }) {
            self.orderOut(nil)
            self.onClose(self)
        }
    }
}

final class OverlayView: NSView, NSDraggingSource {
    unowned let panel: OverlayPanel
    let image: CGImage
    var hovering = false { didSet { needsDisplay = true; chrome.isHidden = !hovering } }
    let chrome = NSStackView()

    init(panel: OverlayPanel, image: CGImage) {
        self.panel = panel; self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.radiusOverlay
        layer?.masksToBounds = true

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                             target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = tip
            return b
        }
        chrome.orientation = .horizontal
        chrome.spacing = 6
        chrome.addArrangedSubview(button("xmark", "Keep & close (⌘W)", #selector(closeTapped)))
        chrome.addArrangedSubview(NSView())
        chrome.addArrangedSubview(button("doc.on.doc", "Copy", #selector(copyTapped)))
        chrome.addArrangedSubview(button("square.and.arrow.down", "Save to export location", #selector(saveTapped)))
        chrome.isHidden = true
        addSubview(chrome)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func closeTapped() { panel.keepAndClose() }
    @objc func copyTapped() { panel.copyToClipboard() }
    @objc func saveTapped() { panel.saveToExportLocation() }

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
        // aspect-fill
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
            ctx.setFillColor(Tokens.overlayScrim.cgColor)
            ctx.fill(CGRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 30))
        }
    }
}
