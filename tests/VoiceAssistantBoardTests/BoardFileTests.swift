import XCTest
@testable import VoiceAssistantBoard

/// board.json is the same file on Windows and the Mac. The samples are what windows-voice-assistant's BoardStore.cs
/// writes, made by running it on Windows: System.Text.Json indented with CRLF line ends, camelCase names, lists by
/// name, times with their offset and up to 7 decimals, .NET's numbers and escapes.
final class BoardFileTests: XCTestCase {
    // ---- Windows' files ----

    func testAWindowsBoardIsReadAndWrittenBackUnchanged() throws {
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        try writeFile(Self.windowsSample, to: path)
        // The times keep the offsets they were written with, whatever the Mac's own time zone.
        let store = try BoardStore(path: path, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        let items = store.items
        XCTAssertEqual(items.map(\.list), [.ideas, .todo, .reminders, .brainstorm, .ideas])
        XCTAssertEqual(items[0].id, "98e441aa3d994d4680d606557aaf0790")
        XCTAssertEqual(items[0].text, "A voice game for kids")
        XCTAssertEqual(items[0].created.timeIntervalSince(moment(2026, 11, 11, 14, 30, 12)), 0.3456789, accuracy: 1e-6)
        XCTAssertNil(items[0].due)
        XCTAssertEqual(items.map(\.order), [0, -1, -1, 0.5, -2.25])
        XCTAssertEqual(items.map(\.done), [false, true, false, false, false])
        XCTAssertEqual(items.map(\.notified), [false, false, true, false, false])
        XCTAssertEqual(items[2].due, moment(2026, 11, 12, 17, 0))
        XCTAssertEqual(items[3].text, "\u{201C}Priya\u{201D} \"caf\u{E9}\" & <b> 's \\ \u{1F389} \u{939}\u{93F}")
        XCTAssertEqual(items[3].due, moment(2027, 3, 15, 9, 0, in: offset(hours: -7)))
        XCTAssertEqual(items[4].created, BoardItem.zeroTime)

        // Every change writes the whole file: with nothing else changed, it's what Windows wrote, byte for byte.
        try store.update(items[0])
        XCTAssertEqual(try fileText(path), Self.windowsSample)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(Self.windowsSample.utf8))
    }

    func testAChangedNoteIsWrittenAsWindowsWouldWriteIt() throws {
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        try writeFile(Self.windowsSample, to: path)
        let now = moment(2026, 11, 12, 10, 0)
        let store = try BoardStore(path: path, clock: { now }, timeZone: india)
        try store.snooze("3898f14a9d2c409aa6dcce738a7525c8", by: 10 * 60)
        let expected = Self.windowsSample.replacingOccurrences(
            of: "\"due\": \"2026-11-12T17:00:00+05:30\",\r\n      \"done\": false,\r\n      \"notified\": true",
            with: "\"due\": \"2026-11-12T10:10:00+05:30\",\r\n      \"done\": false,\r\n      \"notified\": false")
        XCTAssertNotEqual(expected, Self.windowsSample)
        XCTAssertEqual(try fileText(path), expected)
    }

    func testAnOlderFileIsRewrittenAsWindowsRewritesIt() throws {
        // Read and saved by BoardStore.cs on a PC in India: missing values get C#'s defaults, a list's name in other
        // capitals or its number is read, other forms of time are written the usual way (a time without an offset is
        // the PC's local time), and values the board doesn't know are dropped.
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        try writeFile(Self.olderFile, to: path)
        let store = try BoardStore(path: path, timeZone: india)
        // Notes without a position show newest first.
        let todo = store.items.filter { $0.list == .todo }
        XCTAssertEqual(BoardStore.arrange(todo, .todo).map(\.text), ["Buy milk", "Renew passport"])
        try store.update(store.items[0])
        XCTAssertEqual(try fileText(path), Self.olderRewritten)
    }

    // ---- the Mac's files ----

