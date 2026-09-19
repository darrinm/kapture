// The one place that knows what "copy this capture" puts on the pasteboard.
import AppKit
import KaptureCore

@MainActor
enum Clipboard {
    /// The capture file last put on the pasteboard, and the pasteboard's change count at that
    /// moment. While the count is unchanged the pasteboard still holds that URL, so a move of
    /// the file can rewrite it in place.
    private static var lastFile: (url: URL, changeCount: Int)?

    /// Clear, then write the pixels and the file URL in a single declaration. Order matters:
    /// the image first so a receiver that takes the first item it can use gets pixels, the URL
    /// second so a paste into Finder still lands the file. Both go in one `writeObjects` call —
    /// a second call would clear the first's item.
    ///
    /// Slack reads the file URL and reports "File unsupported" when the path no longer exists.
    /// The AI rename moves the file about 30s after capture; `followLibraryMoves` rewrites the
    /// pasteboard with the new path.
    static func write(url: URL, image: NSImage?) {
        var objects: [any NSPasteboardWriting] = []
        if let image { objects.append(image) }
        objects.append(url as NSURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        lastFile = (url, pasteboard.changeCount)
    }

    /// Same contract, reading the pixels off disk.
    static func write(url: URL) {
        write(url: url, image: NSImage(contentsOf: url))
    }

    /// A share link goes on the pasteboard as text, not as a file URL: the point is to paste it
    /// into a message, and a `public.url` item pastes as an attachment in some apps.
    static func write(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static var moveObserver: FileMoveObserver?

    /// When the library moves the file the pasteboard points at (an AI rename, a discard, a
    /// restore) and nothing else has written to the pasteboard since, rewrite it with the new
    /// URL and the same pixels. Anything the user copied afterwards is left alone.
    static func followLibraryMoves() {
        moveObserver = FileMoveObserver(follow)
    }

    private static func follow(_ move: FileMove) {
        guard let last = lastFile, move.moved(last.url),
              NSPasteboard.general.changeCount == last.changeCount else { return }
        write(url: move.to)
    }
}
