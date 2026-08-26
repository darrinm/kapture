// Two-screen onboarding (impl spec v2.1 §10): welcome → Screen Recording grant → capture.
// All other permissions are just-in-time. Auto-relaunch after the grant.
import AppKit
import KaptureCapture
import KaptureCore
import KaptureDesign

@MainActor
final class Onboarding {
    static let shared = Onboarding()
    private var window: NSWindow?
    private var pollTimer: Timer?

    func showIfNeeded() {
        if !Settings.shared.onboardingComplete || !ScreenshotService.hasPermission { show() }
    }

    func show() {
        if window != nil { window?.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.center()
        window = w
        if ScreenshotService.hasPermission { welcomeDone() } else { renderPermission() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func renderPermission() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 36, right: 40)

        let mark = NSTextField(labelWithString: "Kapture.")
        mark.font = .systemFont(ofSize: 30, weight: .bold)
        let head = NSTextField(labelWithString: "Allow screen capture")
        head.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "macOS asks once. Kapture never uploads anything unless you choose to share it.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 320
        let button = NSButton(title: "Open System Settings", target: self, action: #selector(grantTapped))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        let sub = NSTextField(labelWithString: "Kapture will relaunch automatically.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .tertiaryLabelColor

        [mark, head, body, button, sub].forEach { root.addArrangedSubview($0) }
        window?.contentView = root
    }

    @objc private func grantTapped() {
        ScreenshotService.requestPermission()   // registers Kapture in the Screen Recording pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        // TCC evaluates per process launch, so the running app's preflight stays stale after the
        // grant. Poll via a fresh child process (--tcc-check), which reads the current TCC state.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task.detached {
                guard let exe = Bundle.main.executablePath else { return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["--tcc-check"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    await MainActor.run { Onboarding.shared.relaunch() }
                }
            }
        }
    }

    private func relaunch() {
        pollTimer?.invalidate()
        Settings.shared.onboardingComplete = true
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func welcomeDone() {
        Settings.shared.onboardingComplete = true
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 36, right: 40)
        let mark = NSTextField(labelWithString: "Kapture.")
        mark.font = .systemFont(ofSize: 30, weight: .bold)
        let head = NSTextField(labelWithString: "You're ready.")
        head.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Press ⌘⇧4 to take your first capture.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        let button = NSButton(title: "Done", target: self, action: #selector(dismiss))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        [mark, head, body, button].forEach { root.addArrangedSubview($0) }
        window?.contentView = root
    }

    @objc private func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
