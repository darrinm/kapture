import Foundation

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

    public var takeOverSystemShortcuts: Bool {
        get { d.object(forKey: "takeOverSystemShortcuts") as? Bool ?? true }
        set { d.set(newValue, forKey: "takeOverSystemShortcuts") }
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
}
