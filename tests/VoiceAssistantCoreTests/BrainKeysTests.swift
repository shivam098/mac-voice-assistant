import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// The chord grammar `ShortcutKeys` documents for the desktop: modifiers in the order Ctrl, Alt, Shift, then Win
/// (Windows) or Cmd (the Mac), then one key.
enum ChordGrammar {
    private static let named = [
        "Enter", "Tab", "Esc", "Space", "Home", "End", "PageUp", "PageDown", "Up", "Down", "Left", "Right", "Backspace",
        "Delete", "[", "]",
    ]
    private static let keys: Set<String> = Set(
        named + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { String($0) } + (1...24).map { "F\($0)" })

    static func parses(_ chord: String, mac: Bool) -> Bool {
        let pieces = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = pieces.last, keys.contains(key) else { return false }
        let order = ["Ctrl", "Alt", "Shift", mac ? "Cmd" : "Win"]
        var next = 0
        for modifier in pieces.dropLast() {
            guard let at = order[next...].firstIndex(of: modifier) else { return false }
            next = at + 1
        }

        return true
    }
}

/// How the keys a plan names (the Windows way) are pressed on the Mac, and when they're refused or need a "yes"
/// (BrainSafety's list): through `ShortcutKeys`, then the Mac's own rules as well as Windows'.
final class BrainKeysTests: XCTestCase {
    private enum Verdict: Int, Comparable {
        case press
        case ask
        case refuse

        static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    }

    /// Refused, asked about (with nothing known about the focus) or pressed. The interaction controller also asks
    /// before a submit key after typing or in a text box.
    private func verdict(_ chord: String, _ platform: BrainPlatform, focus: FocusInfo? = nil) -> Verdict {
        if BrainSafety.refusalReason(chord, platform) != nil {
            return .refuse
        }

        return BrainSafety.needsConfirmation(chord, platform, focus: focus) ? .ask : .press
    }

    /// Every chord `normalizeChord` can write: modifiers in its order (Ctrl, Alt, Shift, Win), then one key.
    private static let allChords: [String] = {
        let modifiers = ["Ctrl", "Alt", "Shift", "Win"]
        let keys = [
            "Enter", "Tab", "Esc", "Backspace", "Delete", "Space", "Home", "End", "Up", "Down", "Left", "Right",
            "PageUp", "PageDown",
        ] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { String($0) } + (1...24).map { "F\($0)" } + modifiers
        var chords: [String] = []
        for mask in 0..<16 {
            let chosen = modifiers.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            for key in keys where !chosen.contains(key) {
                let chord = (chosen + [key]).joined(separator: "+")
                if BrainSafety.normalizeChord(chord) == chord {
                    chords.append(chord)
                }
            }
        }

        return chords
    }()

