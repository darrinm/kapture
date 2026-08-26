// The annotation editor: tool rail · canvas · options bar. Non-destructive — layers render
// over the pristine base; Done flattens at native resolution through Library.applyEdit.
import AppKit
import KaptureCore
import KaptureDesign

@MainActor
public final class EditorController {
    public static let shared = EditorController()
    private var windows: [String: NSWindow] = [:]   // capture id → window
    public var library: Library?
    /// Called after Done flattens — the shell reopens the capture as an overlay card.
    public var onFlattened: ((String) -> Void)?

    public func open(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) })
        else { return }
        if let existing = windows[recordID] { existing.makeKeyAndOrderFront(nil); return }
        let (baseURL, layersJSON) = library.editBase(for: record)
        guard let image = NSImage(contentsOf: baseURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let editor = EditorViewController(baseImage: cg,
                                          layers: layersJSON.map(AnnotationCodec.decode) ?? []) { [weak self] layers, done in
            self?.save(recordID: recordID, base: cg, layers: layers)
            if done { self?.onFlattened?(recordID) }
        }
        let window = NSWindow(contentViewController: editor)
        window.title = (record.relPath as NSString).lastPathComponent
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(editor.idealSize)
        window.center()
        window.isReleasedWhenClosed = false
        windows[recordID] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windows[recordID] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func save(recordID: String, base: CGImage, layers: [Annotation]) {
        guard let library else { return }
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // image space is top-left; CGContext is bottom-left — flip once
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))   // draw() under flip renders upright
        for layer in layers { layer.draw(in: ctx) }
        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? library.applyEdit(recordID, flattenedPNG: png,
                               layersJSON: AnnotationCodec.encode(layers), width: w, height: h)
    }
}

@MainActor
final class EditorViewController: NSViewController {
    let baseImage: CGImage
    let onDone: ([Annotation], _ dismissing: Bool) -> Void
    let canvas: CanvasView
    var idealSize: NSSize
    private var colorButtons: [NSButton] = []

    init(baseImage: CGImage, layers: [Annotation], onDone: @escaping ([Annotation], Bool) -> Void) {
        self.baseImage = baseImage
        self.onDone = onDone
        self.canvas = CanvasView(image: baseImage, layers: layers)
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let imgSize = NSSize(width: baseImage.width, height: baseImage.height)
        let scale = min(1, (screen.width * 0.7) / imgSize.width, (screen.height * 0.7) / imgSize.height)
        self.idealSize = NSSize(width: max(560, imgSize.width * scale + 56),
                                height: max(420, imgSize.height * scale + 48))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let rail = NSStackView()
        rail.orientation = .vertical
        rail.spacing = 2
        let symbols: [(Tool, String, String)] = [
            (.select, "cursorarrow", "Select / move (delete removes)"),
            (.arrow, "arrow.up.right", "Arrow"),
            (.line, "line.diagonal", "Line"),
            (.rect, "rectangle", "Rectangle"),
            (.ellipse, "circle", "Ellipse"),
            (.freehand, "scribble", "Pen"),
            (.highlight, "highlighter", "Highlight"),
            (.text, "textformat", "Text"),
            (.counter, "1.circle", "Step counter"),
        ]
        for (tool, symbol, tip) in symbols {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!,
                target: self, action: #selector(toolTapped(_:)))
            b.isBordered = false
            b.toolTip = tip
            b.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            b.setButtonType(.toggle)
            b.state = tool == canvas.tool ? .on : .off
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 36),
                                         b.heightAnchor.constraint(equalToConstant: 32)])
            rail.addArrangedSubview(b)
        }

        let options = NSStackView()
        options.orientation = .horizontal
        options.spacing = 8
        let palette = ["#C7423A", "#E8A33D", "#3C9A5F", "#3576C7", "#8B5CD6", "#1C2025", "#FFFFFF"]
        for hex in palette {
            let b = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = Annotation(tool: .rect, points: [], colorHex: hex, strokeWidth: 1).color.cgColor
            b.layer?.cornerRadius = 9
            b.layer?.borderWidth = hex == "#FFFFFF" ? 1 : 0
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.identifier = NSUserInterfaceItemIdentifier(hex)
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 18),
                                         b.heightAnchor.constraint(equalToConstant: 18)])
            options.addArrangedSubview(b)
            colorButtons.append(b)
        }
        updateColorSelection()
        let widthSlider = NSSlider(value: Double(canvas.strokeWidth), minValue: 2, maxValue: 24,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        options.addArrangedSubview(NSTextField(labelWithString: "Width"))
        options.addArrangedSubview(widthSlider)
        options.addArrangedSubview(NSView())

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.bezelColor = Tokens.accent
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        copy.bezelStyle = .rounded
        options.addArrangedSubview(copy)
        options.addArrangedSubview(done)

        root.addSubview(rail)
        root.addSubview(canvas)
        root.addSubview(options)
        rail.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        options.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            rail.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            canvas.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 8),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            canvas.bottomAnchor.constraint(equalTo: options.topAnchor, constant: -10),
            options.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            options.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            options.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            options.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = root
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let tool = Tool(rawValue: raw) else { return }
        canvas.tool = tool
        updateColorSelection()
        // radio behavior
        var v: NSView? = sender.superview
        while v != nil, !(v is NSStackView) { v = v?.superview }
        (sender.superview as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }
            .forEach { $0.state = $0 === sender ? .on : .off }
    }
    @objc private func colorTapped(_ sender: NSButton) {
        guard let hex = sender.identifier?.rawValue else { return }
        if canvas.tool == .highlight { canvas.highlightHex = hex } else { canvas.colorHex = hex }
        updateColorSelection()
    }
    private func updateColorSelection() {
        let active = canvas.tool == .highlight ? canvas.highlightHex : canvas.colorHex
        for b in colorButtons {
            let isActive = b.identifier?.rawValue == active
            b.layer?.borderWidth = isActive ? 2.5 : (b.identifier?.rawValue == "#FFFFFF" ? 1 : 0)
            b.layer?.borderColor = isActive ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        }
    }
    @objc private func widthChanged(_ sender: NSSlider) { canvas.strokeWidth = CGFloat(sender.doubleValue) }
    @objc private func copyTapped() {
        canvas.commitPendingText()
        onDone(canvas.layers, false)   // flatten + persist without dismissing
        if let img = canvas.compositeImage() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
        }
    }
    @objc private func doneTapped() {
        canvas.commitPendingText()
        onDone(canvas.layers, true)
        view.window?.close()
    }
}

