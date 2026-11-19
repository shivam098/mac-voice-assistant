import XCTest
@testable import VoiceAssistantBoard

/// windows-voice-assistant tests/VoiceAssistant.Board.Tests/BoardTests.cs, case for case: the same inputs and expected
/// results. A C# theory is one test here, which runs all its cases.
final class BoardTests: XCTestCase {
    // Wednesday 2026-11-11 14:30 (+05:30)
    private let now = moment(2026, 11, 11, 14, 30)

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { moment(2026, 11, day, hour, minute) }

    private func parse(_ spoken: String, explicitOnly: Bool = false) -> BoardIntent? {
        BoardGrammar.parse(spoken, now: now, explicitOnly: explicitOnly, timeZone: india)
    }

    private func times(_ spoken: String, at said: Date? = nil) -> (task: String, due: Date?) {
        ReminderTime.parse(spoken, now: said ?? now, timeZone: india)
    }

    /// C#'s `Single`: the one item that matches.
    private func single(
        _ items: [BoardItem], file: StaticString = #filePath, line: UInt = #line, _ isIncluded: (BoardItem) -> Bool
    ) throws -> BoardItem {
        let found = items.filter(isIncluded)
        XCTAssertEqual(found.count, 1, file: file, line: line)
        return try XCTUnwrap(found.first, file: file, line: line)
    }

    // ---- grammar ----

    func testExplicitListRequestsWorkEverywhere() {
        let cases: [(String, BoardList, String)] = [
            ("Add to my ideas, a voice game for kids.", .ideas, "A voice game for kids"),
            ("Add to my ideas: build a sticky note board", .ideas, "Build a sticky note board"),
            ("Add to brainstorming, offline voice search", .brainstorm, "Offline voice search"),
            ("Put this on my to-do list, renew passport", .todo, "Renew passport"),
            ("Add renew passport to my to do list.", .todo, "Renew passport"),
            ("Add buy milk to my todos", .todo, "Buy milk"),
            ("Save to my brainstorm board: pricing ideas", .brainstorm, "Pricing ideas"),
            ("Add to my reminders, pay rent", .reminders, "Pay rent"),
        ]
        for (spoken, list, text) in cases {
            for explicitOnly in [true, false] {
                let intent = parse(spoken, explicitOnly: explicitOnly)
                XCTAssertEqual(intent?.action, .add, spoken)
                XCTAssertEqual(intent?.list, list, spoken)
                XCTAssertEqual(intent?.text, text, spoken)
            }
        }
    }

    func testLooserFormsNeedTheWakeWord() {
        let cases = [
            "Remind me to call mom tomorrow at 5 pm.",
            "Note down that the demo needs subtitles.",
            "New idea, a voice-controlled kitchen timer.",
            "Show my ideas.",
            "Mark renew passport as done.",
        ]
        for spoken in cases {
            XCTAssertNil(parse(spoken, explicitOnly: true), spoken)
            XCTAssertNotNil(parse(spoken), spoken)
        }
    }

    func testOrdinaryDictationIsNotABoardRequest() {
        let cases = [
            "Please send the report to my manager.",
            "I added the tests to the pipeline.",
            "Let's put the meeting notes in the wiki.",
            "The board meeting is at 5.",
        ]
        for spoken in cases {
            XCTAssertNil(parse(spoken, explicitOnly: true), spoken)
        }
    }

    func testRemindMeFilesAReminderWithItsTime() {
        let intent = parse("Remind me to call mom tomorrow at 5 pm.")
        XCTAssertEqual(intent?.list, .reminders)
        XCTAssertEqual(intent?.text, "Call mom")
        XCTAssertEqual(intent?.due, at(12, 17))
    }

    func testShowNamesAList() {
        let cases: [(String, BoardList)] = [
            ("Show my ideas.", .ideas),
            ("Open my to-do list", .todo),
            ("Show me my reminders", .reminders),
            ("Show the brainstorming list", .brainstorm),
        ]
        for (spoken, list) in cases {
            XCTAssertEqual(parse(spoken), BoardIntent(action: .show, list: list), spoken)
        }
    }

    func testShowMyBoardOpensTheWholeBoard() {
        XCTAssertEqual(parse("Open my board."), BoardIntent(action: .show, list: nil))
    }

    func testMarkDoneNamesTheItem() {
        let intent = parse("Mark renew passport as done.")
        XCTAssertEqual(intent?.action, .complete)
        XCTAssertEqual(intent?.text, "renew passport")
    }