    func testTheMacPressesEachWindowsChordAsTheListSays() {
        let cases: [(windows: String, mac: String?, verdict: Verdict)] = [
            // ShortcutKeys' shortcuts.
            ("Ctrl+A", "Cmd+A", .press), ("Ctrl+C", "Cmd+C", .refuse), ("Ctrl+V", "Cmd+V", .refuse),
            ("Ctrl+X", "Cmd+X", .refuse), ("Ctrl+Z", "Cmd+Z", .press), ("Ctrl+Y", "Shift+Cmd+Z", .press),
            ("Ctrl+S", "Cmd+S", .press), ("Ctrl+T", "Cmd+T", .press), ("Ctrl+W", "Cmd+W", .ask),
            ("Ctrl+Tab", "Ctrl+Tab", .press), ("Ctrl+Shift+Tab", "Ctrl+Shift+Tab", .press),
            ("Alt+Left", "Cmd+[", .press), ("Alt+Right", "Cmd+]", .press), ("Alt+Up", "Cmd+Up", .press),
            ("F5", "Cmd+R", .press), ("PageDown", "PageDown", .press), ("PageUp", "PageUp", .press),
            ("Ctrl+Backspace", "Alt+Backspace", .ask), ("Win+Up", nil, .refuse),
            // The Win chords Windows allows, and one it doesn't.
            ("Win+Down", "Cmd+M", .press), ("Win+M", "Alt+Cmd+M", .press), ("Win+Left", nil, .refuse),
            ("Win+Right", nil, .refuse), ("Shift+Win+Left", nil, .refuse), ("Shift+Win+Right", nil, .refuse),
            ("Win+D", nil, .refuse), ("Win+R", nil, .refuse),
            // Other Windows meanings.
            ("Alt+F4", "Cmd+W", .ask), ("Ctrl+F4", "Cmd+W", .ask), ("Ctrl+F5", "Shift+Cmd+R", .press),
            ("F11", "Ctrl+Cmd+F", .press),
            // Deleting.
            ("Delete", "Delete", .ask), ("Shift+Delete", "Shift+Delete", .ask), ("Ctrl+Delete", "Alt+Delete", .ask),
            ("Backspace", "Backspace", .ask), ("Shift+Backspace", "Shift+Backspace", .ask),
            ("Ctrl+Shift+Backspace", "Alt+Shift+Backspace", .ask), ("Ctrl+Alt+Backspace", "Alt+Cmd+Backspace", .refuse),
            ("Ctrl+Alt+Shift+Backspace", "Alt+Shift+Cmd+Backspace", .refuse),
            // Discarding, quitting, logging out, Spotlight, Force Quit.
            ("Ctrl+D", "Cmd+D", .refuse), ("Ctrl+Shift+D", "Shift+Cmd+D", .ask), ("Ctrl+Q", "Cmd+Q", .refuse),
            ("Ctrl+Alt+Q", "Alt+Cmd+Q", .refuse), ("Ctrl+Shift+Q", "Shift+Cmd+Q", .refuse),
            ("Ctrl+Alt+Shift+Q", "Alt+Shift+Cmd+Q", .refuse), ("Ctrl+Shift+W", "Shift+Cmd+W", .ask),
            ("Ctrl+Alt+W", "Alt+Cmd+W", .ask), ("Ctrl+Space", "Cmd+Space", .refuse),
            ("Ctrl+Alt+Space", "Alt+Cmd+Space", .refuse), ("Ctrl+Alt+Esc", "Alt+Cmd+Esc", .refuse),
            ("Ctrl+Alt+Shift+Esc", "Alt+Shift+Cmd+Esc", .refuse), ("Ctrl+Esc", "Cmd+Esc", .refuse),
            ("Ctrl+Shift+Esc", "Shift+Cmd+Esc", .press), ("Ctrl+Alt+F5", "Alt+Cmd+F5", .refuse),
            // Moving by word and paragraph, and opening.
            ("Ctrl+Left", "Alt+Left", .press), ("Ctrl+Right", "Alt+Right", .press), ("Ctrl+Up", "Alt+Up", .press),
            ("Ctrl+Down", "Alt+Down", .press), ("Ctrl+Shift+Left", "Alt+Shift+Left", .press),
            ("Ctrl+Shift+Down", "Alt+Shift+Down", .press), ("Ctrl+Alt+Down", "Alt+Cmd+Down", .refuse),
            ("Ctrl+Alt+Shift+Down", "Alt+Shift+Cmd+Down", .refuse), ("Ctrl+Alt+Left", "Alt+Cmd+Left", .press),
            ("Ctrl+Home", "Cmd+Home", .press), ("Ctrl+End", "Cmd+End", .press), ("Alt+Down", "Alt+Down", .press),
            // The clipboard.
            ("Ctrl+Shift+V", "Shift+Cmd+V", .refuse), ("Ctrl+Alt+V", "Alt+Cmd+V", .refuse),
            ("Ctrl+Alt+Shift+V", "Alt+Shift+Cmd+V", .refuse), ("Ctrl+Alt+C", "Alt+Cmd+C", .refuse),
            ("Ctrl+Shift+C", "Shift+Cmd+C", .press),
            // Everyday app keys.
            ("Ctrl+L", "Cmd+L", .press), ("Ctrl+F", "Cmd+F", .press), ("Ctrl+N", "Cmd+N", .press),
            ("Ctrl+Shift+N", "Shift+Cmd+N", .press), ("Ctrl+Shift+T", "Shift+Cmd+T", .press),
            ("Ctrl+P", "Cmd+P", .press), ("Ctrl+K", "Cmd+K", .press), ("Ctrl+1", "Cmd+1", .press),
            ("Ctrl+Enter", "Cmd+Enter", .press), ("Ctrl+Shift+Enter", "Shift+Cmd+Enter", .press),
            ("Alt+Enter", "Alt+Enter", .press), ("Shift+Enter", "Shift+Enter", .press), ("Enter", "Enter", .press),
            ("Space", "Space", .press), ("Tab", "Tab", .press), ("Shift+Tab", "Shift+Tab", .press),
            ("Esc", "Esc", .press), ("Alt+Tab", "Alt+Tab", .press), ("F2", "F2", .press), ("F12", "F12", .press),
            ("Up", "Up", .press), ("Home", "Home", .press), ("M", "M", .press), ("Shift+7", "Shift+7", .press),
            // Menus and access keys.
            ("Alt+S", "Alt+S", .ask), ("Alt+H", "Alt+H", .ask), ("Alt+Shift+D", "Alt+Shift+D", .ask),
            ("Alt", nil, .refuse), ("Alt+Space", "Alt+Space", .refuse), ("F10", "F10", .refuse),
            ("Shift+F10", "Shift+F10", .refuse),
            // A modifier on its own.
            ("Ctrl", nil, .refuse), ("Shift", nil, .refuse), ("Ctrl+Shift", nil, .refuse),
        ]
        for test in cases {
            XCTAssertEqual(test.mac, BrainSafety.pressedChord(test.windows, .mac), test.windows)
            XCTAssertEqual(test.verdict, verdict(test.windows, .mac), test.windows)
        }
    }

