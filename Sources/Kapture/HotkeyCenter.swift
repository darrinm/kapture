// Carbon global hotkeys. Registering ⌘⇧3/4/5 shadows the system screenshot shortcuts while
// Kapture runs (spike D / CleanShot-proven). Verify-by-fire happens in onboarding.
import Carbon.HIToolbox
import AppKit
import KaptureCore

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    /// Each action carries its whole binding — Carbon registration and menu key equivalents
    /// derive from the same table, so they can't drift apart.
    enum Action: UInt32, CaseIterable {
        case fullscreen = 1     // ⌘⇧3
        case area = 2           // ⌘⇧4
        case record = 3         // ⌘⇧5 (stub until M3)
        case previousArea = 4   // ⌥⇧4
        case pinClipboard = 5   // ⌘⇧1

        var keyCode: UInt32 {
            switch self {
            case .fullscreen: 20     // 3
            case .area: 21           // 4
            case .record: 23         // 5
            case .previousArea: 21   // 4
            case .pinClipboard: 18   // 1
            }
        }

        var carbonModifiers: UInt32 {
            switch self {
            case .previousArea: UInt32(optionKey | shiftKey)
            default: UInt32(cmdKey | shiftKey)
            }
        }

        /// Menu-item key equivalent (character form of keyCode).
        var keyEquivalent: String {
            switch self {
            case .fullscreen: "3"
            case .area: "4"
            case .record: "5"
            case .previousArea: "4"
            case .pinClipboard: "1"
            }
        }

        var cocoaModifiers: NSEvent.ModifierFlags {
            switch self {
            case .previousArea: [.option, .shift]
            default: [.command, .shift]
            }
        }
    }
    private var refs: [EventHotKeyRef?] = []
    var handler: ((Action) -> Void)?

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async {
                if let action = Action(rawValue: hk.id) {
                    HotkeyCenter.shared.handler?(action)
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(action.keyCode, action.carbonModifiers,
                                             EventHotKeyID(signature: OSType(0x4B505452), id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { Log.shell.error("hotkey \(action.rawValue) register failed: \(status)") }
            refs.append(ref)
        }
    }
}
