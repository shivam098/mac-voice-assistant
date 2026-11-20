import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

private let editorWindow = windowRef(10, 1, "Notepad", "Untitled - Notepad")

/// EditingTests.cs's text box: typing inserts at the cursor (replacing a selection); Left and Right move (and collapse
/// a selection); Shift+Left extends the selection; Backspace deletes the selection or the character before the
/// cursor. Positions are in UTF-16 units, as in C#.
private final class TextBoxDesktop: JarvisDesktop {
    private(set) var units: [UInt16] = []
    private(set) var caret = 0

    /// Characters selected to the left of the cursor.
    var selectionLength = 0
    var readable = true
    var caretKnown = true
    var editable = true
    var check = AssistantFieldCheck.safe
    private(set) var ctrlBackspaces = 0
    var brainPlatform: BrainPlatform { .windows }

    var text: String { NetText.string(utf16: units) }

    func load(_ text: String) {
        units = Array(text.utf16)
        caret = units.count
        selectionLength = 0
    }

    func moveCaretToStart() {
        caret = 0
        selectionLength = 0
    }

    /// `Text.Length > 0 && !char.IsWhiteSpace(Text[^1])` (half of a surrogate pair isn't white space).
    private var endsWithNonWhiteSpace: Bool {
        guard let last = units.last else { return false }
        return !(Unicode.Scalar(last).map(DotNet.isWhiteSpace) ?? false)
    }

