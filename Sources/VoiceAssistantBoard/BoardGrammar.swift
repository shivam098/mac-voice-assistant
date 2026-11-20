import Foundation

public enum BoardAction: Sendable {
    case add
    case show
    case complete
}

/// A spoken board request: add `text` to `list` (with `due` for reminders), show `list`, or tick off `text`.
public struct BoardIntent: Hashable, Sendable {
    public var action: BoardAction
    public var list: BoardList?
    public var text: String
    public var due: Date?

    public init(action: BoardAction, list: BoardList?, text: String = "", due: Date? = nil) {
        self.action = action
        self.list = list
        self.text = text
        self.due = due
    }
}

/// The board's voice grammar (windows-voice-assistant docs/specs/idea-board.md). Works on the transcript as spoken
/// (capitals and punctuation kept for the note). `explicitOnly` is for push-to-talk dictation, where everything else
/// is typed: only requests that name a list ("add to my ideas …", "add … to my to-do list") go to the board; "remind
/// me to …", "note down …" and the rest need the wake word, because people also dictate such sentences to others.
///
/// `now` is a moment and `timeZone` its wall clock (C#'s `now` is a DateTimeOffset, which carries its own offset).
public enum BoardGrammar {
    public static func parse(
        _ spoken: String, now: Date, explicitOnly: Bool = false, timeZone: TimeZone = .autoupdatingCurrent
    ) -> BoardIntent? {
        let text = DotNet.replace(DotNet.trim(spoken), "\u{2019}", with: "'")

        // "Can you add the slides to our tasks" with push-to-talk dictation is a request to a colleague, typed as
        // dictation.
        if explicitOnly && askingSomeone.isMatch(text) {
            return nil
        }

        // Push-to-talk dictation types everything else, so a sentence for someone else ("put the agenda on the
        // board", "add these to the tasks") must stay dictation: there the list needs "my"/"our" or a name only the
        // board uses.
        if let m = addToListFirst.match(text) ?? addToListLast.match(text), let name = m["list"],
           let named = listFrom(name), !explicitOnly || m["det"] != nil || boardOnlyName(name) {
            return addIntent(named, m["text"] ?? "", now: now, timeZone: timeZone)
        }

        if explicitOnly {
            return nil
        }

        if let m = remind.match(text) {
            return addIntent(.reminders, m["text"] ?? "", now: now, timeZone: timeZone)
        }

        if let m = note.match(text) {
            return addIntent(.ideas, m["text"] ?? "", now: now, timeZone: timeZone)
        }

        if let m = show.match(text), let name = m["list"], let shown = listFrom(name),
           m["det"] != nil || namesTheBoard(name) {
            // "show my board" is the whole board; a list name opens that list.
            return BoardIntent(action: .show, list: isWholeBoard(name) ? nil : shown)
        }

        if showBoard.isMatch(text) {
            return BoardIntent(action: .show, list: nil)
        }

        if let m = complete.match(text) {
            let what = DotNet.trim(m["text1"] ?? m["text2"] ?? m["text3"] ?? "", [" ", ".", ","])
            return what.isEmpty ? nil : BoardIntent(action: .complete, list: nil, text: what)
        }

        return nil
    }

    /// Where dictation goes when there's no text box to type it into, or nil if there's nothing to keep. A request
    /// that names a list or says "remind me" / "note down" is honoured. Otherwise only text that is clearly a task is
    /// filed as one: "I have to / need to / should …", "don't forget to …", "to-do: …", or an instruction starting
    /// with a common action verb ("call the bank …"). A task with a future time is a reminder; without one, a to-do.
    /// Everything else, including sentences that just mention a time ("the demo today went well"), is an idea, kept
    /// word for word.
    public static func forDictation(
        _ text: String, now: Date, timeZone: TimeZone = .autoupdatingCurrent
    ) -> BoardIntent? {
        let text = DotNet.replace(DotNet.trim(text), "\u{2019}", with: "'")
        if BoardStore.tidy(text).isEmpty {
            return nil
        }

        if let asked = parse(text, now: now, timeZone: timeZone), asked.action == .add {
            return asked
        }

        let lead = todo.match(text)
        guard let task = lead.map({ $0["text"] ?? "" }) ?? (action.isMatch(text) ? text : nil),
              !BoardStore.tidy(task).isEmpty
        else { return BoardIntent(action: .add, list: .ideas, text: BoardStore.tidy(text)) }

        let timed = ReminderTime.parse(task, now: now, timeZone: timeZone)
        if let due = timed.due, due > now, !BoardStore.tidy(timed.task).isEmpty {
            return BoardIntent(action: .add, list: .reminders, text: BoardStore.tidy(timed.task), due: due)
        }

        return BoardIntent(action: .add, list: .todo, text: BoardStore.tidy(task))
    }