    func testANewBoardIsWrittenAsWindowsWritesIt() throws {
        // The same steps as in BoardStore.cs on a PC in India give the same file.
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        var current = moment(2026, 11, 11, 14, 30)
        let store = try BoardStore(path: path, clock: { current }, timeZone: india)
        let idea = try store.add(.ideas, "a voice game for kids")
        current = current.addingTimeInterval(90.5)
        let todo = try store.add(.todo, "renew passport")
        let reminder = try store.add(.reminders, "call mom", due: moment(2026, 11, 12, 17, 0))
        try store.setDone(todo.id, true)
        try store.place(idea.id, in: .brainstorm, at: 0)
        try store.snooze(reminder.id, by: 10 * 60)
        let expected = Self.freshFile.replacingOccurrences(of: "{idea}", with: idea.id)
            .replacingOccurrences(of: "{todo}", with: todo.id)
            .replacingOccurrences(of: "{reminder}", with: reminder.id)
        XCTAssertEqual(try fileText(path), expected)
        XCTAssertEqual(idea.id.count, 32)
        XCTAssertEqual(idea.id, idea.id.lowercased())
    }

    func testAnEmptyBoard() throws {
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        let store = try BoardStore(path: path)
        let note = try store.add(.ideas, "x")
        try store.remove(note.id)
        XCTAssertEqual(try fileText(path), "{\r\n  \"version\": 1,\r\n  \"items\": []\r\n}")
    }

    func testWhatCountsAsUnreadable() throws {
        // These make System.Text.Json throw, so C# copies the file aside and starts an empty board.
        let unreadable = [
            "", "   ", "[]", "{ not json", "{\"items\":[{}],}", "// c\n{\"items\":[]}", "{\"items\":[{}]} x",
            "{\"items\":[{\"text\":\"a\"}]}{}", "{\"version\":\"1\",\"items\":[]}", "{\"version\":1.5,\"items\":[]}",
            "{\"items\":{}}", "{\"items\":[[]]}", "{\"items\":[{\"done\":null}]}", "{\"items\":[{\"done\":1}]}",
            "{\"items\":[{\"notified\":\"true\"}]}", "{\"items\":[{\"order\":\"1\"}]}", "{\"items\":[{\"id\":5}]}",
            "{\"items\":[{\"text\":5}]}", "{\"items\":[{\"created\":null}]}", "{\"items\":[{\"due\":5}]}",
            "{\"items\":[{\"list\":\"Nope\"}]}", "{\"items\":[{\"list\":null}]}",
            "{\"items\":[{\"created\":\"2026-11-11 14:30:00+05:30\"}]}",
        ]
        for content in unreadable {
            let path = temporaryBoardPath()
            defer { removeBoardFiles(path) }
            try writeFile(content, to: path)
            XCTAssertTrue(try BoardStore(path: path).items.isEmpty, content)
            XCTAssertEqual(unreadableCopies(of: path).count, 1, content)
            XCTAssertEqual(try fileText(path), content, "The file itself stays until the next change")
        }

        // These are read. Unlike C#, a null in the list is no note (C# keeps a null one, which then fails), and a list
        // number other than 0 to 3 is unreadable (C# keeps a note in no list, never shown).
        let readable: [(String, [BoardList])] = [
            ("null", []), ("{}", []), ("{\"items\":null}", []), ("{\"version\":2,\"items\":[]}", []),
            ("\u{FEFF}{\"items\":[{}]}", [.ideas]), ("{\"items\":[null]}", []),
            ("{\"items\":[{\"list\":\"brainSTORM\"},{\"list\":\"3\"},{\"list\":2}]}", [.brainstorm, .reminders, .todo]),
        ]
        for (content, lists) in readable {
            let path = temporaryBoardPath()
            defer { removeBoardFiles(path) }
            try writeFile(content, to: path)
            XCTAssertEqual(try BoardStore(path: path).items.map(\.list), lists, content)
            XCTAssertTrue(unreadableCopies(of: path).isEmpty, content)
        }
    }

    func testTheUnreadableCopyIsNamedAfterTheTime() throws {
        let path = temporaryBoardPath()
        defer { removeBoardFiles(path) }
        try writeFile("{", to: path)
        _ = try BoardStore(path: path, clock: { moment(2026, 11, 11, 14, 30, 5) }, timeZone: india)
        let name = URL(fileURLWithPath: path).lastPathComponent
        XCTAssertEqual(unreadableCopies(of: path), [name + ".unreadable-20261111143005"])
    }

    // ---- System.Text.Json's formats ----

