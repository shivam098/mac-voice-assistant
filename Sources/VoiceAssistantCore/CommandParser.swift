import Foundation
import ThumbFreeCore
import VoiceAssistantBoard

public enum InteractionMode: Sendable {
    case paused

    /// Listening only for the wake word ("Hey Jarvis"). Other speech is ignored silently.
    case standby

    /// Awake: commands work without the wake word until a short timeout.
    case command

    case dictation
}

public enum CommandKind: Sendable {
    /// Open the app; for apps with a new-window shortcut, a fresh window.
    case openApp

    /// Bring an existing window of the app to the front (launch it if it isn't running).
    case switchToApp

    case startTyping
    case send
    case scratchThat
    case clearBox
    case newLine
    case newParagraph
    case stopTyping
    case pauseListening

    /// Focus the window's search box (in browsers, the address bar) and start typing there.
    case focusSearch

    case focusAddressBar

    /// Focus search, type the argument, press Enter.
    case searchFor

    /// Press the chord in the argument ("Ctrl+T", or a `ShortcutKeys`'s keys).
    case pressKeys

    /// Select a browser tab by position or name (`VoiceCommand.target`).
    case selectTab

    /// Click an element in the front window by name, with optional region and ordinal hints.
    case click

    /// Focus a text box by name ("message box") and start typing there.
    case focusField

    /// Show numbers on everything clickable in the front window.
    case showNumbers

    case hideNumbers

    /// Pick numbered choice `VoiceCommand.argument`.
    case choose

    /// "yes": do the action waiting for confirmation.
    case confirm

    /// "no", "cancel": drop pending choices and confirmations.
    case cancel

    /// "delete the last 3 words", "delete the word very" (`VoiceCommand.edit`).
    case deleteText

    /// "replace Monday with Tuesday" (`VoiceCommand.edit`).
    case replaceText

    /// The idea board: add a note or reminder, show a list, tick an item off (`VoiceCommand.board`).
    case board

    /// "open Instagram in a new tab", "open a new tab and go to github.com": that page in a new tab (`argument` is the
    /// name, or the web address as said), never a tab called "instagram in new".
    case openInNewTab

    /// "open Notepad in a new window": a new window of the app, else the page as for `openInNewTab`.
    case openInNewWindow
}

public struct VoiceCommand: Hashable, Sendable {
    public var kind: CommandKind
    public var argument: String?

    /// For `selectTab`, `click` and `focusField`.
    public var target: ElementTarget?

    /// For `deleteText` and `replaceText`.
    public var edit: TextEdit?

    /// For `board`.
    public var board: BoardIntent?

    public init(
        _ kind: CommandKind,
        _ argument: String? = nil,
        target: ElementTarget? = nil,
        edit: TextEdit? = nil,
        board: BoardIntent? = nil
    ) {
        self.kind = kind
        self.argument = argument
        self.target = target
        self.edit = edit
        self.board = board
    }
}

public struct ParsedUtterance: Hashable, Sendable {
    public static let empty = ParsedUtterance()

    public var commands: [VoiceCommand]

    public var dictationText: String?

    /// The simplified text that looked like a command but matched nothing.
    public var unrecognized: String?

    /// The simplified phrase that matched (to learn rephrasings).
    public var commandText: String?

    /// What was said after the wake word or prefix, as transcribed (capitals and punctuation kept), for the AI brain.
    public var spoken: String?

    /// The command came from a phrase the user taught earlier.
    public var fromLearnedPhrase: Bool

    /// The utterance started with the wake word.
    public var wokeUp: Bool

    /// A full command said with the wake word while typing: typing stops before it runs.
    public var leavesTyping: Bool

