// Live Text: select and copy the words in a capture, as Preview and Quick Look allow.
// VisionKit does the recognition and draws the selection; this is what every host shares.
import AppKit
import VisionKit

@MainActor
public enum LiveText {
    /// One analyzer for the process. Apple recommends reusing it, and it is Sendable.
    private static let analyzer = ImageAnalyzer()

    /// A text-selection overlay with VisionKit's corner Live Text button hidden: a pin is small
    /// and the editor already has a full toolbar, so the button would only cover the capture.
    public static func makeOverlay() -> ImageAnalysisOverlayView {
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
        return overlay
    }

    /// The text VisionKit finds in `image`. Nil when this Mac cannot analyze images or the image
    /// has no text, so a host has nothing to attach.
    public static func analyze(_ image: CGImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        let analysis = try? await analyzer.analyze(image, orientation: .up,
                                                   configuration: .init(.text))
        return analysis?.hasResults(for: .text) == true ? analysis : nil
    }

    /// Whether a press at `point` (the overlay's own coordinates) lands on text.
    /// `hasInteractiveItem(at:)` takes a top-left-origin point whatever the overlay's geometry:
    /// asked with an unflipped view point, it answers for the vertically mirrored row.
    public static func hasText(in overlay: ImageAnalysisOverlayView, at point: CGPoint) -> Bool {
        let topLeft = overlay.isFlipped ? point : CGPoint(x: point.x, y: overlay.bounds.height - point.y)
        return overlay.hasInteractiveItem(at: topLeft)
    }

    /// Put the overlay's selected text on the clipboard. Returns false when nothing is selected,
    /// so the host's own Copy can run instead.
    @discardableResult
    public static func copySelection(of overlay: ImageAnalysisOverlayView) -> Bool {
        guard overlay.hasActiveTextSelection, !overlay.selectedText.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(overlay.selectedText, forType: .string)
        return true
    }
}
