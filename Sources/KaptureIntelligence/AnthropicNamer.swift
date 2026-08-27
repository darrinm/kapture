// The quality tier for naming: the capture image plus the text Vision already read, sent to
// Claude with the user's own key. Opt-in and off unless a key is set — image content leaves the
// Mac only on this path (spec §8). The key lives in the Keychain, never in UserDefaults.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import KaptureCore

public enum AnthropicNamer {
    public static let model = "claude-haiku-4-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxEdge: CGFloat = 1024   // downscaled: naming needs layout, not pixels

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func name(image: CGImage, ocr: String, app: String?, windowTitle: String?,
                            kind: CaptureKind, key: String) async throws -> CaptureNaming {
        guard let jpeg = downscaledJPEG(image) else { throw Failure(description: "encode failed") }

        var context = ""
        if let app { context += "Source app bundle id: \(app)\n" }
        if let windowTitle, !windowTitle.isEmpty { context += "Window title: \(windowTitle)\n" }
        if !ocr.isEmpty { context += "Text recognized in the image:\n\(ocr.prefix(4000))\n" }

        let prompt = """
        Name this \(kind == .recording ? "screen recording" : "screenshot") for a personal capture \
        library, so its owner can find it months later.

        \(context)
        Reply with ONLY a JSON object, no prose:
        {"filename": "<kebab-case, 2-5 words, describing the SPECIFIC content — never generic \
        words like screenshot/window/screen/app>", "tags": ["<up to 4 short lowercase tags>"], \
        "summary": "<one sentence, max 100 chars>"}
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Failure(description: "http \(code): \(text.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first
        else { throw Failure(description: "unexpected response shape") }

        return try parse(text)
    }

    /// The model is asked for bare JSON; tolerate a fenced block anyway.
    static func parse(_ text: String) throws -> CaptureNaming {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"),
              let data = String(cleaned[start...end]).data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawName = obj["filename"] as? String
        else { throw Failure(description: "no JSON object in reply") }

        let filename = sanitize(rawName)
        guard filename.count >= 3 else { throw Failure(description: "empty filename") }
        let tags = ((obj["tags"] as? [String]) ?? []).map { sanitize($0) }.filter { !$0.isEmpty }
        let summary = (obj["summary"] as? String ?? "").prefix(140).trimmingCharacters(in: .whitespaces)
        return CaptureNaming(filename: filename, tags: Array(tags.prefix(4)), summary: summary)
    }

    /// kebab-case, filesystem-safe, capped — the model's output is never trusted as a path.
    static func sanitize(_ raw: String) -> String {
        var out = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
        if out.count > 48 { out = String(out.prefix(48)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static func downscaledJPEG(_ image: CGImage) -> Data? {
        let scale = min(1, maxEdge / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
