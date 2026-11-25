import Carbon.HIToolbox
import ThumbFreeMac
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// The chord presser: `ShortcutKeys`' Mac grammar, the keyboard layout's keys for letters, digits and brackets, and
/// what's pressed for each command.
final class KeysTests: XCTestCase {
    private func chord(_ text: String) -> MacChord? { MacChord(text) }

    private func code(_ key: Int) -> MacChord.Key { .code(CGKeyCode(key)) }

    func testReadsTheMacGrammar() {
        let cases: [(String, PasteTyper.Modifiers, MacChord.Key)] = [
            ("Shift+Cmd+Z", [.shift, .command], .character("z")),
            ("Ctrl+Tab", .control, code(kVK_Tab)),
            ("Ctrl+Shift+Tab", [.control, .shift], code(kVK_Tab)),
            ("Cmd+[", .command, .character("[")),
            ("Cmd+]", .command, .character("]")),
            ("Alt+Backspace", .option, code(kVK_Delete)),
            ("Backspace", [], code(kVK_Delete)),
            ("Delete", [], code(kVK_ForwardDelete)),
            ("Enter", [], code(kVK_Return)),
            ("Return", [], code(kVK_Return)),
            ("Shift+Enter", .shift, code(kVK_Return)),
            ("Esc", [], code(kVK_Escape)),
            ("Escape", [], code(kVK_Escape)),
            ("Space", [], code(kVK_Space)),
            ("Cmd+Up", .command, code(kVK_UpArrow)),
            ("Shift+Left", .shift, code(kVK_LeftArrow)),
            ("Right", [], code(kVK_RightArrow)),
            ("Down", [], code(kVK_DownArrow)),
            ("PageUp", [], code(kVK_PageUp)),
            ("PageDown", [], code(kVK_PageDown)),
            ("Home", [], code(kVK_Home)),
            ("Ctrl+End", .control, code(kVK_End)),
            ("F5", [], code(kVK_F5)),
            ("f12", [], code(kVK_F12)),
            ("Ctrl+Cmd+F", [.control, .command], .character("f")),
            ("Alt+Cmd+M", [.option, .command], .character("m")),
            ("Shift+7", .shift, .character("7")),
            ("M", [], .character("m")),
            (" cmd + shift + n ", [.command, .shift], .character("n")),
            ("Command+Option+Control+K", [.command, .option, .control], .character("k")),
            ("CTRL+a", .control, .character("a")),
        ]
        for (text, modifiers, key) in cases {
            XCTAssertEqual(MacChord(modifiers: modifiers, key: key), chord(text), text)
        }
    }

    /// Keys a Mac doesn't have and chords outside the grammar. F21 to F24 are among them: the core refuses them on the
    /// Mac before it asks, and the presser refuses them too.
    func testRefusesWhatAMacCantPress() {
        for text in [
            "Win+Up", "Win", "F21", "F24", "F0", "Ctrl+A+B", "Ctrl", "Shift+Cmd", "", "+", "Cmd+;", "Hyper+X",
            "Cmd+Enter+Tab", "Ctrl+Fn", "ab",
        ] {
            XCTAssertNil(chord(text), text)
        }
    }

    /// Everything the core presses on the Mac: its shortcuts, "press …" keys, edits, and the Mac chords the AI brain
    /// may press for every Windows chord a plan can name, F21 to F24 too (the core refuses those on the Mac, so it never
    /// asks for them).
    func testPressesEveryChordTheCorePresses() {
        var chords = Shortcut.allCases.map { ShortcutKeys.mac.keys(for: $0) } + [ShortcutKeys.mac.deleteWordBefore]
        chords += [
            "Enter", "Tab", "Esc", "Backspace", "Delete", "Space", "Up", "Down", "Left", "Right", "PageUp", "PageDown",
            "Home", "End", "Shift+Tab", "Shift+Left", "Shift+Enter",
        ]
        let modifiers = ["Ctrl", "Alt", "Shift", "Win"]
        let keys = [
            "Enter", "Tab", "Esc", "Backspace", "Delete", "Space", "Home", "End", "Up", "Down", "Left", "Right",
            "PageUp", "PageDown",
        ] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { String($0) } + (1...24).map { "F\($0)" }
        for mask in 0..<16 {
            let chosen = modifiers.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            for key in keys {
                let named = (chosen + [key]).joined(separator: "+")
                if let pressed = BrainSafety.keyPress(named, .mac).pressable {
                    chords.append(pressed)
                }
            }
        }

        XCTAssertGreaterThan(chords.count, 300)
        for text in chords {
            XCTAssertNotNil(chord(text), text)
        }
    }

