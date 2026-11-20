import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// What the controller reported, in order (the C# tests' `_statuses`, filled by its `Status` event).
final class StatusLog {
    private(set) var all: [AssistantStatus] = []

    func add(_ status: AssistantStatus) { all.append(status) }

    /// The last status (`_statuses[^1]`).
    var last: AssistantStatus? { all.last }

    var messages: [String] { all.map(\.message) }
}

/// What a callback was given, in order.
final class Recorder<Value> {
    private(set) var all: [Value] = []

    func add(_ value: Value) { all.append(value) }
}

/// The C# tests' `new WindowRef(handle, processId, processName, title)`.
func windowRef(_ handle: Int, _ processId: Int, _ processName: String, _ title: String) -> WindowInfo {
    WindowInfo(handle: handle, processId: processId, processName: processName, title: title)
}

extension Array where Element == String {
    /// `Actions[^count..]`: the last `count` actions.
    func lastItems(_ count: Int) -> [String] { Array(suffix(count)) }
}

/// Cancels the task that calls it, as the C# tests cancel the token passed to the controller.
func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

/// A clock the test moves (the C# tests' `_now`, which the controller reads through `Clock = () => _now`).
final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// `new DateTime(year, month, day, hour, minute, second, DateTimeKind.Utc)`.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    return calendar.date(from: parts)!
}
