import Foundation

/// The board's lists, in the order they're shown. The raw values are the names board.json uses.
public enum BoardList: String, CaseIterable, Sendable {
    case ideas = "Ideas"
    case brainstorm = "Brainstorm"
    case todo = "Todo"
    case reminders = "Reminders"

    /// The list with C#'s enum value `number` (Ideas = 0 … Reminders = 3).
    init?(number: Int) {
        guard Self.allCases.indices.contains(number) else { return nil }
        self = Self.allCases[number]
    }
}

/// One note on the board. `due` is set for reminders.
public struct BoardItem: Hashable, Sendable {
    public var id: String
    public var list: BoardList
    public var text: String
    public var created: Date
    public var due: Date?
    public var done: Bool

    /// The reminder popup was shown (so it isn't shown again after a restart).
    public var notified: Bool

    /// Position among the open notes of its list, lowest first (set by dragging; new notes go on top).
    public var order: Double

    /// The defaults are C#'s: a new id, Ideas, no text, created at .NET's zero time, no due time, open, at 0.
    public init(
        id: String = BoardItem.newId(),
        list: BoardList = .ideas,
        text: String = "",
        created: Date = BoardItem.zeroTime,
        due: Date? = nil,
        done: Bool = false,
        notified: Bool = false,
        order: Double = 0
    ) {
        self.id = id
        self.list = list
        self.text = text
        self.created = created
        self.due = due
        self.done = done
        self.notified = notified
        self.order = order
    }

    /// A new id: 32 lower-case hex digits, as C#'s `Guid.NewGuid().ToString("N")`.
    public static func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// .NET's `default(DateTimeOffset)`, 0001-01-01T00:00:00Z: the creation time of a note read without one.
    public static let zeroTime = Date(timeIntervalSinceReferenceDate: -63_113_904_000)
}

/// Everything the board can do, for voice commands and the UI alike (C#'s `IBoard`).
public protocol Board: AnyObject {
    var items: [BoardItem] { get }

    @discardableResult
    func add(_ list: BoardList, _ text: String, due: Date?) throws -> BoardItem

    /// Marks the best-matching open item done. Nil if nothing matches well enough.
    @discardableResult
    func completeMatching(_ spoken: String, list: BoardList?) throws -> BoardItem?
}

extension Board {
    @discardableResult
    public func add(_ list: BoardList, _ text: String) throws -> BoardItem { try add(list, text, due: nil) }

    @discardableResult
    public func completeMatching(_ spoken: String) throws -> BoardItem? { try completeMatching(spoken, list: nil) }
}

/// The board, kept in memory and saved as JSON after every change (written to a temporary file, then swapped in, so a
/// crash never leaves a half-written file). Thread-safe; change handlers run outside the lock. Saving can fail (a full
/// disk, no permission): then the change stays in memory, the handlers aren't called and the error is thrown, as in C#.
public final class BoardStore: Board, @unchecked Sendable {
    private let lock = NSLock()
    private let path: String?
    private let clock: () -> Date
    private let timeZone: TimeZone
    private var stored: [BoardItem] = []
    private var stamps: [String: BoardFile.Stamps] = [:]
    private var handlers: [() -> Void] = []

