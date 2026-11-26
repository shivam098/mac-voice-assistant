import AppKit
import VoiceAssistantBoard
import XCTest
@testable import VoiceAssistantApp

/// Reminder cards (windows-voice-assistant App.xaml.cs' ShowDueReminders and StackPopups, and ReminderPopup.cs) on a
/// board with its own clock, with fake cards that remember where they were put.
final class ReminderCardsTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testDueRemindersPopUpOnceIncludingOnesThatCameDueWhileTheAppWasntRunning() throws {
        let now = Locked(Self.start)
        let board = try BoardStore(path: nil, clock: { now.value })
        let missed = try board.add(.reminders, "Call mom", due: now.value.addingTimeInterval(-86_400))
        try board.add(.reminders, "Stretch", due: now.value)
        try board.add(.reminders, "Water the plants", due: now.value.addingTimeInterval(3_600))
        let shown = try board.add(.reminders, "Shown already", due: now.value.addingTimeInterval(-60))
        try board.markNotified(shown.id)
        let ticked = try board.add(.reminders, "Done already", due: now.value.addingTimeInterval(-60))
        try board.setDone(ticked.id, true)
        try board.add(.ideas, "Not a reminder")
        let screen = FakeScreen()
        let cards = screen.cards(for: board)

        cards.showDue()
        XCTAssertEqual(screen.made.map(\.text), ["Call mom", "Stretch"])
        XCTAssertTrue(screen.made.allSatisfy { $0.shown && $0.frame != nil })
        XCTAssertEqual(screen.sounds, 1)
        XCTAssertEqual(board.items.first { $0.id == missed.id }?.notified, true, "shown once, after a restart too")

        cards.showDue()
        XCTAssertEqual(screen.made.count, 2)
        XCTAssertEqual(screen.sounds, 1, "no sound without a new card")

