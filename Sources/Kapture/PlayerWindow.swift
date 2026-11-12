// Sizing shared by the windows that play a recording: the trimmer and Grab Frames.
import AppKit
import KaptureCore

/// Content size for a window that plays `record` above a bar `barHeight` points tall. The movie
/// shows at half its pixel width, at most 70% of the screen's width, and the whole window at
/// most 85% of the screen's height, so a portrait recording's bar stays on screen.
@MainActor
func playerWindowSize(for record: CaptureRecord, barHeight: CGFloat = 0) -> NSSize {
    let aspect = record.height > 0 ? CGFloat(record.width) / CGFloat(record.height) : 16.0 / 9
    let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    var w = min(CGFloat(record.width) / 2, visible.width * 0.7)
    var h = w / aspect
    let maxHeight = visible.height * 0.85 - barHeight
    if h > maxHeight { h = maxHeight; w = h * aspect }
    return NSSize(width: max(560, w), height: max(320, h) + barHeight)
}