    /// ⌘ chords press the key that types the letter with ⌘ held, others the key that types it alone: AZERTY's Z is
    /// QWERTY's W, and "Dvorak – QWERTY ⌘" types QWERTY with ⌘ but Dvorak without.
    func testLettersAreTheLayoutsKeys() throws {
        let rig = Rig()
        rig.layout.command = ["z": CGKeyCode(kVK_ANSI_W), "a": CGKeyCode(kVK_ANSI_Q)]
        rig.layout.plain = ["z": CGKeyCode(kVK_ANSI_Slash), "j": CGKeyCode(kVK_ANSI_C)]
        let presser = KeyPresser(keys: rig.keys, layout: rig.layout)
        XCTAssertEqual(
            PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_W), modifiers: .command), try presser.resolve("Cmd+Z"))
        XCTAssertEqual(PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_Slash)), try presser.resolve("Z"))
        XCTAssertEqual(PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_C), modifiers: .shift), try presser.resolve("Shift+J"))

        // A key the ⌘ layout doesn't type comes from the plain one, then from the US layout: the top row's digits.
        XCTAssertEqual(
            PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_C), modifiers: .command), try presser.resolve("Cmd+J"))
        XCTAssertEqual(PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_Q)), try presser.resolve("A"))
        XCTAssertEqual(
            PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_1), modifiers: .command), try presser.resolve("Cmd+1"))
        XCTAssertEqual(
            PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_LeftBracket), modifiers: .command), try presser.resolve("Cmd+["))
    }

    func testPressesAChordOnceModifiersAreLetGo() throws {
        let rig = Rig()
        rig.keys.held = [.command, .command]
        try rig.desktop.pressKeys("Shift+Cmd+Z")
        XCTAssertEqual([PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_Z), modifiers: [.shift, .command])], rig.keys.posted)
        XCTAssertTrue(rig.keys.held.isEmpty)
    }

    func testRepeatsKeys() throws {
        let rig = Rig()
        try rig.desktop.pressKeysRepeated("Shift+Left", 3)
        try rig.desktop.backspace(2)
        try rig.desktop.backspace(0)
        try rig.desktop.pressKeysRepeated("Right", 0)
        let left = PasteTyper.Chord(key: CGKeyCode(kVK_LeftArrow), modifiers: .shift)
        let back = PasteTyper.Chord(key: CGKeyCode(kVK_Delete))
        XCTAssertEqual([left, left, left, back, back], rig.keys.posted)
    }

    func testUnknownKeysThrowAndPressNothing() {
        let rig = Rig()
        XCTAssertThrowsError(try rig.desktop.pressKeys("Win+R")) { error in
            XCTAssertEqual(UnknownKeys(chord: "Win+R"), error as? UnknownKeys)
        }

        XCTAssertThrowsError(try rig.desktop.pressKeysRepeated("Ctrl+A+B", 2))
        XCTAssertTrue(rig.keys.posted.isEmpty)
    }

    /// Without the permission to post events nothing goes out, and the keyboard's error comes through.
    func testTheKeyboardsErrorsComeThrough() {
        let rig = Rig()
        rig.keys.failure = PasteTyper.Failure.notAllowed
        XCTAssertThrowsError(try rig.desktop.pressKeys("Enter")) { error in
            XCTAssertEqual(PasteTyper.Failure.notAllowed, error as? PasteTyper.Failure)
        }
    }

    /// Keys asked for by name aren't held back while a password is typed somewhere, as Windows presses them ("press
    /// enter" in Terminal with Secure Keyboard Entry); a typing's are (`TypingTests`).
    func testKeysGoOutDuringSecureInput() throws {
        let rig = Rig()
        rig.keys.secureInput = .on
        try rig.desktop.pressKeys("Enter")
        XCTAssertEqual([PasteTyper.Chord(key: CGKeyCode(kVK_Return))], rig.keys.posted)
    }
}

