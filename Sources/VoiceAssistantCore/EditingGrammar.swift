import ThumbFreeCore

/// The editing grammar: erase or replace part of what was typed. While typing (no wake word) only unusual, explicit
/// forms are commands ("delete the last two words", "delete the word very", "replace the word Monday with Tuesday"),
/// so ordinary sentences are still typed. After the wake word, "replace X with Y" and "change X to Y" work too.
/// See windows-voice-assistant docs/specs/voice-commands.md.
extension CommandParser {
    private static let maxEditCount = 50

    private static let editUnits = OrdinalMap<EditUnit>([
        ("word", .word), ("words", .word), ("sentence", .sentence), ("sentences", .sentence), ("line", .line),
        ("lines", .line), ("paragraph", .paragraph), ("paragraphs", .paragraph), ("character", .character),
        ("characters", .character), ("letter", .character), ("letters", .character),
    ])

    static func matchEdit(_ n: String, lenient: Bool) -> VoiceCommand? {
        // "delete the last three words", "erase the previous sentence", "remove last line", "delete the last word"
        if let m = lastUnitsRegex.match(n), let count = parseEditCount(m.group(named: "count")),
           let unit = editUnits[m.group(named: "unit")] {
            return VoiceCommand(.deleteText, edit: TextEdit(unit: unit, count: count))
        }

        // "delete three words", "delete 2 sentences" (a number is required, so "delete words" stays text)
        if let m = countUnitsRegex.match(n), let count = parseEditCount(m.group(named: "count")),
           let unit = editUnits[m.group(named: "unit")] {
            return VoiceCommand(.deleteText, edit: TextEdit(unit: unit, count: count))
        }

        // "delete that sentence", "remove this line"
        if let m = thatUnitRegex.match(n), let unit = editUnits[m.group(named: "unit")] {
            return VoiceCommand(.deleteText, edit: TextEdit(unit: unit, count: 1))
        }

        // "delete the word very", "remove the words as soon as possible"
        if let m = deleteWordRegex.match(n) {
            return VoiceCommand(.deleteText, edit: TextEdit(phrase: m.group(named: "phrase")))
        }

        // "replace the word monday with tuesday" (always); "replace monday with tuesday", "change monday to tuesday"
        // (only after the wake word: "change the plan to friday" is a normal sentence)
        if let m = (lenient ? replaceRegex : replaceWordRegex).match(n) {
            return VoiceCommand(
                .replaceText, m.group(named: "link"),
                edit: TextEdit(phrase: m.group(named: "phrase"), replacement: m.group(named: "with")))
        }

        // After the wake word: "delete very". "erase the word" is too vague, but "delete monday" names a word.
        if lenient, let m = deletePhraseRegex.match(n) {
            let phrase = m.group(named: "phrase")
            if !editUnits.contains(phrase) && !vagueObjects.contains(phrase) && !DotNet.startsWith(phrase, "the word")
                && !DotNet.startsWith(phrase, "the phrase") {
                return VoiceCommand(.deleteText, edit: TextEdit(phrase: phrase))
            }
        }

        return nil
    }

    private static let vagueObjects = OrdinalSet(["that", "this", "it", "everything", "all"])

    /// Edits are matched before polite words are trimmed from the end: "delete see you again" must not lose "again".
    /// Leading padding ("can you please …") is still removed.
    static func withUntrimmedEdit(_ commands: [VoiceCommand]?, _ normalized: String) -> [VoiceCommand]? {
        if let commands, !isOneEdit(commands) {
            return commands
        }

        var text = normalized
        var changed: Bool
        repeat {
            changed = false
            for prefix in politePrefixes where DotNet.startsWith(text, prefix + " ") {
                text = DotNet.trimStart(DotNet.dropPrefix(text, prefix + " "))
                changed = true
            }
        } while changed && !text.isEmpty

        return matchEdit(text, lenient: true).map { [$0] } ?? commands
    }

    private static func isOneEdit(_ commands: [VoiceCommand]) -> Bool {
        commands.count == 1 && (commands[0].kind == .deleteText || commands[0].kind == .replaceText)
    }

    private static func parseEditCount(_ text: String) -> Int? {
        let text = DotNet.trim(text)
        if text.isEmpty {
            return 1
        }

        if DotNet.ordinalEquals(text, "few") || DotNet.ordinalEquals(text, "a few") {
            return 3
        }

        if NetText.contains(["couple of", "a couple of", "couple", "a couple"], text) {
            return 2
        }

        let value = NetText.parseInteger(text) ?? numberWords[text] ?? 0
        return value >= 1 && value <= maxEditCount ? value : nil
    }

    /// The replacement as it was said, with its capitals and punctuation ("with GitHub Actions." is "GitHub Actions").
    /// The normalized one is kept if the original can't be found. Searched right to left, as in C#.
    static func withSpokenReplacement(_ commands: [VoiceCommand], _ cleaned: String) -> [VoiceCommand] {
        guard commands.count == 1, var command = commands.first, command.kind == .replaceText,
              let edit = command.edit, let link = command.argument,
              let regex = RightToLeftRegex(#"\b"# + NetRegex.escape(link) + #"\b\s+(?<rest>.+)$"#, .ignoreCase),
              let m = regex.match(cleaned)
        else { return commands }

        let spoken = DotNet.trim(DotNet.trimEnd(DotNet.trim(m.group(named: "rest")), [".", "!", "?", ","]))
        if !DotNet.ordinalEquals(TranscriptText.normalize(spoken), TranscriptText.normalize(edit.replacement ?? "")) {
            return commands
        }

        command.edit?.replacement = spoken
        return [command]
    }

    // MARK: Patterns: EditingGrammar.cs's, verbatim (NetRegex translates them)

    private static let editVerbPattern = "(?:delete|erase|remove|scratch|undo)"

    private static let countPattern =
        #"(?<count>\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen"#
        + #"|sixteen|seventeen|eighteen|nineteen|twenty|a few|few|a couple of|couple of)"#

    private static let unitPattern = "(?<unit>words?|sentences?|lines?|paragraphs?|characters?|letters?)"

    private static let lastUnitsRegex = NetRegex(
        "^" + editVerbPattern + " (?:the )?(?:last|previous|past) (?:" + countPattern + " )?" + unitPattern + "$")

    private static let countUnitsRegex =
        NetRegex("^(?:delete|erase|remove) " + countPattern + " " + unitPattern + "$")

    private static let thatUnitRegex = NetRegex("^" + editVerbPattern + " (?:that|this) " + unitPattern + "$")

    private static let deleteWordRegex = NetRegex("^(?:delete|erase|remove) the (?:word|words|phrase) (?<phrase>.+)$")

    private static let replaceWordRegex =
        NetRegex("^replace the (?:word|words|phrase) (?<phrase>.+?) (?<link>with) (?<with>.+)$")

    private static let replaceRegex = NetRegex(
        "^(?:replace|change)(?: the (?:word|words|phrase))? (?<phrase>.+?) (?<link>with|to|into|by) (?<with>.+)$")

    private static let deletePhraseRegex = NetRegex("^(?:delete|erase|remove) (?<phrase>.+)$")
}
