// Verify-by-fire (spike D lesson): RegisterEventHotKey reports success even when another app
// already owns ⌘⇧3/4/5 — the press just goes to them, and Kapture looks broken for a reason
// the user cannot see. So: notice the apps that take those shortcuts, explain the conflict,
// offer to quit the other app, and re-check whenever one launches while Kapture runs.
import AppKit
import KaptureCore

@MainActor
final class ShortcutConflictWatch {
    static let shared = ShortcutConflictWatch()

    /// Apps known to register the system capture shortcuts. This is not a rivals list — it is
    /// the set of apps whose presence explains a shortcut that silently does nothing.
    private nonisolated static let known: [String: String] = [
        "pl.maketheweb.cleanshotx": "CleanShot X",
        "cc.ffitch.shottr": "Shottr",
        "com.xnapper.Xnapper": "Xnapper",
        "com.TechSmith.Snagit2024": "Snagit",
        "com.TechSmith.Snagit2025": "Snagit",
        "com.monosnap.monosnap": "Monosnap",
    ]
    private var dismissed = Set<String>()   // per-session "Ignore"

    func start() {
        check()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, ShortcutConflictWatch.known[id] != nil else { return }
            Task { @MainActor in ShortcutConflictWatch.shared.check() }
        }
    }

    func running() -> [(app: NSRunningApplication, name: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let name = ShortcutConflictWatch.known[id] else { return nil }
            return (app, name)
        }
    }

    func check() {
        for (app, name) in running() where !dismissed.contains(app.bundleIdentifier ?? "") {
            warn(about: app, name: name)
        }
    }

    private func warn(about app: NSRunningApplication, name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) is using the capture shortcuts"
        let contended = [HotkeyCenter.Action.fullscreen, .area, .record]
            .map { HotkeyCenter.shared.binding(for: $0).display }
            .joined(separator: " / ")
        alert.informativeText = "macOS gives \(contended) to whichever app claimed them first, and \(name) is running, so those presses may not reach Kapture. Both apps can be installed — only one can hold the shortcuts at a time."
        // "Keep both" is the default: quitting someone else's app should take a deliberate click
        alert.addButton(withTitle: "Keep \(name) running")
        alert.addButton(withTitle: "Quit \(name)")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            app.terminate()
            Log.shell.info("asked \(name, privacy: .public) to quit (hotkey contention)")
        } else {
            dismissed.insert(app.bundleIdentifier ?? "")
        }
    }
}
