// Click and keystroke visualization. Both are real on-screen windows inside the recorded
// region, so ScreenCaptureKit bakes them into the movie with no compositing work (spike-verified
// approach). Needs the Accessibility grant for the event taps; silently absent without it.
import AppKit
import KaptureCore
import KaptureDesign

@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()
    private var clickWindow: ClickWindow?
    private var keysWindow: KeystrokeWindow?
    private var monitor: Any?

    var isAvailable: Bool { AXIsProcessTrusted() }

    func start(showClicks: Bool, showKeys: Bool) {
        guard isAvailable, showClicks || showKeys else { return }
        if showClicks {
            let w = ClickWindow()
            w.orderFrontRegardless()
            clickWindow = w
        }
        if showKeys {
            let w = KeystrokeWindow()
            w.orderFrontRegardless()
            keysWindow = w
        }
        var mask: NSEvent.EventTypeMask = []
        if showClicks { mask.insert([.leftMouseDown, .rightMouseDown]) }
        if showKeys { mask.insert([.keyDown, .flagsChanged]) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                switch event.type {
                case .leftMouseDown, .rightMouseDown:
                    self?.clickWindow?.ripple(at: NSEvent.mouseLocation)
                case .keyDown:
                    self?.keysWindow?.show(RecordingHUD.describe(event))
                default: break
                }
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clickWindow?.orderOut(nil); clickWindow = nil
        keysWindow?.orderOut(nil); keysWindow = nil
    }

    private static func describe(_ event: NSEvent) -> String {
        var parts = ""
        let f = event.modifierFlags
        if f.contains(.control) { parts += "⌃" }
        if f.contains(.option) { parts += "⌥" }
        if f.contains(.shift) { parts += "⇧" }
        if f.contains(.command) { parts += "⌘" }
        let named: [UInt16: String] = [36: "return", 48: "tab", 49: "space", 51: "delete",
                                       53: "esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = named[event.keyCode] { return parts + name }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        return parts + chars
    }
}

/// Full-screen click-through window drawing expanding click ripples.
final class ClickWindow: NSPanel {
    private let view = ClickView()
    init() {
        let frame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = view
    }
    func ripple(at screenPoint: NSPoint) {
        view.addRipple(at: NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY))
    }
}

final class ClickView: NSView {
    private struct Ripple { let point: NSPoint; let born: Date }
    private var ripples: [Ripple] = []
    private var timer: Timer?

    func addRipple(at p: NSPoint) {
        ripples.append(Ripple(point: p, born: Date()))
        needsDisplay = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.ripples.removeAll { Date().timeIntervalSince($0.born) > 0.55 }
                    self.needsDisplay = true
                    if self.ripples.isEmpty { self.timer?.invalidate(); self.timer = nil }
                }
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for r in ripples {
            let t = min(1, Date().timeIntervalSince(r.born) / 0.55)
            let radius = 8 + 26 * t
            let alpha = 0.55 * (1 - t)
            ctx.setStrokeColor(Tokens.accent.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(3 * (1 - t) + 1)
            ctx.strokeEllipse(in: CGRect(x: r.point.x - radius, y: r.point.y - radius,
                                         width: radius * 2, height: radius * 2))
        }
    }
}

/// Bottom-center keystroke HUD; keys accumulate briefly then fade.
final class KeystrokeWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var recent: [String] = []
    private var clearTask: Task<Void, Never>?

    init() {
        let screen = NSScreen.main?.frame ?? .zero
        super.init(contentRect: NSRect(x: screen.midX - 220, y: screen.minY + 90, width: 440, height: 52),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = 12
        label.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
        alphaValue = 0
    }

    func show(_ key: String) {
        guard !key.isEmpty else { return }
        recent.append(key)
        if recent.count > 6 { recent.removeFirst() }
        label.stringValue = recent.joined(separator: "  ")
        // size to content, keep centered on the main screen
        let width = max(120, label.intrinsicContentSize.width + 48)
        if let screen = NSScreen.main {
            setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 90,
                            width: width, height: 52), display: true)
        }
        alphaValue = 1
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            Tokens.animate(0.25) { self.animator().alphaValue = 0 }
            recent.removeAll()
        }
    }
}
