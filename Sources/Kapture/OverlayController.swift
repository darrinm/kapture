// Quick Access Overlay (M1): stacked capture panels in the bottom corner with hover chrome.
// Keep and discard are distinct one-gesture actions (product spec §2.0): × / ⌘W keeps,
// trash / ⌘⌫ / swipe-toward-edge discards into the 7-day trash. space = Quick Look.
// Beyond 5 the pile collapses into a "+n" card. Right-click menu on every card. Swipe down
// tucks the whole stack off the bottom edge behind a small tab that brings it back.
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
    private var tuckTab: TuckTab?
    private var fannedOut = false
    /// The stack has been swiped down out of the way; only the tab is on screen.
    private(set) var tucked = false
    /// Bumped by every tuck and untuck, so a tuck's animation completion can tell whether it is
    /// still the current one: a tuck→untuck→tuck inside a quarter second must not have the first
    /// tuck's completion order the stack out from under the second's slide.
    private var tuckGeneration = 0
    var library: Library?
    weak var hoveredPanel: OverlayPanel?   // consulted by the event-tap tier

    /// The display the stack lives on, held across layouts. `NSScreen.main` is the screen of the
    /// *key window*, so it swings to whichever display was last clicked; re-reading it on every
    /// layout let a dismissal, a tuck or a fan-out fling the surviving cards onto another monitor.
    /// A new capture re-anchors the stack (it belongs where the shot was taken); nothing else does.
    private var anchorDisplay: CGDirectDisplayID?

    private init() {
        // an unplugged anchor display strands the cards on coordinates no screen covers any
        // more; relayout so they resolve onto a live one
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { OverlayController.shared.layout() } }
    }

    /// The anchored display, or — with no anchor yet, or its display gone — the current one,
    /// which then becomes the anchor.
    private var stackScreen: NSScreen? {
        if let id = anchorDisplay, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        anchorDisplay = screen?.displayID
        return screen
    }

    /// Move the stack to the display a capture came from: the record's own screen for a display
    /// or area shot, the screen under the source rect for a window one, else wherever we are.
    private func anchor(to record: CaptureRecord, sourceRect: NSRect?) {
        if let id = record.screenID.map({ CGDirectDisplayID($0) }),
           NSScreen.screens.contains(where: { $0.displayID == id }) {
            anchorDisplay = id
        } else if let rect = sourceRect,
                  let screen = NSScreen.screens.max(by: {
                      $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
                  }), screen.frame.intersects(rect) {
            anchorDisplay = screen.displayID
        } else {
            anchorDisplay = (NSScreen.main ?? NSScreen.screens.first)?.displayID
        }
    }

    func show(record: CaptureRecord, fileURL: URL, image: CGImage, from sourceRect: NSRect? = nil) {
        let panel = OverlayPanel(record: record, fileURL: fileURL, image: image) { [weak self] panel in
            self?.remove(panel)
        }
        anchor(to: record, sourceRect: sourceRect)   // the stack follows the newest capture
        untuck()   // a new capture is something to look at; the stack comes back with it
        panels.append(panel)
        fannedOut = false

        guard let source = sourceRect, !Tokens.reduceMotion, let screen = stackScreen else {
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
                flight.orderOut(nil)
                // the stack was tucked while this was in flight: the card went down with it (it
                // was already in its slot), and ordering it in here would park it below the
                // screen; untuck brings it up and fades it in with the rest
                guard self?.tucked != true else { return }
                panel.alphaValue = 1
                // re-derive the slot at landing time — the stack may have moved mid-flight
                self?.layout(animated: false)
                panel.orderFrontRegardless()
                panel.settleIn()
                panel.scheduleAutoClose()
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

    // MARK: tuck — swipe down puts the stack out of the way without closing anything

    /// Slide the whole stack down off the screen and leave a tab at the edge to bring it back.
    /// The cards are out of the way of whatever is under them, not gone: nothing closes, and
    /// auto-close waits until they are back in sight.
    func tuck() {
        // only the cards in slots move: the ones collapsed behind the "+n" chip are already
        // ordered out, and shifting them too would leave them parked below the screen for the
        // next fan-out to slide up from
        let stack = slotted
        guard !tucked, let screen = stackScreen,
              let top = stack.map(\.frame.maxY).max() else { return }
        tucked = true
        tuckGeneration += 1
        let generation = tuckGeneration
        hoveredPanel = nil
        collapseChip?.orderOut(nil)
        panels.forEach { $0.pauseAutoClose() }
        // the swiped card is under the pointer, and no mouseExited reaches a window that has
        // left; its chrome would otherwise still be up when the stack came back
        stack.forEach { $0.card.hovering = false }
        // the stack drops as one piece, by however much its top needs to clear the bottom of
        // the display — the display, not the visible area: passing under the Dock is part of it
        let dy = screen.frame.minY - top - Tokens.cornerMargin
        Tokens.animate(0.25, timing: CAMediaTimingFunction(name: .easeIn), {
            for panel in stack {
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: dy), display: true)
            }
        }) { [weak self] in
            guard let self, self.tuckGeneration == generation else { return }
            // ordered out rather than parked below the screen: an ordered-in panel still owns
            // tracking areas, which would keep feeding hoveredPanel and let the event tap
            // swallow keys invisibly
            stack.forEach { $0.orderOut(nil) }
            // the cards above the swiped one slid through the pointer on the way down, and any
            // that picked up a mouseEntered there gets no mouseExited now that it has left
            stack.forEach { $0.card.hovering = false }
            self.hoveredPanel = nil
        }
        layout()   // tucked: lays out the tab
    }

    /// Bring a tucked stack back up into its slots.
    func untuck() {
        guard tucked else { return }
        tucked = false
        tuckGeneration += 1
        tuckTab?.orderOut(nil)
        // the slotted cards are parked below the screen (and ordered out once the tuck finished);
        // put them back on before the relayout so it slides them up from there
        slotted.forEach { $0.orderFrontRegardless() }
        layout()
        panels.forEach { $0.scheduleAutoClose() }
    }

    func fanOut() { fannedOut = true; layout() }

    func closeAllKeeping() {
        panels.forEach { $0.keepAndClose() }
    }

    private func remove(_ panel: OverlayPanel) {
        panels.removeAll { $0 === panel }
        // an emptied stack has nothing to bring back, so it stops being tucked — the next
        // capture must not appear from below the screen
        if panels.isEmpty, tucked { untuck() } else { layout() }
    }

    private let visibleLimit = 5
    /// The cards layout puts in slots. Past the limit the oldest collapse behind the "+n" chip
    /// (ordered out, frames left where they were) until the stack is fanned out.
    private var slotted: [OverlayPanel] {
        fannedOut || panels.count <= visibleLimit ? panels : Array(panels.suffix(visibleLimit))
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
        guard let screen = stackScreen else { return }
        let slot = cornerSlotFrame(on: screen)
        if tucked { layoutTab(on: screen, slot: slot); return }
        let size = slot.size
        let x = slot.minX
        var y = slot.minY

        let visible = slotted
        let hidden = Array(panels.dropLast(visible.count))

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

    /// The stack is off screen; only its tab is placed.
    private func layoutTab(on screen: NSScreen, slot: NSRect) {
        let tab = tuckTab ?? TuckTab { [weak self] in self?.untuck() }
        tuckTab = tab
        tab.update(count: panels.count)
        // flush with the bottom of the visible area, so it rides on top of a bottom Dock rather
        // than disappearing behind it, at the corner the stack lives in
        let size = TuckTab.size
        let x = Settings.shared.overlayOnLeftEdge ? slot.minX : slot.maxX - size.width
        tab.setFrame(NSRect(x: x, y: screen.visibleFrame.minY, width: size.width, height: size.height),
                     display: true)
        if !tab.isVisible {
            tab.alphaValue = 0
            tab.orderFrontRegardless()
            Tokens.animate(0.2) { tab.animator().alphaValue = 1 }
        }
    }
}