    func testOtherWaysToTickOff() {
        let cases = [
            ("Tick off renew passport", "renew passport"),
            ("Cross pay rent off.", "pay rent"),
            ("Mark buy milk done", "buy milk"),
        ]
        for (spoken, text) in cases {
            XCTAssertEqual(parse(spoken), BoardIntent(action: .complete, list: nil, text: text), spoken)
        }
    }

    // These are commands for the app on screen; with the wake word the board must not swallow them.
    func testAppCommandsAreNotBoardRequests() {
        let cases = [
            "Tick the checkbox",
            "Complete the form",
            "Finish typing",
            "Mark this email as read",
            "Open notes",
            "Open tasks",
            "Go to to do",
        ]
        for spoken in cases {
            XCTAssertNil(parse(spoken), spoken)
        }
    }

    // ---- reminder times ----

    func testLeadingFillerWordsAreIgnored() {
        let cases: [(String, BoardList, String)] = [
            ("and add to my reminder, I have to draft a reply to Tata", .reminders, "I have to draft a reply to Tata"),
            ("Um, add to my ideas, a voice game", .ideas, "A voice game"),
            ("Also add renew passport to my to-do list.", .todo, "Renew passport"),
            ("Um, so, add to my brainstorm list, pricing", .brainstorm, "Pricing"),
            ("So, and add to my reminders: pay rent", .reminders, "Pay rent"),
        ]
        for (spoken, list, text) in cases {
            let intent = parse(spoken, explicitOnly: true)
            XCTAssertEqual(intent?.list, list, spoken)
            XCTAssertEqual(intent?.text, text, spoken)
        }
    }

    func testDictationWithNowhereToTypeGoesToASensibleList() {
        let cases: [(String, BoardList, String)] = [
            ("A voice game where kids guess animal sounds.", .ideas, "A voice game where kids guess animal sounds"),
            ("I have to draft a reply to Tata Neu.", .todo, "Draft a reply to Tata Neu"),
            ("We should move the standup to Thursdays", .todo, "Move the standup to Thursdays"),
            ("Don't forget to water the plants", .todo, "Water the plants"),
            ("I have to call mom tomorrow at 5 pm.", .reminders, "Call mom"),
            ("Pay the rent in 2 hours", .reminders, "Pay the rent"),
            ("Add to my brainstorm list, pricing tiers", .brainstorm, "Pricing tiers"),
            ("and add to my reminder, I have to draft a reply", .reminders, "I have to draft a reply"),
            ("Call 3 people about the offsite", .todo, "Call 3 people about the offsite"),
            ("I've got to call mom.", .todo, "Call mom"),
            ("Don\u{2019}t forget to water the plants", .todo, "Water the plants"),
            ("To-do: renew the domain", .todo, "Renew the domain"),
            ("To do that we need more data", .ideas, "To do that we need more data"),
            ("The demo today went well.", .ideas, "The demo today went well"),
            ("We met at 10 and agreed to ship on Friday.", .ideas, "We met at 10 and agreed to ship on Friday"),
            ("Version 2:30 of the app is great", .ideas, "Version 2:30 of the app is great"),
            ("Call the bank this morning", .todo, "Call the bank this morning"),
        ]
        for (spoken, list, text) in cases {
            let intent = BoardGrammar.forDictation(spoken, now: now, timeZone: india)
            XCTAssertEqual(intent?.action, .add, spoken)
            XCTAssertEqual(intent?.list, list, spoken)
            XCTAssertEqual(intent?.text, text, spoken)
        }
    }

    func testNothingToKeepIsNotANote() {
        for text in ["", "\n", " . "] {
            XCTAssertNil(BoardGrammar.forDictation(text, now: now, timeZone: india), text)
        }
    }

    func testCanYouStillWorksAfterTheWakeWord() {
        XCTAssertEqual(parse("Can you please add to my brainstorm list, pricing")?.list, .brainstorm)
    }

    func testPushToTalkTypesSentencesMeantForSomeoneElse() {
        let cases = [
            "Please add the action items to the notes.",
            "Put the agenda on the board.",
            "Write your name on the board.",
            "Add these to the tasks.",
            "Can you add this to the to-do list for the sprint",
            "Can you add the pricing deck to the ideas list.",
            "Could you put the launch date in our reminders.",
            "So will you add the venue to our to-do list.",
            "Can you add the slides to our tasks",
        ]
        for spoken in cases {
            XCTAssertNil(parse(spoken, explicitOnly: true), spoken)
        }
    }