/// Typing through ThumbFreeMac's `PasteTyper`.
final class TypingTests: XCTestCase {
    func testPastesWithLineBreaksAsSpacesAndPutsThePasteboardBack() throws {
        let rig = Rig()
        rig.pasteboard.text = "copied"
        try rig.desktop.typeText("Hello\nworld")
        XCTAssertEqual(["Hello world"], rig.pasteboard.writes)
        XCTAssertEqual([rig.keys.pasteChord], rig.keys.posted)
        XCTAssertEqual("copied", rig.pasteboard.text)
    }

    func testTypesWithKeysWhenSetTo() throws {
        let rig = Rig()
        rig.insertMethod = "Type"
        try rig.desktop.typeText("Hi")
        XCTAssertEqual(["Hi"], rig.keys.typed)
        XCTAssertTrue(rig.pasteboard.writes.isEmpty)
    }

    func testInsertMethodIgnoresCase() throws {
        let rig = Rig()
        rig.insertMethod = "PASTE"
        try rig.desktop.typeText("Hi")
        XCTAssertEqual(["Hi"], rig.pasteboard.writes)
    }

    func testNothingIsTypedWhileAPasswordIsTyped() {
        let rig = Rig()
        rig.keys.secureInput = .on
        XCTAssertThrowsError(try rig.desktop.typeText("secret")) { error in
            XCTAssertEqual(PasteTyper.Failure.secureInput, error as? PasteTyper.Failure)
        }

        XCTAssertTrue(rig.keys.posted.isEmpty)
    }

    /// A typing with line breaks: each line pasted (or typed with keys), the new-line keys pressed between lines.
    func testTypesLinesWithTheNewLineKeys() throws {
        let rig = Rig()
        let newLine = PasteTyper.Chord(key: CGKeyCode(kVK_Return), modifiers: .shift)
        try rig.desktop.typeText("Hi\n\nthere", newLineKeys: "Shift+Enter")
        XCTAssertEqual(["Hi", "there"], rig.pasteboard.writes)
        XCTAssertEqual([rig.keys.pasteChord, newLine, newLine, rig.keys.pasteChord], rig.keys.posted)

        let typed = Rig()
        typed.insertMethod = "Type"
        try typed.desktop.typeText("\nok", newLineKeys: "Enter")
        XCTAssertEqual([PasteTyper.Chord(key: CGKeyCode(kVK_Return))], typed.keys.posted)
        XCTAssertEqual(["ok"], typed.keys.typed)
    }

    /// While a password is typed somewhere, or Terminal's Secure Keyboard Entry is on, a typing sends nothing: not even
    /// the new-line keys of a text that starts with a line break ("new line ls" mustn't press Return in Terminal).
    /// PasteTyper's failure comes through as it is.
    func testATypingSendsNothingDuringSecureInput() {
        let rig = Rig()
        rig.pasteboard.text = "copied"
        let states: [(FocusedField.SecureInput, PasteTyper.Failure)] = [
            (.on, .secureInput), (.unknown, .secureInputUnknown),
        ]
        for (state, failure) in states {
            rig.keys.secureInput = state
            for text in ["\nls -la\nrm -rf build", "ls -la\nrm -rf build", "\n"] {
                XCTAssertThrowsError(try rig.desktop.typeText(text, newLineKeys: "Shift+Enter"), text) { error in
                    XCTAssertEqual(failure, error as? PasteTyper.Failure)
                }
            }
        }

        XCTAssertTrue(rig.keys.posted.isEmpty)
        XCTAssertTrue(rig.keys.typed.isEmpty)
        XCTAssertEqual("copied", rig.pasteboard.text)
    }

    /// New-line keys outside the Mac's grammar: nothing goes out.
    func testUnknownNewLineKeysTypeNothing() {
        let rig = Rig()
        XCTAssertThrowsError(try rig.desktop.typeText("a\nb", newLineKeys: "Win+Enter")) { error in
            XCTAssertEqual(UnknownKeys(chord: "Win+Enter"), error as? UnknownKeys)
        }

        XCTAssertTrue(rig.keys.posted.isEmpty)
        XCTAssertTrue(rig.pasteboard.writes.isEmpty)
    }
}
