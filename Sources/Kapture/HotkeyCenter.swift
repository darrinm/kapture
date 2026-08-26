// Carbon global hotkeys. Registering ⌘⇧3/4/5 shadows the system screenshot shortcuts while
// Kapture runs (spike D / CleanShot-proven). Verify-by-fire happens in onboarding.
import Carbon.HIToolbox
import AppKit
import KaptureCore

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    enum Action: UInt32, CaseIterable {
        case fullscreen = 1   // ⌘⇧3
        case area = 2         // ⌘⇧4
        case record = 3       // ⌘⇧5 (stub until M3)
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

        let bindings: [(UInt32, Action)] = [(20, .fullscreen), (21, .area), (23, .record)]
        for (keyCode, action) in bindings {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, UInt32(cmdKey | shiftKey),
                                             EventHotKeyID(signature: OSType(0x4B505452), id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { Log.shell.error("hotkey \(action.rawValue) register failed: \(status)") }
            refs.append(ref)
        }
    }
}
