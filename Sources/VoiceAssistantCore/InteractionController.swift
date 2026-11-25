import Foundation
import ThumbFreeCore
import VoiceAssistantBoard

/// A status line for the pill: the mode, how it went, the message and what was heard, and where the assistant is
/// acting ("Chrome › YouTube › Search") after a navigation command (C#'s `StatusUpdate`; ThumbFreeCore's has no mode
/// or place).
public struct AssistantStatus: Equatable, Sendable {
    public var mode: InteractionMode
    public var kind: StatusKind
    public var message: String
    public var heard: String?
    public var place: String?

    public init(mode: InteractionMode, kind: StatusKind, message: String, heard: String? = nil, place: String? = nil) {
        self.mode = mode
        self.kind = kind
        self.message = message
        self.heard = heard
        self.place = place
    }
}

public struct ControllerOptions {
    public var returnToCommandModeAfterSend: Bool

    /// Commands below this average token probability are ignored rather than run or typed.
    public var minCommandConfidence: Float

    /// When true, listening starts in standby and commands need the wake word.
    public var wakeWordEnabled: Bool

    /// How long commands work without repeating the wake word (refreshed by each command), in seconds.
    public var awakeTimeout: TimeInterval

    /// A rephrasing within this many seconds after an unrecognised phrase is learned as its meaning.
    public var learnWindow: TimeInterval

    public var wakeWordLabel: String

    /// The most the AI brain may take to answer, in seconds (C#'s `BrainPlanLimit`). At most a day: more, or
    /// `.infinity`, waits a day.
    public var brainPlanLimit: TimeInterval
    public var clock: () -> Date

    public init(
        returnToCommandModeAfterSend: Bool = true,
        minCommandConfidence: Float = 0.3,
        wakeWordEnabled: Bool = true,
        awakeTimeout: TimeInterval = 30,
        learnWindow: TimeInterval = 30,
        wakeWordLabel: String = "Hey Jarvis",
        brainPlanLimit: TimeInterval = 60,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.returnToCommandModeAfterSend = returnToCommandModeAfterSend
        self.minCommandConfidence = minCommandConfidence
        self.wakeWordEnabled = wakeWordEnabled
        self.awakeTimeout = awakeTimeout
        self.learnWindow = learnWindow
        self.wakeWordLabel = wakeWordLabel
        self.brainPlanLimit = brainPlanLimit
        self.clock = clock
    }
}

/// Owns the standby, command and dictation state machine (windows-voice-assistant's InteractionController.cs, with its
/// Navigation and Brain parts in the other two files). Its methods throw what the desktop or the board throws (typing
/// stops there), and `CancellationError` when cancelled.
///
/// It isn't thread-safe, and its async methods aren't isolated to an actor, so the host keeps this contract, as the
/// Windows host does with its one work queue:
/// - One task makes the calls (`handleTranscript`, `tick`, `setListening`, `insertDictation`, `repeatLastTranscript`
///   and `clearUntypedText`) and awaits each before making the next. It also reads `mode`, `target`, `place`,
///   `untypedText` and `lastTranscript`, and asks `worthTranscribingInStandby`, between them. An actor alone isn't
///   enough: it starts another call while one waits at an `await`, and a request to the brain can wait a minute.
/// - A call that starts while another is running is a bug in the host. Debug builds stop at an assertion. Release
///   builds log it (`onTrace`), and the call does nothing and says so, so the two can't race and nothing is lost
///   silently: `handleTranscript` throws `ControllerBusy`, and the host drops the speech and says "Still working on
///   your last request." (it never queues it: a "yes" must not run after a plan); `insertDictation` and
///   `repeatLastTranscript` throw it, and the host keeps the text to type later; `setListening` and
///   `clearUntypedText` return false, and the host calls them again once the running call has ended; `tick` returns
///   false, and the next tick does its work.
/// - While `isBrainRunning`, the host drops speech rather than queueing it (it would run late, on a changed screen),
///   and Esc cancels the task running the call. `isBrainRunning` and `brainChanges` are safe to read from any thread.
/// - The `on…` callbacks run during a call, on its task's thread, which isn't the main thread: the host hops to the
///   main actor for its UI, and never calls back into the controller from a callback (it queues the work instead).
/// - `brain`, `board` and the callbacks are set before the first call.
public final class InteractionController {
    let desktop: JarvisDesktop
    let apps: AppCatalog
    let parser: CommandParser
    let formatter: DictationFormatter
    let options: ControllerOptions
    let memory: PhraseMemory?

    /// The length of each phrase typed, the last at the end, for "scratch that".
    var segments: [Int] = []

    /// The end of what was last typed (or left after an edit), in UTF-16 units, to trust a field's text only while it
    /// still ends this way.
    var typedTail: [UInt16]?
    var targetProfile: AppEntry?
    var boxHadText = false
    var needsLeadingSpace = false
    var endsSentence = true
    var searchField = false
    var awakeSince = Date.distantPast
    var pendingUnrecognized: (phrase: String, at: Date)?

    // Navigation: numbered choices, a click waiting for "yes", the current place.
    var choices: [Choice] = []
    var choicesAt = Date.distantPast
    var pendingClick: (element: UiElement, window: WindowInfo, at: Date)?

    // The AI brain.
    var brainPending: BrainPending?
    var brainRequest: String?
    let brainActivity = BrainActivity()

    /// The last utterance was "Hey Jarvis" on its own: the next one is addressed to Jarvis.
    var brainAddressed = false

    /// The public call running now, to catch one that overlaps it (the class's contract).
    let calls = CallGuard()

