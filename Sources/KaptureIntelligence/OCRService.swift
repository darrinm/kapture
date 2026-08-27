// On-device text recognition (Vision). Two callers: the Capture Text action (⌘⇧2 → clipboard)
// and the background ingest queue, which OCRs every capture so the library's search index has
// something to match. Nothing leaves the Mac.
import Vision
import CoreGraphics
import KaptureCore

public enum OCRService {
    /// Run whichever Vision requests are wanted through a single image handler — Vision decodes
    /// and prepares the image once per handler, so asking it twice doubles that work.
    private static func read(_ image: CGImage, wantText: Bool, wantBarcodes: Bool)
        -> (text: String, barcodes: [String]) {
        var requests: [VNRequest] = []
        let textRequest = VNRecognizeTextRequest()
        if wantText {
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            requests.append(textRequest)
        }
        let barcodeRequest = VNDetectBarcodesRequest()
        if wantBarcodes { requests.append(barcodeRequest) }
        guard !requests.isEmpty else { return ("", []) }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
        } catch {
            Log.capture.error("ocr failed: \(error)")
            return ("", [])
        }
        let text = wantText
            ? (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            : ""
        let codes = wantBarcodes ? (barcodeRequest.results ?? []).compactMap(\.payloadStringValue) : []
        return (text, codes)
    }

    /// Recognized text, reading order preserved, one line per observation.
    public static func text(in image: CGImage) -> String {
        read(image, wantText: true, wantBarcodes: false).text
    }

    /// QR/barcode payloads found in the image, if any.
    public static func barcodes(in image: CGImage) -> [String] {
        read(image, wantText: false, wantBarcodes: true).barcodes
    }

    /// What the Capture Text action puts on the clipboard: barcode payloads win when present
    /// (a QR in frame is almost always the thing you meant), otherwise recognized text.
    /// Deliberately two passes rather than one combined handler: barcode detection is cheap and
    /// accurate text recognition is not, so short-circuiting keeps ⌘⇧2 snappy on the QR case.
    public static func clipboardText(for image: CGImage) -> String {
        let codes = barcodes(in: image)
        if !codes.isEmpty { return codes.joined(separator: "\n") }
        return text(in: image)
    }

    /// What the search index gets: everything readable, in one handler pass. Unlike the
    /// clipboard action there is no precedence here — a QR code in the corner must not displace
    /// the page of text around it, so both are kept.
    public static func indexText(for image: CGImage) -> String {
        let result = read(image, wantText: true, wantBarcodes: true)
        return ([result.text] + result.barcodes).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