@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let image: CGImage
    var layers: [Annotation]
    var tool: Tool = .arrow
    var colorHex = "#C7423A"
    var highlightHex = "#FFE83D"   // highlighter keeps its own color; classic yellow default
    var strokeWidth: CGFloat = 6
    private enum DragMode { case none, move, handle(Int) }
    private var dragMode: DragMode = .none
    private var draft: Annotation?
    private var selected: UUID?
    private var dragOrigin: CGPoint?
    private var undoStack: [[Annotation]] = []
    private var textField: NSTextField?
    private var pendingTextPos: CGPoint?

    init(image: CGImage, layers: [Annotation]) {
        self.image = image
        self.layers = layers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    // MARK: geometry — image rect aspect-fit in view; conversions view↔image space
    private var imageRect: CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        let scale = CGFloat(image.width) / r.width
        return CGPoint(x: (p.x - r.minX) * scale, y: (r.maxY - p.y) * scale)   // flip to top-left space
    }

    func compositeImage() -> NSImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for l in layers { l.draw(in: ctx) }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }

    // MARK: input
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitPendingText()
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch tool {
        case .select:
            // a handle on the already-selected layer wins over re-selection
            if let sel = selected, let layer = layers.first(where: { $0.id == sel }),
               let h = handleIndex(of: layer, at: p) {
                pushUndo()
                dragMode = .handle(h)
                dragOrigin = p
                break
            }
            selected = layers.last(where: { $0.hitTest(p) })?.id
            if selected != nil { pushUndo() }   // snapshot before a potential move
            dragMode = .move
            dragOrigin = p
        case .text:
            beginText(atImagePoint: p, viewPoint: convert(event.locationInWindow, from: nil))
        case .counter:
            pushUndo()
            let next = (layers.compactMap(\.number).max() ?? 0) + 1
            layers.append(Annotation(tool: .counter, points: [p], colorHex: colorHex,
                                     strokeWidth: strokeWidth, number: next))
        default:
            draft = Annotation(tool: tool, points: [p, p],
                               colorHex: tool == .highlight ? highlightHex : colorHex,
                               strokeWidth: strokeWidth)
        }
        needsDisplay = true
    }

    /// endpoints/corners of the selected shape a drag can grab (image-space)
    private func handlePositions(of layer: Annotation) -> [CGPoint] {
        switch layer.tool {
        case .arrow, .line, .rect, .ellipse, .highlight:
            return layer.points.count >= 2 ? [layer.points[0], layer.points[1]] : []
        default:
            return []
        }
    }
    private func handleIndex(of layer: Annotation, at p: CGPoint) -> Int? {
        let grab = 10 * CGFloat(image.width) / imageRect.width
        return handlePositions(of: layer).firstIndex { hypot($0.x - p.x, $0.y - p.y) < grab }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        if var d = draft {
            if d.tool == .freehand { d.points.append(p) } else { d.points[1] = p }
            draft = d
        } else if tool == .select, let sel = selected, let origin = dragOrigin,
                  let i = layers.firstIndex(where: { $0.id == sel }) {
            switch dragMode {
            case .handle(let h) where h < layers[i].points.count:
                layers[i].points[h] = p
            case .move:
                let dx = p.x - origin.x, dy = p.y - origin.y
                if abs(dx) + abs(dy) > 0 {
                    layers[i].points = layers[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                    dragOrigin = p
                }
            default: break
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let d = draft {
            let minSpan = d.tool == .freehand ? 2 : 1
            if d.points.count > minSpan || d.rect.width + d.rect.height > 4 {
                pushUndo(before: d)
                layers.append(d)
            }
            draft = nil
        }
        dragOrigin = nil
        dragMode = .none
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, tool == .select, let sel = selected {   // delete
            pushUndo()
            layers.removeAll { $0.id == sel }
            selected = nil
            needsDisplay = true
        } else if event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "z" {
            undo()
        } else {
            super.keyDown(with: event)
        }
    }

    private func pushUndo(before newDraft: Annotation? = nil) {
        undoStack.append(layers)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }
    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        layers = prev
        selected = nil
        needsDisplay = true
    }

    // MARK: text tool
    private func beginText(atImagePoint p: CGPoint, viewPoint: CGPoint) {
        let scale = imageRect.width / CGFloat(image.width)
        let fontSize = max(11, 48 * scale)
        let height = ceil(fontSize * 1.4)
        // rendered text's top-left lands at the click point; align the field to match
        let field = NSTextField(frame: NSRect(x: viewPoint.x - 2, y: viewPoint.y - height,
                                              width: max(180, imageRect.maxX - viewPoint.x), height: height))
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = Annotation(tool: .text, points: [], colorHex: colorHex, strokeWidth: 1).color
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Text"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        pendingTextPos = p
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {   // esc discards
            textField?.stringValue = ""
            commitPendingText()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {     // return commits
            commitPendingText()
            return true
        }
        return false
    }

    func commitPendingText() {
        guard let field = textField, let pos = pendingTextPos else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        textField = nil
        pendingTextPos = nil
        if !value.isEmpty {
            pushUndo()
            layers.append(Annotation(tool: .text, points: [pos], colorHex: colorHex,
                                     strokeWidth: strokeWidth, text: value, fontSize: 48))
        }
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitPendingText() }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        // checkerboard-free neutral surround already via layer background
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.draw(image, in: r)
        ctx.restoreGState()

        // map image space (top-left px) into the view's image rect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: r.width / CGFloat(image.width), y: -r.height / CGFloat(image.height))
        for l in layers { l.draw(in: ctx) }
        if let d = draft { d.draw(in: ctx) }
        if let sel = selected, let l = layers.first(where: { $0.id == sel }) {
            let px = CGFloat(image.width) / r.width   // 1 view point in image units
            ctx.setStrokeColor(Tokens.accent.cgColor)
            ctx.setLineWidth(2 * px)
            ctx.setLineDash(phase: 0, lengths: [6 * px])
            ctx.stroke(boundsOf(l).insetBy(dx: -10, dy: -10))
            ctx.setLineDash(phase: 0, lengths: [])
            // control-point handles
            for h in handlePositions(of: l) {
                let hr = 6 * px
                let rect = CGRect(x: h.x - hr, y: h.y - hr, width: hr * 2, height: hr * 2)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(Tokens.accent.cgColor)
                ctx.setLineWidth(1.5 * px)
                ctx.strokeEllipse(in: rect)
            }
        }
        ctx.restoreGState()
    }

    private func boundsOf(_ l: Annotation) -> CGRect {
        if l.points.count >= 2 { return l.rect }
        if let p = l.points.first { return CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60) }
        return .zero
    }
}
