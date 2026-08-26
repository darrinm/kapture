// The annotation editor: tool rail · canvas · options bar. Non-destructive — layers render
// over the pristine base; Done flattens at native resolution through Library.applyEdit.
import AppKit
import KaptureCore
import KaptureDesign

@MainActor
public final class EditorController {
    public static let shared = EditorController()
    private var windows: [String: NSWindow] = [:]   // capture id → window
    private var closeObservers: [String: NSObjectProtocol] = [:]   // removed when the window closes
    public var library: Library?
    /// Called after Done flattens — the shell reopens the capture as an overlay card.
    public var onFlattened: ((String) -> Void)?
    /// Window lifecycle hooks — the shell uses these to toggle activation policy.
    public var onWindowOpened: (() -> Void)?
    public var onWindowClosed: (() -> Void)?

    public func open(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) })
        else { return }
        if let existing = windows[recordID] { existing.makeKeyAndOrderFront(nil); return }
        let (baseURL, layersJSON) = library.editBase(for: record)
        // Decoding a 5K PNG takes long enough to stall the UI — do it off the main actor.
        Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: baseURL),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            await MainActor.run {
                EditorController.shared.present(recordID: recordID, record: record,
                                                base: cg, layersJSON: layersJSON)
            }
        }
    }

    private func present(recordID: String, record: CaptureRecord, base cg: CGImage, layersJSON: String?) {
        if let existing = windows[recordID] { existing.makeKeyAndOrderFront(nil); return }
        let editor = EditorViewController(baseImage: cg,
                                          layers: layersJSON.map(AnnotationCodec.decode) ?? []) { [weak self] layers, done in
            self?.save(recordID: recordID, base: cg, layers: layers, reopenAsCard: done)
        }
        let window = NSWindow(contentViewController: editor)
        window.title = (record.relPath as NSString).lastPathComponent
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(editor.idealSize)
        window.center()
        window.isReleasedWhenClosed = false
        windows[recordID] = window
        closeObservers[recordID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.windows[recordID] = nil
                if let token = self?.closeObservers.removeValue(forKey: recordID) {
                    NotificationCenter.default.removeObserver(token)
                }
                self?.onWindowClosed?()
            }
        }
        onWindowOpened?()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Flatten + PNG encode + applyEdit are hundreds of ms for large captures — run them off
    /// the main actor. The onFlattened hop back to MainActor fires only after applyEdit finishes,
    /// so the reopened card reads the fresh pixels.
    private func save(recordID: String, base: CGImage, layers: [Annotation], reopenAsCard: Bool) {
        guard let library else { return }
        let onFlattened = self.onFlattened
        Task.detached(priority: .userInitiated) {
            if let out = AnnotationRenderer.flatten(base: base, layers: layers),
               let png = ImageEncoding.pngData(out) {
                do {
                    try library.applyEdit(recordID, flattenedPNG: png,
                                          layersJSON: AnnotationCodec.encode(layers),
                                          width: out.width, height: out.height)
                } catch { Log.store.error("apply edit failed: \(error)") }
            }
            if reopenAsCard {
                await MainActor.run { onFlattened?(recordID) }
            }
        }
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
            (.crop, "crop", "Crop (applies when you press Done)"),
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
            b.layer?.backgroundColor = NSColor(hex: hex).cgColor
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
        canvas.commitPendingText()   // leaving the text tool commits the in-progress entry
        canvas.tool = tool
        if tool == .select { canvas.selectMostRecent() }
        updateColorSelection()
        // radio behavior
        (sender.superview as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }
            .forEach { $0.state = $0 === sender ? .on : .off }
    }
    @objc private func colorTapped(_ sender: NSButton) {
        guard let hex = sender.identifier?.rawValue else { return }
        if canvas.recolorActiveText(hex) {
            // live-recolored the in-progress text entry
        } else if canvas.tool == .select, canvas.recolorSelected(hex) {
            // recolored the selected layer; also make it the active color for that tool family
        } else if canvas.tool == .highlight {
            canvas.highlightHex = hex
        } else {
            canvas.colorHex = hex
        }
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
    private var sliderGestureActive = false
    @objc private func widthChanged(_ sender: NSSlider) {
        let w = CGFloat(sender.doubleValue)
        if canvas.tool == .select {
            canvas.rewidthSelected(w, recordUndo: !sliderGestureActive)
        } else {
            canvas.strokeWidth = w
        }
        // a gesture continues only through mouse tracking; keyboard changes are discrete
        // (each records its own undo) and must not leave the flag stuck on
        let type = NSApp.currentEvent?.type
        sliderGestureActive = type == .leftMouseDown || type == .leftMouseDragged
    }
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
    private var preGesture: [Annotation]?   // gesture-start snapshot; pushed on first real mutation
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
        Tokens.aspectFit(CGSize(width: image.width, height: image.height), in: bounds)
    }
    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        let scale = CGFloat(image.width) / r.width
        return CGPoint(x: (p.x - r.minX) * scale, y: (r.maxY - p.y) * scale)   // flip to top-left space
    }

    func selectMostRecent() {
        selected = layers.last?.id
        needsDisplay = true
    }

    /// Change the selected layer's stroke width; one undo entry per slider gesture.
    func rewidthSelected(_ width: CGFloat, recordUndo: Bool) {
        strokeWidth = width
        guard let sel = selected, let i = layers.firstIndex(where: { $0.id == sel }) else { return }
        if recordUndo { pushUndo() }
        layers[i].strokeWidth = width
        needsDisplay = true
    }

    /// Recolor the selected layer (undoable). Returns false if nothing is selected.
    @discardableResult
    func recolorSelected(_ hex: String) -> Bool {
        guard let sel = selected, let i = layers.firstIndex(where: { $0.id == sel }) else { return false }
        pushUndo()
        layers[i].colorHex = hex
        if layers[i].tool == .highlight { highlightHex = hex } else { colorHex = hex }
        needsDisplay = true
        return true
    }

    func compositeImage() -> NSImage? {
        guard let out = AnnotationRenderer.flatten(base: image, layers: layers) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    // MARK: input
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitPendingText()
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch tool {
        case .select:
            // double-click on a text layer re-opens it for editing
            if event.clickCount == 2,
               let textLayer = layers.last(where: { $0.tool == .text && $0.hitTest(p) }) {
                beginEditingExistingText(textLayer)
                break
            }
            // a handle on the already-selected layer wins over re-selection
            if let sel = selected, let layer = layers.first(where: { $0.id == sel }),
               let h = handleIndex(of: layer, at: p) {
                preGesture = layers   // snapshot; pushed only if the drag actually mutates
                dragMode = .handle(h)
                dragOrigin = p
                break
            }
            selected = layers.last(where: { $0.hitTest(p) })?.id
            preGesture = selected != nil ? layers : nil   // snapshot; pushed only on actual move
            dragMode = .move
            dragOrigin = p
        case .text:
            beginText(atImagePoint: p, viewPoint: convert(event.locationInWindow, from: nil))
        case .counter:
            pushUndo()
            let next = (layers.compactMap(\.number).max() ?? 0) + 1
            layers.append(Annotation(tool: .counter, points: [p], colorHex: colorHex,
                                     strokeWidth: strokeWidth, number: next))
        case .crop:
            // With a crop already placed, dragging its handles resizes and dragging its inside
            // moves it; a drag outside starts a replacement crop.
            if let crop = layers.last(where: { $0.tool == .crop }) {
                if let h = handleIndex(of: crop, at: p) {
                    selected = crop.id
                    preGesture = layers
                    dragMode = .handle(h)
                    dragOrigin = p
                    break
                }
                if crop.rect.contains(p) {
                    selected = crop.id
                    preGesture = layers
                    dragMode = .move
                    dragOrigin = p
                    break
                }
            }
            draft = Annotation(tool: .crop, points: [p, p], colorHex: colorHex, strokeWidth: strokeWidth)
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
        case .arrow, .line, .rect, .ellipse, .highlight, .crop:
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
        } else if let sel = selected, let origin = dragOrigin,   // select tool, or crop-tool move/resize
                  let i = layers.firstIndex(where: { $0.id == sel }) {
            switch dragMode {
            case .handle(let h) where h < layers[i].points.count:
                commitPreGesture()
                layers[i].points[h] = p
            case .move:
                let dx = p.x - origin.x, dy = p.y - origin.y
                if abs(dx) + abs(dy) > 0 {
                    commitPreGesture()
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
            // freehand needs a real stroke; shapes need a real extent — a bare click commits nothing
            let commit = d.tool == .freehand ? d.points.count > 2
                                             : d.rect.width + d.rect.height > 4
            if commit {
                pushUndo()
                if d.tool == .crop { layers.removeAll { $0.tool == .crop } }   // one crop at a time
                layers.append(d)
            }
            draft = nil
        }
        preGesture = nil
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

    private func pushUndo() {
        undoStack.append(layers)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }
    /// Push the gesture-start snapshot the first time a drag actually mutates the layer.
    private func commitPreGesture() {
        guard let pre = preGesture else { return }
        preGesture = nil
        undoStack.append(pre)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }
    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        layers = prev
        selected = nil
        needsDisplay = true
    }

    // MARK: text tool
    private var pendingFontSize: CGFloat = Annotation.defaultFontSize
    private var cancelRestoresViaUndo = false   // set while re-editing an existing text layer

    /// Re-open a committed text layer for editing: remove it (undoable) and show the field
    /// pre-filled at its position, in its color and size.
    private func beginEditingExistingText(_ layer: Annotation) {
        guard let pos = layer.points.first else { return }
        pushUndo()
        cancelRestoresViaUndo = true   // esc must reinstate the layer removed below
        layers.removeAll { $0.id == layer.id }
        selected = nil
        colorHex = layer.colorHex
        pendingFontSize = layer.fontSize ?? Annotation.defaultFontSize
        let r = imageRect
        let scale = r.width / CGFloat(image.width)
        let viewPoint = CGPoint(x: r.minX + pos.x * scale, y: r.maxY - pos.y * scale)
        beginText(atImagePoint: pos, viewPoint: viewPoint, initialText: layer.text ?? "")
        needsDisplay = true
    }

    private func beginText(atImagePoint p: CGPoint, viewPoint: CGPoint, initialText: String = "") {
        let scale = imageRect.width / CGFloat(image.width)
        if initialText.isEmpty { pendingFontSize = Annotation.defaultFontSize }
        let fontSize = max(11, pendingFontSize * scale)
        let height = ceil(fontSize * 1.4)
        // rendered text's top-left lands at the click point; align the field to match
        let field = NSTextField(frame: NSRect(x: viewPoint.x - 2, y: viewPoint.y - height,
                                              width: max(180, imageRect.maxX - viewPoint.x), height: height))
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = NSColor(hex: colorHex)
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Text"
        field.stringValue = initialText
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        pendingTextPos = p
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {   // esc cancels losslessly
            cancelPendingText()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {     // return commits
            commitPendingText()
            return true
        }
        return false
    }

    /// While the inline text field is open, a swatch click recolors it live. Returns false if no field.
    @discardableResult
    func recolorActiveText(_ hex: String) -> Bool {
        guard let field = textField else { return false }
        colorHex = hex
        field.textColor = NSColor(hex: hex)
        window?.makeFirstResponder(field)   // keep typing where you were
        return true
    }

    /// Shared field teardown: remove the inline field and reset text-entry state.
    /// Returns the field's trimmed value, the pending image-space position, the pending font
    /// size, and whether this was a re-edit of an existing layer; nil when no field is open.
    private func dismissTextField() -> (value: String, pos: CGPoint?, fontSize: CGFloat,
                                        wasEditingExisting: Bool)? {
        guard let field = textField else { return nil }
        let state = (field.stringValue.trimmingCharacters(in: .whitespaces),
                     pendingTextPos, pendingFontSize, cancelRestoresViaUndo)
        field.removeFromSuperview()
        textField = nil
        pendingTextPos = nil
        cancelRestoresViaUndo = false
        pendingFontSize = Annotation.defaultFontSize
        needsDisplay = true
        return state
    }

    func commitPendingText() {
        guard let s = dismissTextField(), let pos = s.pos else { return }
        if !s.value.isEmpty {
            pushUndo()
            layers.append(Annotation(tool: .text, points: [pos], colorHex: colorHex,
                                     strokeWidth: strokeWidth, text: s.value, fontSize: s.fontSize))
        } else if s.wasEditingExisting {
            undo()   // blanked out an existing layer's text — treat as cancel, restore it
        }
    }

    /// Dismiss the inline field without committing; a re-edit of existing text is restored.
    private func cancelPendingText() {
        guard let s = dismissTextField() else { return }
        if s.wasEditingExisting { undo() }   // reinstate the layer beginEditingExistingText removed
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitPendingText() }

    // MARK: drawing
    /// Base image + drop shadow, composited once and blitted per frame — rescaling and
    /// re-shadowing a 5K base on every annotation tweak is the expensive part of draw.
    private var baseComposite: CGImage?
    private var baseCompositeSize: CGSize = .zero
    private let shadowPad: CGFloat = 20   // covers blur 12 + offset 2 on every side

    private func baseComposite(for size: CGSize) -> CGImage? {
        if let cached = baseComposite, baseCompositeSize == size { return cached }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int((size.width + shadowPad * 2) * scale)
        let h = Int((size.height + shadowPad * 2) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.draw(image, in: CGRect(x: shadowPad, y: shadowPad, width: size.width, height: size.height))
        baseComposite = ctx.makeImage()
        baseCompositeSize = size
        return baseComposite
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        // checkerboard-free neutral surround already via layer background
        if let composite = baseComposite(for: r.size) {
            ctx.draw(composite, in: r.insetBy(dx: -shadowPad, dy: -shadowPad))
        }

        // map image space (top-left px) into the view's image rect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: r.width / CGFloat(image.width), y: -r.height / CGFloat(image.height))
        for l in layers { l.draw(in: ctx) }
        if let d = draft { d.draw(in: ctx) }
        // Crop preview: dim everything outside the crop rect, dashed border on it. The in-flight
        // draft previews live; otherwise the committed crop layer shows what Done will keep.
        if let crop = (draft?.tool == .crop ? draft : nil) ?? layers.last(where: { $0.tool == .crop }) {
            let full = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
            let keep = crop.rect.intersection(full)
            if keep.width >= 1, keep.height >= 1 {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: full.width, height: keep.minY))
                ctx.fill(CGRect(x: 0, y: keep.maxY, width: full.width, height: full.height - keep.maxY))
                ctx.fill(CGRect(x: 0, y: keep.minY, width: keep.minX, height: keep.height))
                ctx.fill(CGRect(x: keep.maxX, y: keep.minY, width: full.width - keep.maxX, height: keep.height))
                let px = CGFloat(image.width) / r.width
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5 * px)
                ctx.setLineDash(phase: 0, lengths: [6 * px])
                ctx.stroke(keep)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        if let sel = selected, let l = layers.first(where: { $0.id == sel }) {
            let px = CGFloat(image.width) / r.width   // 1 view point in image units
            let handles = handlePositions(of: l)
            if l.tool == .freehand {
                // halo along the stroke instead of a box
                var halo = l
                halo.colorHex = "#C7423A55"
                halo.strokeWidth = l.strokeWidth + 8 * px
                ctx.saveGState()
                halo.draw(in: ctx)
                ctx.restoreGState()
            } else if handles.isEmpty {   // text, counter: dashed bounds
                ctx.setStrokeColor(Tokens.accent.cgColor)
                ctx.setLineWidth(2 * px)
                ctx.setLineDash(phase: 0, lengths: [6 * px])
                ctx.stroke(l.bounds.insetBy(dx: -10 * px, dy: -10 * px))
                ctx.setLineDash(phase: 0, lengths: [])
            }
            for h in handles {
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
}