    func foregroundWindow() -> WindowInfo? { editorWindow }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        .ok("ok", window: editorWindow)
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "", hasTrailingText: endsWithNonWhiteSpace, focusIsEditable: true)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "no")
    }

    func checkFocusedField() -> AssistantFieldCheck { check }

    func focusedTextEndsWithNonWhitespace() -> Bool? { endsWithNonWhiteSpace }

    func readTextBeforeCaret() -> CaretText? {
        guard readable else { return nil }
        if caretKnown {
            return CaretText(
                before: NetText.string(utf16: units[..<caret]), caretKnown: true, hasSelection: selectionLength > 0,
                editable: editable)
        }

        return CaretText(before: text, caretKnown: false, hasSelection: false, editable: editable)
    }

    func typeText(_ text: String) throws {
        deleteSelection()
        units.insert(contentsOf: text.utf16, at: caret)
        caret += text.utf16.count
    }

    func pressKeys(_ chord: String) throws {
        switch chord {
        case "Left":
            caret = selectionLength > 0 ? caret - selectionLength : max(0, caret - 1)
            selectionLength = 0
        case "Right":
            caret = min(units.count, caret + (selectionLength > 0 ? 0 : 1))
            selectionLength = 0
        case "Shift+Left":
            if caret - selectionLength > 0 {
                selectionLength += 1
            }
        case "Enter":
            try typeText("\n")
        case "Ctrl+Backspace":
            ctrlBackspaces += 1
        default:
            break
        }
    }

    func backspace(_ count: Int) throws {
        var left = count
        if selectionLength > 0 {
            deleteSelection()
            left -= 1
        }

        let n = max(0, min(left, caret))
        units.removeSubrange((caret - n)..<caret)
        caret -= n
    }

    private func deleteSelection() {
        guard selectionLength > 0 else { return }
        let start = caret - selectionLength
        units.removeSubrange(start..<caret)
        caret = start
        selectionLength = 0
    }
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/EditingTests.cs (spoken edits, docs/specs/voice-commands.md,
/// "Editing what you typed"): the grammar, the keystroke plans, and the interaction controller against a simulated
/// text box.
final class EditingTests: XCTestCase {
    // MARK: Grammar

    /// `Commands.SingleOrDefault()`: the only command, or nil.
    private func parse(_ heard: String, _ mode: InteractionMode = .dictation) -> VoiceCommand? {
        let commands = CommandParser().parse(heard, mode).commands
        return commands.count == 1 ? commands[0] : nil
    }

    func testCountedDeletesAreCommandsWhileTyping() {
        let cases: [(String, EditUnit, Int)] = [
            ("Delete the last word.", .word, 1),
            ("Delete the last three words.", .word, 3),
            ("Delete the last 3 words.", .word, 3),
            ("Erase the previous sentence.", .sentence, 1),
            ("Delete the last two sentences.", .sentence, 2),
            ("Remove the last line.", .line, 1),
            ("Delete last paragraph.", .paragraph, 1),
            ("Delete the last few words.", .word, 3),
            ("Delete the last couple of words.", .word, 2),
            ("Delete three words.", .word, 3),
            ("Delete that sentence.", .sentence, 1),
            ("Scratch the last line.", .line, 1),
            ("Delete the last 5 characters.", .character, 5),
        ]
        for (heard, unit, count) in cases {
            let command = parse(heard)
            XCTAssertEqual(.deleteText, command?.kind, heard)
            XCTAssertEqual(TextEdit(unit: unit, count: count), command?.edit, heard)
        }
    }

    func testDeleteTheWordNamesAPhrase() {
        let command = parse("Delete the word very.")
        XCTAssertEqual(.deleteText, command?.kind)
        XCTAssertEqual("very", command?.edit?.phrase)
    }

    func testReplaceTheWordKeepsTheSpokenReplacement() {
        let command = parse("Replace the word Monday with GitHub Actions.")
        XCTAssertEqual(.replaceText, command?.kind)
        XCTAssertEqual("monday", command?.edit?.phrase)
        XCTAssertEqual("GitHub Actions", command?.edit?.replacement)
    }

    func testReplaceWithoutTheWordNeedsTheWakeWord() {
        let cases = [
            ("Hey Jarvis, replace Monday with Tuesday.", "monday", "Tuesday"),
            ("Hey Jarvis, change the meeting to the review.", "the meeting", "the review"),
        ]
        for (heard, phrase, replacement) in cases {
            let command = parse(heard)
            XCTAssertEqual(.replaceText, command?.kind, heard)
            XCTAssertEqual(phrase, command?.edit?.phrase, heard)
            XCTAssertEqual(replacement, command?.edit?.replacement, heard)
        }
    }

    func testOrdinarySentencesAreStillTyped() {
        let sentences = [
            "Replace the battery with a new one.", "Change the plan to Friday.", "Delete the file when you are done.",
            "Remove the last line of the config.", "Delete words.", "Delete 500 words.",
        ]
        for heard in sentences {
            let parsed = CommandParser().parse(heard, .dictation)
            XCTAssertEqual([], parsed.commands, heard)
            XCTAssertNotNil(parsed.dictationText, heard)
        }
    }

    func testAfterTheWakeWordDeleteNamesAPhrase() {
        let command = parse("Hey Jarvis, delete really.")
        XCTAssertEqual(.deleteText, command?.kind)
        XCTAssertEqual("really", command?.edit?.phrase)
    }

    func testExistingCommandsKeepTheirMeaning() {
        for (heard, kind) in [("Delete that.", CommandKind.scratchThat), ("Remove numbers.", .hideNumbers)] {
            let mode: InteractionMode = kind == .hideNumbers ? .command : .dictation
            XCTAssertEqual(kind, parse(heard, mode)?.kind, heard)
        }
    }

    // MARK: Plans

    func testDeleteLastUnits() {
        let cases: [(String, EditUnit, Int, String)] = [
            ("Hello there my friend", .word, 1, "Hello there my"),
            ("Hello there my friend.", .word, 2, "Hello there"),
            ("Hello there my friend   ", .word, 1, "Hello there my"),
            ("One. Two is here. Three is next.", .sentence, 1, "One. Two is here."),
            ("One. Two is here. Three is next.", .sentence, 2, "One."),
            ("One. Two is here? Three", .sentence, 1, "One. Two is here?"),
            ("Version 1.5 is out", .sentence, 1, ""),
            ("first line\nsecond line\nthird", .line, 1, "first line\nsecond line"),
            ("first line\nsecond line\nthird", .line, 2, "first line"),
            ("first line\n", .line, 1, "first line"),
            ("Para one.\n\nPara two. More.", .paragraph, 1, "Para one."),
            ("abc😀", .character, 1, "abc"),
            ("word", .word, 5, ""),
        ]
        for (before, unit, count, expected) in cases {
            let plan = TextEditing.deleteLast(before, unit, count)
            XCTAssertNotNil(plan, before)
            XCTAssertEqual(expected, plan?.textAfterEdit, before)
            XCTAssertEqual(0, plan?.keepAfter, before)
        }
    }

    func testNothingToDeleteIsNil() {
        XCTAssertNil(TextEditing.deleteLast("   ", .word, 1))
    }

    func testReplaceOrDeleteTheLastOccurrence() {
        let cases: [(String, String, String?, String?)] = [
            ("It is very very good", "very", nil, "It is very good"),
            ("Very good idea", "very", nil, "good idea"),
            ("See you on Monday. Monday works.", "monday", "Tuesday", "See you on Monday. Tuesday works."),
            ("I dont know. I don't know", "dont", "do not", "I dont know. I do not know"),
            ("Ship it on monday please", "monday", "tuesday", "Ship it on tuesday please"),
            ("Ship ASAP please", "asap", "now", "Ship NOW please"),
            ("Mondays are long", "monday", "Tuesday", nil),
            ("as soon as possible, then", "as soon as possible", "ASAP", "ASAP, then"),
        ]
        for (before, phrase, replacement, expected) in cases {
            XCTAssertEqual(expected, TextEditing.replaceLast(before, phrase, replacement)?.textAfterEdit, before)
        }
    }

    func testReplaceMovesLeftOverTheTextAfterItAndBack() {
        let plan = TextEditing.replaceLast("go on monday then", "monday", "friday")
        XCTAssertEqual(" then".count, plan?.keepAfter)
        XCTAssertEqual("monday".count, plan?.delete)
        XCTAssertEqual("friday", plan?.insert)
    }

    func testParagraphsSplitBySingleLineBreaks() {
        XCTAssertEqual("A.\nB.", TextEditing.deleteLast("A.\nB.\nC.", .paragraph, 1)?.textAfterEdit)
    }

    func testDeletesNeverReachFurtherThanTheLimit() {
        XCTAssertNil(TextEditing.deleteLast(String(repeating: "a", count: TextEditing.maxReach + 10), .sentence, 1))
    }

    func testOnlySpacesBeforeALineDoesNotThrow() {
        XCTAssertEqual("", TextEditing.deleteLast("  \nfoo", .line, 2)?.textAfterEdit)
    }

    func testPoliteWordsStayInEditPhrases() {
        let cases = [
            ("Hey Jarvis, delete see you again.", "see you again"), ("Hey Jarvis, delete the word now.", "now"),
        ]
        for (heard, phrase) in cases {
            XCTAssertEqual(phrase, parse(heard, .command)?.edit?.phrase, heard)
        }
    }

    // MARK: The controller against a simulated text box

    private var box: TextBoxDesktop!
    private var controller: InteractionController!
    private var statuses: StatusLog!

    override func setUp() {
        super.setUp()
        box = TextBoxDesktop()
        let notepad = AppEntry(
            name: "Notepad", launch: "notepad.exe", processNames: ["Notepad"], submitKeys: "", newLineKeys: "Enter")
        controller = InteractionController(
            box, AppCatalog([notepad]), CommandParser(), options: ControllerOptions(wakeWordEnabled: false))
        statuses = StatusLog()
        controller.onStatus = statuses.add
        controller.setListening(true)
    }

    private func say(_ text: String) async throws {
        try await controller.handleTranscript(text, 0.9)
    }

    func testDeleteTheLastWordsThenKeepTyping() async throws {
        try await say("Start typing.")
        try await say("Hello there, my good friend and family.")
        try await say("Delete the last two words.")
        XCTAssertEqual("Hello there, my good friend", box.text)
        try await say("and colleagues.")
        XCTAssertEqual("Hello there, my good friend and colleagues.", box.text)
    }

    func testDeleteTheLastSentence() async throws {
        try await say("Start typing.")
        try await say("This stays.")
        try await say("This one goes.")
        try await say("Delete the last sentence.")
        XCTAssertEqual("This stays.", box.text)
        XCTAssertTrue(statuses.last?.message.contains("sentence") == true)
    }

    func testReplaceAWordInTheMiddleAndReturnToTheEnd() async throws {
        try await say("Start typing.")
        try await say("The review is on Monday at noon.")
        try await say("Replace the word Monday with Tuesday.")
        XCTAssertEqual("The review is on Tuesday at noon.", box.text)
        XCTAssertEqual(box.units.count, box.caret)
        try await say("Bring snacks.")
        XCTAssertEqual("The review is on Tuesday at noon. Bring snacks.", box.text)
    }

    func testDeleteAWordInTheMiddle() async throws {
        try await say("Start typing.")
        try await say("It is very very good.")
        try await say("Delete the word very.")
        XCTAssertEqual("It is very good.", box.text)
    }

    func testMissingPhraseChangesNothing() async throws {
        try await say("Start typing.")
        try await say("Hello world.")
        try await say("Delete the word banana.")
        XCTAssertEqual("Hello world.", box.text)
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testUnreadableBoxStillDeletesWordsWithCtrlBackspace() async throws {
        box.readable = false
        try await say("Start typing.")
        try await say("One two three.")
        try await say("Delete the last two words.")
        XCTAssertEqual(2, box.ctrlBackspaces)
        try await say("Delete the last sentence.")
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testSelectedTextBlocksEdits() async throws {
        try await say("Start typing.")
        try await say("Hello world.")
        box.selectionLength = 3
        try await say("Delete the last word.")
        XCTAssertEqual("Hello world.", box.text)
        XCTAssertTrue(statuses.last?.message.contains("selected") == true)
    }

    func testReadOnlyTextIsNotEdited() async throws {
        controller.setListening(true)
        box.editable = false
        box.load("Some page text with the word banana.")
        try await say("Delete banana.")
        XCTAssertEqual("Some page text with the word banana.", box.text)
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testValueOnlyBoxIsTrustedWhileItEndsWithWhatWasTyped() async throws {
        box.caretKnown = false
        try await say("Start typing.")
        try await say("One two three four.")
        try await say("Delete the last two words.")
        XCTAssertEqual("One two", box.text)
        // The user typed more at the end by hand: the value no longer ends with what was typed, so it isn't trusted.
        try box.typeText(" five")
        try await say("Delete the last sentence.")
        XCTAssertEqual("One two five", box.text)
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testCommandModeNeedsACheckedField() async throws {
        box.load("Draft text here")
        box.check = .unknown
        try await say("Delete the last word.")
        XCTAssertEqual("Draft text here", box.text)
    }

    // MARK: Beyond the C# tests

    func testTextElementsAreCountedAsInDotNet() {
        // (text, after deleting one character, after deleting two, characters in its last word), from the C# core
        // (harness, `misc`): emoji, combining marks, flags, ZWJ sequences, Hangul jamo and \r\n are one element each.
        let cases: [(String, String, String, Int)] = [
            ("abc\u{1F600}", "abc", "ab", 4),
            ("cafe\u{301}", "caf", "ca", 4),
            ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "", 2),
            ("\u{1F1EE}\u{1F1F3}\u{1F1EE}\u{1F1F3}", "\u{1F1EE}\u{1F1F3}", "", 2),
            ("a\u{D}\u{A}b", "a\u{A}", "a", 1),
            ("\u{1F44D}\u{1F3FD}", "", "", 1),
            ("\u{1100}\u{1161}\u{11A8}", "", "", 1),
            ("x\u{308}\u{301}", "", "", 1),
        ]
        for (text, one, two, word) in cases {
            XCTAssertEqual(one, TextEditing.deleteLast(text, .character, 1)?.textAfterEdit, text)
            XCTAssertEqual(two, TextEditing.deleteLast(text, .character, 2)?.textAfterEdit ?? "", text)
            XCTAssertEqual(word, TextEditing.deleteLast(text, .word, 1)?.delete, text)
        }
    }

    func testDevanagariConjunctsAreCountedAsInDotNet() {
        // .NET 10 splits a conjunct after its virama (क्ष is क् and ष): it doesn't have Unicode 15.1's rule GB9c.
        // Swift's `Character` keeps the conjunct whole; the core counts as .NET does.
        let cases: [(String, String, Int)] = [
            ("\u{915}\u{94D}\u{937}", "\u{915}\u{94D}", 2),
            ("\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947}", "\u{928}\u{92E}\u{938}\u{94D}", 4),
            ("\u{915}\u{94D}\u{200D}\u{937}", "\u{915}\u{94D}\u{200D}", 2),
            ("\u{915}\u{94D}\u{937}\u{93F}", "\u{915}\u{94D}", 2),
        ]
        for (text, one, word) in cases {
            XCTAssertEqual(one, TextEditing.deleteLast(text, .character, 1)?.textAfterEdit, text)
            XCTAssertEqual(word, TextEditing.deleteLast(text, .word, 1)?.delete, text)
        }
    }
}
