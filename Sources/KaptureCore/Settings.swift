import Foundation
import AppKit

/// UserDefaults-backed settings. Keychain-bound values (API key, upload token) come later (M4/M5).
public struct Settings {
    public static var shared = Settings()
    private let d = UserDefaults.standard

    public var libraryRoot: URL {
        get {
            if let path = d.string(forKey: "libraryRoot") { return URL(fileURLWithPath: path) }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kapture")
        }
        set { d.set(newValue.path, forKey: "libraryRoot") }
    }

    public var exportLocation: URL {
        get {
            if let path = d.string(forKey: "exportLocation") { return URL(fileURLWithPath: path) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { d.set(newValue.path, forKey: "exportLocation") }
    }

    public var copyToClipboardAfterCapture: Bool {
        get { d.object(forKey: "copyAfterCapture") as? Bool ?? true }
        set { d.set(newValue, forKey: "copyAfterCapture") }
    }

    /// Serialized previous-area selection: "displayID:x:y:w:h" (display-local points).
    public var lastArea: String? {
        get { d.string(forKey: "lastArea") }
        set { d.set(newValue, forKey: "lastArea") }
    }

    public var overlaySizeIndex: Int {
        get { min(max(d.object(forKey: "overlaySizeIndex") as? Int ?? 1, 0), 2) }
        set { d.set(newValue, forKey: "overlaySizeIndex") }
    }

    /// Which library thumbnail size the zoom control is on. An index into `Tokens.gridRowHeights`,
    /// which lives in the design module — so the range is clamped at the point of use, where that
    /// array actually is, rather than restated as a number here that would silently go stale.
    public var librarySizeIndex: Int {
        get { d.object(forKey: "librarySizeIndex") as? Int ?? 1 }
        set { d.set(newValue, forKey: "librarySizeIndex") }
    }

    public var overlayOnLeftEdge: Bool {
        get { d.bool(forKey: "overlayOnLeftEdge") }
        set { d.set(newValue, forKey: "overlayOnLeftEdge") }
    }

    public var onboardingComplete: Bool {
        get { d.bool(forKey: "onboardingComplete") }
        set { d.set(newValue, forKey: "onboardingComplete") }
    }

    public var soundsEnabled: Bool {
        get { d.object(forKey: "soundsEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "soundsEnabled") }
    }

    public var autoCloseEnabled: Bool {
        get { d.bool(forKey: "autoCloseEnabled") }
        set { d.set(newValue, forKey: "autoCloseEnabled") }
    }

    /// seconds; 5 / 10 / 15 / 30
    public var autoCloseInterval: Int {
        get { d.object(forKey: "autoCloseInterval") as? Int ?? 10 }
        set { d.set(newValue, forKey: "autoCloseInterval") }
    }

    /// true = save-and-close, false = close (keep in library)
    public var autoCloseSaves: Bool {
        get { d.bool(forKey: "autoCloseSaves") }
        set { d.set(newValue, forKey: "autoCloseSaves") }
    }

    public var recordSystemAudio: Bool {
        get { d.object(forKey: "recordSystemAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "recordSystemAudio") }
    }

    public var recordMicrophone: Bool {
        get { d.bool(forKey: "recordMicrophone") }
        set { d.set(newValue, forKey: "recordMicrophone") }
    }

    public var showClicksWhileRecording: Bool {
        get { d.object(forKey: "showClicksWhileRecording") as? Bool ?? true }
        set { d.set(newValue, forKey: "showClicksWhileRecording") }
    }

    public var showKeysWhileRecording: Bool {
        get { d.bool(forKey: "showKeysWhileRecording") }
        set { d.set(newValue, forKey: "showKeysWhileRecording") }
    }

    /// strftime-style tokens: %Y %m %d %H %M %S, plus %n for the capture kind.
    public var filenameTemplate: String {
        get { d.string(forKey: "filenameTemplate") ?? "%n %Y-%m-%d at %H.%M.%S" }
        set { d.set(newValue, forKey: "filenameTemplate") }
    }

    /// Name captures from their recognized text (on-device). Default OFF: the heuristic namer
    /// produces mediocre names from menu-bar chrome (verified against the real library), and a
    /// wrong filename is worse than a timestamp. The API engine is the quality tier.
    public var aiNamingEnabled: Bool {
        // Default follows the engine that's available: with an Anthropic key the names are good
        // enough to be worth having (verified), without one the heuristic isn't.
        get { d.object(forKey: "aiNamingEnabled") as? Bool ?? Keychain.hasAnthropicKey }
        set { d.set(newValue, forKey: "aiNamingEnabled") }
    }

    /// Where shares are uploaded. Overridable so a fork can point at its own Worker, but the
    /// default is the one kapture.sh runs.
    public var shareEndpoint: URL {
        get {
            guard let raw = d.string(forKey: "shareEndpoint"), let url = URL(string: raw),
                  url.scheme == "https"
            else { return URL(string: "https://kapture.sh")! }
            return url
        }
        set { d.set(newValue.absoluteString, forKey: "shareEndpoint") }
    }

    /// Put the link on the clipboard as soon as a share finishes — the reason to share is almost
    /// always to paste it somewhere.
    public var copyShareLinkAutomatically: Bool {
        get { d.object(forKey: "copyShareLink") as? Bool ?? true }
        set { d.set(newValue, forKey: "copyShareLink") }
    }

    /// Route ⌘W/⌘C/⌘S/⌘⌫/space to the hovered overlay without clicking (needs Accessibility).
    public var hoverShortcutsEnabled: Bool {
        get { d.object(forKey: "hoverShortcutsEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hoverShortcutsEnabled") }
    }
}

/// One place that plays UI sounds, honoring the master toggle.
///
/// Starting the sound off the calling thread is the point of this type, not a detail of it.
/// `NSSound.play()` does not return until CoreAudio has the output device running: 137ms on the
/// first play of a run, and 27-30ms again any time the device has been quiet for a few seconds —
/// which is every sound here, because they all mark occasional events rather than a stream.
///
/// Every one of them is played at a moment that must not stutter: a card released mid-swipe, a
/// capture landing in the corner, a recording starting. On the calling thread that cost lands as
/// a freeze between the gesture and the animation it set off, which is precisely the gap you saw
/// halfway through a swipe.
public enum Sounds {
    /// Serial, so two sounds starting at once can't have their device setup fight; and there is
    /// nothing to wait for afterwards, because `play()` returns once playback is under way.
    private static let queue = DispatchQueue(label: "sh.kapture.sounds", qos: .userInitiated)

    /// The player itself, behind a seam only so a test can prove `play` returns without waiting on
    /// it. Nothing else can show that from the outside: on a machine with no audio device — a CI
    /// runner — `NSSound.play()` is quick whichever thread it is called on, so a stopwatch around
    /// the real one would pass whether or not the work had been moved off the caller.
    ///
    /// A fresh sound each time, as before: named sounds are kept alive by AppKit, and sharing one
    /// instance would make a second discard in quick succession fall silent on a sound still
    /// playing from the first.
    static var player: (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() }

    public static func play(_ name: String) {
        // read on the caller's thread: it is the caller's setting, and it is only a defaults read
        guard Settings.shared.soundsEnabled else { return }
        queue.async { player(name) }
    }
}
