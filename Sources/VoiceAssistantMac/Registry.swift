import Foundation

/// The elements scans handed out, by the ids in their `UiElement`s and `BrowserTab`s (windows-voice-assistant
/// `WindowsDesktop.Navigation`'s `_registry`): "click 7" after "show numbers" finds element 7 again. Ids from old scans
/// are kept only long enough for that.
final class ElementRegistry: @unchecked Sendable {
    /// An element handed out: an Accessibility element, or a Safari tab (`MacDesktop.ScriptedTab`).
    final class Entry: @unchecked Sendable {
        let element: AnyObject

        /// It's part of a web page, which decides how it's named and clicked.
        let inPage: Bool

        init(_ element: AnyObject, inPage: Bool) {
            self.element = element
            self.inPage = inPage
        }
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var lastID = 0

    /// A new id for `element`. Past 6,000 entries, those 4,000 ids older than this one go.
    func register(_ element: AnyObject, inPage: Bool = false) -> Int {
        lock.withLock {
            lastID += 1
            let id = lastID
            entries[id] = Entry(element, inPage: inPage)
            if entries.count > 6000 {
                for stale in entries.keys.filter({ $0 < id - 4000 }) {
                    entries[stale] = nil
                }
            }

            return id
        }
    }

    func lookup(_ id: Int) -> Entry? {
        lock.withLock { entries[id] }
    }
}

/// A set of keys several threads share: the apps that didn't answer when asked to describe their pages, the browsers
/// whose Automation permission is being asked for.
final class KeySet: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    /// True when `key` wasn't in the set and now is.
    func insert(_ key: String) -> Bool {
        lock.withLock { keys.insert(key).inserted }
    }

    func remove(_ key: String) {
        lock.withLock { _ = keys.remove(key) }
    }
}

/// When a desktop asked each app to describe its pages (`MacDesktop.wake`), on the desktop's clock, by process and
/// bundle identifier; several threads share it.
final class WakeTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [String: TimeInterval] = [:]

    /// Keeps `time` for `key`; true when it had none, false when the app was asked already.
    func claim(_ key: String, at time: TimeInterval) -> Bool {
        lock.withLock {
            guard times[key] == nil else { return false }
            times[key] = time
            return true
        }
    }

    func remove(_ key: String) {
        lock.withLock { _ = times.removeValue(forKey: key) }
    }

    /// When the app was asked; nil when it wasn't.
    func time(_ key: String) -> TimeInterval? {
        lock.withLock { times[key] }
    }
}
