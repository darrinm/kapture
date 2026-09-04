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
        // canAnnotate, not "isn't a recording": Done flattens PNG bytes over the opened file, so
        // a .gif must never reach here even though NSImage decodes one perfectly well.
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) }),
              record.canAnnotate
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
    /// The effects cache holds the capture it was sampled from — a full-resolution CGImage,
    /// tens of megabytes — so it must not outlive the editor.
    private func releaseEditorMemory() {
        AnnotationEffects.clearCache()
    }

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
                } catch { Log.store.error("apply edit failed: \(error)"); return }
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
    private var railButtons: [NSButton] = []
    private var widthLabel: NSTextField!
    private var widthSlider: NSSlider!
    private var sizeLabel: NSTextField!
    private var sizeSlider: NSSlider!
    private var fillCheck: NSButton!
    private var ratioPopup: NSPopUpButton!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    /// menu order matches: nil = Free, .infinity sentinel = image's own aspect ("Original")
    private let ratioChoices: [(String, CGFloat?)] = [
        ("Free", nil), ("Original", .infinity), ("1:1", 1), ("4:3", 4.0 / 3),
        ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    /// Programmatic tool switch (e.g. after applying a crop): canvas, rail radio, and bars agree.
    private func selectTool(_ tool: Tool) {
        canvas.tool = tool
        for b in railButtons { b.state = b.identifier?.rawValue == tool.rawValue ? .on : .off }
        updateColorSelection()
        updateOptionsBar()
    }

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
            (.blur, "drop.fill", "Blur out"),
            (.pixelate, "square.grid.3x3.fill", "Pixelate"),
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
            railButtons.append(b)
        }
        canvas.onCropApplied = { [weak self] in self?.selectTool(.select) }
        canvas.onSelectionChanged = { [weak self] in self?.updateOptionsBar() }

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
        widthSlider = NSSlider(value: Double(canvas.strokeWidth), minValue: 2, maxValue: 24,
                               target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        widthLabel = NSTextField(labelWithString: "Width")
        options.addArrangedSubview(widthLabel)
        options.addArrangedSubview(widthSlider)

        sizeSlider = NSSlider(value: Double(canvas.textSize), minValue: 18, maxValue: 120,
                              target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sizeLabel = NSTextField(labelWithString: "Size")
        options.addArrangedSubview(sizeLabel)
        options.addArrangedSubview(sizeSlider)

        fillCheck = NSButton(checkboxWithTitle: "Fill", target: self, action: #selector(fillTapped(_:)))
        options.addArrangedSubview(fillCheck)

        ratioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ratioPopup.addItems(withTitles: ratioChoices.map(\.0))
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged(_:))
        options.addArrangedSubview(ratioPopup)

        options.addArrangedSubview(NSView())
        updateOptionsBar()

        // Undo/redo live at the right, next to Copy and Done: always present, never shifted by
        // the per-tool controls that come and go on the left.
        undoButton = historyButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoTapped))
        redoButton = historyButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redoTapped))
        options.addArrangedSubview(undoButton)
        options.addArrangedSubview(redoButton)
        canvas.onHistoryChanged = { [weak self] in self?.updateHistoryButtons() }
        updateHistoryButtons()

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

    private func historyButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
        let b = NSButton(image: image, target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    /// Dimmed when there is nothing to undo or redo — the button is the only place the editor
    /// says whether a mistake is still recoverable.
    private func updateHistoryButtons() {
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
    }

    @objc private func undoTapped() {
        canvas.undo()
        updateOptionsBar()
    }

    @objc private func redoTapped() {
        canvas.redo()
        updateOptionsBar()
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let tool = Tool(rawValue: raw) else { return }
        canvas.commitPendingText()   // leaving the text tool commits the in-progress entry
        if tool != canvas.tool, tool != .select { canvas.clearSelection() }
        canvas.tool = tool
        if tool == .select { canvas.selectMostRecent() }
        updateColorSelection()
        updateOptionsBar()
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
    /// The bottom row shows only what the effective tool can use: the active tool, or — in
    /// select mode — the selected layer's tool, with values synced to that layer. Color for
    /// anything painted; width for stroked marks ("Size" for counters); text size for text;
    /// fill for rect/ellipse; nothing for crop (it has its on-canvas chips).
    private func updateOptionsBar() {
        // the live element owns the controls whatever tool is in hand — that is the point of
        // not having to enter a select mode to adjust what you just drew
        let selectedLayer = canvas.selectedLayer
        let effective = canvas.effectiveTool

        var showColor = true, showWidth = false, showSize = false, showFill = false
        var showRatio = false
        var widthTitle = "Width"
        switch effective {
        case .crop: showColor = false; showRatio = true
        case .highlight: break
        case .text: showSize = true
        case .counter: showWidth = true; widthTitle = "Size"
        case .rect, .ellipse: showWidth = true; showFill = true
        case .select, .arrow, .line, .freehand: showWidth = true
        case .blur, .pixelate:
            showColor = false      // a redaction has no colour to pick
            showWidth = true
            widthTitle = "Amount"
        }
        // the width slider doubles as the redaction amount, on its own scale
        let redacting = effective.isRedaction
        widthSlider.minValue = redacting ? 4 : 2
        widthSlider.maxValue = redacting ? 80 : 24
        colorButtons.forEach { $0.isHidden = !showColor }
        widthLabel.isHidden = !showWidth
        widthSlider.isHidden = !showWidth
        widthLabel.stringValue = widthTitle
        sizeLabel.isHidden = !showSize
        sizeSlider.isHidden = !showSize
        fillCheck.isHidden = !showFill
        ratioPopup.isHidden = !showRatio

        // sync control values to the selected layer (or the tool defaults)
        if let layer = selectedLayer {
            widthSlider.doubleValue = redacting
                ? Double(layer.intensity ?? layer.tool.defaultIntensity)
                : Double(layer.strokeWidth)
            sizeSlider.doubleValue = Double(layer.fontSize ?? Annotation.defaultFontSize)
            fillCheck.state = layer.filled == true ? .on : .off
        } else {
            widthSlider.doubleValue = redacting ? Double(canvas.intensity) : Double(canvas.strokeWidth)
            sizeSlider.doubleValue = Double(canvas.textSize)
            fillCheck.state = canvas.fillShapes ? .on : .off
        }
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue)
        if !canvas.resizeTextSelected(v, recordUndo: !sliderGestureActive) { canvas.textSize = v }
        sliderGestureActive = NSApp.currentEvent?.type != .leftMouseUp
    }

    @objc private func fillTapped(_ sender: NSButton) {
        let on = sender.state == .on
        if !canvas.refillSelected(on) { canvas.fillShapes = on }
    }

    @objc private func ratioChanged(_ sender: NSPopUpButton) {
        let choice = ratioChoices[max(0, sender.indexOfSelectedItem)].1
        let ratio = choice == .infinity ? canvas.imageAspect : choice
        canvas.cropAspect = ratio
        canvas.reshapeCrop(toRatio: ratio)   // undoable; no-op with no crop or Free
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
        // the same rule the options bar uses: whatever the controls are pointed at
        let effective = canvas.effectiveTool
        // both setters update the default for the next element and apply to the live one if
        // there is one, so the slider means the same thing either way
        if effective.isRedaction {
            canvas.reintensifySelected(w, recordUndo: !sliderGestureActive)
        } else {
            canvas.rewidthSelected(w, recordUndo: !sliderGestureActive)
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
    var textSize: CGFloat = Annotation.defaultFontSize
    var fillShapes = false
    /// Blur radius / pixelate block size for new redactions, image-space.
    var intensity: CGFloat = Tool.blur.defaultIntensity
    var onSelectionChanged: (() -> Void)?
    var selectedLayer: Annotation? {
        guard let sel = selected else { return nil }
        return layers.first(where: { $0.id == sel })
    }
    private enum DragMode { case none, move, handle(Int) }
    private var dragMode: DragMode = .none
    private var draft: Annotation?
    private var selected: UUID?
    private var dragOrigin: CGPoint?
    private var preGesture: [Annotation]?   // gesture-start snapshot; pushed on first real mutation
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    /// Fired whenever the history changes, so the buttons can reflect what is actually available.
    var onHistoryChanged: (() -> Void)?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private var textField: NSTextField?
    private var pendingTextPos: CGPoint?
    private var chipApplyRect: CGRect?    // view-space crop chips, refreshed each draw
    private var chipRemoveRect: CGRect?

    init(image: CGImage, layers: [Annotation]) {
        self.image = image
        self.layers = layers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    // MARK: geometry — the canvas shows the VIEWPORT (full image, or the applied crop's rect)
    // aspect-fit in the view; all annotation geometry stays in full-image space throughout.
    private var cropLayerIndex: Int? { layers.lastIndex(where: { $0.tool == .crop }) }
    var cropPending: Bool {
        guard let i = cropLayerIndex else { return false }
        return layers[i].applied != true
    }
    /// While the crop tool is active the full frame shows (for re-adjusting); otherwise an
    /// applied crop re-bases the canvas to its rect.
    private var viewport: CGRect {
        guard tool != .crop, let i = cropLayerIndex, layers[i].applied == true else { return imageBounds }
        let r = layers[i].rect.intersection(imageBounds)
        return (r.width >= 1 && r.height >= 1) ? r : imageBounds
    }
    // MARK: zoom — 1 means "fit the window", which is the floor; above that the canvas
    // magnifies about the pointer and can be panned. All annotation geometry still lives in
    // image space, because every conversion goes through imageRect.
    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGPoint = .zero
    private let maxZoom: CGFloat = 8

    var fittedRect: CGRect { Tokens.aspectFit(viewport.size, in: bounds) }

    var imageRect: CGRect {
        let fitted = fittedRect
        guard zoom > 1.001 else { return fitted }
        let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let origin = CGPoint(x: fitted.midX - size.width / 2 + pan.x,
                             y: fitted.midY - size.height / 2 + pan.y)
        return clampToView(CGRect(origin: origin, size: size))
    }

    /// Keep the magnified image covering the view: panning must never strand the canvas against
    /// an empty background.
    private func clampToView(_ rect: CGRect) -> CGRect {
        var r = rect
        if r.width <= bounds.width {
            r.origin.x = bounds.midX - r.width / 2
        } else {
            r.origin.x = min(bounds.minX, max(bounds.maxX - r.width, r.origin.x))
        }
        if r.height <= bounds.height {
            r.origin.y = bounds.midY - r.height / 2
        } else {
            r.origin.y = min(bounds.minY, max(bounds.maxY - r.height, r.origin.y))
        }
        return r
    }

    /// Zoom, keeping whatever is under `anchor` (view space) pinned there.
    func setZoom(_ requested: CGFloat, anchor: CGPoint? = nil) {
        let target = max(1, min(maxZoom, requested))
        guard abs(target - zoom) > 0.0001 else { return }
        let before = imageRect
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let u = before.width > 0 ? (a.x - before.minX) / before.width : 0.5
        let v = before.height > 0 ? (a.y - before.minY) / before.height : 0.5
        zoom = target
        if target <= 1.0001 {
            pan = .zero
        } else {
            let fitted = fittedRect
            let w = fitted.width * zoom, h = fitted.height * zoom
            pan = CGPoint(x: a.x - u * w - (fitted.midX - w / 2),
                          y: a.y - v * h - (fitted.midY - h / 2))
        }
        needsDisplay = true
    }

    /// One image pixel per point.
    func zoomToActualSize() {
        let fitted = fittedRect
        guard fitted.width > 0 else { return }
        setZoom(viewport.width / fitted.width)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom > 1.001 else { return }
        // the image follows the fingers, same mapping the overlay cards use
        pan.x -= event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": setZoom(zoom * 1.25); return true
        case "-": setZoom(zoom / 1.25); return true
        case "0": setZoom(1); return true
        case "1": zoomToActualSize(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = imageRect, vp = viewport
        let scale = vp.width / r.width
        return CGPoint(x: vp.minX + (p.x - r.minX) * scale,
                       y: vp.minY + (r.maxY - p.y) * scale)   // flip to top-left space
    }
    private func toView(_ q: CGPoint) -> CGPoint {
        let r = imageRect, vp = viewport
        let scale = r.width / vp.width
        return CGPoint(x: r.minX + (q.x - vp.minX) * scale,
                       y: r.maxY - (q.y - vp.minY) * scale)
    }

    /// Drop the live selection — picking a different tool is a statement of intent to draw
    /// something new, not to keep nudging the last thing.
    func clearSelection() {
        guard selected != nil else { return }
        selected = nil
        needsDisplay = true
        onSelectionChanged?()
    }

    /// What a press does under the live-selection model: whatever you just drew stays
    /// manipulable with the same tool in hand — handles resize it, its body moves it — and a
    /// press anywhere else begins the next element, which becomes live in its turn. The select
    /// and crop tools keep their own dispatch, which already worked this way.
    enum PressTarget: Equatable {
        case resizeLive(Int)
        case moveLive
        case selectOther(UUID)
        case newElement
    }

    func pressTarget(at p: CGPoint) -> PressTarget {
        guard tool != .select, tool != .crop, let sel = selected,
              let live = layers.first(where: { $0.id == sel })
        else { return .newElement }
        if let h = handleIndex(of: live, at: p) { return .resizeLive(h) }
        if live.hitTest(p) { return .moveLive }
        // Outside the live element, but on another of the same kind: take that one up instead of
        // starting a new element on top of it. Only the same kind, because the arrow you draw
        // across a screenshot lands on top of half the boxes already there, and having it grab a
        // box would make the tool in your hand impossible to use. Topmost first — that is the one
        // drawn last, so it is the one under the pointer.
        if let other = layers.last(where: { $0.id != sel && $0.tool == live.tool && $0.hitTest(p) }) {
            return .selectOther(other.id)
        }
        return .newElement
    }

    /// What the tool controls apply to: the live element if there is one, otherwise the tool in
    /// hand. Defined once — the options bar and the sliders disagreed about this, which decided
    /// both a slider's range and what it wrote to.
    var effectiveTool: Tool { selectedLayer?.tool ?? tool }

    func selectMostRecent() {
        selected = layers.last(where: { !($0.tool == .crop && $0.applied == true) })?.id
        needsDisplay = true
        onSelectionChanged?()
    }

    /// Toggle fill on the selected rect/ellipse (undoable). Returns false if none applies.
    @discardableResult
    func refillSelected(_ filled: Bool) -> Bool {
        guard let sel = selected, let i = layers.firstIndex(where: { $0.id == sel }),
              layers[i].tool == .rect || layers[i].tool == .ellipse else { return false }
        pushUndo()
        layers[i].filled = filled
        needsDisplay = true
        return true
    }

    /// Change the selected text layer's size; one undo entry per slider gesture.
    @discardableResult
    func resizeTextSelected(_ size: CGFloat, recordUndo: Bool) -> Bool {
        textSize = size
        if let field = textField {   // live entry follows the slider
            pendingFontSize = size
            let scale = imageRect.width / viewport.width
            field.font = .systemFont(ofSize: max(11, size * scale), weight: .semibold)
            return true
        }
        guard let sel = selected, let i = layers.firstIndex(where: { $0.id == sel }),
              layers[i].tool == .text else { return false }
        if recordUndo { pushUndo() }
        layers[i].fontSize = size
        needsDisplay = true
        return true
    }

    // MARK: crop aspect constraint (width/height; nil = free)
    var cropAspect: CGFloat?
    var imageAspect: CGFloat { CGFloat(image.width) / CGFloat(image.height) }

    /// Largest ratio-true rect from `anchor` toward `p`, kept inside the image.
    private func ratioRect(anchor a: CGPoint, toward p: CGPoint, ratio r: CGFloat) -> CGRect {
        let sx: CGFloat = p.x >= a.x ? 1 : -1
        let sy: CGFloat = p.y >= a.y ? 1 : -1
        var w = max(abs(p.x - a.x), abs(p.y - a.y) * r)
        let maxW = sx > 0 ? imageBounds.maxX - a.x : a.x - imageBounds.minX
        let maxH = sy > 0 ? imageBounds.maxY - a.y : a.y - imageBounds.minY
        w = min(w, maxW, maxH * r)
        let h = w / r
        return CGRect(x: min(a.x, a.x + sx * w), y: min(a.y, a.y + sy * h), width: w, height: h)
    }

    /// Reshape the existing crop to `ratio` (undoable): keep its center, fit within its span and
    /// the image. No-op without a crop.
    func reshapeCrop(toRatio r: CGFloat?) {
        guard let ratio = r, let i = cropLayerIndex else { return }
        let cur = layers[i].rect
        pushUndo()
        var w = min(cur.width, cur.height * ratio)
        var h = w / ratio
        // grow back up to the current span's larger side where the image allows
        let growW = min(max(cur.width, cur.height * ratio), imageBounds.width, imageBounds.height * ratio)
        w = max(w, min(growW, imageBounds.width)); h = w / ratio
        var rect = CGRect(x: cur.midX - w / 2, y: cur.midY - h / 2, width: w, height: h)
        rect.origin.x = min(max(rect.origin.x, 0), imageBounds.width - rect.width)
        rect.origin.y = min(max(rect.origin.y, 0), imageBounds.height - rect.height)
        layers[i].points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
        needsDisplay = true
    }

    // MARK: crop apply/remove — in-editor, undoable (the flag lives in the layer stack)
    var onCropApplied: (() -> Void)?

    func applyCrop() {
        guard let i = cropLayerIndex, layers[i].applied != true else { return }
        pushUndo()
        layers[i].applied = true
        selected = nil
        needsDisplay = true
        onCropApplied?()
    }

    func removeCrop() {
        guard cropLayerIndex != nil else { return }
        pushUndo()
        layers.removeAll { $0.tool == .crop }
        selected = nil
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

    /// Change the selected redaction's amount (undoable). False if the selection isn't one.
    @discardableResult
    func reintensifySelected(_ amount: CGFloat, recordUndo: Bool) -> Bool {
        intensity = amount
        guard let sel = selected, let i = layers.firstIndex(where: { $0.id == sel }),
              layers[i].tool.isRedaction else { return false }
        if recordUndo { pushUndo() }
        layers[i].intensity = amount
        needsDisplay = true
        return true
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
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let a = chipApplyRect, a.contains(viewPoint) { applyCrop(); return }
        if let x = chipRemoveRect, x.contains(viewPoint) { removeCrop(); return }
        let p = toImage(viewPoint)

        switch pressTarget(at: p) {
        case .resizeLive(let h):
            preGesture = layers          // snapshot; pushed only if the drag mutates
            dragMode = .handle(h)
            dragOrigin = p
            needsDisplay = true
            return
        case .moveLive:
            preGesture = layers
            dragMode = .move
            dragOrigin = p
            needsDisplay = true
            return
        case .selectOther(let id):
            // it becomes live and is draggable in the same gesture, exactly as if it had just
            // been drawn — otherwise selecting it would cost a click before it could be moved
            selected = id
            onSelectionChanged?()
            preGesture = layers
            dragMode = .move
            dragOrigin = p
            needsDisplay = true
            return
        case .newElement:
            // outside the live element: this press starts something new, so the old one stops
            // being live
            if tool != .select, tool != .crop { clearSelection() }
        }

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
            selected = layers.last(where: { $0.hitTest(p) && !($0.tool == .crop && $0.applied == true) })?.id
            preGesture = selected != nil ? layers : nil   // snapshot; pushed only on actual move
            dragMode = .move
            dragOrigin = p
            onSelectionChanged?()
        case .text:
            beginText(atImagePoint: p, viewPoint: convert(event.locationInWindow, from: nil))
        case .counter:
            pushUndo()
            let next = (layers.compactMap(\.number).max() ?? 0) + 1
            let counter = Annotation(tool: .counter, points: [p], colorHex: colorHex,
                                     strokeWidth: strokeWidth, number: next)
            layers.append(counter)
            selected = counter.id
            onSelectionChanged?()
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
            let cp = clampToImage(p)
            draft = Annotation(tool: .crop, points: [cp, cp], colorHex: colorHex, strokeWidth: strokeWidth)
        default:
            var d = Annotation(tool: tool, points: [p, p],
                               colorHex: tool == .highlight ? highlightHex : colorHex,
                               strokeWidth: strokeWidth)
            if tool == .rect || tool == .ellipse { d.filled = fillShapes }
            if tool.isRedaction { d.intensity = intensity }
            draft = d
        }
        needsDisplay = true
    }

    /// endpoints/corners of the selected shape a drag can grab (image-space)
    func handlePositions(of layer: Annotation) -> [CGPoint] {
        switch layer.tool {
        case .crop:
            // 8 handles: corners then edge midpoints — order matched by resizeCrop(_:handle:to:)
            guard layer.points.count >= 2 else { return [] }
            let r = layer.rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                    CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        case .arrow, .line:
            return layer.points.count >= 2 ? [layer.points[0], layer.points[1]] : []
        default:
            // every box-shaped tool resizes by its two drawn corners, redactions included
            guard layer.tool.isRectangular, layer.points.count >= 2 else { return [] }
            return [layer.points[0], layer.points[1]]
        }
    }
    /// Resize the crop rect by one of its 8 handles (order per handlePositions: 4 corners TL/TR/BL/BR,
    /// then edge midpoints top/bottom/left/right). Edges crossing over are re-standardized.
    private func resizeCrop(_ layer: inout Annotation, handle h: Int, to p: CGPoint) {
        let r = layer.rect
        if let ratio = cropAspect {
            // corners resize ratio-true from the opposite corner; edges resize their dimension
            // with the other derived, centered on the rect's other axis
            switch h {
            case 0...3:
                let anchor = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                              CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)][h]
                let out = ratioRect(anchor: anchor, toward: p, ratio: ratio)
                layer.points = [out.origin, CGPoint(x: out.maxX, y: out.maxY)]
            case 4...7:
                var w: CGFloat
                if h <= 5 {   // top/bottom edge drives height
                    let hgt = h == 4 ? r.maxY - p.y : p.y - r.minY
                    w = max(hgt, 1) * ratio
                } else {      // left/right edge drives width
                    w = max(h == 6 ? r.maxX - p.x : p.x - r.minX, 1)
                }
                // center the derived dimension; shrink to what the image allows around the centers
                let cx = r.midX, cy = r.midY
                w = min(w, 2 * min(cx, imageBounds.width - cx))
                var hgt = w / ratio
                let maxHgt = 2 * min(cy, imageBounds.height - cy)
                if hgt > maxHgt { hgt = maxHgt; w = hgt * ratio }
                let out = CGRect(x: cx - w / 2, y: cy - hgt / 2, width: w, height: hgt)
                layer.points = [out.origin, CGPoint(x: out.maxX, y: out.maxY)]
            default: break
            }
            return
        }
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch h {
        case 0: minX = p.x; minY = p.y
        case 1: maxX = p.x; minY = p.y
        case 2: minX = p.x; maxY = p.y
        case 3: maxX = p.x; maxY = p.y
        case 4: minY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x
        case 7: maxX = p.x
        default: return
        }
        layer.points = [CGPoint(x: min(minX, maxX), y: min(minY, maxY)),
                        CGPoint(x: max(minX, maxX), y: max(minY, maxY))]
    }

    private func handleIndex(of layer: Annotation, at p: CGPoint) -> Int? {
        let grab = 10 * CGFloat(image.width) / imageRect.width
        return handlePositions(of: layer).firstIndex { hypot($0.x - p.x, $0.y - p.y) < grab }
    }

    private var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
    }
    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageBounds.width), y: min(max(p.y, 0), imageBounds.height))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        if var d = draft {
            if d.tool == .freehand {
                d.points.append(p)
            } else if d.tool == .crop {
                if let ratio = cropAspect {
                    let r = ratioRect(anchor: d.points[0], toward: clampToImage(p), ratio: ratio)
                    d.points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
                } else {
                    d.points[1] = clampToImage(p)
                }
            } else {
                d.points[1] = p
            }
            draft = d
        } else if let sel = selected, let origin = dragOrigin,   // select tool, or crop-tool move/resize
                  let i = layers.firstIndex(where: { $0.id == sel }) {
            switch dragMode {
            case .handle(let h) where layers[i].tool == .crop:
                commitPreGesture()
                resizeCrop(&layers[i], handle: h, to: clampToImage(p))
            case .handle(let h) where h < layers[i].points.count:
                commitPreGesture()
                layers[i].points[h] = p
            case .move:
                var dx = p.x - origin.x, dy = p.y - origin.y
                if layers[i].tool == .crop {   // the crop rect never leaves the image
                    let r = layers[i].rect
                    dx = min(max(dx, -r.minX), imageBounds.width - r.maxX)
                    dy = min(max(dy, -r.minY), imageBounds.height - r.maxY)
                }
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
                if d.tool != .crop {
                    selected = d.id       // finished: now live, no mode switch needed
                    onSelectionChanged?()
                }
            }
            draft = nil
        }
        preGesture = nil
        dragOrigin = nil
        dragMode = .none
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, tool == .crop, cropPending {            // return applies the crop
            applyCrop()
        } else if event.keyCode == 53, tool == .crop, cropLayerIndex != nil {   // esc removes it
            removeCrop()
        } else if event.keyCode == 51, tool == .select, let sel = selected {   // delete
            pushUndo()
            layers.removeAll { $0.id == sel }
            selected = nil
            needsDisplay = true
            onSelectionChanged?()
        } else if event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "z" {
            event.modifierFlags.contains(.shift) ? redo() : undo()
        } else {
            super.keyDown(with: event)
        }
    }

    private func pushUndo() { record(layers) }

    /// One place that knows what recording a history step means, so a rule added later cannot
    /// land on one of the two callers.
    private func record(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        // a new edit is a new branch: whatever was undone is no longer reachable
        redoStack.removeAll()
        onHistoryChanged?()
    }
    /// Push the gesture-start snapshot the first time a drag actually mutates the layer.
    private func commitPreGesture() {
        guard let pre = preGesture else { return }
        preGesture = nil
        record(pre)
    }
    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(layers)
        adopt(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(layers)
        adopt(next)
    }

    /// Step to a snapshot from the history. Mirror images otherwise drift.
    private func adopt(_ snapshot: [Annotation]) {
        layers = snapshot
        selected = nil
        needsDisplay = true
        onSelectionChanged?()
        onHistoryChanged?()
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
        let scale = imageRect.width / viewport.width
        if initialText.isEmpty { pendingFontSize = textSize }
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
            let text = Annotation(tool: .text, points: [pos], colorHex: colorHex,
                                  strokeWidth: strokeWidth, text: s.value, fontSize: s.fontSize)
            layers.append(text)
            selected = text.id      // finished text is live like anything else you just drew
            onSelectionChanged?()
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
    private var baseCompositeViewport: CGRect = .zero
    private let shadowPad: CGFloat = 20   // covers blur 12 + offset 2 on every side

    private func baseComposite(for size: CGSize, viewport vp: CGRect) -> CGImage? {
        if let cached = baseComposite, baseCompositeSize == size, baseCompositeViewport == vp {
            return cached
        }
        let source = vp == imageBounds ? image : (image.cropping(to: vp) ?? image)
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
        ctx.draw(source, in: CGRect(x: shadowPad, y: shadowPad, width: size.width, height: size.height))
        baseComposite = ctx.makeImage()
        baseCompositeSize = size
        baseCompositeViewport = vp
        return baseComposite
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        let vp = viewport
        // checkerboard-free neutral surround already via layer background
        if zoom > 1.001 {
            // Magnified, the drop shadow is off screen anyway and the cached composite would be
            // a bitmap the size of the zoomed canvas — 8x of a 5K capture is over a gigabyte.
            // Draw the source directly and let CoreGraphics do the scaling.
            ctx.saveGState()
            ctx.clip(to: bounds)
            let source = vp == imageBounds ? image : (image.cropping(to: vp) ?? image)
            ctx.interpolationQuality = zoom > 2 ? .none : .high   // pixels, not mush, up close
            ctx.draw(source, in: r)
            ctx.restoreGState()
        } else if let composite = baseComposite(for: r.size, viewport: vp) {
            ctx.draw(composite, in: r.insetBy(dx: -shadowPad, dy: -shadowPad))
        }

        // map image space (top-left px) into the view's image rect through the viewport
        let s = r.width / vp.width
        ctx.saveGState()
        ctx.translateBy(x: r.minX - vp.minX * s, y: r.maxY + vp.minY * s)
        ctx.scaleBy(x: s, y: -s)
        for l in layers { l.draw(in: ctx, base: image) }
        if let d = draft { d.draw(in: ctx, base: image) }
        // Crop preview: dim everything outside the crop rect, dashed border on it — shown while
        // the crop tool is active or the crop is still pending (applied crops re-base the view).
        chipApplyRect = nil
        chipRemoveRect = nil
        let showCropChrome = tool == .crop || cropPending
        if showCropChrome,
           let crop = (draft?.tool == .crop ? draft : nil) ?? layers.last(where: { $0.tool == .crop }) {
            let full = imageBounds
            let keep = crop.rect.intersection(full)
            if keep.width >= 1, keep.height >= 1 {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: full.width, height: keep.minY))
                ctx.fill(CGRect(x: 0, y: keep.maxY, width: full.width, height: full.height - keep.maxY))
                ctx.fill(CGRect(x: 0, y: keep.minY, width: keep.minX, height: keep.height))
                ctx.fill(CGRect(x: keep.maxX, y: keep.minY, width: full.width - keep.maxX, height: keep.height))
                let px = 1 / s
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5 * px)
                ctx.setLineDash(phase: 0, lengths: [6 * px])
                ctx.stroke(keep)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        if let sel = selected, let l = layers.first(where: { $0.id == sel }) {
            let px = 1 / s   // 1 view point in image units
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

        // Apply/remove chips (view space), anchored under the crop rect's bottom-right corner.
        if showCropChrome, draft == nil, let i = cropLayerIndex {
            let crop = layers[i]
            let corner = toView(CGPoint(x: crop.rect.maxX, y: crop.rect.maxY))
            let pending = crop.applied != true
            let applyW: CGFloat = pending ? 76 : 0
            let removeW: CGFloat = pending ? 26 : 84
            let chipH: CGFloat = 24, gap: CGFloat = 6
            var y = corner.y - chipH - 8
            if y < 4 { y = corner.y + 8 }   // no room below: place inside the rect
            var x = corner.x - removeW
            let removeRect = CGRect(x: x, y: y, width: removeW, height: chipH)
            drawChip(pending ? "✕" : "✕ Remove crop", in: removeRect,
                     fill: NSColor.black.withAlphaComponent(0.65))
            chipRemoveRect = removeRect
            if pending {
                x -= applyW + gap
                let applyRect = CGRect(x: x, y: y, width: applyW, height: chipH)
                drawChip("✓ Apply ⏎", in: applyRect, fill: Tokens.accent)
                chipApplyRect = applyRect
            }
        }
    }

    private func drawChip(_ label: String, in rect: CGRect, fill: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        fill.setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = label as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
               withAttributes: attrs)
    }
}
