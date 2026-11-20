import Foundation
import ThumbFreeCore
import VoiceAssistantBoard
import XCTest
@testable import VoiceAssistantCore

private let india = TimeZone(secondsFromGMT: 19_800)!

/// A moment on India's wall clock (the C# tests' `DateTimeOffset` at +5:30).
private func indiaTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = india
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private let boardNow = indiaTime(2026, 11, 11, 14, 30)
private let editor = windowRef(10, 1, "Notepad", "Untitled - Notepad")

/// BoardVoiceTests.cs's desktop: it keeps what was typed.
private final class TypingDesktop: JarvisDesktop {
    var typed: [String] = []
    var foreground: WindowInfo? = editor
    var field = AssistantFieldCheck.safe
    var brainPlatform: BrainPlatform { .windows }

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult { .ok("ok", window: editor) }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "", hasTrailingText: false, focusIsEditable: true)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "no")
    }

    func checkFocusedField() -> AssistantFieldCheck { field }

    func focusedTextEndsWithNonWhitespace() -> Bool? { false }

    func typeText(_ text: String) throws { typed.append(text) }

    func pressKeys(_ chord: String) throws {}

    func backspace(_ count: Int) throws {}
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/BoardVoiceTests.cs: the idea board by voice
/// (docs/specs/idea-board.md): commands, push-to-talk dictation routing, and what stays typed.
final class BoardVoiceTests: XCTestCase {
    private struct Fixture {
        let desktop: TypingDesktop
        let board: BoardStore
        let controller: InteractionController
        let statuses: StatusLog
        let shown: Recorder<BoardList?>
    }

