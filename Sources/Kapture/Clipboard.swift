// The one place that knows what "copy this capture" puts on the pasteboard.
import AppKit

enum Clipboard {
    /// Clear, then write the file URL and the pixels in a single declaration. Order matters:
    /// the URL first so a paste into Finder or a mail compose window attaches the file, the
    /// image second so a paste into a canvas that can't take a file still gets pixels. Both go
    /// in one `writeObjects` call — a second call would clear the first's item.
    static func write(url: URL, image: NSImage?) {
        var objects: [any NSPasteboardWriting] = [url as NSURL]
        if let image { objects.append(image) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(objects)
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
}