    func testTimesAreReadAsSystemTextJsonReadsThem() {
        let cases: [(String, String?)] = [
            ("2026-11-11T14:30:00+05:30", "2026-11-11T14:30:00+05:30"),
            ("2026-11-11T14:30:00Z", "2026-11-11T14:30:00+00:00"),
            ("2026-11-11T14:30Z", "2026-11-11T14:30:00+00:00"),
            ("2026-11-11T14:30+05:30", "2026-11-11T14:30:00+05:30"),
            ("2026-11-11T14:30:00", "2026-11-11T14:30:00+05:30"),
            ("2026-11-11T14:30", "2026-11-11T14:30:00+05:30"),
            ("2026-11-11", "2026-11-11T00:00:00+05:30"),
            ("2026-11-11T14:30:00.5", "2026-11-11T14:30:00.5+05:30"),
            ("2026-11-11T14:30:00.1234567+05:30", "2026-11-11T14:30:00.1234567+05:30"),
            ("2026-11-11T14:30:00.12345678901+05:30", "2026-11-11T14:30:00.1234567+05:30"),
            ("2026-11-11T14:30:00.1234567890123456+05:30", "2026-11-11T14:30:00.1234567+05:30"),
            ("2026-11-11T14:30:00.12345678901234567+05:30", nil),
            ("2026-11-11T14:30:00.0000000+05:30", "2026-11-11T14:30:00+05:30"),
            ("2026-11-11T14:30:00.1+05:30", "2026-11-11T14:30:00.1+05:30"),
            ("2026-11-11T14:30:00.+05:30", "2026-11-11T14:30:00+05:30"),
            ("2026-11-11T14:30:00.Z", "2026-11-11T14:30:00+00:00"),
            ("2026-11-11T14:30:00+05", "2026-11-11T14:30:00+05:00"),
            ("2026-11-11T14:30:00-00:00", "2026-11-11T14:30:00+00:00"),
            ("2026-11-11T14:30:00+14:00", "2026-11-11T14:30:00+14:00"),
            ("2026-11-11T23:59:59.9999999+05:30", "2026-11-11T23:59:59.9999999+05:30"),
            ("2028-02-29T00:00:00Z", "2028-02-29T00:00:00+00:00"),
            ("0001-01-01T00:00:00+00:00", "0001-01-01T00:00:00+00:00"),
            ("9999-12-31T23:59:59.9999999+00:00", "9999-12-31T23:59:59.9999999+00:00"),
            ("2026-11-11T14:30:00+0530", nil),
            ("2026-11-11T14:30:00+05:3", nil),
            ("2026-11-11T14:30:00+05:60", nil),
            ("2026-11-11T14:30:00+14:30", nil),
            ("2026-11-11T14:30:00+15:00", nil),
            ("2026-11-11 14:30:00+05:30", nil),
            ("2026-11-11t14:30:00z", nil),
            ("2026-11-11T14:30:00 +05:30", nil),
            (" 2026-11-11T14:30:00+05:30", nil),
            ("+2026-11-11T14:30:00+05:30", nil),
            ("2026-13-01T00:00:00Z", nil),
            ("2026-02-30T10:00:00+05:30", nil),
            ("2027-02-29T00:00:00Z", nil),
            ("2026-11-11T14:30:60+05:30", nil),
            ("0000-12-31T00:00:00+00:00", nil),
            ("0001-01-01T00:30:00+01:00", nil),
            ("9999-12-31T23:30:00-01:00", nil),
        ]
        for (text, rewritten) in cases {
            XCTAssertEqual(DateTimeOffset(iso: text, localZone: india)?.iso, rewritten, text)
        }

        let read = DateTimeOffset(iso: "2026-11-11T14:30:00+05:30", localZone: india)
        XCTAssertEqual(read?.date, moment(2026, 11, 11, 14, 30))
        XCTAssertEqual(DateTimeOffset(iso: "0001-01-01T00:00:00+00:00", localZone: india)?.date, BoardItem.zeroTime)
    }

