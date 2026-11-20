import XCTest
@testable import VoiceAssistantBoard

/// The store's behaviour that BoardTests.cs doesn't show: its lock, a failed save and the capital letter, as
/// BoardStore.cs has them.
final class BoardStoreTests: XCTestCase {
    func testWhatRunsUnderTheLockMayReadTheBoard() throws {
        // C#'s lock is re-entrant, so the clock, which runs under it, may read the board.
        final class Holder: @unchecked Sendable {
            var store: BoardStore?
        }

        let holder = Holder()
        let now = moment(2026, 11, 11, 14, 30)
        holder.store = try BoardStore(path: nil, clock: {
            _ = holder.store?.items
            return now
        })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? holder.store?.add(.ideas, "x")
            done.signal()
        }

        guard done.wait(timeout: .now() + 10) == .success else { return XCTFail("The store's lock isn't re-entrant") }
        XCTAssertEqual(holder.store?.items.map(\.text), ["X"])
        holder.store = nil
    }

    func testAFailedSaveThrowsKeepsTheChangeAndTellsNoOne() throws {
        // /dev/null isn't a folder, so the file can't be written.
        let store = try BoardStore(path: "/dev/null/board.json")
        var changes = 0
        store.onChange { changes += 1 }
        XCTAssertThrowsError(try store.add(.ideas, "x"))
        XCTAssertEqual(store.items.map(\.text), ["X"])
        XCTAssertEqual(changes, 0)
    }

    func testTidyCapitalisesAsCSharpDoes() {
        // char.ToUpperInvariant on the first letter: "ı" keeps its case, a Greek letter with ypogegrammeni becomes its
        // title case ("ᾳ" → "ᾼ"), and "ß" and "ﬁ", which have no one-letter capital, stay.
        func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }
        let cases = [
            ("\u{131}dea", "\u{131}dea"),
            ("\u{1FB3} note", "\u{1FBC} note"),
            ("\u{1F80} note", "\u{1F88} note"),
            ("\u{DF}ig", "\u{DF}ig"),
            ("\u{FB01}x it", "\u{FB01}x it"),
            ("\u{1C6}ungla", "\u{1C4}ungla"),
        ]
        for (text, tidied) in cases {
            XCTAssertEqual(scalars(BoardStore.tidy(text)), scalars(tidied), text)
        }
    }
}
