import XCTest
@testable import VoiceAssistantApp

/// One Voice Assistant at a time (App.xaml.cs's mutex).
final class SingleInstanceTests: XCTestCase {
    func testOnlyOneCopyHoldsTheLockUntilItLetsGo() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let first = SingleInstance(path: folder.file("instance.lock"))
        let second = SingleInstance(path: folder.file("instance.lock"))

        XCTAssertTrue(try first.acquire(waiting: 0))
        XCTAssertTrue(try first.acquire(waiting: 0))
        XCTAssertFalse(try second.acquire(waiting: 0.2))

        first.release()
        XCTAssertTrue(try second.acquire(waiting: 0))
        second.release()
    }
}