    /// - Parameters:
    ///   - path: The JSON file; nil keeps the board in memory only (tests).
    ///   - clock: Now; the system clock by default.
    ///   - timeZone: The zone whose offset new times are written with, as C# writes the PC's local offset, and in which
    ///     a time written without an offset is read. It also names an unreadable file's copy.
    /// - Throws: When the file exists but can't be read, or an unreadable one can't be copied aside.
    public init(path: String?, clock: (() -> Date)? = nil, timeZone: TimeZone = .autoupdatingCurrent) throws {
        self.path = path
        self.clock = clock ?? { Date() }
        self.timeZone = timeZone
        var isDirectory: ObjCBool = false
        guard let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            let file = try BoardFile.read(data, localZone: timeZone)
            stored = file.items
            stamps = file.stamps
        } catch {
            // Keep the unreadable file for the user, start a fresh board next to it.
            let copy = BoardFile.unreadableName(path, at: self.clock(), in: timeZone)
            if FileManager.default.fileExists(atPath: copy) {
                try FileManager.default.removeItem(atPath: copy)
            }

            try FileManager.default.copyItem(atPath: path, toPath: copy)
        }
    }

    /// Calls `handler` after every change, on the thread that made it and outside the lock (C#'s `Changed` event).
    public func onChange(_ handler: @escaping () -> Void) {
        locked { handlers.append(handler) }
    }

    public var items: [BoardItem] { locked { stored } }

    @discardableResult
    public func add(_ list: BoardList, _ text: String, due: Date?) throws -> BoardItem {
        var added: BoardItem?
        try mutate { items in
            // On top of the list, above anything placed by hand.
            let top = items.filter { $0.list == list && !$0.done }.map(\.order).min() ?? 0
            let item = BoardItem(list: list, text: Self.tidy(text), created: clock(), due: due, order: top - 1)
            items.append(item)
            added = item
        }

        return added!
    }

    /// Puts a note in a list at a position among that list's open notes (0 = top), as when it is dragged there. A done
    /// note just changes list (done notes are shown newest first).
    public func place(_ id: String, in list: BoardList, at index: Int) throws {
        try mutate { items in
            guard let at = items.firstIndex(where: { $0.id == id }) else { return }
            items[at].list = list
            let item = items[at]
            if item.done {
                return
            }

            var open = Self.arrange(items.filter { $0.list == list && !$0.done && $0.id != id }, list)
            open.insert(item, at: min(max(index, 0), open.count))
            for (position, note) in open.enumerated() {
                if let j = items.firstIndex(where: { $0.id == note.id }) {
                    items[j].order = Double(position)
                }
            }
        }
    }

    /// The order a list's open notes are shown in: by position (newest first among equals); reminders by due time
    /// first (those without one last).
    public static func arrange(_ open: some Sequence<BoardItem>, _ list: BoardList) -> [BoardItem] {
        // A stable sort, as LINQ's OrderBy: notes that tie keep their order.
        Array(open.enumerated()).sorted { a, b in
            let x = a.element, y = b.element
            if list == .reminders && x.due != y.due {
                guard let xDue = x.due else { return false }
                guard let yDue = y.due else { return true }
                return xDue < yDue
            }

            if x.order != y.order {
                return x.order < y.order
            }

            if x.created != y.created {
                return x.created > y.created
            }

            return a.offset < b.offset
        }.map { $0.element }
    }

    /// Replaces the note that has `item`'s id (with its text tidied).
    public func update(_ item: BoardItem) throws {
        try mutate { items in
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
                items[index].text = Self.tidy(item.text)
            }
        }
    }

    public func remove(_ id: String) throws {
        try mutate { items in items.removeAll { $0.id == id } }
    }

    public func setDone(_ id: String, _ done: Bool) throws {
        try change(id) { $0.done = done }
    }

    /// Changes only the text, so an edit can't undo a tick, move or snooze made while it was open.
    public func setText(_ id: String, _ text: String) throws {
        try change(id) { $0.text = Self.tidy(text) }
    }

    /// Moves a note to the top of another list.
    public func move(_ id: String, to list: BoardList) throws {
        try place(id, in: list, at: 0)
    }

    public func markNotified(_ id: String) throws {
        try change(id) { $0.notified = true }
    }

    /// Moves a reminder's due time (snooze) and lets it notify again.
    public func snooze(_ id: String, by interval: TimeInterval) throws {
        try change(id) { item in
            item.due = clock().addingTimeInterval(interval)
            item.notified = false
        }
    }

    /// Reminders whose time has come and that haven't been shown.
    public func dueReminders() -> [BoardItem] {
        items.filter { item in
            guard let due = item.due else { return false }
            return due <= clock() && !item.done && !item.notified
        }
    }

    @discardableResult
    public func completeMatching(_ spoken: String, list: BoardList?) throws -> BoardItem? {
        let match = BoardGrammar.bestMatch(items.filter { !$0.done && (list == nil || $0.list == list) }, spoken)
        if let match {
            try setDone(match.id, true)
        }

        return match
    }

    private static let tidySpaces: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]

    /// Notes are short: no stray spaces, a capital first letter, no full stop at the end.
    public static func tidy(_ text: String) -> String {
        let words = text.unicodeScalars.split(whereSeparator: { tidySpaces.contains($0) })
        var tidied = DotNet.trim(words.map { String(String.UnicodeScalarView($0)) }.joined(separator: " "))
        tidied = DotNet.trim(DotNet.trimEnd(tidied, [".", ",", ";", ":"]))
        // C# capitalises the first UTF-16 code unit, so a letter beyond U+FFFF (a surrogate pair) stays as it is.
        guard let first = tidied.unicodeScalars.first, first.value <= 0xFFFF else { return tidied }
        var scalars = String.UnicodeScalarView()
        scalars.append(DotNet.upperInvariant(first))
        scalars.append(contentsOf: tidied.unicodeScalars.dropFirst())
        return String(scalars)
    }

    private func change(_ id: String, _ edit: (inout BoardItem) -> Void) throws {
        try mutate { items in
            if let index = items.firstIndex(where: { $0.id == id }) {
                edit(&items[index])
            }
        }
    }

    /// Changes the notes and saves them, under the lock; then tells the handlers.
    private func mutate(_ change: (inout [BoardItem]) -> Void) throws {
        let notify = try locked { () throws -> [() -> Void] in
            change(&stored)
            try save()
            return handlers
        }

        for handler in notify {
            handler()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func save() throws {
        guard let path else { return }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = path + ".tmp"
        let json = BoardFile.write(stored, stamps: stamps, zone: timeZone)
        try Data(json.utf8).write(to: URL(fileURLWithPath: temp))
        guard rename(temp, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
