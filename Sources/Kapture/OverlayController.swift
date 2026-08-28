// Quick Access Overlay (M1): stacked capture panels in the bottom corner with hover chrome.
// Keep and discard are distinct one-gesture actions (product spec §2.0): × / ⌘W keeps,
// trash / ⌘⌫ / swipe-toward-edge discards into the 7-day trash. space = Quick Look.
// Beyond 5 the pile collapses into a "+n" card. Right-click menu on every card.
import AppKit
import AVFoundation
import Quartz
import KaptureCore
import KaptureDesign
import KaptureEditor
import KaptureRecording
import KaptureIntelligence

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
                panel.settleIn()   // the flight arrives; this is it coming to rest
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
        let url = library.url(for: record)
        // decoding the flattened PNG is slow for big captures — keep it off the main actor
        Task.detached(priority: .userInitiated) {
            guard let image = OverlayController.poster(for: url) else { return }
            await MainActor.run {
                OverlayController.shared.show(record: record, fileURL: url, image: image)
            }
        }
    }

    /// Card pixels for any library file: decoded stills, first frame for movies.
    /// NSImage returns nil for .mp4, so a movie needs the asset generator (post-trim cards).
    nonisolated static func poster(for url: URL) -> CGImage? {
        if let still = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return still
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
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
            panel.restingFrame = frame
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
    var placed = false
    /// Where the stack says this card belongs. A swipe springs back to *this*, never to wherever
    /// the card happened to be when the gesture started — otherwise an interrupted swipe leaves
    /// the card displaced and the next one starts from the new spot, walking it across the screen.
    var restingFrame: NSRect = .zero   // set on first layout; first placement never animates
    /// The card view. Not the content view — see the container note in init.
    private(set) var card: OverlayView!
    /// How far the window is grown on each side while a swipe is in flight, so the card has room
    /// to travel without the window having to move.
    private var swipePad: CGFloat = 0
    /// The same, above and below, so the card has room to lean without the window clipping it.
    private var swipeVPad: CGFloat = 0
    private var swiping = false
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
        // The card lives inside a container rather than being the content view itself. A swipe
        // moves the card within the window instead of moving the window: a window that slides
        // out from under the pointer stops receiving the gesture's scroll events, which left the
        // card stranded halfway through a swipe.
        let container = OverlayContainerView(frame: NSRect(origin: .zero, size: size))
        let card = OverlayView(panel: self, image: image)
        card.frame = container.bounds
        card.autoresizingMask = []
        container.card = card
        container.addSubview(card)
        self.card = card
        contentView = container
    }
    override var canBecomeKey: Bool { true }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        Tokens.animate(0.25) { self.animator().alphaValue = 1 }
        settleIn()
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
        Task { await IngestQueue.shared.expedite(record.id) }   // acted on: index it now
        try? OverlayController.shared.library?.setStatus(record.id, .kept)
    }

    func keepAndClose() {
        markKept()
        fadeOut()
    }

    func discard() {
        guard commitDiscard() else { fadeOut(); return }   // no false discard feedback
        slideOff()
    }

    /// Moves the capture to the trash and gives the feedback for it. Returns false if the record
    /// was already gone, in which case nothing should animate as though it worked.
    @discardableResult
    func commitDiscard() -> Bool {
        var discarded = false
        if let library = OverlayController.shared.library,
           let fresh = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: record.id) }) {
            do {
                try library.discard(fresh)
                discarded = true
            } catch { Log.store.error("discard failed: \(error)") }
        }
        guard discarded else { return false }
        Task { await IngestQueue.shared.cancel(record.id) }     // discarded: don't spend OCR on it
        Sounds.play("Bottle")
        return true
    }

    /// Take the card off screen and out of the stack. The caller has already animated it to
    /// wherever it should end up.
    func finishClose() {
        orderOut(nil)
        onClose(self)
    }

    /// Grow the window around the card so the card can be moved without the window moving.
    func beginSwipe() {
        guard !swiping else { return }
        swiping = true
        let rest = restingFrame == .zero ? frame : restingFrame
        restingFrame = rest
        swipePad = rest.width + 60
        // Vertical room as well, for the lean: a window clips what leaves its bounds, so without
        // this the card's corners are sheared off the moment it starts to turn.
        swipeVPad = ceil(SwipePhysics.verticalClearance(
            width: rest.width, height: rest.height,
            degrees: SwipePhysics.maxDragTilt + SwipePhysics.maxFlingSpin))
        setFrame(NSRect(x: rest.minX - swipePad, y: rest.minY - swipeVPad,
                        width: rest.width + swipePad * 2, height: rest.height + swipeVPad * 2),
                 display: false)
        // a settle-in spring still in flight would keep driving the card back to the slot's
        // origin — inside the grown window that is the far left edge, so the card would lurch
        // sideways under a swipe started in the first fraction of a second
        card.layer?.removeAllAnimations()
        card.frame = NSRect(x: swipePad, y: swipeVPad, width: rest.width, height: rest.height)
        invalidateShadow()
    }

    /// Move the card within the window. `offset` is in screen terms, from the resting position.
    func swipe(to offset: CGFloat) {
        guard swiping else { return }
        card.frame.origin.x = swipePad + offset
        card.frameCenterRotation = SwipePhysics.tilt(offset: offset, width: card.frame.width)
        invalidateShadow()
    }

    /// Animate the card back to where it rests and shrink the window around it again.
    func endSwipe(springBackOver duration: TimeInterval) {
        guard swiping else { return }
        // a whole frame, not frame.origin.x: through the animator proxy a sub-property is a
        // read-modify-write against an in-flight presentation value
        let target = NSRect(x: swipePad, y: swipeVPad,
                            width: card.frame.width, height: card.frame.height)
        Tokens.animate(duration, timing: Tokens.springBack, {
            self.card.animator().frame = target
            self.card.animator().frameCenterRotation = 0   // unwinds as it comes back to square
        }) { [weak self] in
            self?.settleAfterSwipe()
        }
    }

    /// Animate the card off along the direction it was actually flung, then close. The window
    /// stays where it is throughout; only the card inside it moves.
    func flyOffAndClose(direction: CGVector, velocity: CGFloat, over duration: TimeInterval) {
        guard swiping else { return }
        // Distance along the throw's own line, not across: dismissal is defined by clearing the
        // edge, so the *horizontal* component still has to cover a full card plus margin. Taken
        // flat, a 45° exit would fall a third short sideways and be finished off by the fade.
        let travel = (card.frame.width + 60) / max(abs(direction.dx), 0.001)
        // keeps turning on the way out, harder the harder it was flicked
        let spin = card.frameCenterRotation + SwipePhysics.spin(velocity: velocity, direction: direction)
        // A diagonal exit leaves the window's bounds vertically, and a window clips what leaves
        // it — so make room for the whole path before starting, not just for the rotation.
        let needed = abs(direction.dy) * travel
            + SwipePhysics.verticalClearance(width: card.frame.width, height: card.frame.height,
                                             degrees: spin)
        growVertically(by: needed - swipeVPad)
        let target = NSRect(x: swipePad + direction.dx * travel,
                            y: swipeVPad + direction.dy * travel,
                            width: card.frame.width, height: card.frame.height)
        Tokens.animate(duration, {
            self.card.animator().frame = target
            self.card.animator().frameCenterRotation = spin
            self.card.animator().alphaValue = 0
        }) { [weak self] in
            // out of sight before anything is put back, or the card reappears at rest for a frame
            self?.finishClose()
            self?.settleAfterSwipe()
        }
    }

    /// End a gesture that never moved the card — a swipe that turned out to be vertical, or one
    /// that was abandoned before it committed to an axis. Nothing to animate back, but the
    /// window must still shrink around the card: left grown, the next stack layout resizes it to
    /// the slot while the card is still parked at `swipePad`, which puts the card outside the
    /// window and it vanishes.


    /// Grow the window above and below without the card appearing to move: the window's origin
    /// drops by as much as its height gains, and the card's offset inside it rises to match.
    private func growVertically(by extra: CGFloat) {
        guard extra > 0 else { return }
        let current = frame
        setFrame(NSRect(x: current.minX, y: current.minY - extra,
                        width: current.width, height: current.height + extra * 2),
                 display: false)
        card.frame.origin.y += extra
        swipeVPad += extra
    }

    /// Put the window back around the card once a gesture is over.
    func settleAfterSwipe() {
        guard swiping else { return }
        swiping = false
        setFrame(restingFrame, display: true)
        card.frameCenterRotation = 0   // before the frame: rotation is about the frame's centre
        card.frame = NSRect(origin: .zero, size: restingFrame.size)
        card.alphaValue = 1
        swipePad = 0
        swipeVPad = 0
        invalidateShadow()
    }

    /// Land in the slot with a little weight: arrive fractionally small and spring to full size,
    /// so a capture drops onto the stack instead of materialising there.
    ///
    /// Inset rather than scaled up, because a card that overshoots *larger* is clipped by its own
    /// window — the window is exactly the slot. Skipped outright under Reduce Motion: the animator
    /// proxy animates against the ambient context even when `Tokens.animate` runs the body without
    /// a group of its own, so leaving it to `Tokens.animate` would still bounce the card.
    func settleIn() {
        guard !swiping, restingFrame != .zero, !Tokens.reduceMotion else { return }
        let full = NSRect(origin: .zero, size: restingFrame.size)
        card.frame = full.insetBy(dx: full.width * 0.03, dy: full.height * 0.03)
        invalidateShadow()   // or the window's shadow stays drawn around the full-size card
        Tokens.animate(0.22, timing: Tokens.springBack, {
            self.card.animator().frame = full
        }) { [weak self] in
            self?.invalidateShadow()
        }
    }

    func copyToClipboard() {
        Clipboard.write(url: fileURL, image: NSImage(cgImage: image, size: .zero))
        keepAndClose()
    }

    func saveToExportLocation() {
        do { try Library.copyToExportLocation(fileURL) }
        catch { Log.store.error("export failed: \(error)") }
        keepAndClose()
    }

    func saveAs() {
        markKept()
        Library.markInUse(record.id)
        let save = NSSavePanel()
        save.nameFieldStringValue = fileURL.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        let id = record.id
        save.begin { [weak self] response in
            // clear on every exit — a cancelled panel used to leave the capture marked in use
            // for the rest of the session, which blocks its AI rename permanently
            defer { Library.clearInUse(id) }
            guard let self, response == .OK, let url = save.url else { return }
            try? FileManager.default.copyItem(at: self.fileURL, to: url)
            Task { @MainActor in self.fadeOut() }
        }
    }

    func pin() {
        PinController.shared.pin(fileURL: fileURL)
        keepAndClose()
    }

    /// Recording → optimized GIF as a NEW library capture (the movie stays untouched).
    func convertToGIF() {
        guard record.canExportGIF else { return }
        markKept()
        let source = fileURL
        let app = record.sourceApp
        fadeOut()
        Task.detached(priority: .userInitiated) {
            do {
                let gif = try await GIFExporter.export(movie: source)
                guard let library = await OverlayController.shared.library else { return }
                let (record, _) = try library.storeMovie(gif, sourceApp: app, ext: "gif", kind: .gif)
                await MainActor.run {
                    Sounds.play("Glass")
                    OverlayController.shared.showCard(recordID: record.id)
                }
            } catch { Log.capture.error("gif export failed: \(error)") }
        }
    }

    /// ⌘E / double-click / "Edit…" — routed by what the capture can actually do. A GIF is
    /// neither trimmable nor PNG-editable, so it opens nothing rather than landing in the
    /// still editor, whose save would write PNG bytes over the .gif file.
    func edit() {
        markKept()
        if record.canTrim {
            TrimmerController.shared.open(recordID: record.id)
        } else if record.canAnnotate {
            EditorController.shared.open(recordID: record.id)
        } else {
            return   // nothing to open; the card stays put
        }
        fadeOut()
    }

    /// Upload to kapture.sh and put the link on the clipboard. The card stays up while the
    /// upload runs and closes only on success, so a failed share leaves something to retry.
    func shareLink() {
        markKept()
        ShareCoordinator.shared.share(record) { [weak self] url in
            guard url != nil else { return }
            self?.fadeOut()
        }
    }

    /// The one overlay shortcut table (used by both the click-to-key tier and the AX event
    /// tap): space → Quick Look; ⌘⌫ discard; ⌘W keep; ⌘C copy; ⌘S save; ⌘E edit; ⌘U share.
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
        case "u": shareLink(); return true
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
            self.finishClose()
        }
    }
}

