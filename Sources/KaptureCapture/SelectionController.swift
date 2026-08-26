// Frozen-frame selection chrome: one borderless window per display showing that display's frozen
// frame, dimmed, with a rubber-band selection, crosshair guides, and a live dimensions label.
// esc cancels. ⇧ locks axis, ⌥ resizes from center. (Window mode / space-toggle: M0 follow-up.)
import AppKit
import KaptureCore
import KaptureDesign

public struct AreaSelection {
    public let frame: FrozenFrame
    public let rectInPoints: CGRect   // top-left origin, display-local points
}

@MainActor
public final class SelectionController {
    public static let shared = SelectionController()
    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<AreaSelection?, Never>?

    public func selectArea(frames: [FrozenFrame]) async -> AreaSelection? {
        finish(nil, resume: false)
        return await withCheckedContinuation { cont in
            continuation = cont
            windows = frames.map { frame in
                let w = SelectionWindow(frame: frame,
                    onDone: { [weak self] sel in self?.finish(sel, resume: true) },
                    onCancel: { [weak self] in self?.finish(nil, resume: true) })
                w.orderFrontRegardless()
                return w
            }
            NSCursor.crosshair.set()
        }
    }

    private func finish(_ sel: AreaSelection?, resume: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSCursor.arrow.set()
        if resume { continuation?.resume(returning: sel); continuation = nil }
    }
}

final class SelectionWindow: NSWindow {
    init(frame: FrozenFrame, onDone: @escaping (AreaSelection) -> Void, onCancel: @escaping () -> Void) {
        super.init(contentRect: frame.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionView(frame: frame, onDone: onDone, onCancel: onCancel)
        makeFirstResponder(contentView)
    }
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    let frozen: FrozenFrame
    let onDone: (AreaSelection) -> Void
    let onCancel: () -> Void
    var dragStart: CGPoint?
    var dragRect: CGRect?
    var mouse: CGPoint = .zero

    init(frame frozen: FrozenFrame, onDone: @escaping (AreaSelection) -> Void, onCancel: @escaping () -> Void) {
        self.frozen = frozen; self.onDone = onDone; self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }   // esc
    }

    override func mouseMoved(with event: NSEvent) { mouse = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { dragStart = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        mouse = p
        if event.modifierFlags.contains(.shift) {  // axis lock
            if abs(p.x - start.x) > abs(p.y - start.y) { p.y = start.y } else { p.x = start.x }
        }
        var rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                          width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.option) {  // center-out
            rect = CGRect(x: start.x - rect.width, y: start.y - rect.height,
                          width: rect.width * 2, height: rect.height * 2)
        }
        dragRect = rect
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let rect = dragRect, rect.width >= 2, rect.height >= 2 else { onCancel(); return }
        // view coords are bottom-left; convert to display-local top-left points
        let topLeft = CGRect(x: rect.origin.x, y: bounds.height - rect.maxY,
                             width: rect.width, height: rect.height)
        onDone(AreaSelection(frame: frozen, rectInPoints: topLeft))
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // frozen frame as background (flip to view coords)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(frozen.image, in: bounds)
        ctx.restoreGState()
        // dim everything…
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)
        if let rect = dragRect {
            // …except the selection: repaint the frozen pixels there
            let cropTopLeft = CGRect(x: rect.origin.x, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            if let crop = ScreenshotService.crop(frozen, rectInPoints: cropTopLeft) {
                ctx.draw(crop, in: rect)
            }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
            drawDimensions(rect)
        } else {
            // crosshair guides
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: mouse.x, y: 0), CGPoint(x: mouse.x, y: bounds.height),
                                             CGPoint(x: 0, y: mouse.y), CGPoint(x: bounds.width, y: mouse.y)])
        }
    }

    private func drawDimensions(_ rect: CGRect) {
        let px = Int(rect.width * frozen.scale)
        let py = Int(rect.height * frozen.scale)
        let text = "\(px) × \(py)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 5
        var origin = CGPoint(x: rect.maxX - size.width - pad * 2, y: rect.minY - size.height - pad * 2 - 4)
        if origin.y < 0 { origin.y = rect.minY + 4 }
        let bg = CGRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad * 2)
        let path = NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        path.fill()
        text.draw(at: CGPoint(x: bg.minX + pad, y: bg.minY + pad), withAttributes: attrs)
    }
}