    public init(
        commands: [VoiceCommand] = [],
        dictationText: String? = nil,
        unrecognized: String? = nil,
        commandText: String? = nil,
        spoken: String? = nil,
        fromLearnedPhrase: Bool = false,
        wokeUp: Bool = false,
        leavesTyping: Bool = false
    ) {
        self.commands = commands
        self.dictationText = dictationText
        self.unrecognized = unrecognized
        self.commandText = commandText
        self.spoken = spoken
        self.fromLearnedPhrase = fromLearnedPhrase
        self.wokeUp = wokeUp
        self.leavesTyping = leavesTyping
    }

    public var isWakeOnly: Bool { wokeUp && commands.isEmpty && dictationText == nil && unrecognized == nil }

    public var isEmpty: Bool { !wokeUp && commands.isEmpty && dictationText == nil && unrecognized == nil }
}

/// The voice grammar (windows-voice-assistant docs/specs/voice-commands.md): the wake word, polite padding, the core
/// commands and, in NavigationGrammar.swift and EditingGrammar.swift, navigation and editing. Shortcut commands press
/// the keys of the `ShortcutKeys` it is given.
public final class CommandParser {
    public static let defaultWakeWords = [
        "hey jarvis", "hi jarvis", "hello jarvis", "ok jarvis", "okay jarvis", "a jarvis", "hey jervis", "hey javis",
        "jarvis",
    ]

    // Conversational padding around a command: "can you please open notepad for me" is "open notepad".
    static let politePrefixes = [
        "can you please", "could you please", "would you please", "will you please", "can you", "could you",
        "would you", "will you", "would you mind", "please", "kindly", "i want you to", "i want to", "i would like to",
        "id like to", "i need you to", "i need to", "i wanna", "lets", "let us", "go ahead and", "now", "just", "okay",
        "ok", "so", "and", "then", "hey", "um", "uh", "alright", "all right",
    ]

    private static let politeSuffixes =
        ["please", "for me", "right now", "now", "thanks", "thank you", "if you can", "again", "quickly"]

    // While dictating without the wake word, only these exact phrases are commands: everything else is the user's
    // text. Keep this list short and unusual: "Post it." or "That's all." must be typed, not run.
    private static let strictSend =
        ["send", "send it", "submit", "send message", "send the message", "search", "search it"]
    private static let strictScratch = ["scratch that", "undo that", "delete that"]
    private static let strictClear =
        ["clear box", "clear the box", "clear text", "clear all", "clear message", "clear the message"]
    private static let strictNewLine = ["new line", "next line"]
    private static let strictNewParagraph = ["new paragraph"]
    private static let strictStopTyping = ["stop typing", "stop dictation", "command mode", "stop writing"]
    private static let strictPause = ["pause listening", "stop listening", "go to sleep", "pause"]

    private static let strictSendPhrases = OrdinalSet(strictSend)
    private static let strictScratchPhrases = OrdinalSet(strictScratch)
    private static let strictClearPhrases = OrdinalSet(strictClear)
    private static let strictNewLinePhrases = OrdinalSet(strictNewLine)
    private static let strictNewParagraphPhrases = OrdinalSet(strictNewParagraph)
    private static let strictStopTypingPhrases = OrdinalSet(strictStopTyping)
    private static let strictPausePhrases = OrdinalSet(strictPause)

    // Broader phrasings, accepted only when waiting for a command or after the wake word.
    private static let sendPhrases = OrdinalSet(strictSend + ["send that", "submit it", "post it"])

    private static let startTypingPhrases = OrdinalSet([
        "start typing", "start dictation", "resume typing", "begin typing", "type", "start writing", "start dictating",
        "let me type", "type here", "type in it", "type something", "start typing here", "take dictation", "dictate",
        "begin dictation", "write", "start typing in it", "i want to type", "lets type", "continue typing",
    ])

    private static let pausePhrases = OrdinalSet(strictPause + ["be quiet"])
    private static let stopTypingPhrases = OrdinalSet(
        strictStopTyping + ["stop dictating", "done typing", "im done", "that is all", "thats all", "end dictation"])
    private static let scratchPhrases = OrdinalSet(strictScratch + ["remove that", "erase that"])
    private static let clearPhrases = OrdinalSet(strictClear + ["clear everything", "delete everything"])
    private static let newLinePhrases = OrdinalSet(strictNewLine + ["line break"])
    private static let newParagraphPhrases = OrdinalSet(strictNewParagraph + ["next paragraph"])

