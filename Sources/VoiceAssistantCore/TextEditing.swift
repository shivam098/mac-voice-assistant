import ThumbFreeCore

public enum EditUnit: Sendable {
    case character
    case word
    case sentence
    case line
    case paragraph
}

/// A spoken edit: "delete the last 3 words" (unit and count), "delete the word very" (phrase), or "replace Monday with
/// Tuesday" (phrase and replacement). Phrases are normalized (lower case, no punctuation); the replacement keeps what
/// was said.
public struct TextEdit: Hashable, Sendable {
    public var unit: EditUnit
    public var count: Int
    public var phrase: String?
    public var replacement: String?

    public init(unit: EditUnit = .word, count: Int = 1, phrase: String? = nil, replacement: String? = nil) {
        self.unit = unit
        self.count = count
        self.phrase = phrase
        self.replacement = replacement
    }
}

/// The keys for an edit, worked out from the text before the cursor: move left past `keepAfter` text elements, select
/// `delete` elements to the left (Shift+Left), then delete them or type `insert` over them, then move right again.
/// Selecting with the arrow keys keeps movement and deletion in the units the app uses (Backspace alone deletes one
/// code point in some scripts).
public struct EditPlan: Hashable, Sendable {
    public var keepAfter: Int
    public var delete: Int
    public var insert: String
    public var textAfterEdit: String

    /// The (normalized) text that was removed, for "Deleted …" messages.
    public var removed: String

    public init(keepAfter: Int, delete: Int, insert: String, textAfterEdit: String, removed: String = "") {
        self.keepAfter = keepAfter
        self.delete = delete
        self.insert = insert
        self.textAfterEdit = textAfterEdit
        self.removed = removed
    }
}

/// Turns spoken edits into exact keys. Works on the text before the cursor (line ends as "\n"), counts text elements
/// (Swift `Character`s, .NET's text elements: an emoji or an accented letter is one Backspace), and never looks further
/// back than it was given. Positions are UTF-16 offsets, as in C#. The same rules apply on every platform; only
/// reading the text and pressing keys are the platform's.
public enum TextEditing {
    /// The furthest an edit may reach back, in text elements: arrow-key edits further than this are refused.
    public static let maxReach = 3000

    public static func normalizeNewLines(_ text: String) -> String {
        DotNet.replace(DotNet.replace(text, "\r\n", "\n"), "\r", "\n")
    }

    /// Deletes the last `count` units before the cursor. Nil if there is nothing to delete.
    public static func deleteLast(_ before: String, _ unit: EditUnit, _ count: Int) -> EditPlan? {
        let text = Array(normalizeNewLines(before).utf16)
        let end = text.count
        var cut = end
        var done = 0
        while done < count && cut > 0 {
            switch unit {
            case .character: cut = previousTextElement(text, cut)
            case .word: cut = previousWordStart(text, cut)
            case .sentence: cut = previousSentenceStart(text, cut)
            case .line: cut = previousLineStart(text, cut)
            case .paragraph: cut = previousParagraphStart(text, cut)
            }

            done += 1
        }

        if unit != .character {
            // Take the spaces before the deleted text too, so the cursor sits right after the previous word.
            while cut > 0 && (text[cut - 1] == space || text[cut - 1] == tab) {
                cut -= 1
            }
        }

        let removed = NetText.string(utf16: text[cut...])
        if cut >= end || ((unit == .word || unit == .sentence) && DotNet.trim(removed).isEmpty) {
            return nil
        }

        let elements = removed.count
        if elements > maxReach {
            return nil
        }

        return EditPlan(
            keepAfter: 0, delete: elements, insert: "", textAfterEdit: NetText.string(utf16: text[..<cut]),
            removed: DotNet.trim(removed))
    }

    /// Finds the last whole-word occurrence of `phrase` before the cursor and removes it (with one neighbouring space)
    /// or replaces it. Nil if it isn't there or is too far back.
    public static func replaceLast(_ before: String, _ phrase: String, _ replacement: String?) -> EditPlan? {
        let normalized = normalizeNewLines(before)
        guard let match = findLast(normalized, phrase) else { return nil }
        let text = Array(normalized.utf16)
        var start = match.start
        var end = match.start + match.length
        let found = NetText.string(utf16: text[start..<end])
        let insert: String
        if let replacement, !replacement.isEmpty {
            insert = matchCase(found, DotNet.trim(replacement))
        } else {
            insert = ""

            // "very good" becomes "good": drop the space before (or, at the start of a line, the one after).
            if start > 0 && text[start - 1] == space {
                start -= 1
            } else if end < text.count && text[end] == space {
                end += 1
            }
        }

        let after = NetText.string(utf16: text[end...])
        let removed = NetText.string(utf16: text[start..<end])
        let keepAfter = after.count
        if keepAfter + removed.count > maxReach {
            return nil
        }

        return EditPlan(
            keepAfter: keepAfter, delete: removed.count, insert: insert,
            textAfterEdit: NetText.string(utf16: text[..<start]) + insert + after, removed: found)
    }

