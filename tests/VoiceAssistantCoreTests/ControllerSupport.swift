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