    private static let openVerbs =
        ["open up", "open", "launch", "start", "run", "fire up", "pull up", "load", "get me", "give me"]
    private static let switchVerbs = [
        "switch to", "switch over to", "go to", "go back to", "bring up", "show me", "show", "focus", "jump to",
        "take me to",
    ]
    static let chainedStartTyping = [
        " and start typing", " and start dictation", " and type", " and let me type", " and start writing", " to type",
        " so i can type",
    ]

    private static let appNameNoise = ["app", "application", "window", "program", "browser"]

    static let searchTargets = ["search box", "search bar", "search field", "search"]
    static let addressTargets = ["address bar", "url bar", "address box", "location bar"]
    private static let focusVerbs = [
        "go to", "click", "click on", "focus", "focus on", "select", "move to", "put the cursor in", "type in",
        "jump to", "open",
    ]

    private static let pressableKeys = OrdinalMap<String>([
        ("enter", "Enter"), ("return", "Enter"), ("tab", "Tab"), ("escape", "Esc"), ("backspace", "Backspace"),
        ("delete", "Delete"), ("space", "Space"), ("up", "Up"), ("down", "Down"), ("left", "Left"), ("right", "Right"),
        ("up arrow", "Up"), ("down arrow", "Down"), ("left arrow", "Left"), ("right arrow", "Right"),
        ("page up", "PageUp"), ("page down", "PageDown"), ("home", "Home"), ("end", "End"), ("shift tab", "Shift+Tab"),
    ])

    /// Editing and navigation shortcuts available while waiting for a command; the keys come from the key map.
    private static let shortcuts = OrdinalMap<Shortcut>([
        ("select all", .selectAll), ("copy", .copy), ("copy that", .copy), ("paste", .paste), ("paste that", .paste),
        ("paste it", .paste), ("cut", .cut), ("cut that", .cut), ("undo", .undo), ("redo", .redo),
        ("save", .save), ("save file", .save), ("save it", .save), ("save this", .save), ("save the file", .save),
        ("new tab", .newTab), ("open a new tab", .newTab), ("open new tab", .newTab), ("open a tab", .newTab),
        ("close tab", .closeTab), ("close the tab", .closeTab), ("close this tab", .closeTab),
        ("next tab", .nextTab), ("previous tab", .previousTab), ("go back", .back), ("go forward", .forward),
        ("back", .back), ("forward", .forward),

        // Back and forward in browsers and File Explorer or Finder. "Go to the previous page" must not be read as an
        // app called "previous page"; pagination links ("Next" under search results) are clicked with "click next".
        ("previous page", .back), ("go to previous page", .back), ("go to the previous page", .back),
        ("go back to the previous page", .back), ("go back a page", .back), ("go back one page", .back),
        ("back page", .back), ("navigate back", .back), ("take me back", .back), ("move back", .back),
        ("next page", .forward), ("go to next page", .forward), ("go to the next page", .forward),
        ("go forward a page", .forward), ("go forward one page", .forward), ("navigate forward", .forward),
        ("move forward", .forward),

        // File Explorer and Finder: the folder that contains this one.
        ("go up", .parentFolder), ("go up a level", .parentFolder), ("go up one level", .parentFolder),
        ("up one level", .parentFolder), ("parent folder", .parentFolder), ("go to parent folder", .parentFolder),
        ("go to the parent folder", .parentFolder), ("open parent folder", .parentFolder),
        ("open the parent folder", .parentFolder),
        ("refresh", .refresh), ("reload", .refresh), ("reload page", .refresh), ("refresh page", .refresh),
        ("refresh the page", .refresh), ("reload the page", .refresh),
        ("scroll down", .scrollDown), ("scroll up", .scrollUp), ("page down", .scrollDown), ("page up", .scrollUp),
    ])

