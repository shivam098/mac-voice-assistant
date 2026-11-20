import ThumbFreeCore

/// What the assistant has learned from the user, kept on the device:
/// - Rephrasings: a phrase it didn't understand, followed shortly by a command it did, becomes a synonym for that
///   command, but only when both share a meaningful word (such as the app's name), so unrelated chatter before a
///   command is never learned.
/// - How often each app is opened, to prefer the apps the user actually opens when a name is ambiguous.
///
/// Not thread-safe: the controller uses it from its serial queue.
public final class PhraseMemory {
    public static let maxPhrases = 300

    // Words that don't say *what* the user wants (verbs, articles, padding).
    private static let nonDistinctive = OrdinalSet([
        "a", "an", "the", "to", "it", "me", "my", "i", "you", "can", "could", "would", "will", "please", "for", "up",
        "open", "launch", "start", "run", "go", "switch", "get", "give", "show", "bring", "pull", "fire", "let", "lets",
        "on", "in", "into", "and", "now", "just", "want", "need", "like", "this", "that", "some", "new", "app",
        "window", "hey", "jarvis", "ok", "okay", "do", "make", "with", "of", "is", "be", "of", "what", "how",
    ])

    private var commands: [[Unicode.Scalar]: String] = [:]

    /// The phrases, oldest first.
    private var order: [String] = []

    /// How often each app was opened, by name in any case (`StringComparer.OrdinalIgnoreCase`), with the name as it
    /// was first recorded, in that order.
    private var uses: [[Unicode.Scalar]: Int] = [:]
    private var appNames: [String] = []

    public init() {}

    public var phraseCount: Int { commands.count }

    /// The command a phrase was learned as (C#'s `TryGet`).
    public func command(for phrase: String) -> String? { commands[DotNet.ordinal(phrase)] }

    /// Remembers `phrase` as meaning `command`. False if it isn't a safe pairing.
    @discardableResult
    public func learn(_ phrase: String, _ command: String) -> Bool {
        let phrase = DotNet.trim(phrase)
        let command = DotNet.trim(command)
        if phrase.isEmpty || command.isEmpty || DotNet.ordinalEquals(phrase, command)
            || !Self.sharesDistinctiveWord(phrase, command) {
            return false
        }

        store(phrase, command)
        return true
    }

    @discardableResult
    public func forget(_ phrase: String) -> Bool {
        if let index = order.firstIndex(where: { DotNet.ordinalEquals($0, phrase) }) {
            order.remove(at: index)
        }

        return commands.removeValue(forKey: DotNet.ordinal(phrase)) != nil
    }

    public func recordAppUse(_ appName: String) {
        let key = DotNet.ordinalIgnoreCase(appName)
        if uses[key] == nil {
            appNames.append(appName)
        }

        uses[key, default: 0] += 1
    }

    public func usesOf(_ appName: String) -> Int { uses[DotNet.ordinalIgnoreCase(appName)] ?? 0 }

    /// How often each app was opened, for saving: the names as first recorded, in that order.
    public var appUses: [(app: String, uses: Int)] { appNames.map { ($0, usesOf($0)) } }

    public func clear() {
        commands.removeAll()
        order.removeAll()
        uses.removeAll()
        appNames.removeAll()
    }

    /// Loads phrases (oldest first) and how often each app was opened.
    public func load(_ phrases: [(phrase: String, command: String)]?, _ appUses: [(app: String, uses: Int)]?) {
        clear()
        for (phrase, command) in phrases ?? [] where !phrase.isEmpty && !command.isEmpty {
            store(phrase, command)
        }

        for (app, count) in appUses ?? [] {
            let key = DotNet.ordinalIgnoreCase(app)
            if uses[key] == nil {
                appNames.append(app)
            }

            uses[key] = max(0, count)
        }
    }

    /// The phrases, oldest first, for saving.
    public func phrasesInOrder() -> [(phrase: String, command: String)] {
        order.map { ($0, commands[DotNet.ordinal($0)] ?? "") }
    }

    private func store(_ phrase: String, _ command: String) {
        let key = DotNet.ordinal(phrase)
        if commands[key] != nil {
            if let index = order.firstIndex(where: { DotNet.ordinalEquals($0, phrase) }) {
                order.remove(at: index)
            }
        } else if commands.count >= Self.maxPhrases, let oldest = order.first {
            commands[DotNet.ordinal(oldest)] = nil
            order.removeFirst()
        }

        commands[key] = command
        order.append(phrase)
    }

    public static func sharesDistinctiveWord(_ a: String, _ b: String) -> Bool {
        let words = Set(distinctive(b).map(DotNet.ordinal))
        return distinctive(a).contains { words.contains(DotNet.ordinal($0)) }
    }

    private static func distinctive(_ text: String) -> [String] {
        NetText.words(text).filter { $0.utf16.count > 1 && !nonDistinctive.contains($0) }
    }
}