    /// What a call that overlaps another does besides the log line: fails an assertion (debug builds only). Tests
    /// replace it to watch.
    var overlapped: (String) -> Void = { assertionFailure("InteractionController.\($0) overlapped another call.") }

    public init(
        _ desktop: JarvisDesktop,
        _ apps: AppCatalog,
        _ parser: CommandParser,
        options: ControllerOptions = ControllerOptions(),
        formatter: DictationFormatter = DictationFormatter(),
        memory: PhraseMemory? = nil
    ) {
        self.desktop = desktop
        self.apps = apps
        self.parser = parser
        self.options = options
        self.formatter = formatter
        self.memory = memory
    }

    public var onStatus: ((AssistantStatus) -> Void)?

    /// A voice command asked to stop listening: the host turns the microphone off.
    public var onPauseRequested: (() -> Void)?

    /// Something was learned (a rephrasing or an app's use): the host saves the memory.
    public var onMemoryChanged: (() -> Void)?

    /// Content-free diagnostics (command kinds and outcomes, never transcripts) for the log.
    public var onTrace: ((String) -> Void)?

    /// The idea board voice commands add to; nil turns them off.
    public var board: Board?

    /// "show my ideas": the host opens the board (on that list, or the whole board for nil).
    public var onShowBoardRequested: ((BoardList?) -> Void)?

    /// Numbers to draw on screen (nil hides them).
    public var onChoicesChanged: (([ChoiceBadge]?) -> Void)?

    /// Briefly outline what was just clicked, selected or focused.
    public var onHighlight: ((ScreenRect) -> Void)?

    /// The on-device model for requests the fixed commands don't cover; nil keeps the fixed commands only.
    public var brain: BrainModel?

    public internal(set) var mode: InteractionMode = .paused

    /// Dictated text that couldn't be typed (focus moved, the field couldn't be checked). Kept only in memory.
    public internal(set) var untypedText: String?

    /// The last text typed by dictation, for "paste last transcript". Kept only in memory.
    public internal(set) var lastTranscript: String?

    /// The window dictation types into.
    public internal(set) var target: WindowInfo?

    /// Where the assistant last acted, e.g. "Google Chrome › YouTube › Search".
    public internal(set) var place: String?

    /// The platform's keys for the shortcuts the controller presses itself (select all, delete a word, back…).
    var keys: ShortcutKeys { parser.keys }

    private var idleMode: String {
        options.wakeWordEnabled ? "Say “\(options.wakeWordLabel)” to give a command." : "Listening for a command."
    }

    /// Starts a public call: false when another is still running, which the class's contract rules out. Then the
    /// call is logged, does nothing and says so (debug builds stop at `overlapped`'s assertion first).
    private func beginCall(_ name: String) -> Bool {
        if calls.enter() {
            return true
        }

        trace("\(name) overlapped another call: ignored")
        overlapped(name)
        return false
    }

    /// Starts or stops listening. False if another call was still running, so nothing changed: the host calls it again
    /// once that call has ended.
    @discardableResult
    public func setListening(_ listening: Bool) -> Bool {
        guard beginCall("setListening") else { return false }
        defer { calls.leave() }
        if listening {
            if mode == .paused {
                mode = options.wakeWordEnabled ? .standby : .command
                report(.info, idleMode)
            }

            return true
        }

        if mode != .paused {
            mode = .paused
            report(.info, "Paused. Microphone is off.")
        }

        return true
    }

    /// Forgets `untypedText`. False if another call was still running, so the text is still there: the host calls it
    /// again once that call has ended.
    @discardableResult
    public func clearUntypedText() -> Bool {
        guard beginCall("clearUntypedText") else { return false }
        defer { calls.leave() }
        untypedText = nil
        return true
    }

    /// Call periodically: returns to standby when the wake word's command window has expired. False if another call
    /// was still running; the next tick does the work.
    @discardableResult
    public func tick() -> Bool {
        guard beginCall("tick") else { return false }
        defer { calls.leave() }
        expirePending()
        if expireAwake() {
            report(.info, idleMode)
        }

        return true
    }

