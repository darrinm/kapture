// Brief confirmation for actions with no visible artifact — Capture Text's clipboard result,
// mostly. Bottom-center, click-through, fades on its own.
import AppKit
import KaptureDesign

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismiss: Task<Void, Never>?

    static func show(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let width = min(max(label.intrinsicContentSize.width + 40, 160), 520)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: screen.midX - width / 2, y: screen.minY + 120, width: width, height: 44)

        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: width - 24),
        ])
        p.contentView = container
        p.setFrame(frame, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        dismiss?.cancel()
        dismiss = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Tokens.animate(0.25, { p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
    }
}