extension NSScreen {
    /// The display this screen draws, stable across the NSScreen objects AppKit hands back
    /// after a display configuration change — which the screen references themselves are not.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The stack's chrome — the "+n" chip and the tuck tab — floats beside the cards: the same
/// non-activating panel on every Space, at the cards' level, wrapping one custom view.
class StackChromePanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear
        level = .statusBar; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = contentView
    }
}

/// The handle a tucked stack leaves at the bottom edge: click it, or swipe up on it, and the
/// stack comes back. Sized as a tab rather than a card — it exists to stay out of the way.
final class TuckTab: StackChromePanel {
    static let size = CGSize(width: 64, height: 22)

    init(onOpen: @escaping () -> Void) {
        super.init(contentView: TuckTabView(onOpen: onOpen))
    }

    func update(count: Int) {
        (contentView as? TuckTabView)?.count = count
    }
}

final class TuckTabView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    let onOpen: () -> Void
    private var swipeY: CGFloat = 0

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onOpen() }

    /// The reverse of the swipe that tucked the stack.
    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began:
            swipeY = 0
        case .changed:
            swipeY += event.scrollingDeltaY
            // the tab is ordered out by the first of these, so the rest of the stream never arrives
            if swipeY > 40 { onOpen() }
        default: break
        }
    }

    override func draw(_ dirty: NSRect) {
        // rounded at the top only: the tab grows out of the screen edge
        let r: CGFloat = 8
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: 0, y: 0))
        shape.line(to: NSPoint(x: 0, y: bounds.height - r))
        shape.appendArc(withCenter: NSPoint(x: r, y: bounds.height - r), radius: r,
                        startAngle: 180, endAngle: 90, clockwise: true)
        shape.line(to: NSPoint(x: bounds.width - r, y: bounds.height))
        shape.appendArc(withCenter: NSPoint(x: bounds.width - r, y: bounds.height - r), radius: r,
                        startAngle: 90, endAngle: 0, clockwise: true)
        shape.line(to: NSPoint(x: bounds.width, y: 0))
        shape.close()
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        shape.fill()

        // an up chevron and the count, centered as one unit
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let label = "\(count)" as NSString
        let labelSize = label.size(withAttributes: attrs)
        let chevronWidth: CGFloat = 9, gap: CGFloat = 5
        let left = (bounds.width - (chevronWidth + gap + labelSize.width)) / 2
        let midY = bounds.midY

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: left, y: midY - 2))
        chevron.line(to: NSPoint(x: left + chevronWidth / 2, y: midY + 2.5))
        chevron.line(to: NSPoint(x: left + chevronWidth, y: midY - 2))
        chevron.lineWidth = 1.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.labelColor.setStroke()
        chevron.stroke()

        label.draw(at: NSPoint(x: left + chevronWidth + gap, y: midY - labelSize.height / 2), withAttributes: attrs)
    }
}