    /// Handles one utterance. `followsForcedCut`: the audio continues a sentence cut at the length cap, so it is typed
    /// (or ignored) but never run as a command. `dictationTranscript`: while typing, the text to type from a second
    /// model (Hindi and English, say); the command check still uses `transcript`, and it's called only when the
    /// utterance is to be typed. `brainChangesWhenSpoken`: `brainChanges` when the speech started; if the AI brain
    /// started or stopped since, the speech is ignored (it was said before the brain's question or result was shown).
    /// Throws `ControllerBusy` if another call was still running: the speech was dropped.
    public func handleTranscript(
        _ transcript: String,
        _ confidence: Float,
        followsForcedCut: Bool = false,
        dictationTranscript: (() async throws -> String)? = nil,
        brainChangesWhenSpoken: Int? = nil
    ) async throws {
        guard beginCall("handleTranscript") else { throw ControllerBusy(call: "handleTranscript") }
        defer { calls.leave() }
        if mode == .paused {
            return
        }

        if let spoken = brainChangesWhenSpoken, spoken != brainChanges {
            trace("speech from while the AI brain was busy: ignored")
            return
        }

        _ = expireAwake()
        var heard = TranscriptText.clean(transcript)
        if followsForcedCut && mode == .dictation {
            // The tail of a sentence cut at the length cap: type it, never treat it as "send" or "stop typing".
            if let dictationTranscript {
                heard = TranscriptText.clean(try await dictationTranscript())
            }

            if !heard.isEmpty {
                _ = try typeDictated(heard, heard)
            }

            return
        }

        let parsed = parser.parse(transcript, mode)
        if let dictationTranscript, mode == .dictation, parsed.isEmpty || parsed.dictationText != nil {
            // Not a command: what the English model heard may be empty or garbled (Hindi), so the second model's text.
            let text = TranscriptText.clean(try await dictationTranscript())
            if !text.isEmpty {
                _ = try typeDictated(text, text)
            }

            return
        }

        let answer = parsed.commands.count == 1 ? parsed.commands[0].kind : nil
        let answers = answer == .confirm || answer == .cancel
        if pendingClick != nil && !answers {
            // A destructive click waits only for the very next utterance to be "yes" (or "no"); anything else drops it.
            pendingClick = nil
        }

        if brainPending != nil && !answers {
            brainPending = nil
            trace("brain: waiting step dropped")
        }

        // The AI brain acts only on speech addressed to Jarvis: said with the wake word, right after "Hey Jarvis" on
        // its own, or when commands need no wake word. Conversation in the 30 s after a command is never planned.
        let addressed = parsed.wokeUp || brainAddressed || !options.wakeWordEnabled
        brainAddressed = false

        if parsed.isEmpty {
            if mode == .standby && isCommandWithoutWakeWord(transcript) {
                // A real command without the wake word: say why nothing happened instead of staying silent.
                trace("standby: command without wake word")
                report(.info, "Say “\(options.wakeWordLabel)” first, then the command.", heard)
            }

            return
        }

        if (!parsed.commands.isEmpty || parsed.isWakeOnly) && confidence < options.minCommandConfidence {
            trace("low confidence command ignored")
            report(.warning, "Not sure I heard that right — ignored.", heard)
            return
        }

        if parsed.isWakeOnly {
            if mode != .dictation {
                awake()
                brainAddressed = true
                if brainTakes {
                    // A request is probably next: a sleeping model starts loading while it's said.
                    brain?.prepare()
                }

                trace("wake")
                report(.info, "Yes? Say a command.", heard)
            }

            return
        }

        if let unrecognized = parsed.unrecognized {
            if mode == .standby {
                awake()
            }

            if brainTakes && addressed {
                if confidence < options.minCommandConfidence {
                    // Unclear speech is never planned and acted on.
                    trace("low confidence request ignored")
                    report(.warning, "Not sure I heard that right — ignored.", heard)
                    return
                }

                // Not a fixed command: the AI brain plans it from what's on screen.
                if try await askBrain(parsed.spoken ?? unrecognized, heard) == nil {
                    // No plan: a rephrasing that works can still be learned.
                    pendingUnrecognized = (unrecognized, options.clock())
                }

                if mode == .command {
                    awakeSince = options.clock()
                }

                return
            }

            pendingUnrecognized = (unrecognized, options.clock())
            trace("unrecognized command")
            let message = brain?.availability == .notInstalled
                ? "Not a command I know. Say it another way, or get the AI brain in Settings to ask for anything."
                : brainTakes
                    ? "Not a command I know. Start with “\(options.wakeWordLabel)” to ask the AI brain, or say it "
                        + "another way."
                    : "Not a command I know. Say it another way and I'll remember."
            report(.warning, message, heard)
            return
        }

        if let dictation = parsed.dictationText {
            _ = try typeDictated(dictation, heard)
            return
        }

        if mode == .standby {
            awake()
        }

        if parsed.leavesTyping && mode == .dictation {
            // "Hey Jarvis, next tab" while typing: stop typing first, so dictation never lands in the new place.
            awake()
        }

        var allSucceeded = true

        // A single command that finds nothing ("open the MrBeast video on YouTube" read as an app name) goes to the
        // brain.
        brainRequest = parsed.commands.count == 1 && addressed ? parsed.spoken : nil
        do {
            for command in parsed.commands {
                try Task.checkCancellation()
                if ![.choose, .confirm, .cancel, .hideNumbers].contains(command.kind) {
                    // Any other command makes numbered choices and pending confirmations stale.
                    clearPending()
                }

                let ok = try await execute(command, heard)
                let learned = parsed.fromLearnedPhrase ? " (learned phrase)" : ""
                trace("command \(Self.name(of: command.kind)) \(ok ? "ok" : "failed")\(learned)")
                if !ok {
                    allSucceeded = false
                    break
                }
            }
        } catch {
            brainRequest = nil
            throw error
        }

        brainRequest = nil
        learnRephrasing(parsed, allSucceeded, heard)

        if mode == .command {
            awakeSince = options.clock()
        }
    }

    /// If the user just said something unrecognised and now rephrased it as a working command, remembers the first
    /// phrase as meaning the second (PhraseMemory only takes pairs sharing a meaningful word).
    private func learnRephrasing(_ parsed: ParsedUtterance, _ succeeded: Bool, _ heard: String) {
        let waiting = pendingUnrecognized
        pendingUnrecognized = nil
        guard let memory, succeeded, let command = parsed.commandText, let pending = waiting,
              options.clock().timeIntervalSince(pending.at) <= options.learnWindow
        else { return }

        if memory.learn(pending.phrase, command) {
            trace("learned a rephrasing")
            onMemoryChanged?()
            report(.info, "Got it — next time “\(pending.phrase)” will do that too.", heard)
        }
    }