    func testTheMacSaysWhyItWontPress() {
        let cases: [(String, String?)] = [
            ("Ctrl+Q", "it quits the app"), ("Ctrl+Shift+Q", "it logs you out"), ("Ctrl+Space", "it can run commands"),
            ("Ctrl+Alt+Esc", "it force quits apps"), ("Ctrl+Alt+Backspace", "it deletes files and documents"),
            ("Ctrl+Alt+Shift+Backspace", "it empties the Trash"),
            ("Ctrl+D", "in a Save dialog it throws the changes away"), ("Ctrl+Alt+Down", "it opens the selected file"),
            ("Ctrl+Alt+F5", "it changes the accessibility settings"), ("Win+D", "a Mac has no key for it"),
            ("Win+Up", "a Mac has no key for it"), ("Ctrl+C", "I type text myself rather than use the clipboard"),
            ("Win+R", "it can run commands"), ("Ctrl+L", nil),
        ]
        check(cases) { BrainSafety.refusalReason($0, .mac) }
    }

    func testMacChordsNoPlanReachesAreRefusedToo() {
        let chords = [
            "Cmd+Backspace", "Shift+Cmd+Backspace", "Ctrl+Cmd+Q", "Cmd+Down", "Shift+Cmd+Down", "Cmd+F5",
            "Ctrl+F2", "Ctrl+F3", "Ctrl+F8",
        ]
        for chord in chords {
            XCTAssertNotNil(BrainSafety.macRefusalReason(chord), chord)
        }

        XCTAssertNil(BrainSafety.macRefusalReason("Cmd+Up"))
        XCTAssertNil(BrainSafety.macRefusalReason("Alt+Down"))
    }