    private let prefix: String
    private let requirePrefixWhileTyping: Bool
    private let wakeWords: [String]
    private let wakeNames: [String]
    private let wakeUncheckable: Bool
    private let memory: PhraseMemory?

    /// The keys shortcut commands press.
    public let keys: ShortcutKeys

    /// The clock for reminder times ("tomorrow at 5"). Tests set it.
    public let boardClock: () -> Date

    /// The time zone of `boardClock`'s wall clock (C#'s `DateTimeOffset` carries its own offset).
    public let boardTimeZone: TimeZone

    public init(
        commandPrefix: String = "computer",
        requirePrefixWhileTyping: Bool = false,
        wakeWords: [String]? = nil,
        memory: PhraseMemory? = nil,
        keys: ShortcutKeys = .windows,
        boardClock: @escaping () -> Date = { Date() },
        boardTimeZone: TimeZone = .autoupdatingCurrent
    ) {
        prefix = TranscriptText.normalize(commandPrefix)
        self.requirePrefixWhileTyping = requirePrefixWhileTyping
        self.memory = memory
        self.keys = keys
        self.boardClock = boardClock
        self.boardTimeZone = boardTimeZone
        let normalized = (wakeWords ?? CommandParser.defaultWakeWords).map { TranscriptText.normalize($0) }
        let wakes = DotNet.orderByDescending(NetText.distinct(normalized.filter { !$0.isEmpty })) { $0.utf16.count }
        self.wakeWords = wakes

        // The name in each wake phrase (its last word: "hey jarvis" has "jarvis"), for the standby pre-check.
        let names = wakes.map { DotNet.split($0, [" "]).last ?? "" }
        wakeNames = NetText.distinct(names.filter { $0.utf16.count >= 3 })

        // A wake phrase without a usable name ("hey pc") can't be pre-checked: every phrase then gets a full
        // transcription.
        wakeUncheckable = names.contains { $0.utf16.count < 3 }
    }

    private func matchBoard(_ spoken: String) -> VoiceCommand? {
        BoardGrammar.parse(spoken, now: boardClock(), timeZone: boardTimeZone).map { VoiceCommand(.board, board: $0) }
    }

    private static func wordCount(_ normalized: String) -> Int { NetText.words(normalized).count }

    /// Drops the transcript's first words that normalizing turned into `normalizedWords` words (the wake word or
    /// prefix), keeping the rest exactly as said.
    private static func dropLeadingWords(_ cleaned: String, _ normalizedWords: Int) -> String {
        if normalizedWords <= 0 {
            return cleaned
        }

        let tokens = NetText.words(cleaned)
        var used = 0
        var taken = 0
        while taken < tokens.count && used < normalizedWords {
            used += max(1, wordCount(TranscriptText.normalize(tokens[taken])))
            taken += 1
        }

        return DotNet.trimStart(tokens[taken...].joined(separator: " "), [",", ".", " ", ":", ";", "!"])
    }

    /// Removes conversational padding ("can you please …", "… for me"). Public for learning rephrasings.
    public static func simplify(_ normalized: String) -> String {
        var text = normalized
        var changed: Bool
        repeat {
            changed = false
            for prefix in politePrefixes where DotNet.startsWith(text, prefix + " ") {
                text = DotNet.trimStart(DotNet.dropPrefix(text, prefix + " "))
                changed = true
            }

            for suffix in politeSuffixes where DotNet.endsWith(text, " " + suffix) {
                text = DotNet.trimEnd(NetText.dropSuffix(text, " " + suffix))
                changed = true
            }
        } while changed && !text.isEmpty

        return text
    }

