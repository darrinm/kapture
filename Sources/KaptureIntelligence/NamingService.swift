// Names, tags and a one-line summary for a capture. The on-device engine works from the text
// Vision already recognized plus the source app — the M3 benchmark found a 2B VLM's *good*
// answers came from text in the image anyway, and this needs no model download and no GPU.
// The API engine (opt-in, user's own key) is the quality tier; see NamingEngine.
import Foundation
import KaptureCore

public struct CaptureNaming: Sendable, Equatable {
    public var filename: String      // kebab-case, no extension
    public var tags: [String]
    public var summary: String
}

public enum NamingService {
    /// Words that never make a useful filename on their own.
    private static let stop: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "your", "you", "are", "was", "has",
        "have", "not", "but", "all", "can", "will", "when", "what", "how", "why", "into", "out",
        "new", "get", "set", "let", "use", "see", "our", "its", "it's", "http", "https", "www",
        "com", "org", "net", "png", "jpg", "mp4", "gif", "am", "pm",
    ]

    /// Menu-bar and window chrome: present in almost every screenshot, so a name built only
    /// from these says nothing. A capture whose text yields nothing else keeps its timestamp.
    private static let chrome: Set<String> = [
        "file", "edit", "view", "window", "help", "format", "tools", "options", "settings",
        "preferences", "app", "apps", "menu", "bar", "tab", "tabs", "untitled", "document",
        "search", "close", "open", "save", "cancel", "done", "back", "next", "home", "page",
    ]

    /// App name from a bundle id: "com.apple.dt.Xcode" → "xcode".
    static func appName(_ bundleID: String?) -> String? {
        guard let bundleID, bundleID != "sh.kapture.app" else { return nil }   // never name after ourselves
        // last component is usually the app ("com.apple.dt.Xcode" → xcode), but a trailing
        // ".app"/".macos" is packaging noise — step back to the meaningful component
        let parts = bundleID.split(separator: ".").map { $0.lowercased() }
        guard let name = parts.reversed().first(where: { !chrome.contains($0) && $0.count > 2 && $0 != "macos" })
        else { return nil }
        return name
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && $0.count < 24 && !stop.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// The most title-like line of recognized text: short, wordy, near the top.
    static func headline(_ ocr: String) -> String? {
        let lines = ocr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = lines.prefix(12).filter { line in
            let words = line.split(separator: " ")
            return words.count >= 2 && words.count <= 8 && line.count >= 8 && line.count <= 64
                && line.contains(where: \.isLetter)
        }
        return candidates.first ?? lines.first(where: { $0.count >= 4 && $0.contains(where: \.isLetter) })
    }

    public static func local(ocr: String, app: String?, windowTitle: String?,
                             kind: CaptureKind) -> CaptureNaming? {
        let appToken = appName(app)
        // window title beats OCR when we have one — it's the app's own summary of the view
        let source = (windowTitle?.isEmpty == false ? windowTitle : headline(ocr)) ?? headline(ocr)
        var words = tokens(source ?? "").filter { !chrome.contains($0) }
        if words.count < 2 { words = Array(tokens(ocr).filter { !chrome.contains($0) }.prefix(4)) }
        // Confidence gate: a name needs real content words. Without them the timestamp is the
        // honest answer — a wrong name is worse than no name (M3 benchmark lesson).
        guard words.count >= 2 else { return nil }

        var parts: [String] = []
        if let appToken, !words.contains(appToken) { parts.append(appToken) }
        parts.append(contentsOf: words.prefix(5))
        var filename = parts.joined(separator: "-")
        if filename.count > 48 { filename = String(filename.prefix(48)) }
        while filename.hasSuffix("-") { filename.removeLast() }
        guard filename.count >= 3 else { return nil }

        // tags: the app, the kind, and the two most repeated content words
        var counts: [String: Int] = [:]
        for t in tokens(ocr) where !chrome.contains(t) { counts[t, default: 0] += 1 }
        let frequent = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(2).map(\.key)
        var tags = [appToken, kind == .recording ? "recording" : nil].compactMap { $0 }
        tags.append(contentsOf: frequent.filter { !tags.contains($0) })

        let summary = (source ?? "").prefix(120).trimmingCharacters(in: .whitespaces)
        return CaptureNaming(filename: filename, tags: Array(tags.prefix(4)), summary: summary)
    }
}
