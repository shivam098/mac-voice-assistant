import Foundation
import XCTest
@testable import VoiceAssistantApp

/// Blocking speech work, as Whisper.net runs it: a cancelled wait returns at once while the work runs on.
final class ConcurrencyTests: XCTestCase {
    func testACancelledWaitReturnsAtOnceWhileTheWorkRunsOn() async throws {
        let finished = Locked(false)
        let started = Date()
        let waiting = Task {
            try await Blocking.run {
                Thread.sleep(forTimeInterval: 0.5)
                finished.value = true
                return 1
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("The wait wasn't cancelled")
        } catch is CancellationError {
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
        XCTAssertFalse(finished.value)
        let ranOn = await eventually { finished.value }
        XCTAssertTrue(ranOn)
    }

    func testWorkThatMustFinishIsWaitedForEvenWhenCancelled() async throws {
        let waiting = Task {
            try await Blocking.run(cancellable: false) {
                Thread.sleep(forTimeInterval: 0.2)
                return "done"
            }
        }

        waiting.cancel()
        let result = try await waiting.value
        XCTAssertEqual(result, "done")
    }

    func testAFinishedTaskIsToldFromOneStillRunning() async {
        let quick = Task<Void, Never> {}
        let slow = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }

        let quickDone = await Blocking.finished(quick, within: 1)
        let slowDone = await Blocking.finished(slow, within: 0.1)
        XCTAssertTrue(quickDone)
        XCTAssertFalse(slowDone)
        slow.cancel()
    }
}