    /// Parses one complete, pause-delimited utterance. Commands must match the whole utterance (after polite padding
    /// is removed), so "please send me the logs" is dictation while "Send." is a command.
    public func parse(_ transcript: String?, _ mode: InteractionMode) -> ParsedUtterance {
        let cleaned = TranscriptText.clean(transcript)
        var normalized = TranscriptText.normalize(cleaned)
        if normalized.isEmpty || mode == .paused {
            return .empty
        }

        let normalizedBefore = normalized
        let woke = tryStripWakeWord(&normalized)
        let prefixed = woke || tryStripPrefix(&normalized)

        // The idea board keeps the note's own capitals and punctuation, so it reads the transcript as said.
        let spoken = Self.dropLeadingWords(cleaned, Self.wordCount(normalizedBefore) - Self.wordCount(normalized))

        switch mode {
        case .standby where !woke:
            return .empty

        case .dictation:
            if normalized.isEmpty {
                return ParsedUtterance(wokeUp: woke)
            }

            if prefixed, let boardWhileTyping = matchBoard(spoken) {
                // "Hey Jarvis, add to my ideas …" while typing: filed on the board; typing carries on.
                return ParsedUtterance(
                    commands: [boardWhileTyping], commandText: Self.simplify(normalized), wokeUp: woke)
            }

            if requirePrefixWhileTyping && !prefixed {
                return ParsedUtterance(dictationText: cleaned)
            }

            // Unprefixed speech while typing stays strict: "please send it to Sam" is text, not a command.
            var text = prefixed ? Self.simplify(normalized) : normalized
            var command = Self.matchDictationCommand(text, lenient: prefixed)
            if command == nil && prefixed, let edits = Self.withUntrimmedEdit(nil, normalized), edits.count == 1 {
                // "delete the word now": the trimmed text lost the phrase.
                command = edits[0]
            }

            var learned = false
            if command == nil && prefixed, let taught = memory?.command(for: text) {
                command = Self.matchDictationCommand(taught, lenient: true)
                learned = command != nil
                text = learned ? taught : text
            }

            if let command {
                let commands = prefixed ? Self.withUntrimmedEdit([command], normalized) ?? [command] : [command]
                return ParsedUtterance(
                    commands: Self.asSaid(commands, cleaned), commandText: text, fromLearnedPhrase: learned,
                    wokeUp: woke)
            }

            if prefixed, let full = matchCommandMode(text) {
                // "Hey Jarvis, go to the first tab" while typing: any command works after the wake word, and typing
                // stops first so nothing lands in the new place.
                return ParsedUtterance(
                    commands: Self.asSaid(Self.withUntrimmedEdit(full, normalized) ?? full, cleaned), commandText: text,
                    spoken: spoken, wokeUp: woke, leavesTyping: true)
            }

            return prefixed
                ? ParsedUtterance(unrecognized: text, spoken: spoken, wokeUp: woke)
                : ParsedUtterance(dictationText: cleaned)

        default:
            var text = Self.simplify(normalized)
            if text.isEmpty {
                return ParsedUtterance(wokeUp: woke)
            }

            if let board = matchBoard(spoken) {
                return ParsedUtterance(commands: [board], commandText: text, wokeUp: woke)
            }

            var matched = matchCommandMode(text) ?? Self.withUntrimmedEdit(nil, normalized)
            var learned = false
            if matched == nil, let taught = memory?.command(for: text) {
                matched = matchCommandMode(taught)
                learned = matched != nil

                // Learn rephrasings against the real command, not another learned phrase.
                text = learned ? taught : text
            }

            guard let commands = matched else {
                return ParsedUtterance(unrecognized: text, spoken: spoken, wokeUp: woke)
            }

            let untrimmed = learned ? commands : Self.withUntrimmedEdit(commands, normalized) ?? commands
            return ParsedUtterance(
                commands: Self.asSaid(untrimmed, cleaned), commandText: text, spoken: spoken,
                fromLearnedPhrase: learned, wokeUp: woke)
        }
    }

