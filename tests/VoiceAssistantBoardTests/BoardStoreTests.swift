import XCTest
@testable import VoiceAssistantBoard

/// The store's behaviour that BoardTests.cs doesn't show: its lock and a failed save, as BoardStore.cs has them.
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
}
