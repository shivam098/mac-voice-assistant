import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ThumbFreeMac

/// A chord as the core writes it ("Shift+Cmd+Z", "Ctrl+Tab", "Cmd+[", "Alt+Backspace", "Enter"), read as
/// `ShortcutKeys` documents the Mac's grammar: modifiers (Ctrl ⌃, Alt or Option ⌥, Shift ⇧, Cmd ⌘, in any order and
/// any case), then one key. The key is in a fixed place (Enter, Tab, Esc, Space, Home, End, PageUp, PageDown, the
/// arrows, F1 to F20, Backspace ⌫ and Delete ⌦), or a letter, a digit, "[" or "]", pressed as the key that types it in
/// the keyboard layout in use. windows-voice-assistant `KeyboardInput.ParseChord` also takes several keys or
/// modifiers alone; nothing the core presses on the Mac needs that, so such chords are refused, as are the Windows key
/// and F21 to F24, which a Mac doesn't have.
struct MacChord: Equatable {
    enum Key: Equatable {
        /// A virtual key code (kVK_Return…): where the key is, not what it types.
        case code(CGKeyCode)

        /// A lower-case ASCII letter, a digit, "[" or "]".
        case character(Character)
    }

    var modifiers: PasteTyper.Modifiers
    var key: Key

    init(modifiers: PasteTyper.Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil for a chord outside the grammar.
    init?(_ chord: String) {
        var modifiers: PasteTyper.Modifiers = []
        var key: Key?
        for part in chord.split(separator: "+") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                continue
            }

            let lower = name.lowercased()
            if let modifier = Self.modifierNames[lower] {
                modifiers.insert(modifier)
            } else if key == nil, let found = Self.key(lower) {
                key = found
            } else {
                return nil
            }
        }

        guard let key else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    private static func key(_ name: String) -> Key? {
        if let code = namedKeys[name] {
            return .code(CGKeyCode(code))
        }

        if name.count == 1, let character = name.first, character.isASCII,
           character.isLetter || character.isNumber || character == "[" || character == "]" {
            return .character(character)
        }

        if name.hasPrefix("f"), let number = Int(name.dropFirst()), (1...functionKeys.count).contains(number),
           name.count <= 3 {
            return .code(CGKeyCode(functionKeys[number - 1]))
        }

        return nil
    }

    private static let modifierNames: [String: PasteTyper.Modifiers] = [
        "ctrl": .control, "control": .control, "alt": .option, "option": .option, "opt": .option, "shift": .shift,
        "cmd": .command, "command": .command,
    ]

    /// Backspace deletes backwards (⌫, kVK_Delete) and Delete forwards (⌦), as on Windows.
    private static let namedKeys: [String: Int] = [
        "enter": kVK_Return, "return": kVK_Return, "tab": kVK_Tab, "esc": kVK_Escape, "escape": kVK_Escape,
        "space": kVK_Space, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
    ]

    /// F1 to F20: Macs have no F21 to F24.
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
        kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}

/// Keys the Mac can't press (C#'s "Unknown key" `ArgumentException`).
public struct UnknownKeys: Error, Equatable, LocalizedError {
    public let chord: String

    public init(chord: String) {
        self.chord = chord
    }

    public var errorDescription: String? { "“\(chord)” aren't keys I can press on a Mac." }
}

/// Which key types a character in the keyboard layout in use, for chords' letters, digits and brackets, behind a
/// protocol for the tests.
public protocol KeyLayout: AnyObject {
    /// The key that types `character` (a lower-case letter, a digit, "[" or "]"), with ⌘ held (`command`) or with no
    /// modifiers; nil when no key does.
    func keyCode(typing character: Character, command: Bool) -> CGKeyCode?
}

/// The keyboard layout in use, read with ThumbFreeMac's `PasteTyper.SystemKeys.keyCode(typing:with:)` (as it finds ⌘V's
/// key): with ⌘ held, the layout ⌘ shortcuts use (the current one, or for a non-Latin one the Latin layout that goes
/// with it; "Dvorak – QWERTY ⌘" types QWERTY); without modifiers, that layout's own keys. It answers on the main thread
/// only, so the keys of all the characters chords use are found there, now or as soon as the main thread is free, and
/// again whenever the layout changes. Until then there are none, and `KeyPresser` uses the US layout's.
public final class SystemKeyLayout: NSObject, KeyLayout, @unchecked Sendable {
    /// The characters chords can name.
    static let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789[]")

    private let lock = NSLock()
    private var plain: [Character: CGKeyCode] = [:]
    private var command: [Character: CGKeyCode] = [:]

    public override init() {
        super.init()
        if Thread.isMainThread {
            watchLayout()
        } else {
            DispatchQueue.main.async { [weak self] in self?.watchLayout() }
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    public func keyCode(typing character: Character, command: Bool) -> CGKeyCode? {
        lock.withLock { command ? self.command[character] : plain[character] }
    }

    /// ThumbFree's way: Jarvis is almost never the active app, and the distributed center holds back notifications
    /// for inactive apps, so this one is delivered at once.
    private func watchLayout() {
        update()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func layoutChanged(_ notification: Notification) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async { [weak self] in self?.update() }
        }
    }

    /// The keys that type each character chords can name, with ⌘ held and with no modifiers. Main thread only.
    private func update() {
        var plain: [Character: CGKeyCode] = [:]
        var command: [Character: CGKeyCode] = [:]
        for character in Self.characters {
            plain[character] = PasteTyper.SystemKeys.keyCode(typing: character, with: [])
            command[character] = PasteTyper.SystemKeys.keyCode(typing: character, with: .command)
        }

        lock.withLock {
            self.plain = plain
            self.command = command
        }
    }
}

/// Presses chords with CGEvent through ThumbFreeMac's `PasteTyper.Keys`, whose events carry this app's process
/// identifier, so its own dictation key ignores them, and which says when the permission to post events is missing
/// (windows-voice-assistant `KeyboardInput.PressChord` and `Repeat`).
final class KeyPresser {
    private let keys: PasteTyper.Keys
    private let layout: KeyLayout

    init(keys: PasteTyper.Keys, layout: KeyLayout) {
        self.keys = keys
        self.layout = layout
    }

    /// The key and modifiers `chord` presses; `UnknownKeys` for a chord outside the grammar.
    func resolve(_ chord: String) throws -> PasteTyper.Chord {
        guard let parsed = MacChord(chord) else { throw UnknownKeys(chord: chord) }
        switch parsed.key {
        case .code(let code):
            return PasteTyper.Chord(key: code, modifiers: parsed.modifiers)
        case .character(let character):
            let command = parsed.modifiers.contains(.command)
            let code = layout.keyCode(typing: character, command: command)
                ?? layout.keyCode(typing: character, command: !command)
                ?? Self.usKeys[character]
                ?? CGKeyCode(kVK_ANSI_A)
            return PasteTyper.Chord(key: code, modifiers: parsed.modifiers)
        }
    }

    /// Presses `chord` `times` times, one after another (Windows sends them in one SendInput call).
    func press(_ chord: PasteTyper.Chord, times: Int = 1) throws {
        for _ in 0..<max(0, times) {
            try keys.post(chord)
        }
    }

    /// The keys of the US layout, for a layout that types the character with no key (as ThumbFreeMac falls back to
    /// kVK_ANSI_V): a digit on an AZERTY keyboard is typed with ⇧, so its key on the top row is pressed, as Windows
    /// presses that row's keys for digits.
    static let usKeys: [Character: CGKeyCode] = {
        let keys: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ]
        return keys.mapValues { CGKeyCode($0) }
    }()
}