    func testTimesAreWrittenWithTheOffsetOfTheirZone() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func iso(_ date: Date, _ zone: TimeZone) -> String { DateTimeOffset(date, in: zone).iso }
        XCTAssertEqual(iso(moment(2026, 11, 11, 14, 30), india), "2026-11-11T14:30:00+05:30")
        XCTAssertEqual(iso(moment(2027, 3, 15, 9, 0, in: losAngeles), losAngeles), "2027-03-15T09:00:00-07:00")
        XCTAssertEqual(iso(moment(2027, 1, 15, 9, 0, in: losAngeles), losAngeles), "2027-01-15T09:00:00-08:00")
        let utc = offset(hours: 0)
        XCTAssertEqual(iso(moment(2026, 11, 11, 9, 0, in: utc), utc), "2026-11-11T09:00:00+00:00")
        // To the microsecond, which a Date this century holds.
        let fraction = moment(2026, 11, 11, 14, 30).addingTimeInterval(0.123456)
        XCTAssertEqual(iso(fraction, india), "2026-11-11T14:30:00.123456+05:30")
        // Kept within .NET's years, 1 to 9999.
        XCTAssertEqual(iso(BoardItem.zeroTime, losAngeles), "0001-01-01T00:00:00+00:00")
        XCTAssertEqual(iso(.distantPast, india), "0001-01-01T05:30:00+05:30")
        XCTAssertEqual(iso(Date(timeIntervalSince1970: 1e12), india), "9999-12-31T23:59:59.9999999+00:00")
    }

    func testNumbersAreWrittenAsDotNetWritesThem() {
        let cases: [(Double, String)] = [
            (-1, "-1"), (0, "0"), (-0.0, "-0"), (0.5, "0.5"), (-2.25, "-2.25"), (1.5, "1.5"), (-0.5, "-0.5"),
            (100, "100"), (1e14, "100000000000000"), (1e15, "1000000000000000"), (-1e15, "-1000000000000000"),
            (1e16, "10000000000000000"), (1e17, "1E+17"), (1e21, "1E+21"), (123_456_789_012_345, "123456789012345"),
            (1_234_567_890_123_456, "1234567890123456"), (9_007_199_254_740_992, "9007199254740992"),
            (1.2345678901234568e17, "1.2345678901234568E+17"), (123_456_789.125, "123456789.125"),
            (0.001, "0.001"), (0.0001, "0.0001"), (0.00025, "0.00025"), (0.00012345, "0.00012345"),
            (1.5e-5, "1.5E-05"), (1e-7, "1E-07"), (1.0 / 3, "0.3333333333333333"), (0.1 + 0.2, "0.30000000000000004"),
            (4.35, "4.35"), (.leastNonzeroMagnitude, "5E-324"), (.greatestFiniteMagnitude, "1.7976931348623157E+308"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(BoardFile.number(value), text, "\(value)")
        }
    }

    func testTextIsEscapedAsSystemTextJsonEscapesIt() {
        let cases: [(String, String)] = [
            ("plain", #""plain""#),
            ("it's", #""it\u0027s""#),
            ("say \"hi\"", #""say \u0022hi\u0022""#),
            ("a & b < c > d + e `f`", #""a \u0026 b \u003C c \u003E d \u002B e \u0060f\u0060""#),
            (#"back\slash /slash"#, #""back\\slash /slash""#),
            ("tab\tand\nnewline\r", #""tab\tand\nnewline\r""#),
            ("bs\u{8}ff\u{C}vt\u{B}nul\u{0}", #""bs\bff\fvt\u000Bnul\u0000""#),
            ("ctrl \u{1}\u{1F}\u{7F}\u{80}\u{9F}\u{A0}", #""ctrl \u0001\u001F\u007F\u0080\u009F\u00A0""#),
            ("caf\u{E9} \u{201C}curly\u{201D} \u{2019}", #""caf\u00E9 \u201Ccurly\u201D \u2019""#),
            ("emoji \u{1F389} hindi \u{939}\u{93F}", #""emoji \uD83C\uDF89 hindi \u0939\u093F""#),
            ("ls\u{2028}ps\u{2029} bom\u{FEFF} \u{FFFD}", #""ls\u2028ps\u2029 bom\uFEFF \uFFFD""#),
            (" !#$%()*,-./:;=?@[]^_{|}~", "\" !#$%()*,-./:;=?@[]^_{|}~\""),
        ]
        for (text, json) in cases {
            XCTAssertEqual(BoardFile.string(text), json, text)
        }
    }

    // ---- samples ----

    private static func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

    /// Written by BoardStore.cs on Windows: a note in every list; times with 7, 2, 1 and no decimals and in other
    /// offsets; a done note and a notified reminder; positions 0, -1, 0.5 and -2.25; text that needs escapes; and a
    /// note created at .NET's zero time (as when read from a file without a creation time).
    static let windowsSample = crlf(#"""
    {
      "version": 1,
      "items": [
        {
          "id": "98e441aa3d994d4680d606557aaf0790",
          "list": "Ideas",
          "text": "A voice game for kids",
          "created": "2026-11-11T14:30:12.3456789+05:30",
          "due": null,
          "done": false,
          "notified": false,
          "order": 0
        },
        {
          "id": "c0246730bc374988a46b48a00685da27",
          "list": "Todo",
          "text": "Renew passport",
          "created": "2026-11-11T14:33:12.12+05:30",
          "due": null,
          "done": true,
          "notified": false,
          "order": -1
        },
        {
          "id": "3898f14a9d2c409aa6dcce738a7525c8",
          "list": "Reminders",
          "text": "Call mom",
          "created": "2026-11-11T14:34:12+05:30",
          "due": "2026-11-12T17:00:00+05:30",
          "done": false,
          "notified": true,
          "order": -1
        },
        {
          "id": "7f793cf3ec4e4753bbc371148772e892",
          "list": "Brainstorm",
          "text": "\u201CPriya\u201D \u0022caf\u00E9\u0022 \u0026 \u003Cb\u003E \u0027s \\ \uD83C\uDF89 \u0939\u093F",
          "created": "2026-11-12T09:15:00.0000001+05:30",
          "due": "2027-03-15T09:00:00-07:00",
          "done": false,
          "notified": false,
          "order": 0.5
        },
        {
          "id": "d9d1a3805b744acab18a0bcb71aba632",
          "list": "Ideas",
          "text": "From an older file",
          "created": "0001-01-01T00:00:00+00:00",
          "due": null,
          "done": false,
          "notified": false,
          "order": -2.25
        }
      ]
    }
    """#)

    /// A file as older versions wrote it (no `notified` or `order`), with other forms the reader accepts.
    static let olderFile = #"""
    {
      "version": 1,
      "items": [
        {
          "id": "0f5c2b1e8d7a4c3b9a6e5d4c3b2a1f00",
          "list": "Todo",
          "text": "Renew passport",
          "created": "2026-11-10T03:30:00Z",
          "due": null,
          "done": false
        },
        {
          "id": "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6",
          "list": "todo",
          "text": "Buy milk",
          "created": "2026-11-11T09:00+05:30",
          "due": "2026-11-12T09:00:00.120+05:30",
          "done": false,
          "color": "blue"
        },
        {
          "id": "2b3c4d5e6f7a48b9c0d1e2f3a4b5c6d7",
          "list": 3,
          "text": "Pay rent",
          "created": "2026-11-09T18:45:10",
          "due": "2026-11-15T10:00:00.12345678901-08:00",
          "done": false,
          "notified": true
        }
      ]
    }
    """#

    /// `olderFile` after BoardStore.cs read it on a PC in India and saved it.
    static let olderRewritten = crlf(#"""
    {
      "version": 1,
      "items": [
        {
          "id": "0f5c2b1e8d7a4c3b9a6e5d4c3b2a1f00",
          "list": "Todo",
          "text": "Renew passport",
          "created": "2026-11-10T03:30:00+00:00",
          "due": null,
          "done": false,
          "notified": false,
          "order": 0
        },
        {
          "id": "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6",
          "list": "Todo",
          "text": "Buy milk",
          "created": "2026-11-11T09:00:00+05:30",
          "due": "2026-11-12T09:00:00.12+05:30",
          "done": false,
          "notified": false,
          "order": 0
        },
        {
          "id": "2b3c4d5e6f7a48b9c0d1e2f3a4b5c6d7",
          "list": "Reminders",
          "text": "Pay rent",
          "created": "2026-11-09T18:45:10+05:30",
          "due": "2026-11-15T10:00:00.1234567-08:00",
          "done": false,
          "notified": true,
          "order": 0
        }
      ]
    }
    """#)

    /// Written by BoardStore.cs after the steps in `testANewBoardIsWrittenAsWindowsWritesIt`, its ids replaced.
    static let freshFile = crlf(#"""
    {
      "version": 1,
      "items": [
        {
          "id": "{idea}",
          "list": "Brainstorm",
          "text": "A voice game for kids",
          "created": "2026-11-11T14:30:00+05:30",
          "due": null,
          "done": false,
          "notified": false,
          "order": 0
        },
        {
          "id": "{todo}",
          "list": "Todo",
          "text": "Renew passport",
          "created": "2026-11-11T14:31:30.5+05:30",
          "due": null,
          "done": true,
          "notified": false,
          "order": -1
        },
        {
          "id": "{reminder}",
          "list": "Reminders",
          "text": "Call mom",
          "created": "2026-11-11T14:31:30.5+05:30",
          "due": "2026-11-11T14:41:30.5+05:30",
          "done": false,
          "notified": false,
          "order": -1
        }
      ]
    }
    """#)
}