    /// Push-to-talk dictation: formats the transcript and types it wherever the cursor is. The user's own key press is
    /// the consent, so only password and administrator windows are refused. Throws `ControllerBusy` if another call
    /// was still running: nothing was typed, and the host keeps the text.
    public func insertDictation(_ transcript: String) throws {
        guard beginCall("insertDictation") else { throw ControllerBusy(call: "insertDictation") }
        defer { calls.leave() }

        // Dictation that names a list ("add to my ideas …") is filed on the board instead of typed.
        let cleaned = TranscriptText.clean(transcript)
        if board != nil,
           let intent = BoardGrammar.parse(
               cleaned, now: boardNow(), explicitOnly: true, timeZone: parser.boardTimeZone),
           intent.action == .add {
            _ = try executeBoard(intent, cleaned)
            return
        }

        let formatted = formatter.format(transcript)
        if formatted.isEmpty {
            report(.info, "I didn't catch anything to type.")
            return
        }

        try insertIntoFocused(formatted, cleaned, fileIfNoTextBox: true)
    }

    /// Types the last dictated text again into the focused field. Throws `ControllerBusy` if another call was still
    /// running: nothing was typed.
    public func repeatLastTranscript() throws {
        guard beginCall("repeatLastTranscript") else { throw ControllerBusy(call: "repeatLastTranscript") }
        defer { calls.leave() }
        guard let last = lastTranscript, !last.isEmpty else {
            report(.info, "There's no previous dictation yet.")
            return
        }

        try insertIntoFocused(last, nil)
    }

    private func execute(_ command: VoiceCommand, _ heard: String) async throws -> Bool {
        if mode == .dictation && [.openApp, .switchToApp, .selectTab, .click, .showNumbers].contains(command.kind) {
            // "Hey Jarvis, go to the first tab" while typing: stop typing first so nothing lands in the new place.
            awake()
        }

        if movesAway(command) {
            // The page or app under the typing target may change: "send" must not press Enter in the new place.
            unbind()
        }

        let argument = command.argument ?? ""
        switch command.kind {
        case .openApp:
            return try await navigate(argument, newWindow: true, heard)
        case .switchToApp:
            return try await navigate(argument, newWindow: false, heard)
        case .openInNewTab, .openInNewWindow:
            return try await openInNewPlace(argument, window: command.kind == .openInNewWindow, heard)
        case .startTyping:
            return try await startTyping(heard)
        case .focusSearch:
            return try await focusSearch(heard, addressBar: false)
        case .focusAddressBar:
            return try await focusSearch(heard, addressBar: true)
        case .searchFor:
            guard try await focusSearch(heard, addressBar: false), try typeDictated(argument, heard) else {
                return false
            }

            return try send(heard, "Searching.")
        case .pressKeys:
            return try pressChord(argument, heard)
        case .send:
            return try send(heard, "Sent.")
        case .scratchThat:
            guard ensureTargetFocused(heard, nil) else { return false }
            guard let last = segments.popLast() else {
                report(.warning, "Nothing to undo.", heard)
                return false
            }

            try desktop.backspace(last)
            typedTail = nil
            needsLeadingSpace = !segments.isEmpty || boxHadText
            report(.success, "Removed the last phrase.", heard)
            return true
        case .clearBox:
            guard ensureTargetFocused(heard, nil) else { return false }
            try desktop.pressKeys(keys.selectAll)
            try desktop.backspace(1)
            segments.removeAll()
            typedTail = nil
            boxHadText = false
            needsLeadingSpace = false
            endsSentence = true
            report(.success, "Cleared.", heard)
            return true
        case .newLine, .newParagraph:
            guard ensureTargetFocused(heard, nil) else { return false }
            let lines = command.kind == .newLine ? 1 : 2
            for _ in 0..<lines {
                try desktop.pressKeys(newLineKeys)
            }

            segments.append(lines)
            needsLeadingSpace = false
            endsSentence = true
            report(.success, lines == 1 ? "New line." : "New paragraph.", heard)
            return true
        case .stopTyping:
            if mode == .dictation {
                awake()
                report(.info, "Stopped typing. Nothing was sent.", heard)
            }

            return true
        case .pauseListening:
            mode = .paused
            report(.info, "Paused. Microphone is off.", heard)
            onPauseRequested?()
            return false
        case .selectTab:
            return try await selectTab(command.target ?? ElementTarget(name: argument), heard)
        case .click:
            return try await click(command.target ?? ElementTarget(name: argument), heard, minScore: NameMatcher.fuzzy)
        case .focusField:
            return try await focusField(command.target ?? ElementTarget(name: argument), heard)
        case .showNumbers:
            return try await showNumbers(heard)
        case .hideNumbers:
            clearPending()
            report(.info, "Numbers hidden.", heard)
            return true
        case .choose:
            return try await choose(NetText.parseInteger(command.argument ?? "0") ?? 0, heard)
        case .confirm:
            return try await confirmPending(heard)
        case .cancel:
            let hadPending = !choices.isEmpty || pendingClick != nil || brainPending != nil
            clearPending()
            report(.info, hadPending ? "Cancelled." : "Nothing to cancel.", heard)
            return hadPending
        case .deleteText, .replaceText:
            return try editText(command.edit ?? TextEdit(), heard)
        case .board:
            guard let intent = command.board else { return false }
            return try executeBoard(intent, heard)
        }
    }