    func testPushToTalkFilesRequestsForMyBoard() {
        let cases: [(String, BoardList)] = [
            ("Put the agenda on my board.", .ideas),
            ("Add these to our tasks.", .todo),
            ("Add pricing to the brainstorm list", .brainstorm),
        ]
        for (spoken, list) in cases {
            XCTAssertEqual(parse(spoken, explicitOnly: true)?.list, list, spoken)
        }
    }

    func testVagueAmountsCount() {
        let cases = [
            ("stretch in a couple of hours", 2 * 60),
            ("stretch in a few minutes", 3),
            ("stretch in  a  few  minutes", 3),
            ("stretch in couple of hours", 2 * 60),
        ]
        for (spoken, minutes) in cases {
            XCTAssertEqual(times(spoken).due, now.addingTimeInterval(TimeInterval(minutes * 60)), spoken)
        }
    }

    func testAReminderPastADaylightSavingChangeKeepsItsClockTime() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let friday = moment(2027, 3, 12, 15, 0, in: offset(hours: -8)) // clocks go forward on 14 March
        let due = ReminderTime.parse("standup on Monday at 9 am", now: friday, timeZone: zone).due
        XCTAssertEqual(due, moment(2027, 3, 15, 9, 0, in: offset(hours: -7)))
    }

    func testNoonAndMidnightAreNeverSwapped() {
        let cases = [
            (9, "back up the laptop at midnight", 12, 0),
            (9, "lunch at noon", 11, 12),
            (23, "lunch at noon", 12, 12),
        ]
        for (nowHour, spoken, day, hour) in cases {
            XCTAssertEqual(times(spoken, at: moment(2026, 11, 11, nowHour, 0)).due, at(day, hour), spoken)
        }
    }

    func testTimesAreFoundAndRemoved() {
        let cases: [(String, String, Int, Int, Int)] = [
            ("call mom tomorrow at 5 pm", "call mom", 12, 17, 0),
            ("call mom tomorrow at 5", "call mom", 12, 17, 0),
            ("standup tomorrow at 9", "standup", 12, 9, 0),
            ("pay rent at 6", "pay rent", 11, 18, 0),
            ("pay rent at 2", "pay rent", 12, 2, 0),
            ("water plants at 5:30 p.m.", "water plants", 11, 17, 30),
            ("water plants 17:45", "water plants", 11, 17, 45),
            ("check the oven at noon", "check the oven", 12, 12, 0),
            ("take medicine tonight", "take medicine", 11, 20, 0),
            ("take medicine tomorrow morning", "take medicine", 12, 9, 0),
            ("send the invoice tomorrow", "send the invoice", 12, 9, 0),
            ("gym in the evening", "gym", 11, 18, 0),
            ("review the deck on Friday at 10 am", "review the deck", 13, 10, 0),
            ("team lunch next Wednesday", "team lunch", 18, 9, 0),
        ]
        for (spoken, task, day, hour, minute) in cases {
            let found = times(spoken)
            XCTAssertEqual(found.task, task, spoken)
            XCTAssertEqual(found.due, at(day, hour, minute), spoken)
        }
    }

    func testRelativeTimes() {
        let cases = [
            ("stretch in 10 minutes", 10),
            ("stretch in ten minutes", 10),
            ("check the build in an hour", 60),
            ("check the build in half an hour", 30),
            ("follow up in 2 days", 2 * 24 * 60),
        ]
        for (spoken, minutes) in cases {
            XCTAssertEqual(times(spoken).due, now.addingTimeInterval(TimeInterval(minutes * 60)), spoken)
        }
    }

    func testNoTimeMeansNoDueDate() {
        for spoken in ["call 3 people about the launch", "buy a gift"] {
            let found = times(spoken)
            XCTAssertNil(found.due, spoken)
            XCTAssertEqual(found.task, spoken)
        }
    }

    // ---- store ----

    func testItemsSurviveARestart() throws {
        let now = self.now
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        let store = try BoardStore(path: path, clock: { now })
        let idea = try store.add(.ideas, "  voice game   for kids. ")
        try store.add(.reminders, "call mom", due: at(12, 17))
        try store.setDone(idea.id, true)

        let reloaded = try BoardStore(path: path, clock: { now })
        XCTAssertEqual(reloaded.items.count, 2)
        let item = try single(reloaded.items) { $0.list == .ideas }
        XCTAssertEqual(item.text, "Voice game for kids")
        XCTAssertTrue(item.done)
        XCTAssertEqual(try single(reloaded.items) { $0.list == .reminders }.due, at(12, 17))
    }

    func testUnreadableFileIsKeptAndAFreshBoardStarts() throws {
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        try writeFile("{ not json", to: path)
        let store = try BoardStore(path: path)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(unreadableCopies(of: path).count, 1)
    }

    func testDueRemindersNotifyOnceAndSnoozeBringsThemBack() throws {
        var current = now
        let store = try BoardStore(path: nil, clock: { current })
        let reminder = try store.add(.reminders, "call mom", due: now.addingTimeInterval(5 * 60))
        XCTAssertTrue(store.dueReminders().isEmpty)
        current = now.addingTimeInterval(6 * 60)
        XCTAssertEqual(store.dueReminders().count, 1)
        try store.markNotified(reminder.id)
        XCTAssertTrue(store.dueReminders().isEmpty)
        try store.snooze(reminder.id, by: 10 * 60)
        current = current.addingTimeInterval(11 * 60)
        XCTAssertEqual(store.dueReminders().count, 1)
    }

    func testCompleteMatchingTicksTheClosestOpenItem() throws {
        let now = self.now
        let store = try BoardStore(path: nil, clock: { now })
        try store.add(.todo, "Renew passport")
        try store.add(.todo, "Buy milk")
        let done = try store.completeMatching("renew the passport")
        XCTAssertEqual(done?.text, "Renew passport")
        XCTAssertTrue(try single(store.items) { $0.text == "Renew passport" }.done)
        XCTAssertNil(try store.completeMatching("call the plumber"))
    }

    func testChangedFiresAfterEachChange() throws {
        let now = self.now
        let store = try BoardStore(path: nil, clock: { now })
        var count = 0
        store.onChange { count += 1 }
        let item = try store.add(.ideas, "x")
        try store.move(item.id, to: .brainstorm)
        try store.remove(item.id)
        XCTAssertEqual(count, 3)
    }

    // ---- dragging (positions) ----

    private func shown(_ store: BoardStore, _ list: BoardList) -> [String] {
        BoardStore.arrange(store.items.filter { $0.list == list && !$0.done }, list).map(\.text)
    }

    func testNewNotesGoOnTop() throws {
        let now = self.now
        let store = try BoardStore(path: nil, clock: { now })
        try store.add(.ideas, "one")
        try store.add(.ideas, "two")
        XCTAssertEqual(shown(store, .ideas), ["Two", "One"])
    }

    func testDraggingWithinAListReordersItAndSurvivesAReload() throws {
        let now = self.now
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        let store = try BoardStore(path: path, clock: { now })
        let a = try store.add(.todo, "a")
        try store.add(.todo, "b")
        try store.add(.todo, "c")
        try store.place(a.id, in: .todo, at: 0)
        XCTAssertEqual(shown(store, .todo), ["A", "C", "B"])
        try store.add(.todo, "d")
        XCTAssertEqual(shown(try BoardStore(path: path, clock: { now }), .todo), ["D", "A", "C", "B"])
    }

    func testDraggingToAnotherListPutsItWhereItWasDropped() throws {
        let now = self.now
        let store = try BoardStore(path: nil, clock: { now })
        let idea = try store.add(.ideas, "idea")
        try store.add(.brainstorm, "x")
        try store.add(.brainstorm, "y")
        try store.place(idea.id, in: .brainstorm, at: 1)
        XCTAssertTrue(shown(store, .ideas).isEmpty)
        XCTAssertEqual(shown(store, .brainstorm), ["Y", "Idea", "X"])
        try store.place(idea.id, in: .todo, at: 99)
        XCTAssertEqual(shown(store, .todo), ["Idea"])
    }

    func testRemindersStayInTimeOrderAndADoneNoteKeepsItsTick() throws {
        let now = self.now
        let store = try BoardStore(path: nil, clock: { now })
        try store.add(.reminders, "later", due: now.addingTimeInterval(2 * 3600))
        let soon = try store.add(.reminders, "soon", due: now.addingTimeInterval(3600))
        try store.place(soon.id, in: .reminders, at: 1)
        XCTAssertEqual(shown(store, .reminders), ["Soon", "Later"])

        let done = try store.add(.ideas, "done one")
        try store.setDone(done.id, true)
        try store.place(done.id, in: .todo, at: 0)
        let item = try single(store.items) { $0.id == done.id }
        XCTAssertTrue(item.done && item.list == .todo)
    }
}