    /// The open item whose words best cover what was said (the newest on a tie); nil below 60 %.
    public static func bestMatch(_ items: some Sequence<BoardItem>, _ spoken: String) -> BoardItem? {
        let said = words(spoken)
        if said.isEmpty {
            return nil
        }

        var best: (item: BoardItem, score: Double)?
        for item in items {
            let own = words(item.text)
            let score = Double(said.filter { own.contains($0) }.count) / Double(said.count)
            guard score >= 0.6 else { continue }
            // As LINQ's OrderByDescending(score).ThenByDescending(created): the first of equals wins.
            if let leader = best,
               leader.score > score || (leader.score == score && leader.item.created >= item.created) {
                continue
            }

            best = (item, score)
        }

        return best?.item
    }

    public static func listFrom(_ spoken: String) -> BoardList? {
        let s = DotNet.lowerInvariant(spoken)
        if DotNet.contains(s, "brainstorm") {
            return .brainstorm
        } else if DotNet.contains(s, "remind") {
            return .reminders
        } else if DotNet.contains(s, "do") || DotNet.contains(s, "task") {
            return .todo
        } else if DotNet.contains(s, "idea") || DotNet.contains(s, "board") || DotNet.contains(s, "note") {
            return .ideas
        }

        return nil
    }

    private static func isWholeBoard(_ list: String) -> Bool {
        let s = DotNet.lowerInvariant(DotNet.trim(list))
        return DotNet.ordinalEquals(s, "board") || DotNet.ordinalEquals(s, "idea board")
            || DotNet.startsWith(s, "idea board")
    }

    private static func boardOnlyName(_ list: String) -> Bool {
        DotNet.containsOrdinalIgnoreCase(list, "idea") || DotNet.containsOrdinalIgnoreCase(list, "brain")
            || DotNet.containsOrdinalIgnoreCase(list, "remind")
    }

    // "open notes" / "open tasks" / "open to do" may be an app; "open my notes" or "open ideas" is the board.
    private static func namesTheBoard(_ list: String) -> Bool {
        boardOnlyName(list) || DotNet.containsOrdinalIgnoreCase(list, "list")
    }

    private static func addIntent(_ list: BoardList, _ text: String, now: Date, timeZone: TimeZone) -> BoardIntent? {
        var text = text
        var due: Date?
        if list == .reminders {
            let timed = ReminderTime.parse(text, now: now, timeZone: timeZone)
            text = timed.task
            due = timed.due
        }

        text = BoardStore.tidy(leadingLink.replace(text) { _ in "" })
        return text.isEmpty ? nil : BoardIntent(action: .add, list: list, text: text, due: due)
    }

    private static let stopWords: Set<String> = ["the", "my", "to", "a", "an", "and"]

    private static func words(_ text: String) -> Set<String> {
        Set(word.matches(DotNet.lowerInvariant(text)).filter { $0.utf16.count > 1 && !stopWords.contains($0) })
    }

    // MARK: Patterns: BoardGrammar.cs's, with \b, . and repeated group names spelled out for ICU (see DotNetRegex)

    private static let wordEnd = DotNetRegex.wordEnd

    private static let list: String =
        #"(?<list>idea\s+board|ideas?(?:\s+list)?|board|brain\s?storm(?:ing)?(?:\s+(?:list|board|ideas))?"#
        + #"|to[\s\-]?do(?:\s+list)?|to[\s\-]?dos|todos?|task\s+list|tasks|reminders?(?:\s+list)?|notes?)"#

    // Recognisers often start a phrase with a joining or filler word ("and add to my reminders …", "um, can you …").
    private static let lead: String =
        #"^(?:(?:please|okay|ok|so|and|also|now|then|um|uh|oh|hey|alright|right)[\s,.]+"#
        + #"|(?:can|could|would|will)\s+you(?:\s+please)?[\s,]+)*"#

    private static let separator = #"[\s,:;.\-–—]+"#

