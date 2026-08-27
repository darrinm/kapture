// The quality tier for naming: the capture image plus the text Vision already read, sent to
// Claude with the user's own key. Opt-in and off unless a key is set — image content leaves the
// Mac only on this path (spec §8). The key lives in the Keychain, never in UserDefaults.
import Foundation
import KaptureCore

public enum AnthropicNamer {
    public static let model = "claude-haiku-4-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Takes already-encoded JPEG bytes, never a CGImage: the caller encodes on a background
    /// task and lets the full-size image go, so only ~100 KB is alive across the network await.
    public static func name(jpeg: Data, ocr: String, app: String?, windowTitle: String?,
                            kind: CaptureKind, key: String) async throws -> CaptureNaming {
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
        // start < end matters: a reply whose only "}" precedes its "{" would trap on the slice
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"),
              start < end, let data = String(cleaned[start...end]).data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawName = obj["filename"] as? String
        else { throw Failure(description: "no JSON object in reply") }

        let filename = NamingService.sanitize(rawName)
        guard filename.count >= 3 else { throw Failure(description: "empty filename") }
        let tags = ((obj["tags"] as? [String]) ?? [])
            .map { NamingService.sanitize($0) }.filter { !$0.isEmpty }
        let summary = (obj["summary"] as? String ?? "").prefix(140).trimmingCharacters(in: .whitespaces)
        return CaptureNaming(filename: filename, tags: Array(tags.prefix(4)), summary: summary)
    }
}