    /// "delete the last 3 words", "delete the word very", "replace Monday with Tuesday" in the field being typed in
    /// (or, when not typing, the focused field). The text before the cursor decides exactly what to erase; without it,
    /// only "last N words" works (the platform's delete-a-word keys), the rest say why.
    private func editText(_ edit: TextEdit, _ heard: String) throws -> Bool {
        let typing = mode == .dictation
        if typing ? !ensureTargetFocused(heard, nil) : desktop.foregroundWindow() == nil {
            if !typing {
                report(.warning, "There's no window in front.", heard)
            }

            return false
        }

        // Outside typing, the focused field must be checked: keys sent to a file list or a page do other things.
        if !checkField(heard, nil, allowUnknown: typing) {
            return false
        }

        let caret = desktop.readTextBeforeCaret()
        if caret?.hasSelection == true {
            report(
                .warning,
                "Some text is selected. Click where you want to edit (or say “press right”), then say it again.",
                heard)
            return false
        }

        if caret?.editable == false {
            report(.warning, "That isn't a text box I can edit.", heard)
            return false
        }

        // When only the whole text is readable, trust "the cursor is at the end" only if it ends with what was just
        // typed.
        var readable: String?
        if let caret {
            if caret.caretKnown {
                readable = caret.before
            } else if typing, let tail = typedTail, !tail.isEmpty,
                      Array(DotNet.trimEnd(TextEditing.normalizeNewLines(caret.before)).utf16).suffix(tail.count)
                          .elementsEqual(tail) {
                readable = caret.before
            }
        }

        guard let before = readable else {
            if typing && edit.phrase == nil && edit.unit == .word {
                try desktop.pressKeysRepeated(keys.deleteWordBefore, edit.count)
                forgetTypedLengths()
                report(
                    .success, edit.count == 1 ? "Deleted the last word." : "Deleted the last \(edit.count) words.",
                    heard)
                return true
            }

            if typing && edit.phrase == nil && edit.unit == .character {
                try desktop.backspace(edit.count)
                forgetTypedLengths()
                report(
                    .success,
                    edit.count == 1 ? "Deleted the last character." : "Deleted the last \(edit.count) characters.",
                    heard)
                return true
            }

            report(
                .warning,
                "I can't read the text in this box, so I can't find that. Say “delete the last 3 words” or “press "
                    + "backspace”.",
                heard)
            return false
        }

        let planned: EditPlan?
        if let phrase = edit.phrase {
            planned = TextEditing.replaceLast(before, phrase, edit.replacement)
        } else {
            planned = TextEditing.deleteLast(before, edit.unit, edit.count)
        }

        guard let plan = planned else {
            report(
                .warning,
                edit.phrase.map { "I couldn't find “\(Self.short($0, 40))” before the cursor." }
                    ?? "There's nothing before the cursor to delete (or it's too far back).",
                heard)
            return false
        }

        if plan.keepAfter > 0 {
            try desktop.pressKeysRepeated("Left", plan.keepAfter)
        }

        // Select, then delete or type over the selection: the arrow keys move in the app's own units.
        try desktop.pressKeysRepeated("Shift+Left", plan.delete)
        if !plan.insert.isEmpty {
            try desktop.typeText(plan.insert)
        } else {
            try desktop.backspace(1)
        }

        if plan.keepAfter > 0 {
            try desktop.pressKeysRepeated("Right", plan.keepAfter)
        }

        forgetTypedLengths()
        let rest = plan.textAfterEdit
        typedTail = Self.tail(rest)
        boxHadText = !rest.isEmpty
        needsLeadingSpace = !rest.isEmpty && !Self.endsWithWhiteSpace(rest)
        let trimmed = DotNet.trimEnd(rest, [" "])
        endsSentence = trimmed.isEmpty || Self.endsWithAny(trimmed, ".!?\n:")
        report(.success, Self.describeEdit(edit), heard)
        return true
    }

    /// Lengths of earlier phrases no longer match the text, so "scratch that" can't undo by length any more.
    private func forgetTypedLengths() {
        segments.removeAll()
        typedTail = nil
    }

    /// The end of the text (its last 40 UTF-16 units), trimmed, to recognise "the cursor is still where I typed" later.
    static func tail(_ text: String) -> [UInt16]? {
        let trimmed = Array(DotNet.trimEnd(TextEditing.normalizeNewLines(text)).utf16)
        return trimmed.isEmpty ? nil : Array(trimmed.suffix(40))
    }

    func boardNow() -> Date { parser.boardClock() }

    /// In standby, whether a quick, rough transcript of the start of a phrase is worth transcribing in full: it may
    /// hold the wake word, or it is a command said without it (which gets a hint). Everything else (conversation,
    /// videos, meetings) is ignored after the quick pass, which keeps always-on listening cheap. `cutShort`: the quick
    /// pass saw only the start of the phrase, so a long command may not parse yet.
    public func worthTranscribingInStandby(_ rough: String, cutShort: Bool = false) -> Bool {
        !options.wakeWordEnabled || parser.mayContainWakeWord(rough) || isCommandWithoutWakeWord(rough)
            || (cutShort && CommandParser.mayStartCommand(rough))
    }

    // "yes", "no", "two" are everyday words: no hint for those.
    private func isCommandWithoutWakeWord(_ transcript: String) -> Bool {
        parser.parse(transcript, .command).commands.contains {
            ![.confirm, .cancel, .choose, .showNumbers, .hideNumbers].contains($0.kind)
        }
    }

