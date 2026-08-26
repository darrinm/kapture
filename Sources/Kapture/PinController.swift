// Pins (impl spec §6): float a capture always-on-top. Drag to move, scroll to adjust opacity,
// double-click restores 100%, right-click: Lock (click-through), Copy, Close.
// Locked pins are closed from the menu bar's Pins submenu.
import AppKit
import KaptureCore
import KaptureDesign

@MainActor
final class PinController {
    static let shared = PinController()
    private(set) var pins: [PinPanel] = []

    func pin(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return }
        let panel = PinPanel(fileURL: fileURL, image: image) { [weak self] p in
            self?.pins.removeAll { $0 === p }
        }
        pins.append(panel)
        panel.orderFrontRegardless()
    }

    func pinFromClipboard() {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           NSImage(contentsOf: url) != nil {
            pin(fileURL: url)
        } else if let img = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
                  let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(ULID.generate()).png")
            try? png.write(to: tmp)
            pin(fileURL: tmp)
        }
    }

    func closeAll() {
        pins.forEach { $0.orderOut(nil) }
        pins.removeAll()
    }
}

final class PinPanel: NSPanel {
    let fileURL: URL
    let onClose: (PinPanel) -> Void
    var locked = false

    init(fileURL: URL, image: NSImage, onClose: @escaping (PinPanel) -> Void) {
        self.fileURL = fileURL; self.onClose = onClose
        // start at 50% of image point size, capped to 60% of screen
        var size = image.size
        let cap = (NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
        var scale = min(0.5, cap.width * 0.6 / max(size.width, 1), cap.height * 0.6 / max(size.height, 1))
        scale = max(scale, 0.1)
        size = CGSize(width: size.width * scale, height: size.height * scale)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        contentView = PinView(panel: self, image: image)
        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 24,
                                   y: screen.visibleFrame.maxY - size.height - 24))
        }
    }
    override var canBecomeKey: Bool { true }

    func toggleLock() {
        locked.toggle()
        ignoresMouseEvents = locked
    }

    func closePin() {
        orderOut(nil)
        onClose(self)
    }
}

final class PinView: NSImageView {
    unowned let panel: PinPanel
    private let closeButton = NSButton()

    init(panel: PinPanel, image: NSImage) {
        self.panel = panel
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor   // visible edge on any content

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pin")!
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.toolTip = "Close pin (esc)"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY * 0.01
        panel.alphaValue = min(1.0, max(0.2, panel.alphaValue + delta))
    }

    private var dragOffset: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { panel.alphaValue = 1.0; return }
        let mouseInScreen = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouseInScreen.x - panel.frame.origin.x,
                             y: mouseInScreen.y - panel.frame.origin.y)
        panel.makeKey()
        panel.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragOffset else { return }
        let mouseInScreen = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouseInScreen.x - offset.x, y: mouseInScreen.y - offset.y))
    }

    override func mouseUp(with event: NSEvent) { dragOffset = nil }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var origin = panel.frame.origin
        switch event.keyCode {
        case 123: origin.x -= step   // ←
        case 124: origin.x += step   // →
        case 125: origin.y -= step   // ↓
        case 126: origin.y += step   // ↑
        case 53: panel.closePin(); return  // esc
        default: super.keyDown(with: event); return
        }
        panel.setFrameOrigin(origin)
    }
    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: panel.locked ? "Unlock" : "Lock (click-through)",
                     action: #selector(lockTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Pin", action: #selector(closeTapped), keyEquivalent: "").target = self
        return menu
    }
    @objc func lockTapped() { panel.toggleLock() }
    @objc func copyTapped() {
        NSPasteboard.general.clearContents()
        if let img = image { NSPasteboard.general.writeObjects([img]) }
    }
    @objc func closeTapped() { panel.closePin() }
}
