// What happens automatically once a capture is taken. CleanShot calls this the After Capture
// list; the idea is that the common follow-up shouldn't need a keystroke.
//
// The list is deliberately small and its order fixed: these run in the order below, which is the
// only order that makes sense (copy the bytes, save a copy, then whatever opens a window).
import Foundation

public enum CaptureAction: String, CaseIterable, Sendable {
    case copy
    case save
    case editor
    case pin
    case share

    public var title: String {
        switch self {
        case .copy: "Copy to clipboard"
        case .save: "Save a copy to the export folder"
        case .editor: "Open the editor"
        case .pin: "Pin to screen"
        case .share: "Upload and copy the link"
        }
    }

    /// Actions that act on the capture rather than just copying it — the capture stops being a
    /// staged card and is indexed immediately.
    public var marksKept: Bool {
        switch self {
        case .copy, .save: return false
        case .editor, .pin, .share: return true
        }
    }

    public var detail: String? {
        switch self {
        case .editor: "Opens the editor instead of the corner card."
        case .share: "Uploads every capture as soon as it is taken."
        default: nil
        }
    }
}

extension Settings {
    /// The enabled actions, always in `CaptureAction.allCases` order.
    public var afterCaptureActions: [CaptureAction] {
        get {
            let defaults = UserDefaults.standard
            guard let stored = defaults.array(forKey: "afterCaptureActions") as? [String] else {
                // first run after the upgrade: inherit the old single "copy after capture" flag,
                // so nobody's clipboard behavior changes silently underneath them
                return copyToClipboardAfterCapture ? [.copy] : []
            }
            let enabled = Set(stored)
            return CaptureAction.allCases.filter { enabled.contains($0.rawValue) }
        }
        set {
            let ordered = CaptureAction.allCases.filter(newValue.contains)
            UserDefaults.standard.set(ordered.map(\.rawValue), forKey: "afterCaptureActions")
        }
    }

    public mutating func setAfterCaptureAction(_ action: CaptureAction, enabled: Bool) {
        var actions = Set(afterCaptureActions)
        if enabled { actions.insert(action) } else { actions.remove(action) }
        afterCaptureActions = Array(actions)
    }
}