    /// Adds to the idea board, opens it, or ticks an item off; says what happened.
    func executeBoard(_ intent: BoardIntent, _ heard: String, noTextBox: Bool = false) throws -> Bool {
        guard let board else {
            report(.warning, "The idea board isn't available.", heard)
            return false
        }

        switch intent.action {
        case .add:
            let list = intent.list ?? .ideas
            let item = try board.add(list, intent.text, due: intent.due)
            let timed = item.due == nil ? "" : " with time"
            trace("board add \(list.rawValue)\(timed)\(noTextBox ? " (no text box)" : "")")
            let lead = noTextBox ? "No text box, so I saved it. " : ""
            let message: String
            if let due = item.due {
                let now = boardNow()
                let soon = due > now && due.timeIntervalSince(now) < 3600
                message = "Reminder \(soon ? "" : "for ")\(Self.describeDue(due, now, parser.boardTimeZone)): "
                    + "“\(Self.short(item.text, 50))”."
            } else {
                message = "Added to \(Self.listName(list)): “\(Self.short(item.text, 50))”."
            }

            report(.success, lead + message, heard)
            return true
        case .show:
            onShowBoardRequested?(intent.list)
            report(.info, intent.list.map { "Opening \(Self.listName($0))." } ?? "Opening your idea board.", heard)
            return true
        case .complete:
            let done = try board.completeMatching(intent.text, list: intent.list)
            report(
                done == nil ? .warning : .success,
                done.map { "Done: “\(Self.short($0.text, 50))”." }
                    ?? "I couldn't find “\(Self.short(intent.text, 40))” on your board.",
                heard)
            return done != nil
        }
    }

    private static func listName(_ list: BoardList) -> String {
        switch list {
        case .ideas: return "Ideas"
        case .brainstorm: return "Brainstorm"
        case .todo: return "To-do"
        case .reminders: return "Reminders"
        }
    }

    /// "today 5:00 PM", "tomorrow 9:00 AM", "Fri 13 Nov 10:00 AM", "in 10 min", on the wall clock of `timeZone`.
    public static func describeDue(_ due: Date, _ now: Date, _ timeZone: TimeZone) -> String {
        if due > now && due.timeIntervalSince(now) < 3600 {
            let minutes = (due.timeIntervalSince(now) / 60).rounded(.toNearestOrEven)
            return "in \(max(1, Int(minutes))) min"
        }

        let time = invariantDate(due, "h:mm a", timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return "today \(time)"
        case 1: return "tomorrow \(time)"
        default: return invariantDate(due, "EEE d MMM ", timeZone) + time
        }
    }

    /// The date as `DateTime.ToString(format, CultureInfo.InvariantCulture)` writes it (English names, "AM" and "PM").
    private static func invariantDate(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func describeEdit(_ edit: TextEdit) -> String {
        if let phrase = edit.phrase {
            return edit.replacement.map { "Replaced “\(short(phrase, 30))” with “\(short($0, 30))”." }
                ?? "Deleted “\(short(phrase, 40))”."
        }

        let unit = "\(edit.unit)"
        return edit.count == 1 ? "Deleted the last \(unit)." : "Deleted the last \(edit.count) \(unit)s."
    }

    var newLineKeys: String { targetProfile?.newLineKeys ?? "Shift+Enter" }

    func open(_ spokenName: String, newWindow: Bool, _ heard: String) async throws -> Bool {
        switch apps.resolve(spokenName) {
        case .found(let app):
            report(.info, "Opening \(app.name)…", heard)
            let result = try await desktop.openOrActivate(app, newWindow: newWindow)
            if result.success {
                memory?.recordAppUse(app.name)
                onMemoryChanged?()
            }

            guard let opened = result.window else {
                if result.success {
                    // Launched, but which window is the app isn't known, so "start typing" isn't chained into a guess.
                    report(.info, "\(result.message) Say “start typing” when it's ready.", heard)
                    return false
                }

                report(.warning, result.message, heard)
                return false
            }

            if result.success {
                setPlace(opened, placeOf(opened, apps.findProfileForProcess(opened.processName, opened.title)))
            }

            report(result.success ? .success : .warning, result.message, heard, place: result.success ? place : nil)
            return result.success
        case .ambiguous(let names):
            report(.warning, "Which one? \(names.prefix(4).joined(separator: ", "))", heard)
            return false
        case .notFound:
            report(.warning, "I couldn't find an app called “\(spokenName)”.", heard)
            return false
        }
    }

    private func startTyping(_ heard: String) async throws -> Bool {
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window to type into.", heard)
            return false
        }

        let profile = apps.findProfileForProcess(window.processName, window.title)
        let prepared = try await desktop.prepareTextTarget(window, profile: profile)
        if !prepared.success {
            report(.warning, prepared.message, heard)
            return false
        }

        if profile?.searchKeys != nil && profile?.textArea == nil && prepared.focusIsEditable == false {
            // Browsers: a known site's box ("start typing" on YouTube is its search box), then the page's own text
            // boxes (the only one, or ask which), else the address or search bar.
            if let site = SiteProfile.forTitle(window.title), try await focusSiteBox(window, site, heard) {
                return true
            }

            if let pickedInPage = try await pickTextBox(window, heard, browser: true) {
                return pickedInPage
            }

            return try await focusSearch(heard, addressBar: false)
        }

        if profile?.textArea == nil && prepared.focusIsEditable == false {
            // Nothing editable has the focus in an app with no profile: pick its text box, or ask which.
            if let picked = try await pickTextBox(window, heard) {
                return picked
            }
        }

        bindTarget(window, profile, boxHadText: prepared.hasTrailingText == true, searchField: false)
        setPlace(window, placeOf(window, profile))
        report(
            .success,
            "Typing into “\(profile?.name ?? displayName(window))”. Say “stop typing” when done.",
            heard,
            place: place)
        return true
    }

    func focusSearch(_ heard: String, addressBar: Bool) async throws -> Bool {
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window in front.", heard)
            return false
        }

        let profile = apps.findProfileForProcess(window.processName, window.title)
        let name = profile?.name ?? displayName(window)
        if let boxKeys = addressBar ? profile?.addressBarKeys : profile?.searchKeys {
            if !checkField(heard, nil, allowUnknown: true) {
                return false
            }

            try desktop.pressKeys(boxKeys)
            try await Task.sleep(nanoseconds: 150_000_000)
        } else if addressBar {
            report(.warning, "\(name) doesn't have an address bar I know.", heard)
            return false
        } else {
            let focused = try await desktop.focusSearchBox(window)
            if !focused.success {
                report(.warning, focused.message, heard)
                return false
            }
        }