        now.update { $0 = $0.addingTimeInterval(3_600) }
        cards.showDue()
        XCTAssertEqual(screen.made.map(\.text), ["Call mom", "Stretch", "Water the plants"])
        XCTAssertEqual(screen.sounds, 2)
        XCTAssertEqual(cards.openReminders.count, 3)
    }

    @MainActor
    func testAtMostFourAreOpenAndTheNextComesOnceOneIsAnswered() throws {
        let now = Locked(Self.start)
        let board = try BoardStore(path: nil, clock: { now.value })
        for number in 1...6 {
            try board.add(.reminders, "Reminder \(number)", due: now.value.addingTimeInterval(Double(number - 10)))
        }

        let screen = FakeScreen()
        let cards = screen.cards(for: board)
        cards.showDue()
        XCTAssertEqual(screen.open.map(\.text), ["Reminder 1", "Reminder 2", "Reminder 3", "Reminder 4"])

        screen.open[1].answer(.done)
        XCTAssertEqual(screen.open.map(\.text), ["Reminder 1", "Reminder 3", "Reminder 4"])
        cards.showDue()
        XCTAssertEqual(screen.open.map(\.text), ["Reminder 1", "Reminder 3", "Reminder 4", "Reminder 5"])
    }

    @MainActor
    func testCardsStackUpFromTheBottomRightOldestAtTheBottom() throws {
        // A 1440 × 900 screen whose Dock ends 70 points up and whose menu bar starts at 875.
        let area = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let sizes = [CGSize(width: 354, height: 128), CGSize(width: 354, height: 150), CGSize(width: 354, height: 110)]
        XCTAssertEqual(
            ReminderCards.stack(sizes, in: area),
            [
                CGRect(x: 1070, y: 74, width: 354, height: 128),
                CGRect(x: 1070, y: 214, width: 354, height: 150),
                CGRect(x: 1070, y: 376, width: 354, height: 110),
            ])

        let now = Locked(Self.start)
        let board = try BoardStore(path: nil, clock: { now.value })
        for (index, text) in ["Call mom", "Book the dentist for Thursday morning", "Stretch"].enumerated() {
            try board.add(.reminders, text, due: now.value.addingTimeInterval(Double(index - 10)))
        }

        let screen = FakeScreen()
        let cards = screen.cards(for: board)
        cards.showDue()
        let frames: [CGRect] = screen.made.map { card -> CGRect in card.frame ?? CGRect.null }
        XCTAssertEqual(frames, ReminderCards.stack(screen.made.map(\.size), in: screen.area))

        // The bottom one is answered: the others move down.
        screen.made[0].answer(.snooze)
        XCTAssertEqual(screen.made[1].frame, CGRect(x: 1070, y: 74, width: 354, height: 150))
        XCTAssertEqual(screen.made[2].frame, CGRect(x: 1070, y: 236, width: 354, height: 128))
    }

    @MainActor
    func testDoneSnoozeAndOpenBoard() throws {
        let now = Locked(Self.start)
        let board = try BoardStore(path: nil, clock: { now.value })
        for (index, text) in ["Call mom", "Stretch", "Water the plants"].enumerated() {
            try board.add(.reminders, text, due: now.value.addingTimeInterval(Double(index - 10)))
        }

        let screen = FakeScreen()
        let cards = screen.cards(for: board)
        cards.showDue()
        let call = screen.made[0]
        let stretch = screen.made[1]
        let water = screen.made[2]

        call.answer(.done)
        XCTAssertEqual(board.items.first { $0.text == "Call mom" }?.done, true)
        XCTAssertTrue(call.closed)

        stretch.answer(.snooze)
        let snoozed = try XCTUnwrap(board.items.first { $0.text == "Stretch" })
        XCTAssertEqual(snoozed.due, now.value.addingTimeInterval(600))
        XCTAssertFalse(snoozed.notified)
        XCTAssertTrue(stretch.closed)

        water.answer(.openBoard)
        XCTAssertEqual(screen.boardsOpened, 1)
        XCTAssertTrue(water.closed)
        XCTAssertEqual(board.items.first { $0.text == "Water the plants" }?.done, false)
        XCTAssertEqual(cards.openReminders, [])

        // The snoozed one comes back ten minutes later.
        now.update { $0 = $0.addingTimeInterval(599) }
        cards.showDue()
        XCTAssertEqual(screen.made.count, 3)
        now.update { $0 = $0.addingTimeInterval(1) }
        cards.showDue()
        XCTAssertEqual(screen.made.map(\.text).last, "Stretch")
        XCTAssertEqual(screen.made.count, 4)
    }

    @MainActor
    func testAnAnswerThatCantBeSavedKeepsTheCardAndSaysSo() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let now = Locked(Self.start)
        let board = try BoardStore(path: folder.file("board.json"), clock: { now.value })
        try board.add(.reminders, "Call mom", due: now.value)
        // From now on the board can't be saved: where it writes before swapping its file in is taken by a folder.
        try FileManager.default.createDirectory(
            atPath: folder.file("board.json.tmp"), withIntermediateDirectories: true)
        let screen = FakeScreen()
        let cards = screen.cards(for: board)

        cards.showDue()
        XCTAssertEqual(screen.made.count, 1, "the card shows although saving that it was shown failed")
        XCTAssertEqual(screen.reports.count, 1)
        cards.showDue()
        XCTAssertEqual(screen.made.count, 1, "and it isn't shown twice")

        screen.made[0].answer(.done)
        XCTAssertFalse(screen.made[0].closed, "the card stays until its answer is saved")
        XCTAssertEqual(screen.reports.count, 2)
        XCTAssertTrue(screen.reports.allSatisfy { $0.hasPrefix("Something went wrong: ") }, "\(screen.reports)")
    }

    @MainActor
    func testStartingChecksTheBoardStraightAway() throws {
        let now = Locked(Self.start)
        let board = try BoardStore(path: nil, clock: { now.value })
        try board.add(.reminders, "Call mom", due: now.value.addingTimeInterval(-3_600))
        let screen = FakeScreen()
        let cards = screen.cards(for: board)

        cards.start()
        defer { cards.stop() }
        XCTAssertTrue(screen.made.isEmpty, "on the main loop's next turn")
        let deadline = Date().addingTimeInterval(2)
        while screen.made.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(screen.made.map(\.text), ["Call mom"])
    }
}

/// The cards' side of the screen: fake cards, the sound, the reports and the board's opening.
@MainActor
private final class FakeScreen {
    @MainActor
    final class Card: ReminderCardWindow {
        let text: String
        let answer: @MainActor (ReminderAnswer) -> Void
        let size: CGSize
        var frame: CGRect?
        var shown = false
        var closed = false

        init(text: String, answer: @escaping @MainActor (ReminderAnswer) -> Void, size: CGSize) {
            self.text = text
            self.answer = answer
            self.size = size
        }

        func place(_ frame: CGRect) {
            self.frame = frame
        }

        func show() {
            shown = true
        }

        func close() {
            closed = true
        }
    }

    /// A 1440 × 900 screen's visible area.
    let area = CGRect(x: 0, y: 70, width: 1440, height: 805)
    var made: [Card] = []
    var sounds = 0
    var reports: [String] = []
    var boardsOpened = 0

    var open: [Card] { made.filter { !$0.closed } }

    func cards(for board: BoardStore) -> ReminderCards {
        ReminderCards(
            board: board,
            openBoard: { self.boardsOpened += 1 },
            report: { self.reports.append($0) },
            sound: { self.sounds += 1 },
            makeCard: { item, answer in
                // A longer reminder makes a taller card.
                let card = Card(
                    text: item.text, answer: answer, size: CGSize(width: 354, height: item.text.count > 20 ? 150 : 128))
                self.made.append(card)
                return card
            },
            area: { self.area })
    }
}
