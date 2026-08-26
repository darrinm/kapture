// Verify-by-fire (spike D lesson): RegisterEventHotKey reports success even when another
// capture app owns ⌘⇧3/4/5 — the press just goes to them. So: detect known capture apps,
// warn with a one-click quit, and re-check whenever one launches while Kapture runs.
import AppKit
import KaptureCore

@MainActor
final class CompetitorWatch {
    static let shared = CompetitorWatch()

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
                  let id = app.bundleIdentifier, CompetitorWatch.known[id] != nil else { return }
            Task { @MainActor in CompetitorWatch.shared.check() }
        }
    }

    func running() -> [(app: NSRunningApplication, name: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let name = CompetitorWatch.known[id] else { return nil }
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
        alert.messageText = "\(name) may intercept your capture shortcuts"
        alert.informativeText = "\(name) is running and also listens for ⌘⇧3 / ⌘⇧4 / ⌘⇧5, so presses may go to it instead of Kapture. Quit it to make Kapture's shortcuts reliable."
        alert.addButton(withTitle: "Quit \(name)")
        alert.addButton(withTitle: "Ignore")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            app.terminate()
            Log.shell.info("asked \(name, privacy: .public) to quit (hotkey contention)")
        } else {
            dismissed.insert(app.bundleIdentifier ?? "")
        }
    }
}