final class CollapseChip: StackChromePanel {
    init(onClick: @escaping () -> Void) {
        super.init(contentView: ChipView(text: "", onClick: onClick))
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
    /// Derived rather than stored: it is the card's own offset inside the grown window, and a
    /// second copy of that is a second thing to keep in step. (`swipePad` is not derivable the
    /// same way — the card's x genuinely leaves the pad during a drag.)
    private var swipeVPad: CGFloat { card.frame.origin.y }
    private var container: OverlayContainerView? { contentView as? OverlayContainerView }
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
        // a tucked card is out of sight; it must not quietly close (or save) while it is
        guard Settings.shared.autoCloseEnabled, !OverlayController.shared.tucked else { return }
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: Double(Settings.shared.autoCloseInterval),
                                              repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Settings.shared.autoCloseSaves ? self.saveToExportLocation() : self.keepAndClose()
            }
        }
    }

    func pauseAutoClose() {
        autoCloseTimer?.invalidate(); autoCloseTimer = nil
    }

    func hoverChanged(_ hovering: Bool) {
        if hovering {
            pauseAutoClose()
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
        swipePad = rest.width + SwipePhysics.flyOffMargin
        // Vertical room as well, for the lean — see `verticalClearance` for why it is needed.
        let vpad = ceil(SwipePhysics.verticalClearance(width: rest.width, height: rest.height,
                                                       degrees: SwipePhysics.maxRotation))
        setFrame(rest.insetBy(dx: -swipePad, dy: -vpad), display: false)
        // the margins have to catch events for as long as they exist, or the gesture dies the
        // moment the card clears the pointer — see `catchesEventsAcrossTheWindow`
        container?.catchesEventsAcrossTheWindow = true
        // a settle-in spring still in flight would keep driving the card back to the slot's
        // origin — inside the grown window that is the far left edge, so the card would lurch
        // sideways under a swipe started in the first fraction of a second
        card.layer?.removeAllAnimations()
        card.frame = NSRect(x: swipePad, y: vpad, width: rest.width, height: rest.height)
        invalidateShadow()
    }

    /// Move the card within the window. `offset` is in screen terms, from the resting position.
    func swipe(to offset: CGFloat) {
        guard swiping else { return }
        // restingFrame.width, not card.frame.width: the card cannot resize mid-gesture, and this
        // runs on every scroll event. setFrameOrigin rather than mutating frame.origin.x, which
        // is a get-modify-set through the rotation-aware frame conversion.
        card.setFrameOrigin(NSPoint(x: swipePad + offset, y: swipeVPad))
        card.frameCenterRotation = SwipePhysics.tilt(offset: offset, width: restingFrame.width)
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
        let box = card.frame
        // Dismissal is defined by clearing the edge, so the horizontal distance is fixed at a full
        // card plus margin whatever the angle, and the vertical follows from the slope. Stated this
        // way round the guarantee is visible; as a distance-along-the-line it had to be divided by
        // dx and multiplied straight back, and a flat reading of it fell a third short sideways.
        let reach = box.width + SwipePhysics.flyOffMargin
        let rise = reach * direction.dy / direction.dx
        // keeps turning on the way out, harder the harder it was flicked
        let spin = card.frameCenterRotation + SwipePhysics.spin(velocity: velocity, direction: direction)
        // The exit leaves the window vertically as well, so make room for the whole path before
        // starting — the rotation alone is not enough. See `verticalClearance`.
        let vpad = max(swipeVPad,
                       abs(rise) + SwipePhysics.verticalClearance(width: box.width, height: box.height,
                                                                  degrees: spin))
        setFrame(restingFrame.insetBy(dx: -swipePad, dy: -vpad), display: false)
        card.frame.origin.y = vpad
        let target = NSRect(x: swipePad + copysign(reach, direction.dx), y: vpad + rise,
                            width: box.width, height: box.height)
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

    /// Put the window back around the card once a gesture is over.
    func settleAfterSwipe() {
        guard swiping else { return }
        swiping = false
        container?.catchesEventsAcrossTheWindow = false   // the margins are gone again
        setFrame(restingFrame, display: true)
        card.frameCenterRotation = 0   // before the frame: rotation is about the frame's centre
        card.frame = NSRect(origin: .zero, size: restingFrame.size)
        card.alphaValue = 1
        swipePad = 0
        invalidateShadow()
    }

    /// Land in the slot with a little weight: arrive fractionally small and spring to full size,
    /// so a capture drops onto the stack instead of materialising there.
    ///
    /// Inset rather than scaled up, because a card that overshoots *larger* is clipped by its own
    /// window — the window is exactly the slot. Reduce Motion is left to `Tokens.animate`, which
    /// runs it at zero duration: the card is set inset and restored within the same runloop turn,
    /// so nothing is ever drawn small.
    func settleIn() {
        guard !swiping, restingFrame != .zero else { return }
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true   // the swipe needs somewhere to put the fill below
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Whether the grown margins exist as far as the *window server* is concerned.
    ///
    /// It decides which window a scroll belongs to from the alpha in the window's backing store,
    /// and passes straight through fully transparent pixels to whatever is behind. The margins a
    /// swipe grows are unpainted, so the instant the card slid out from under the pointer the rest
    /// of the gesture was delivered to another window entirely: the card froze, `.ended` never
    /// came, and the watchdog resolved it a quarter-second later — often on too little travel to
    /// count as a dismissal, which is why it sometimes sprang back instead.
    ///
    /// That is also why it depended on where you grabbed the card. The card leaves the pointer
    /// after travelling the distance from its leading edge to the cursor, so a swipe started near
    /// that edge died almost at once and one started near the trailing edge outlived the gesture.
    ///
    /// One part in 255 is invisible and is enough to make the window claim the events.
    var catchesEventsAcrossTheWindow = false {
        didSet {
            guard catchesEventsAcrossTheWindow != oldValue else { return }
            layer?.backgroundColor = catchesEventsAcrossTheWindow
                ? NSColor.black.withAlphaComponent(1.0 / 255).cgColor
                : nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let card else { return nil }
        // For the length of a gesture the swipe owns the whole window. A trackpad swipe leaves the
        // pointer where it started while the card slides out from under it, and scroll events are
        // hit-tested afresh every one — so testing them against the card's *moved* frame would cut
        // the gesture off the moment the card cleared the pointer.
        //
        // This is only half of keeping the stream alive, and on its own it changes nothing: the
        // window server drops the event before AppKit ever gets to hit-test it. See
        // `catchesEventsAcrossTheWindow` for the half that makes the window claim the event, and
        // this one for routing it to the card once it arrives.
        if card.swiping { return card }
        guard card.frame.contains(convert(point, from: superview)) else { return nil }
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
    private var trashButton: HoverButton!
    // Swipe-to-dismiss, modelled on a macOS notification banner: the card tracks the finger,
    // resists when dragged the wrong way, and on release either carries on off the edge or
    // springs back. The old version only measured the gesture and acted at the end, so the card
    // sat still under your finger and dismissal felt like a command rather than a movement.
    private enum SwipeAxis { case undecided, horizontal, vertical }
    private var swipeAxis: SwipeAxis = .undecided
    /// Read by the container, which widens its hit test to the whole window for the length of a
    /// gesture — otherwise the card moving away from the pointer ends its own event stream.
    private(set) var swiping = false
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

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> HoverButton {
        let b = HoverButton(symbol: symbol, pointSize: 11, tip: tip, target: self, action: action)
        b.contentTintColor = .white
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
        // A layer-backed view defaults to .duringViewResize, which re-renders its contents at
        // every step of a size change — and `draw` here downsamples the entire capture at .high
        // quality. `settleIn` animates the card's size on the frame a capture lands, so the
        // default would resample a multi-megapixel image repeatedly at the busiest moment in the
        // app. Stretch the cached contents instead: the change is 3% and lasts 0.22s.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
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
        trackHover()
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
            // down to tuck the stack was paying for a resize it never used
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
            if swipeY < -40 { OverlayController.shared.tuck() }
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
        // the same full-card-plus-margin the exit travels and tracking stops at, so a card the
        // finger already carried the whole way has only the floor left to cover
        let remaining = max(bounds.width + SwipePhysics.flyOffMargin - abs(swipeOffset()), 40)
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