    /// A cheap check in standby: could this rough transcript hold the wake word? Lenient on purpose (a false yes only
    /// costs a full transcription; a false no ignores the user): any word, or two neighbouring words joined, within a
    /// small edit distance of a wake word's name ("jarvis", "jervis", "jar vis", "jarvi").
    public func mayContainWakeWord(_ transcript: String) -> Bool {
        if wakeUncheckable {
            return true
        }

        let words = NetText.words(TranscriptText.normalize(transcript))
        if words.isEmpty {
            return false
        }

        for name in wakeNames {
            let length = name.utf16.count
            let allowed = length >= 5 ? 2 : length >= 3 ? 1 : 0
            for i in words.indices {
                if Self.editDistance(words[i], name) <= allowed
                    || (i + 1 < words.count && Self.editDistance(words[i] + words[i + 1], name) <= allowed) {
                    return true
                }
            }
        }

        return false
    }

    // First words of commands, for a quick transcript that was cut short ("open the downloads folder in…").
    private static let commandStarts = OrdinalSet([
        "open", "launch", "start", "switch", "go", "click", "select", "press", "search", "show", "close", "new", "type",
        "scroll", "pause", "stop", "remind", "add", "note", "mark", "delete", "replace", "send", "expand", "refresh",
        "copy", "paste", "undo", "save", "hide", "focus", "bring", "pull", "fire", "please", "can", "could",
    ])

    /// Whether a transcript cut short could be the start of a command (its first word starts one).
    public static func mayStartCommand(_ transcript: String) -> Bool {
        guard let first = NetText.words(TranscriptText.normalize(transcript)).first else { return false }
        return commandStarts.contains(first)
    }