/// Transparent host for the card. While a swipe is in flight the window is wider than the card,
/// and the empty margins must not swallow clicks meant for whatever is behind them.
final class OverlayContainerView: NSView {
    weak var card: OverlayView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let card, card.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
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
    // Swipe-to-dismiss, modelled on a macOS notification banner: the card tracks the finger,
    // resists when dragged the wrong way, and on release either carries on off the edge or
    // springs back. The old version only measured the gesture and acted at the end, so the card
    // sat still under your finger and dismissal felt like a command rather than a movement.
    private enum SwipeAxis { case undecided, horizontal, vertical }
    private var swipeAxis: SwipeAxis = .undecided
    private var swiping = false
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    /// Toward-edge points per second, smoothed so one jittery frame can't fling the card.
    private var swipeVelocity: CGFloat = 0
    private var swipeTime: TimeInterval = 0
    /// A swipe that carries the card out from under the pointer stops receiving scroll events,
    /// so `.ended` never arrives. Without this the card would sit stranded mid-gesture.
    private var swipeWatchdog: DispatchWorkItem?
    private var swipeWatchdogArmed = Date.distantPast

    /// Sign of accumulated deltaX that means "toward the edge the cards live on".
    private var towardEdgeSign: CGFloat { Settings.shared.overlayOnLeftEdge ? 1 : -1 }
    /// Which way that edge lies on screen.
    private var edgeScreenSign: CGFloat { Settings.shared.overlayOnLeftEdge ? -1 : 1 }

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
        chrome.addArrangedSubview(button("link", "Share link (⌘U)", #selector(shareTapped)))
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
    @objc func shareTapped() { panel.shareLink() }
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
        let record = panel.record
        if record.canTrim || record.canAnnotate {
            menu.addItem(withTitle: record.canTrim ? "Trim…" : "Edit…",
                         action: #selector(editTapped), keyEquivalent: "").target = self
        }
        if record.canExportGIF {
            menu.addItem(withTitle: "Convert to GIF", action: #selector(gifTapped), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Pin to Screen", action: #selector(pinTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Share Link", action: #selector(shareTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save As…", action: #selector(saveAsTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Discard", action: #selector(discardTapped), keyEquivalent: "").target = self
        return menu
    }
    @objc func saveAsTapped() { panel.saveAs() }
    @objc func gifTapped() { panel.convertToGIF() }
    @objc func revealTapped() {
        panel.markKept()
        NSWorkspace.shared.activateFileViewerSelecting([panel.fileURL])
    }

    // MARK: two-finger swipes — toward edge = discard, down = hide all
    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began:
            swipeAxis = .undecided
            swipeX = 0
            swipeY = 0
            swipeVelocity = 0
            swipeTime = event.timestamp
            swiping = true
            // no watchdog yet: it exists for a card that has moved out from under the pointer,
            // and arming it here would end a gesture that has simply not moved yet — a slow
            // downward swipe would be resolved 250ms in, before it had travelled far enough to
            // mean anything.
        case .changed:
            guard swiping else { return }
            swipeX += event.scrollingDeltaX
            swipeY += event.scrollingDeltaY
            // lock the axis once the gesture commits to one, so a slightly diagonal swipe
            // doesn't drag the card sideways while the user is scrolling the stack down
            if swipeAxis == .undecided, max(abs(swipeX), abs(swipeY)) > 8 {
                swipeAxis = abs(swipeX) > abs(swipeY) ? .horizontal : .vertical
            }
            guard swipeAxis == .horizontal else { return }
            // the window only has to grow once the gesture is known to be horizontal: a swipe
            // down to hide the stack was paying for a resize it never used
            panel.beginSwipe()
            armSwipeWatchdog()
            let elapsed = max(event.timestamp - swipeTime, 1.0 / 240)
            swipeTime = event.timestamp
            swipeVelocity = swipeVelocity * 0.6 + (event.scrollingDeltaX * towardEdgeSign / elapsed) * 0.4
            panel.swipe(to: swipeOffset())
        case .ended, .cancelled:
            finishSwipe(cancelled: event.phase == .cancelled)
        default: break
        }
    }

    /// Settle the gesture: dismiss if it earned it, otherwise put the card back in its slot.
    private func finishSwipe(cancelled: Bool) {
        swipeWatchdog?.cancel()
        swipeWatchdog = nil
        let inProgress = swiping
        let axis = swipeAxis
        swiping = false
        swipeAxis = .undecided
        guard inProgress else { return }
        switch axis {
        case .vertical:
            // the window is only grown once a gesture turns horizontal, so there is nothing
            // to put back here
            if swipeY < -40 { OverlayController.shared.hideAll() }
        case .horizontal:
            let dismiss = SwipePhysics.shouldDismiss(progress: swipeX * towardEdgeSign,
                                                     velocity: swipeVelocity,
                                                     width: bounds.width)
            if !cancelled, dismiss {
                flyOff()
            } else {
                springBack()
            }
        case .undecided:
            springBack()
        }
    }

    /// Scroll events stop the moment the card slides out from under the pointer, and `.ended`
    /// never arrives. Treat a gap in the stream as the end of the gesture so the card always
    /// resolves — dismissed if it was already far enough, back in its slot if it wasn't.
    private func armSwipeWatchdog() {
        // re-arming per scroll event allocated and cancelled a work item at trackpad rate;
        // the gap this detects is 250ms, so refreshing it a few times a second is plenty
        if let existing = swipeWatchdog, !existing.isCancelled,
           Date().timeIntervalSince(swipeWatchdogArmed) < 0.1 { return }
        swipeWatchdogArmed = Date()
        swipeWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.swiping else { return }
            self.finishSwipe(cancelled: false)
        }
        swipeWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// How far the card has moved with the finger, in screen terms.
    private func swipeOffset() -> CGFloat {
        SwipePhysics.offset(progress: swipeX * towardEdgeSign, width: bounds.width) * edgeScreenSign
    }

    private func flyOff() {
        // commit first: if the record is already gone there is nothing to fly away, and the card
        // should settle back rather than pretend it discarded something
        guard panel.commitDiscard() else { springBack(); return }
        let remaining = max(bounds.width + 60 - abs(swipeOffset()), 40)
        let duration = SwipePhysics.flyOffDuration(remaining: remaining, velocity: swipeVelocity)
        // the whole gesture, not just its committed axis: a swipe is rarely flat, and the card
        // should leave along the line it was actually thrown
        let direction = SwipePhysics.flyOffDirection(dx: swipeX, dy: swipeY, towardEdge: edgeScreenSign)
        panel.flyOffAndClose(direction: direction, velocity: swipeVelocity, over: duration)
    }

    /// The card animates back to its slot, which also shrinks the window around it again.
    private func springBack() {
        panel.endSwipe(springBackOver: 0.32)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDragged(with event: NSEvent) {
        // the pasteboard carries a concrete path — an AI rename mid-drag would break the drop
        Library.markInUse(panel.record.id)
        let item = NSDraggingItem(pasteboardWriter: panel.fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(cgImage: image, size: bounds.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Library.clearInUse(panel.record.id)
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
        if let seconds = panel.record.durationS, !hovering {
            // same formatter as the menu-bar timer, so a 59.6s clip can't read 0:59 there and 1:00 here
            let label = "▸ " + Tokens.duration(seconds) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            let pill = CGRect(x: 6, y: 6, width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attrs)
        }
    }
}