    func testBackspaceOnTheMacAsksUnlessItEditsAText() {
        let box = FocusInfo(name: "Message", editable: true, inPage: true)
        let list = FocusInfo(name: "Inbox", editable: false, inPage: false)
        for chord in ["Backspace", "Shift+Backspace", "Ctrl+Backspace", "Alt+Backspace"] {
            XCTAssertTrue(BrainSafety.focusDecides(chord, .mac), chord)
            XCTAssertFalse(BrainSafety.focusDecides(chord, .windows), chord)
            XCTAssertEqual(.press, verdict(chord, .mac, focus: box), chord)
            XCTAssertEqual(.ask, verdict(chord, .mac, focus: list), chord)
            XCTAssertEqual(.ask, verdict(chord, .mac), chord)
            XCTAssertEqual(.press, verdict(chord, .windows, focus: list), chord)
        }

        XCTAssertFalse(BrainSafety.focusDecides("Delete", .mac))
        XCTAssertEqual(.refuse, verdict("Ctrl+Alt+Backspace", .mac, focus: box))
    }

    func testWindowsPressesEachChordAsNamed() {
        for chord in Self.allChords {
            XCTAssertEqual(chord, BrainSafety.pressedChord(chord, .windows))
        }
    }

    func testEveryChordWindowsAllowsIsAtLeastAsGuardedOnTheMac() {
        let neverPressed: Set<String> = [
            "Cmd+Space", "Alt+Cmd+Space", "Cmd+Q", "Alt+Cmd+Q", "Shift+Cmd+Q", "Alt+Shift+Cmd+Q", "Ctrl+Cmd+Q",
            "Alt+Cmd+Esc", "Alt+Shift+Cmd+Esc", "Cmd+Backspace", "Alt+Cmd+Backspace", "Shift+Cmd+Backspace",
            "Alt+Shift+Cmd+Backspace", "Cmd+D", "Cmd+F5", "Alt+Cmd+F5", "Cmd+C", "Cmd+X", "Cmd+V", "Shift+Cmd+V",
            "Alt+Cmd+V", "Alt+Shift+Cmd+V", "Alt+Cmd+C", "Ctrl+F2", "Ctrl+F3", "Ctrl+F8",
        ]
        let askFirst: Set<String> = ["Cmd+W", "Alt+Cmd+W", "Shift+Cmd+W", "Shift+Cmd+D"]
        // 16 sets of modifiers with 74 keys, and the 32 chords whose key is a modifier.
        XCTAssertEqual(1_216, Self.allChords.count)
        var allowed = 0
        for chord in Self.allChords {
            let windows = verdict(chord, .windows)
            let mac = verdict(chord, .mac)
            XCTAssertGreaterThanOrEqual(mac, windows, chord)
            guard windows != .refuse else { continue }
            allowed += 1
            guard let pressed = BrainSafety.pressedChord(chord, .mac) else {
                XCTAssertEqual(.refuse, mac, chord)
                continue
            }

            let pieces = pressed.split(separator: "+").map(String.init)
            let key = pieces[pieces.count - 1]
            XCTAssertTrue(ChordGrammar.parses(pressed, mac: true), "\(chord): \(pressed)")
            XCTAssertFalse(pieces.contains("Win"), "\(chord): \(pressed)")
            if neverPressed.contains(pressed) || (key == "Down" && pieces.contains("Cmd")) {
                XCTAssertEqual(.refuse, mac, "\(chord): \(pressed)")
            }

            if askFirst.contains(pressed) || key == "Delete" || key == "Backspace" {
                XCTAssertNotEqual(.press, mac, "\(chord): \(pressed)")
            }
        }

        // Windows refuses the 604 Win chords it doesn't allowlist, Ctrl+Esc, 5 clipboard and 5 menu chords.
        XCTAssertEqual(601, allowed)
    }

    func testEveryShortcutKeysChordParses() {
        for keys in [ShortcutKeys.windows, .mac] {
            let mac = keys == .mac
            for chord in Shortcut.allCases.map({ keys.keys(for: $0) }) + [keys.deleteWordBefore] {
                XCTAssertTrue(ChordGrammar.parses(chord, mac: mac), chord)
            }

            if case .keys(let maximize) = keys.maximize {
                XCTAssertTrue(ChordGrammar.parses(maximize, mac: mac), maximize)
            }
        }
    }
}