    /// Edit distance by UTF-16 code unit, as in C#; 3 when the lengths differ by more than 2.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        abs(a.utf16.count - b.utf16.count) > 2 ? 3 : NameMatcher.levenshtein(a, b)
    }

    private func tryStripWakeWord(_ normalized: inout String) -> Bool {
        for wake in wakeWords {
            if DotNet.ordinalEquals(normalized, wake) {
                normalized = ""
                return true
            }

            if DotNet.startsWith(normalized, wake + " ") {
                normalized = DotNet.trim(DotNet.dropPrefix(normalized, wake + " "))
                return true
            }
        }

        return false
    }

    private func tryStripPrefix(_ normalized: inout String) -> Bool {
        if prefix.isEmpty {
            return false
        }

        for candidate in [prefix + " ", "hey " + prefix + " "] where DotNet.startsWith(normalized, candidate) {
            normalized = DotNet.trim(DotNet.dropPrefix(normalized, candidate))
            return true
        }

        return false
    }

    private static func matchDictationCommand(_ n: String, lenient: Bool) -> VoiceCommand? {
        if (lenient ? sendPhrases : strictSendPhrases).contains(n) {
            return VoiceCommand(.send)
        }

        if (lenient ? scratchPhrases : strictScratchPhrases).contains(n) {
            return VoiceCommand(.scratchThat)
        }

        if (lenient ? clearPhrases : strictClearPhrases).contains(n) {
            return VoiceCommand(.clearBox)
        }

        if (lenient ? newLinePhrases : strictNewLinePhrases).contains(n) {
            return VoiceCommand(.newLine)
        }

        if (lenient ? newParagraphPhrases : strictNewParagraphPhrases).contains(n) {
            return VoiceCommand(.newParagraph)
        }

        if (lenient ? stopTypingPhrases : strictStopTypingPhrases).contains(n) {
            return VoiceCommand(.stopTyping)
        }

        if (lenient ? pausePhrases : strictPausePhrases).contains(n) {
            return VoiceCommand(.pauseListening)
        }

        return matchEdit(n, lenient: lenient) ?? matchPress(n)
    }

    private func matchCommandMode(_ n: String) -> [VoiceCommand]? {
        if Self.startTypingPhrases.contains(n) {
            return [VoiceCommand(.startTyping)]
        }

        if Self.sendPhrases.contains(n) {
            return [VoiceCommand(.send)]
        }

        if Self.pausePhrases.contains(n) {
            return [VoiceCommand(.pauseListening)]
        }

        if Self.stopTypingPhrases.contains(n) {
            return [VoiceCommand(.stopTyping)]
        }

        if Self.matchFocusTarget(n, Self.addressTargets) {
            return [VoiceCommand(.focusAddressBar)]
        }

        if Self.matchFocusTarget(n, Self.searchTargets) {
            return [VoiceCommand(.focusSearch)]
        }

        if let shortcut = Self.shortcuts[n] {
            return [VoiceCommand(.pressKeys, keys.keys(for: shortcut))]
        }

        if let press = Self.matchPress(n) {
            return [press]
        }

        if let newPlace = Self.matchOpenInNewPlace(n) {
            return [newPlace]
        }

        if let navigation = Self.matchNavigation(n) {
            return navigation
        }

        if let edit = Self.matchEdit(n, lenient: true) {
            return [edit]
        }

        for prefix in ["search for ", "search the web for ", "search google for ", "google ", "look up ", "search "]
        where DotNet.startsWith(n, prefix) && n.utf16.count > prefix.utf16.count {
            var query = DotNet.trim(DotNet.dropPrefix(n, prefix))
            for tail in [" on google", " on the web", " online"] where DotNet.endsWith(query, tail) {
                query = NetText.dropSuffix(query, tail)
            }

            return [VoiceCommand(.searchFor, query)]
        }

        return Self.matchApp(n, Self.openVerbs, .openApp) ?? Self.matchApp(n, Self.switchVerbs, .switchToApp)
    }

    private static func matchApp(_ n: String, _ verbs: [String], _ kind: CommandKind) -> [VoiceCommand]? {
        for verb in verbs where DotNet.startsWith(n, verb + " ") {
            var app = DotNet.trim(DotNet.dropPrefix(n, verb + " "))
            var startTyping = false
            for suffix in chainedStartTyping where DotNet.endsWith(app, suffix) {
                app = DotNet.trim(NetText.dropSuffix(app, suffix))
                startTyping = true
                break
            }

            app = cleanAppName(app)
            if app.isEmpty {
                return nil
            }

            return startTyping ? [VoiceCommand(kind, app), VoiceCommand(.startTyping)] : [VoiceCommand(kind, app)]
        }

        return nil
    }

    /// "up a new notepad window" is "notepad".
    static func cleanAppName(_ app: String) -> String {
        var app = app
        for article in ["up ", "the ", "my ", "a ", "an ", "new ", "a new ", "another "]
        where DotNet.startsWith(app, article) {
            app = DotNet.dropPrefix(app, article)
        }

        for noise in appNameNoise where DotNet.endsWith(app, " " + noise) && app.utf16.count > noise.utf16.count + 1 {
            app = NetText.dropSuffix(app, " " + noise)
        }

        return simplify(DotNet.trim(app))
    }

    /// "go to the search box", "click on the search bar", "search box", "focus search" …
    private static func matchFocusTarget(_ n: String, _ targets: [String]) -> Bool {
        for target in targets {
            for article in ["", "the "] {
                let phrase = article + target
                if DotNet.ordinalEquals(n, phrase) && DotNet.contains(target, " ") {
                    return true
                }

                if focusVerbs.contains(where: { DotNet.ordinalEquals(n, $0 + " " + phrase) }) {
                    return true
                }
            }
        }

        return false
    }

    private static func matchPress(_ n: String) -> VoiceCommand? {
        for prefix in ["press the ", "press ", "hit the ", "hit ", "tap "] where DotNet.startsWith(n, prefix) {
            var key = DotNet.trim(DotNet.dropPrefix(n, prefix))
            if DotNet.endsWith(key, " key") {
                key = NetText.dropSuffix(key, " key")
            }

            if DotNet.endsWith(key, " button") {
                key = NetText.dropSuffix(key, " button")
            }

            return pressableKeys[key].map { VoiceCommand(.pressKeys, $0) }
        }

        return nil
    }
}
