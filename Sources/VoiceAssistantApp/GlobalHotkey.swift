import Carbon
import Foundation
import ThumbFreeCore
import ThumbFreeMac

/// A hotkey from settings.json ("Ctrl+Shift+Space"), read as Windows' `GlobalHotkey.Parse` reads it: modifiers and one
/// key, joined by "+", in any case and order. On the Mac Ctrl is ⌃, Alt ⌥, Shift ⇧, and Win ⌘ (the key in its place);
/// the Mac's names Option and Cmd are read too.
public struct HotkeyChord: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        /// A letter (lower case) or a digit.
        case character(Character)

        /// Any other key, by its Mac key code (Carbon's `kVK_…`).
        case code(UInt16)
    }

    /// Why a hotkey can't be used, in the words Windows uses (C#'s `ArgumentException` messages).
    public struct Problem: Error, Equatable, LocalizedError {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    public var modifiers: PasteTyper.Modifiers
    public var key: Key

    public init(modifiers: PasteTyper.Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// The chord in `text`. Throws a `Problem` for an unknown key, or without a modifier and a key.
    public static func parse(_ text: String) throws -> HotkeyChord {
        var modifiers: PasteTyper.Modifiers = []
        var named: Key?
        for part in DotNet.split(text, ["+"]).map({ DotNet.trim($0) }) where !part.isEmpty {
            switch DotNet.lowerInvariant(part) {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option", "opt":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            case "win", "cmd", "command":
                modifiers.insert(.command)
            default:
                named = try parseKey(part)
            }
        }

        guard let key = named, !modifiers.isEmpty else {
            throw Problem("Hotkey '\(text)' needs a modifier and a key.")
        }

        return HotkeyChord(modifiers: modifiers, key: key)
    }

    /// The hotkey the Mac uses for a hotkey setting. A settings.json copied from Windows holds Windows' defaults, which
    /// clash with macOS or type characters here, so a value that is the same chord as `windowsDefault` (in any case or
    /// order) means `macDefault`. Any other value is used as written.
    public static func onMac(_ setting: String, windowsDefault: String, macDefault: String) -> String {
        guard let chord = try? parse(setting), let windows = try? parse(windowsDefault), chord == windows else {
            return setting
        }

        return macDefault
    }

    /// The chord as macOS writes shortcuts: "⌃⇧Space", "⌃⇧Z".
    public var displayName: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }

        if modifiers.contains(.option) {
            text += "⌥"
        }

        if modifiers.contains(.shift) {
            text += "⇧"
        }

        if modifiers.contains(.command) {
            text += "⌘"
        }

        switch key {
        case .character(let character):
            return text + String(character).uppercased()
        case .code(let code):
            return text + (Self.keyNames[code] ?? "Key \(code)")
        }
    }

    /// The modifiers as Carbon's `RegisterEventHotKey` takes them.
    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.control) {
            flags |= controlKey
        }

        if modifiers.contains(.option) {
            flags |= optionKey
        }

        if modifiers.contains(.shift) {
            flags |= shiftKey
        }

        if modifiers.contains(.command) {
            flags |= cmdKey
        }

        return UInt32(flags)
    }

    /// The key to register: for a letter, the key that types it in the keyboard layout in use (ThumbFreeMac's
    /// `PasteTyper.SystemKeys.keyCode`), as a Windows letter key follows the layout, else the US layout's; for a digit,
    /// the number row's key, as on Windows. Main thread (Text Input Sources answers only there).
    @MainActor
    var keyCode: UInt16 {
        switch key {
        case .code(let code):
            return code
        case .character(let character):
            if character.isLetter, let code = PasteTyper.SystemKeys.keyCode(typing: character, with: modifiers) {
                return code
            }

            return Self.usKeys[character] ?? UInt16(kVK_Space)
        }
    }

    /// C#'s `KeyboardInput.ParseKey`: a named key in any case, one letter or digit, or a function key. The Mac's keys
    /// end at F20 (Windows' at F24).
    static func parseKey(_ name: String) throws -> Key {
        let lower = DotNet.lowerInvariant(name)
        if let code = namedKeys[lower] {
            return .code(code)
        }

        let scalars = Array(lower.unicodeScalars)
        if scalars.count == 1, scalars[0].isASCII, DotNet.isLetterOrDigit(scalars[0]) {
            return .character(Character(scalars[0]))
        }

        if scalars.count == 2 || scalars.count == 3, scalars[0] == "f",
           let number = Int(DotNet.trim(String(lower.dropFirst()))), let code = functionKeys[number] {
            return .code(code)
        }

        throw Problem("Unknown key '\(name)'.")
    }

    private static let namedKeys: [String: UInt16] = [
        "enter": UInt16(kVK_Return), "return": UInt16(kVK_Return), "tab": UInt16(kVK_Tab),
        "esc": UInt16(kVK_Escape), "escape": UInt16(kVK_Escape), "backspace": UInt16(kVK_Delete),
        "delete": UInt16(kVK_ForwardDelete), "space": UInt16(kVK_Space), "home": UInt16(kVK_Home),
        "end": UInt16(kVK_End), "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
        "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow), "pageup": UInt16(kVK_PageUp),
        "pagedown": UInt16(kVK_PageDown),
    ]

    private static let functionKeys: [Int: UInt16] = [
        1: UInt16(kVK_F1), 2: UInt16(kVK_F2), 3: UInt16(kVK_F3), 4: UInt16(kVK_F4), 5: UInt16(kVK_F5),
        6: UInt16(kVK_F6), 7: UInt16(kVK_F7), 8: UInt16(kVK_F8), 9: UInt16(kVK_F9), 10: UInt16(kVK_F10),
        11: UInt16(kVK_F11), 12: UInt16(kVK_F12), 13: UInt16(kVK_F13), 14: UInt16(kVK_F14), 15: UInt16(kVK_F15),
        16: UInt16(kVK_F16), 17: UInt16(kVK_F17), 18: UInt16(kVK_F18), 19: UInt16(kVK_F19), 20: UInt16(kVK_F20),
    ]

    /// The names macOS shows for the named keys.
    private static let keyNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab", UInt16(kVK_Escape): "Esc",
            UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Forward Delete", UInt16(kVK_Space): "Space",
            UInt16(kVK_Home): "Home", UInt16(kVK_End): "End", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
        ]
        for (number, code) in functionKeys {
            names[code] = "F\(number)"
        }

        return names
    }()

    /// The US layout's letter and digit keys.
    private static let usKeys: [Character: UInt16] = [
        "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C), "d": UInt16(kVK_ANSI_D),
        "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F), "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H),
        "i": UInt16(kVK_ANSI_I), "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
        "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O), "p": UInt16(kVK_ANSI_P),
        "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R), "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T),
        "u": UInt16(kVK_ANSI_U), "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
        "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z), "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1),
        "2": UInt16(kVK_ANSI_2), "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
        "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8), "9": UInt16(kVK_ANSI_9),
    ]
}

