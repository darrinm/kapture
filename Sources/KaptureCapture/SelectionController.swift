// Frozen-frame selection chrome: one borderless window per display showing that display's frozen
// frame, dimmed, with a rubber-band selection, crosshair + magnifier loupe, and a live dimensions
// label. space toggles window mode (hover-highlight, click to capture the live window).
// esc cancels. ⇧ locks axis, ⌥ resizes from center.
import AppKit
import ScreenCaptureKit
import KaptureCore
import KaptureDesign

public struct AreaSelection {
    public let frame: FrozenFrame
    public let rectInPoints: CGRect   // top-left origin, display-local points
}

public enum SelectionResult {
    case area(AreaSelection)
    case window(SCWindow)
}

@MainActor
public final class SelectionController {
    public static let shared = SelectionController()
    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<SelectionResult?, Never>?

    public func select(frames: [FrozenFrame], windows scWindows: [SCWindow],
                       startInWindowMode: Bool = false) async -> SelectionResult? {
        finish(nil, resume: false)
        let candidates = scWindows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            windows = frames.map { frame in
                let w = SelectionWindow(frame: frame, scWindows: candidates,
                    startInWindowMode: startInWindowMode,
                    onDone: { [weak self] sel in self?.finish(sel, resume: true) },
                    onCancel: { [weak self] in self?.finish(nil, resume: true) })
                w.orderFrontRegardless()
                return w
            }
            // Activate: an inactive app swallows the first mouse-down as an activation click,
            // and NSCursor.hide() only takes effect for the active app.
            NSApp.activate(ignoringOtherApps: true)
            windows.first?.makeKey()
            NSCursor.hide()   // the drawn crosshair replaces the pointer entirely
        }
    }

    private func finish(_ sel: SelectionResult?, resume: Bool) {
        if !windows.isEmpty {
            NSCursor.unhide()
            NSApp.deactivate()   // hand focus back to the app the user was in
        }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if resume { continuation?.resume(returning: sel); continuation = nil }
    }
}