        bindTarget(window, profile, boxHadText: false, searchField: true)
        setPlace(window, "\(placeOf(window, profile)) › \(addressBar ? "Address bar" : "Search")")
        report(
            .success,
            addressBar
                ? "In the address bar. Say where to go, then “search”."
                : "In the search box. Say what to search for, then “search”.",
            heard,
            place: place)
        return true
    }

    func bindTarget(_ window: WindowInfo, _ profile: AppEntry?, boxHadText: Bool, searchField: Bool) {
        clearPending()
        target = window
        targetProfile = profile
        segments.removeAll()
        typedTail = nil
        self.boxHadText = boxHadText
        needsLeadingSpace = boxHadText
        endsSentence = true
        self.searchField = searchField
        mode = .dictation
    }

    /// A shortcut or "press …" command. With the Mac's keys, back and forward (⌘[ and ⌘]) change the indentation or
    /// list level in many apps, so they're pressed only in a browser or the file manager (ShortcutKeys says why).
    private func pressChord(_ chord: String, _ heard: String) throws -> Bool {
        if mode == .dictation {
            if !ensureTargetFocused(heard, nil) {
                return false
            }
        } else if desktop.foregroundWindow() == nil {
            report(.warning, "There's no window in front.", heard)
            return false
        }

        if let refusal = backForwardRefusal(chord, keys) {
            trace("back or forward refused outside a browser")
            report(.warning, refusal, heard)
            return false
        }

        if !checkField(heard, nil, allowUnknown: true) {
            return false
        }

        try desktop.pressKeys(chord)

        // Keys can move the cursor or change the text, so earlier phrases can no longer be undone by length.
        segments.removeAll()
        typedTail = nil
        report(.success, "Pressed \(chord).", heard)
        return true
    }

    /// Why back or forward (as `keys` names them) isn't pressed in the front window, or nil if it may be: only with
    /// keys that act elsewhere too (`ShortcutKeys.backForwardInBrowsersOnly`) and outside a browser and the file
    /// manager.
    func backForwardRefusal(_ chord: String, _ keys: ShortcutKeys) -> String? {
        guard keys.backForwardInBrowsersOnly, DotNet.equalsOrdinalIgnoreCase(chord, keys.back)
            || DotNet.equalsOrdinalIgnoreCase(chord, keys.forward), let window = desktop.foregroundWindow()
        else { return nil }

        let platform = desktop.brainPlatform
        let profile = apps.findProfileForProcess(window.processName, window.title)
        if isBrowser(window, profile) || platform.isFileManager(window.processName) {
            return nil
        }

        let back = DotNet.equalsOrdinalIgnoreCase(chord, keys.back)
        return "\(back ? "Back" : "Forward") works in browsers and \(platform.fileManagerName)."
    }

    private func send(_ heard: String, _ doneMessage: String) throws -> Bool {
        if target == nil {
            report(.warning, "Say “start typing” first.", heard)
            return false
        }

        if !ensureTargetFocused(heard, nil) {
            return false
        }

        let submitKeys = targetProfile?.submitKeys ?? "Enter"
        if DotNet.isNullOrWhiteSpace(submitKeys) {
            report(.warning, "\(targetProfile?.name ?? "") has no send action.", heard)
            return false
        }

        try desktop.pressKeys(submitKeys)
        segments.removeAll()
        typedTail = nil
        boxHadText = false
        needsLeadingSpace = false
        endsSentence = true
        if mode == .dictation && options.returnToCommandModeAfterSend {
            awake()
        }

        report(.success, doneMessage, heard)
        return true
    }

    /// Formats and types dictated text into the bound target. False if nothing was typed.
    func typeDictated(_ text: String, _ heard: String) throws -> Bool {
        if !ensureTargetFocused(heard, text) {
            return false
        }

        if !checkField(heard, text, allowUnknown: false) {
            return false
        }

        let formatted = formatter.format(text, continuesSentence: !endsSentence, searchField: searchField)
        if formatted.isEmpty {
            return false
        }

        let toType = needsLeadingSpace && formatted.utf16.first != 0x0A ? " " + formatted : formatted
        segments.append(try typeWithNewLines(toType, newLineKeys))
        typedTail = Self.tail(toType) ?? typedTail
        needsLeadingSpace = !Self.endsWithWhiteSpace(toType)
        endsSentence = Self.endsWithAny(toType, ".!?\n:")
        lastTranscript = formatted
        report(.success, "Typed.", heard)
        return true
    }

    private func insertIntoFocused(_ formatted: String, _ heard: String?, fileIfNoTextBox: Bool = false) throws {
        let front = desktop.foregroundWindow()
        let check = front == nil ? nil : desktop.checkFocusedField()
        if fileIfNoTextBox && board != nil && (front == nil || check == .notText) {
            // Nowhere to type: keep the thought on the idea board rather than lose it.
            guard let note = BoardGrammar.forDictation(formatted, now: boardNow(), timeZone: parser.boardTimeZone)
            else {
                report(.info, "I didn't catch anything to save.", heard)
                return
            }

            _ = try executeBoard(note, heard ?? formatted, noTextBox: true)
            lastTranscript = formatted
            return
        }

        guard let window = front else {
            report(.warning, "There's no window to type into.", heard)
            return
        }

        if !checkField(heard ?? "", formatted, allowUnknown: true, known: check) {
            return
        }

        let profile = apps.findProfileForProcess(window.processName, window.title)
        let leadingSpace = desktop.focusedTextEndsWithNonWhitespace() == true && formatted.utf16.first != 0x0A
        _ = try typeWithNewLines(leadingSpace ? " " + formatted : formatted, profile?.newLineKeys ?? "Shift+Enter")

        // Push-to-talk text isn't part of the voice "scratch that" history.
        segments.removeAll()
        typedTail = nil
        lastTranscript = formatted
        report(.success, "Typed.", heard)
    }

    /// Types the text, pressing the new-line keys for each line break. The count of text elements and line breaks.
    func typeWithNewLines(_ text: String, _ newLineKeys: String) throws -> Int {
        var count = 0
        for (i, part) in DotNet.split(text, ["\n"]).enumerated() {
            if i > 0 {
                try desktop.pressKeys(newLineKeys)
                count += 1
            }

            if !part.isEmpty {
                try desktop.typeText(part)
                count += NetText.textElementCount(part)
            }
        }

        return count
    }

    /// Refuses password fields and windows that can't take this app's input (on Windows, administrator windows), in the
    /// platform's words, and, unless allowed, fields that can't be checked.
    func checkField(_ heard: String, _ pendingText: String?, allowUnknown: Bool, known: AssistantFieldCheck? = nil)
        -> Bool {
        let check = known ?? desktop.checkFocusedField()
        let refused: String?
        switch check {
        case .password:
            refused = "That's a password field — I won't type there."
        case .elevated:
            refused = desktop.brainPlatform.elevatedRefusal
        case .unknown where !allowUnknown:
            refused = "I couldn't check the focused field, so nothing was typed. The text is in the tray menu."
        default:
            refused = nil
        }

        guard let refusal = refused else { return true }
        if let pendingText, check == .unknown {
            keepUntyped(pendingText)
        }

        report(.warning, refusal, heard)
        return false
    }

    /// Refuses to act if the bound window is no longer in front, keeping any dictated text in memory.
    func ensureTargetFocused(_ heard: String, _ pendingText: String?) -> Bool {
        let foreground = desktop.foregroundWindow()
        if let target, target.sameWindow(foreground) {
            return true
        }

        if let pendingText {
            keepUntyped(pendingText)
        }

        if mode == .dictation {
            awake()
        }

        report(
            .warning,
            pendingText == nil
                ? "Focus moved to another window, so I didn't do that. Say “start typing” to continue."
                : "Focus moved to another window, so nothing was typed. Say “start typing” to continue.",
            heard)
        return false
    }

    private func keepUntyped(_ text: String) {
        untypedText = untypedText.map { $0.isEmpty ? text : $0 + " " + text } ?? text
    }

    func awake() {
        mode = .command
        awakeSince = options.clock()
    }

    private func expireAwake() -> Bool {
        if options.wakeWordEnabled && mode == .command
            && options.clock().timeIntervalSince(awakeSince) > options.awakeTimeout {
            mode = .standby
            return true
        }

        return false
    }

    /// What the pill calls a window without a profile: on Windows its title, which names the app there ("Untitled -
    /// Notepad"), else its process; on the Mac, where titles don't, its app's name (`macAppName`), else its title.
    func displayName(_ window: WindowInfo) -> String {
        if desktop.brainPlatform.kind == .mac, let app = macAppName(window) {
            return app
        }

        return DotNet.isNullOrWhiteSpace(window.title) ? window.processName : window.title
    }

    func report(_ kind: StatusKind, _ message: String, _ heard: String? = nil, place: String? = nil) {
        onStatus?(AssistantStatus(mode: mode, kind: kind, message: message, heard: heard, place: place))
    }

    func trace(_ text: String) {
        onTrace?(text)
    }

    /// A command kind as the C# writes it in traces ("OpenApp").
    static func name(of kind: CommandKind) -> String { DotNet.upperFirst("\(kind)") }

    /// `text[^1]` is white space (a half of a surrogate pair isn't).
    static func endsWithWhiteSpace(_ text: String) -> Bool {
        guard let last = text.utf16.last, let scalar = Unicode.Scalar(last) else { return false }
        return DotNet.isWhiteSpace(scalar)
    }

    /// `text[^1]` is one of `characters` (ASCII).
    static func endsWithAny(_ text: String, _ characters: String) -> Bool {
        guard let last = text.utf16.last else { return false }
        return characters.utf16.contains(last)
    }

    /// At most `max` UTF-16 units, cut with "…" (half of an emoji cut off is U+FFFD, as in `BrainSafety.cleanText`).
    static func short(_ text: String, _ max: Int) -> String {
        let units = Array(text.utf16)
        if units.count <= max {
            return text
        }

        return DotNet.trimEnd(NetText.string(utf16: units[..<Swift.max(0, max - 1)])) + "…"
    }
}

/// The brain's running flag and change count, which other threads read (C#'s `Volatile` and `Interlocked`).
final class BrainActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var changes = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    func set(running: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.running = running
        changes += 1
    }
}

/// Thrown by the interaction controller's `handleTranscript`, `insertDictation` and `repeatLastTranscript` when they
/// start while another of its calls is still running, which its contract rules out: the call did nothing. For speech
/// the host says "Still working on your last request." and never queues it; for push-to-talk it keeps the text.
public struct ControllerBusy: Error, Equatable, Sendable {
    /// The call that did nothing ("insertDictation").
    public let call: String
}

/// Whether a public call of the interaction controller is running, so one that overlaps it can be caught.
final class CallGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    /// Marks a call as running: false if one already is.
    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running {
            return false
        }

        running = true
        return true
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        running = false
    }
}
