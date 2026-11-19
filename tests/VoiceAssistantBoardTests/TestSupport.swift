import Foundation
import VoiceAssistantBoard

/// +05:30, the offset of the C# tests' `Now`.
let india = TimeZone(secondsFromGMT: 19_800)!

/// A fixed offset from UTC, as C#'s `TimeSpan.FromHours(hours)` in a DateTimeOffset.
func offset(hours: Int) -> TimeZone { TimeZone(secondsFromGMT: hours * 3600)! }

/// A moment on `zone`'s wall clock, made with Foundation's calendar: a check on the board's own date arithmetic.
func moment(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0, in zone: TimeZone = india
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    return calendar.date(from: components)!
}

/// A board file's path in the temporary folder, as the C# tests use Path.GetTempPath().
func temporaryBoardPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("board-\(BoardItem.newId()).json").path
}

/// The names of the copies kept of an unreadable board file.
func unreadableCopies(of path: String) -> [String] {
    let file = URL(fileURLWithPath: path)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []
    return names.filter { $0.hasPrefix(file.lastPathComponent + ".unreadable-") }
}

/// Deletes a board file and the files named after it.
func removeBoardFiles(_ path: String) {
    let file = URL(fileURLWithPath: path)
    let folder = file.deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasPrefix(file.lastPathComponent) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}

/// The text of a file.
func fileText(_ path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return String(decoding: data, as: UTF8.self)
}

/// Writes `text` to a file as UTF-8.
func writeFile(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}
