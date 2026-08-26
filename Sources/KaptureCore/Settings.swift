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

    /// Route ⌘W/⌘C/⌘S/⌘⌫/space to the hovered overlay without clicking (needs Accessibility).
    public var hoverShortcutsEnabled: Bool {
        get { d.object(forKey: "hoverShortcutsEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hoverShortcutsEnabled") }
    }
}

/// One place that plays UI sounds, honoring the master toggle.
public enum Sounds {
    public static func play(_ name: String) {
        guard Settings.shared.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