    private var fixture: Fixture!
    private var desktop: TypingDesktop { fixture.desktop }
    private var board: BoardStore { fixture.board }
    private var controller: InteractionController { fixture.controller }
    private var statuses: StatusLog { fixture.statuses }

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try makeFixture()
    }

    /// The C# test class's constructor, also for each case of a theory.
    private func makeFixture() throws -> Fixture {
        let desktop = TypingDesktop()
        let board = try BoardStore(path: nil, clock: { boardNow }, timeZone: india)
        let notepad = AppEntry(
            name: "Notepad", launch: "notepad.exe", processNames: ["Notepad"], submitKeys: "", newLineKeys: "Enter")
        let controller = InteractionController(
            desktop, AppCatalog([notepad]), CommandParser(boardClock: { boardNow }, boardTimeZone: india),
            options: ControllerOptions(wakeWordEnabled: false))
        controller.board = board
        let statuses = StatusLog()
        let shown = Recorder<BoardList?>()
        controller.onStatus = statuses.add
        controller.onShowBoardRequested = shown.add
        controller.setListening(true)
        return Fixture(desktop: desktop, board: board, controller: controller, statuses: statuses, shown: shown)
    }

    private func say(_ text: String) async throws {
        try await controller.handleTranscript(text, 0.9)
    }

    func testAddToMyIdeasFilesANote() async throws {
        try await say("Add to my ideas, a voice game for kids.")
        XCTAssertEqual(1, board.items.count)
        let item = try XCTUnwrap(board.items.first)
        XCTAssertEqual(.ideas, item.list)
        XCTAssertEqual("A voice game for kids", item.text)
        XCTAssertTrue(statuses.last?.message.contains("Ideas") == true)
    }

    func testRemindMeSetsAReminderWithItsTime() async throws {
        try await say("Remind me to call mom tomorrow at 5 pm.")
        XCTAssertEqual(1, board.items.count)
        let item = try XCTUnwrap(board.items.first)
        XCTAssertEqual(.reminders, item.list)
        XCTAssertEqual("Call mom", item.text)
        XCTAssertEqual(indiaTime(2026, 11, 12, 17), item.due)
        XCTAssertTrue(statuses.last?.message.contains("tomorrow 5:00 PM") == true)
    }

    func testShowMyRemindersAsksTheAppToOpenTheList() async throws {
        try await say("Show my reminders.")
        XCTAssertEqual([.reminders], fixture.shown.all)
    }

    func testShowMyIdeasIsNotABrowserTabSwitch() async throws {
        try await say("Go to my ideas.")
        XCTAssertEqual([.ideas], fixture.shown.all)
        XCTAssertEqual([], desktop.typed)
    }

    func testMarkDoneTicksTheItemOff() async throws {
        _ = try board.add(.todo, "Renew passport")
        try await say("Mark renew passport as done.")
        XCTAssertEqual(1, board.items.count)
        XCTAssertEqual(true, board.items.first?.done)
    }

    func testPushToTalkNamingAListGoesToTheBoardNotTheTextBox() throws {
        try controller.insertDictation("Add to my to-do list, renew passport.")
        XCTAssertEqual(["Renew passport"], board.items.map(\.text))
        XCTAssertEqual([], desktop.typed)
    }

    func testPushToTalkWithoutAListNameIsTyped() throws {
        for spoken in ["Please remind me to send the report.", "Note down that the build failed."] {
            let fixture = try makeFixture()
            try fixture.controller.insertDictation(spoken)
            XCTAssertEqual(0, fixture.board.items.count, spoken)
            XCTAssertFalse(fixture.desktop.typed.isEmpty, spoken)
        }
    }

    func testWhileTypingTheWakeWordFilesANoteAndTypingContinues() async throws {
        try await say("Start typing.")
        try await say("Hey Jarvis, add to my ideas, offline mode.")
        XCTAssertEqual(["Offline mode"], board.items.map(\.text))
        XCTAssertEqual(.dictation, controller.mode)
        try await say("Add to my ideas, this sentence is just typed.")
        XCTAssertEqual(1, board.items.count)
        XCTAssertTrue(desktop.typed.contains { NetText.containsOrdinalIgnoreCase($0, "this sentence is just typed") })
    }

    func testPushToTalkWithNoWindowSavesTheDictationToTheBoard() throws {
        desktop.foreground = nil
        try controller.insertDictation("I have to draft a reply to Tata Neu about the refund.")
        XCTAssertEqual(1, board.items.count)
        let item = try XCTUnwrap(board.items.first)
        XCTAssertEqual(.todo, item.list)
        XCTAssertEqual("Draft a reply to Tata Neu about the refund", item.text)
        XCTAssertTrue(statuses.last?.message.hasPrefix("No text box") == true)
        XCTAssertEqual(.success, statuses.last?.kind)
    }

    func testPushToTalkOnSomethingThatIsNotATextBoxSavesToTheRightList() throws {
        let cases: [(String, BoardList, String?)] = [
            ("A voice game where kids guess animal sounds.", .ideas, nil),
            ("Call the bank tomorrow at 11 am.", .reminders, "Call the bank"),
            ("I need to renew the car insurance.", .todo, "Renew the car insurance"),
        ]
        for (spoken, list, text) in cases {
            let fixture = try makeFixture()
            fixture.desktop.field = .notText
            try fixture.controller.insertDictation(spoken)
            XCTAssertEqual(1, fixture.board.items.count, spoken)
            XCTAssertEqual(list, fixture.board.items.first?.list, spoken)
            if let text {
                XCTAssertEqual(text, fixture.board.items.first?.text, spoken)
            }

            XCTAssertEqual([], fixture.desktop.typed, spoken)
        }
    }

    func testPushToTalkIntoAFieldThatMightTakeTextStillTypes() throws {
        for field in [AssistantFieldCheck.unknown, .safe] {
            let fixture = try makeFixture()
            fixture.desktop.field = field
            try fixture.controller.insertDictation("I have to draft a reply.")
            XCTAssertEqual(0, fixture.board.items.count, "\(field)")
            XCTAssertFalse(fixture.desktop.typed.isEmpty, "\(field)")
        }
    }

    func testSayingOnlyNewLineWithNoTextBoxSavesNothing() throws {
        desktop.foreground = nil
        try controller.insertDictation("new line")
        XCTAssertEqual(0, board.items.count)
    }

    func testPasteLastDictationWithNoWindowDoesNotFileItAgain() throws {
        try controller.insertDictation("Hello there.")
        desktop.foreground = nil
        try controller.repeatLastTranscript()
        XCTAssertEqual(0, board.items.count)
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testWithoutABoardNoWindowStillWarns() throws {
        controller.board = nil
        desktop.foreground = nil
        try controller.insertDictation("Something to remember.")
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testWithoutABoardTheCommandSaysSo() async throws {
        controller.board = nil
        try await say("Add to my ideas, something.")
        XCTAssertEqual(.warning, statuses.last?.kind)
    }
}
