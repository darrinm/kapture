// On-device text recognition (Vision). Two callers: the Capture Text action (⌘⇧2 → clipboard)
// and the background ingest queue, which OCRs every capture so the library's search index has
// something to match. Nothing leaves the Mac.
import Vision
import CoreGraphics
import KaptureCore

public enum OCRService {
    /// Recognized text, reading order preserved, one line per observation.
    public static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.capture.error("ocr failed: \(error)")
            return ""
        }
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// QR/barcode payloads found in the image, if any.
    public static func barcodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// What the Capture Text action puts on the clipboard: barcode payloads win when present
    /// (a QR in frame is almost always the thing you meant), otherwise recognized text.
    public static func clipboardText(for image: CGImage) -> String {
        let codes = barcodes(in: image)
        if !codes.isEmpty { return codes.joined(separator: "\n") }
        return text(in: image)
    }
}