final class SelectionWindow: NSWindow {
    init(frame: FrozenFrame, scWindows: [SCWindow], startInWindowMode: Bool,
         onDone: @escaping (SelectionResult) -> Void, onCancel: @escaping () -> Void) {
        super.init(contentRect: frame.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionView(frame: frame, scWindows: scWindows,
                                    startInWindowMode: startInWindowMode, onDone: onDone, onCancel: onCancel)
        makeFirstResponder(contentView)
    }
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    let frozen: FrozenFrame
    let scWindows: [SCWindow]
    let onDone: (SelectionResult) -> Void
    let onCancel: () -> Void
    var windowMode: Bool
    var hoveredWindow: SCWindow?
    var dragStart: CGPoint?
    var dragRect: CGRect?
    var mouse: CGPoint = .zero

    init(frame frozen: FrozenFrame, scWindows: [SCWindow], startInWindowMode: Bool,
         onDone: @escaping (SelectionResult) -> Void, onCancel: @escaping () -> Void) {
        self.frozen = frozen; self.scWindows = scWindows; self.windowMode = startInWindowMode
        self.onDone = onDone; self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        // seed from the real cursor position so the loupe/crosshair start where the pointer is,
        // not at the view origin
        if let window {
            mouse = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            updateHover()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel()                                   // esc
        case 49:                                              // space: toggle window mode
            windowMode.toggle()
            dragStart = nil; dragRect = nil
            updateHover()
            needsDisplay = true
        default: break
        }
    }

    // MARK: coordinate conversions (CG global is top-left origin; NS global is bottom-left)
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func cgGlobal(fromView p: CGPoint) -> CGPoint {
        guard let screen = window?.screen else { return .zero }
        let ns = CGPoint(x: screen.frame.origin.x + p.x, y: screen.frame.origin.y + p.y)
        return CGPoint(x: ns.x, y: primaryHeight - ns.y)
    }

    private func viewRect(fromCG r: CGRect) -> CGRect {
        guard let screen = window?.screen else { return .zero }
        let nsTop = primaryHeight - r.origin.y
        let ns = CGRect(x: r.origin.x, y: nsTop - r.height, width: r.width, height: r.height)
        return CGRect(x: ns.origin.x - screen.frame.origin.x, y: ns.origin.y - screen.frame.origin.y,
                      width: ns.width, height: ns.height)
    }

    private func updateHover() {
        guard windowMode else { hoveredWindow = nil; return }
        let cg = cgGlobal(fromView: mouse)
        hoveredWindow = scWindows.first { $0.frame.contains(cg) }   // list is front-to-back
    }

    // MARK: mouse
    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if windowMode {
            if let win = hoveredWindow { onDone(.window(win)) } else { onCancel() }
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
    }
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
        guard !windowMode else { return }
        guard let rect = dragRect, rect.width >= 2, rect.height >= 2 else { onCancel(); return }
        let topLeft = CGRect(x: rect.origin.x, y: bounds.height - rect.maxY,
                             width: rect.width, height: rect.height)
        onDone(.area(AreaSelection(frame: frozen, rectInPoints: topLeft)))
    }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(frozen.image, in: bounds)
        ctx.restoreGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)

        if windowMode {
            if let win = hoveredWindow {
                let r = viewRect(fromCG: win.frame).intersection(bounds)
                if let crop = cropView(r) { ctx.draw(crop, in: r) }
                ctx.setStrokeColor(Tokens.accent.cgColor)
                ctx.setLineWidth(2)
                let path = CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
                ctx.addPath(path)
                ctx.strokePath()
            }
            drawHint("click to capture window · space for area · esc to cancel")
            return
        }

        if let rect = dragRect {
            if let crop = cropView(rect) { ctx.draw(crop, in: rect) }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
            drawDimensions(rect)
        } else if bounds.contains(mouse) {   // only the display the cursor is on shows chrome
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: mouse.x, y: 0), CGPoint(x: mouse.x, y: bounds.height),
                                             CGPoint(x: 0, y: mouse.y), CGPoint(x: bounds.width, y: mouse.y)])
            drawLoupe(ctx)
        }
    }

    /// Frozen pixels for a view-coords rect (undims the selection).
    private func cropView(_ rect: CGRect) -> CGImage? {
        let topLeft = CGRect(x: rect.origin.x, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return ScreenshotService.crop(frozen, rectInPoints: topLeft)
    }

    private func drawLoupe(_ ctx: CGContext) {
        let radius: CGFloat = 60
        let sample: CGFloat = 16   // points sampled around the cursor
        var center = CGPoint(x: mouse.x + radius + 24, y: mouse.y - radius - 24)
        if center.x + radius > bounds.width { center.x = mouse.x - radius - 24 }
        if center.y - radius < 0 { center.y = mouse.y + radius + 24 }

        let srcTopLeft = CGRect(x: mouse.x - sample / 2, y: bounds.height - mouse.y - sample / 2,
                                width: sample, height: sample)
        guard let crop = ScreenshotService.crop(frozen, rectInPoints: srcTopLeft) else { return }

        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: circle)
        // pixel grid
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(0.5)
        let cell = circle.width / sample
        var x = circle.minX
        while x <= circle.maxX { ctx.strokeLineSegments(between: [CGPoint(x: x, y: circle.minY), CGPoint(x: x, y: circle.maxY)]); x += cell }
        var y = circle.minY
        while y <= circle.maxY { ctx.strokeLineSegments(between: [CGPoint(x: circle.minX, y: y), CGPoint(x: circle.maxX, y: y)]); y += cell }
        ctx.restoreGState()
        // center pixel marker + ring
        ctx.setStrokeColor(Tokens.accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: center.x - cell / 2, y: center.y - cell / 2, width: cell, height: cell))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle)
        // hex caption
        if let hex = centerHex() {
            drawBadge(hex, at: CGPoint(x: center.x, y: circle.minY - 18), monospaced: true)
        }
    }

    private func centerHex() -> String? {
        let src = CGRect(x: mouse.x - 0.5, y: bounds.height - mouse.y - 0.5, width: 1, height: 1)
        guard let px = ScreenshotService.crop(frozen, rectInPoints: src) else { return nil }
        let rep = NSBitmapImageRep(cgImage: px)
        guard let c = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func drawDimensions(_ rect: CGRect) {
        let px = Int(rect.width * frozen.scale)
        let py = Int(rect.height * frozen.scale)
        var y = rect.minY - 26
        if y < 0 { y = rect.minY + 6 }
        drawBadge("\(px) × \(py)", at: CGPoint(x: rect.maxX - 40, y: y), monospaced: true)
    }

    private func drawHint(_ text: String) {
        drawBadge(text, at: CGPoint(x: bounds.midX, y: bounds.height - 60), monospaced: false)
    }

    private func drawBadge(_ string: String, at point: CGPoint, monospaced: Bool) {
        let text = string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: monospaced ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                              : NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let bg = CGRect(x: point.x - size.width / 2 - pad, y: point.y,
                        width: size.width + pad * 2, height: size.height + pad * 1.4)
        let path = NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        text.draw(at: CGPoint(x: bg.minX + pad, y: bg.minY + pad * 0.7), withAttributes: attrs)
    }
}