    /// The start and length (in UTF-16 code units) of the last whole-word, case-insensitive match of a normalized
    /// phrase. Each word may carry the apostrophes and hyphens that normalizing removed ("dont" finds "don't"), and
    /// words may be separated by spaces, hyphens or punctuation. Searched right to left, as in C#.
    public static func findLast(_ text: String, _ phrase: String) -> (start: Int, length: Int)? {
        let words = NetText.words(TranscriptText.normalize(phrase))
        if words.isEmpty {
            return nil
        }

        let pattern = words
            .map { word in word.unicodeScalars.map { NetRegex.escape(String($0)) }.joined(separator: #"['’\-]?"#) }
            .joined(separator: #"[\s\p{P}]+"#)
        guard let regex = RightToLeftRegex(#"(?<![\p{L}\p{N}])"# + pattern + #"(?![\p{L}\p{N}])"#, .ignoreCase),
              let match = regex.match(text)
        else { return nil }
        return (match.start, match.length)
    }

    /// Keeps a capital at the start of a sentence: replacing "Monday" with "tuesday" types "Tuesday".
    private static func matchCase(_ found: String, _ replacement: String) -> String {
        guard let first = found.unicodeScalars.first, let next = replacement.unicodeScalars.first else {
            return replacement
        }

        let letters = found.unicodeScalars.filter { DotNet.isLetter($0) }
        if letters.allSatisfy({ DotNet.isUpper($0) }) && letters.count > 1 {
            return DotNet.upperInvariant(replacement)
        }

        return DotNet.isUpper(first) && DotNet.isLower(next) ? DotNet.upperFirst(replacement) : replacement
    }

    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let newLine: UInt16 = 0x0A

    /// `char.IsWhiteSpace` for one UTF-16 code unit (a surrogate isn't).
    private static func isWhiteSpace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { DotNet.isWhiteSpace($0) } ?? false
    }

    private static func previousTextElement(_ text: [UInt16], _ end: Int) -> Int {
        guard let last = NetText.string(utf16: text[..<end]).last else { return 0 }
        return end - last.utf16.count
    }

    /// A word is a run of non-space characters, with the punctuation attached to it ("world.").
    private static func previousWordStart(_ text: [UInt16], _ end: Int) -> Int {
        var i = end
        while i > 0 && isWhiteSpace(text[i - 1]) {
            i -= 1
        }

        while i > 0 && !isWhiteSpace(text[i - 1]) {
            i -= 1
        }

        return i
    }

    private static let sentenceEnds: Set<UInt16> = [0x2E, 0x21, 0x3F] // . ! ?

    // A sentence's own closing punctuation: . ! ? " ” )
    private static let closers: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x22, 0x201D, 0x29]

    /// Back to just after the previous ". ", "? ", "! " or line break.
    private static func previousSentenceStart(_ text: [UInt16], _ end: Int) -> Int {
        var i = end
        while i > 0 && isWhiteSpace(text[i - 1]) {
            i -= 1
        }

        // Skip this sentence's own closing punctuation.
        while i > 0 && closers.contains(text[i - 1]) {
            i -= 1
        }

        while i > 0 {
            let c = text[i - 1]
            if c == newLine || (sentenceEnds.contains(c) && i < text.count && isWhiteSpace(text[i])) {
                break
            }

            i -= 1
        }

        return i
    }

    /// The whole last line, including the line break before it (so the cursor ends on the line above).
    private static func previousLineStart(_ text: [UInt16], _ end: Int) -> Int {
        var i = end
        while i > 0 && (text[i - 1] == space || text[i - 1] == tab) {
            i -= 1
        }

        if i > 0 && text[i - 1] == newLine {
            // The cursor is on an empty line: that line is the one to delete.
            return i - 1
        }

        if i == 0 {
            return 0
        }

        return lastNewLine(text, from: i - 1) ?? 0
    }

    /// Back to the previous blank line or, in editors that separate paragraphs with a single line break (Word, most
    /// chat and mail apps), the previous line break.
    private static func previousParagraphStart(_ text: [UInt16], _ end: Int) -> Int {
        var i = end
        while i > 0 && isWhiteSpace(text[i - 1]) {
            i -= 1
        }

        if i == 0 {
            return 0
        }

        guard var lineBreak = lastNewLine(text, from: i - 1) else { return 0 }

        // Take the blank lines that separated it from the paragraph before.
        while lineBreak > 0 && text[lineBreak - 1] == newLine {
            lineBreak -= 1
        }

        return lineBreak
    }

    /// `text.LastIndexOf('\n', start)`: the last line break at or before `start`.
    private static func lastNewLine(_ text: [UInt16], from start: Int) -> Int? {
        text[...start].lastIndex(of: newLine)
    }
}