    private static let todo = DotNetRegex(
        lead + #"(?:(?:i|we)(?:\s+(?:have\s+to|need\s+to|must|should|ought\s+to|gotta|got\s+to|have\s+got\s+to)"#
            + #"|'ve\s+got\s+to|'ll\s+have\s+to)|(?:don't|do\s+not)\s+forget(?:\s+to)?|remember\s+to"#
            + #"|to[\s\-]?do\s*[,:;.\-–—])\s*(?<text>[^\n]+)$"#,
        ignoreCase: true)

    // An instruction to yourself: starts with a common action verb ("call the bank", "buy milk", "email Priya").
    private static let action = DotNetRegex(
        lead + #"(?:call|phone|ring|email|e-mail|mail|text|message|ping|reply|respond|send|pay|buy|order|book"#
            + #"|schedule|reschedule|cancel|renew|submit|file|review|check|finish|complete|fix|update|prepare|draft"#
            + #"|write|read|clean|wash|water|pick\s+up|drop\s+off|collect|return|visit|meet|ask|tell|follow\s+up"#
            + #"|confirm|sign|print|backup|back\s+up|charge|recharge|register|apply|transfer|deposit|withdraw)"#
            + wordEnd,
        ignoreCase: true)

    private static let askingSomeone = DotNetRegex(
        #"^(?:(?:please|okay|ok|so|and|also|now|then|um|uh|oh|hey|alright|right)[\s,.]+)*"#
            + #"(?:can|could|would|will)\s+you"# + wordEnd,
        ignoreCase: true)

    // "add to my ideas: a voice game", "put this on my to-do list, renew passport"
    private static let addToListFirst = DotNetRegex(
        lead + #"(?:add|put|save|write|note|jot)(?:\s+(?:this|it|that))?(?:\s+down)?"#
            + #"\s+(?:to|in|into|on|onto|under)\s+(?:(?<det>my|our)\s+|the\s+)?"# + list
            + separator + #"(?<text>[^\n]+)$"#,
        ignoreCase: true)

    // "add renew passport to my to-do list"
    private static let addToListLast = DotNetRegex(
        lead + #"(?:add|put|save|write)\s+(?<text>[^\n]+?)\s+(?:to|in|into|on|onto|under)\s+"#
            + #"(?:(?<det>my|our)\s+|the\s+)?"# + list + #"[\s.!]*$"#,
        ignoreCase: true)

    private static let remind = DotNetRegex(
        lead + #"(?:remind\s+me|set\s+(?:a\s+)?reminder|add\s+(?:a\s+)?reminder|create\s+(?:a\s+)?reminder)"#
            + #"(?:\s+(?:to|about|that|for|of))?"# + separator + #"(?<text>[^\n]+)$"#,
        ignoreCase: true)

    private static let note = DotNetRegex(
        lead + #"(?:note\s+down|jot\s+down|make\s+a\s+note|take\s+a\s+note|new\s+idea|i\s+have\s+an\s+idea)"#
            + #"(?:\s+(?:that|this|of))?"# + separator + #"(?<text>[^\n]+)$"#,
        ignoreCase: true)

    private static let show = DotNetRegex(
        lead + #"(?:show|open|display|go\s+to)(?:\s+me)?\s+(?<det>my\s+|the\s+)?"# + list + #"[\s.!]*$"#,
        ignoreCase: true)

    private static let showBoard = DotNetRegex(
        lead + #"(?:show|open)(?:\s+me)?\s+(?:my\s+|the\s+)?(?:idea\s+)?board[\s.!]*$"#, ignoreCase: true)

    // Needs "done" after "mark", or "off" with tick/check/cross: a bare "tick the checkbox" or "complete the form" is
    // a command for the app on screen, not the board.
    private static let complete = DotNetRegex(
        lead + #"(?:mark\s+(?<text1>[^\n]+?)\s+(?:as\s+)?(?:done|complete|completed|finished)"#
            + #"|(?:tick|check|cross)\s+off\s+(?<text2>[^\n]+?)"#
            + #"|(?:tick|check|cross)\s+(?<text3>[^\n]+?)\s+off)[\s.!]*$"#,
        ignoreCase: true)

    private static let leadingLink = DotNetRegex(#"^\s*(?:to|that|about|for)\s+"#, ignoreCase: true)

    private static let word = DotNetRegex(#"[\p{L}\p{N}]+"#)
}
