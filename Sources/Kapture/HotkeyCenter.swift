// Carbon global hotkeys. Registering ⌘⇧3/4/5 shadows the system screenshot shortcuts while
// Kapture runs (spike D / CleanShot-proven). Verify-by-fire happens in onboarding.
//
// Bindings are user-editable and live in UserDefaults; the defaults below are only the starting
// point. Menu key equivalents derive from the same table, so a rebound shortcut can't leave the
// menu advertising the old one.
import Carbon.HIToolbox
import AppKit
import KaptureCore

/// One key combination. The character is captured when the user records the shortcut rather
/// than derived from the key code later: translating a key code needs the keyboard layout that
/// was active at the time, and the recorded event already knows it.
struct HotkeyBinding: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var character: String

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// Menu items want the bare character; the modifier mask is set separately.
    var keyEquivalent: String { character.lowercased() }

    /// ⌘⇧4, for the Settings pane and any place we describe the shortcut in words.
    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + character.uppercased()
    }

    /// "keyCode modifiers character" — a defaults value that stays readable in `defaults read`.
    var storageValue: String { "\(keyCode) \(carbonModifiers) \(character)" }

    init(keyCode: UInt32, carbonModifiers: UInt32, character: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.character = character
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiers = UInt32(parts[1]),
              !parts[2].isEmpty
        else { return nil }
        self.init(keyCode: keyCode, carbonModifiers: modifiers, character: String(parts[2]))
    }
}

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    enum Action: UInt32, CaseIterable {
        case fullscreen = 1     // ⌘⇧3
        case area = 2           // ⌘⇧4
        case record = 3         // ⌘⇧5
        case previousArea = 4   // ⌥⇧4
        case pinClipboard = 5   // ⌘⇧1
        case library = 6        // ⌘⇧L
        case captureText = 7    // ⌘⇧2

        var title: String {
            switch self {
            case .fullscreen: "Capture fullscreen"
            case .area: "Capture area"
            case .record: "Start or stop recording"
            case .previousArea: "Capture previous area"
            case .pinClipboard: "Pin from clipboard"
            case .library: "Open library"
            case .captureText: "Capture text"
            }
        }

        var defaultBinding: HotkeyBinding {
            let cmdShift = UInt32(cmdKey | shiftKey)
            switch self {
            case .fullscreen: return HotkeyBinding(keyCode: 20, carbonModifiers: cmdShift, character: "3")
            case .area: return HotkeyBinding(keyCode: 21, carbonModifiers: cmdShift, character: "4")
            case .record: return HotkeyBinding(keyCode: 23, carbonModifiers: cmdShift, character: "5")
            case .previousArea: return HotkeyBinding(keyCode: 21,
                                                     carbonModifiers: UInt32(optionKey | shiftKey),
                                                     character: "4")
            case .pinClipboard: return HotkeyBinding(keyCode: 18, carbonModifiers: cmdShift, character: "1")
            case .library: return HotkeyBinding(keyCode: 37, carbonModifiers: cmdShift, character: "L")
            case .captureText: return HotkeyBinding(keyCode: 19, carbonModifiers: cmdShift, character: "2")
            }
        }

        var storageKey: String { "hotkey.\(rawValue)" }
    }

    /// What went wrong when a shortcut couldn't be taken.
    enum BindingError: Error {
        /// Another Kapture action already holds this combination.
        case takenBy(Action)
        /// Carbon refused it. Note this does NOT catch another *app* holding the combination —
        /// RegisterEventHotKey succeeds anyway in that case (spike D), which is why onboarding
        /// verifies by fire instead of trusting this.
        case registrationFailed(OSStatus)
    }

    var handler: ((Action) -> Void)?
    /// Called after any binding changes so the menu can refresh its key equivalents.
    var onBindingsChanged: (() -> Void)?

    private var refs: [Action: EventHotKeyRef] = [:]
    private var installed = false
    private let defaults = UserDefaults.standard

    func binding(for action: Action) -> HotkeyBinding {
        guard let stored = defaults.string(forKey: action.storageKey),
              let binding = HotkeyBinding(storageValue: stored)
        else { return action.defaultBinding }
        return binding
    }

    func isDefault(_ action: Action) -> Bool { binding(for: action) == action.defaultBinding }

    /// The action already holding this combination, if any.
    private func conflict(with binding: HotkeyBinding, ignoring action: Action) -> Action? {
        Action.allCases.first {
            $0 != action && self.binding(for: $0).keyCode == binding.keyCode
                && self.binding(for: $0).carbonModifiers == binding.carbonModifiers
        }
    }

    func setBinding(_ binding: HotkeyBinding, for action: Action) throws {
        if let other = conflict(with: binding, ignoring: action) { throw BindingError.takenBy(other) }
        let previous = self.binding(for: action)
        defaults.set(binding.storageValue, forKey: action.storageKey)
        unregister(action)
        let status = register(action)
        guard status == noErr else {
            // put the old one back rather than leave the action with no working shortcut
            defaults.set(previous.storageValue, forKey: action.storageKey)
            unregister(action)
            _ = register(action)
            throw BindingError.registrationFailed(status)
        }
        onBindingsChanged?()
    }

    func resetToDefault(_ action: Action) {
        defaults.removeObject(forKey: action.storageKey)
        unregister(action)
        _ = register(action)
        onBindingsChanged?()
    }

    func resetAllToDefaults() {
        for action in Action.allCases { defaults.removeObject(forKey: action.storageKey) }
        for action in Action.allCases {
            unregister(action)
            _ = register(action)
        }
        onBindingsChanged?()
    }

    func install() {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async {
                    if let action = Action(rawValue: hk.id) {
                        HotkeyCenter.shared.handler?(action)
                    }
                }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        for action in Action.allCases {
            let status = register(action)
            if status != noErr {
                Log.shell.error("hotkey \(action.rawValue) register failed: \(status)")
            }
        }
    }

    @discardableResult
    private func register(_ action: Action) -> OSStatus {
        let binding = self.binding(for: action)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers,
                                         EventHotKeyID(signature: OSType(0x4B505452), id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        if let ref, status == noErr { refs[action] = ref }
        return status
    }

    private func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }
}