/// A system-wide hotkey (windows-voice-assistant `GlobalHotkey`), registered with Carbon's `RegisterEventHotKey`, which
/// needs no permission. It's registered exclusively, so a chord another app has registered isn't taken, as Windows'
/// `RegisterHotKey` fails then. A letter's hotkey moves with the keyboard layout. Main thread.
@MainActor
public final class GlobalHotkey {
    /// The chord as settings.json writes it (C#'s `Description`).
    public let description: String

    public let chord: HotkeyChord

    /// False when another app has the chord.
    public private(set) var isRegistered = false

    /// Runs when a keyboard layout change moved a letter's hotkey and that changed whether it's registered: false when
    /// another app has the key that types the letter now, so the hotkey does nothing; true when it's registered again.
    public var registrationChanged: (@MainActor (_ isRegistered: Bool) -> Void)?

    nonisolated static let signature: OSType = 0x5641_484B

    /// The hotkeys registered now, by id.
    private static var registered: [UInt32: GlobalHotkey] = [:]
    private static var lastId: UInt32 = 0
    private static var handlerInstalled = false
    private static var layoutWatcher: LayoutWatcher?

    private let id: UInt32
    private let pressed: () -> Void
    private var reference: EventHotKeyRef?

    /// Registers `text`'s chord; `pressed` runs on the main thread. Throws `HotkeyChord.Problem` for a chord it can't
    /// read (C#'s `ArgumentException`).
    public init(_ text: String, pressed: @escaping () -> Void) throws {
        chord = try HotkeyChord.parse(text)
        description = text
        self.pressed = pressed
        GlobalHotkey.lastId += 1
        id = GlobalHotkey.lastId
        GlobalHotkey.installHandler()
        GlobalHotkey.registered[id] = self
        if case .character = chord.key, GlobalHotkey.layoutWatcher == nil {
            GlobalHotkey.layoutWatcher = LayoutWatcher()
        }

        register()
    }

    /// Unregisters it for good (C#'s `Dispose`).
    public func unregister() {
        release()
        GlobalHotkey.registered[id] = nil
    }

    private func register() {
        var made: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.carbonModifiers, EventHotKeyID(signature: GlobalHotkey.signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &made)
        reference = status == 0 ? made : nil
        isRegistered = reference != nil
    }

    private func release() {
        if let reference {
            _ = UnregisterEventHotKey(reference)
            self.reference = nil
        }

        isRegistered = false
    }

    /// The keyboard layout changed: each letter's hotkey moves to the key that types the letter now, which another app
    /// may have.
    fileprivate static func layoutChanged() {
        for hotkey in registered.values {
            if case .character = hotkey.chord.key {
                let wasRegistered = hotkey.isRegistered
                hotkey.release()
                hotkey.register()
                if hotkey.isRegistered != wasRegistered {
                    hotkey.registrationChanged?(hotkey.isRegistered)
                }
            }
        }
    }

    /// One handler for all of them, on the application's event target, whose events come on the main thread.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        HotkeyEvents.install()
    }

    /// A hotkey was pressed: its action.
    fileprivate static func hotkeyPressed(_ id: UInt32) {
        registered[id]?.pressed()
    }
}

/// Carbon's hot key events for `GlobalHotkey`, outside any actor: the handler is a C function.
private enum HotkeyEvents {
    static func install() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == 0, hotKey.signature == GlobalHotkey.signature else {
                return OSStatus(eventNotHandledErr)
            }

            let id = hotKey.id
            MainActor.assumeIsolated { GlobalHotkey.hotkeyPressed(id) }
            return 0
        }, 1, &pressed, nil, nil)
    }
}

/// Hears that the keyboard layout changed. Voice Assistant is almost never the active app, and the distributed center
/// holds notifications back for inactive apps, so it asks for this one at once, as ThumbFreeMac's `PasteTyper` does.
private final class LayoutWatcher: NSObject {
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func changed(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GlobalHotkey.layoutChanged() }
        }
    }
}
