import ScreenCaptureKit
import KaptureCore

/// Cached SCShareableContent — never fetched on the capture hot path (spec §3.1, spike A).
public actor ContentCache {
    public static let shared = ContentCache()
    private var content: SCShareableContent?
    private var lastRefresh = Date.distantPast

    public func current(maxAge: TimeInterval = 5) async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(lastRefresh) < maxAge { return content }
        return await refresh()
    }

    @discardableResult
    public func refresh() async -> SCShareableContent? {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = c
            lastRefresh = Date()
            return c
        } catch {
            Log.capture.error("shareable content refresh failed: \(error)")
            return content
        }
    }

    /// Kick off a background refresh at launch and keep warm.
    public func startWarming() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
