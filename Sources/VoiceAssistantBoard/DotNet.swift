import Foundation

/// Text rules as .NET applies them, for code ported from windows-voice-assistant `src/VoiceAssistant.Board`. They work
/// on Unicode scalars, the closest Swift unit to .NET's UTF-16 `char` here, rather than on Swift's `Character`
/// (grapheme clusters, full case mapping, canonically equivalent strings comparing equal).
///
/// thumbfree-mac has the same rules for its C# core, in `Sources/ThumbFreeCore/DotNet.swift`. The board depends on
/// nothing, so it keeps its own copy: the two must stay in step, with the same casing and ignore-case rules and names.
enum DotNet {
    // MARK: Characters

    /// `char.IsWhiteSpace`: Unicode's White_Space property is the same set (Zs, Zl, Zp, U+0009–U+000D, U+0085).
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    /// `char.ToUpperInvariant`: the simple (one-to-one) uppercase mapping, so "ß" stays "ß" instead of becoming "SS".
    /// Where the full mapping adds a letter ("ᾀ" → "ἈΙ"), the simple one is the one-letter title case ("ᾈ"). As in
    /// .NET, the Turkish dotless "ı" keeps its case.
    static func toUpperInvariant(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar == "\u{131}" {
            return scalar
        }

        let upper = scalar.properties.uppercaseMapping.unicodeScalars
        if upper.count == 1 {
            return upper.first!
        }

        let title = scalar.properties.titlecaseMapping.unicodeScalars
        return title.count == 1 ? title.first! : scalar
    }

    /// `char.ToLowerInvariant`: the simple lowercase mapping ("İ", whose full mapping is two scalars, keeps its case).
    static func toLowerInvariant(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first! : scalar
    }

    /// The case `StringComparison.OrdinalIgnoreCase` compares: the simple uppercase, except that "ſ" isn't "S".
    private static func ordinalUpper(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        scalar == "\u{17F}" ? scalar : toUpperInvariant(scalar)
    }

    // MARK: Case

    /// `string.ToUpperInvariant()`.
    static func upperInvariant(_ text: String) -> String { string(text.unicodeScalars.map { toUpperInvariant($0) }) }

    /// `string.ToLowerInvariant()`.
    static func lowerInvariant(_ text: String) -> String { string(text.unicodeScalars.map { toLowerInvariant($0) }) }

    // MARK: Trimming and replacing

    /// `string.Trim()`.
    static func trim(_ text: String) -> String { trim(text, while: isWhiteSpace) }

    /// `string.Trim(params char[])`: those characters only, from both ends.
    static func trim(_ text: String, _ characters: Set<Unicode.Scalar>) -> String {
        trim(text) { characters.contains($0) }
    }

    /// `string.TrimEnd(params char[])`.
    static func trimEnd(_ text: String, _ characters: Set<Unicode.Scalar>) -> String {
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !characters.contains($0) }) else { return "" }
        return String(String.UnicodeScalarView(scalars[...last]))
    }

    /// `string.Replace(char, char)`.
    static func replace(_ text: String, _ old: Unicode.Scalar, with new: Unicode.Scalar) -> String {
        string(text.unicodeScalars.map { $0 == old ? new : $0 })
    }

    private static func trim(_ text: String, while drop: (Unicode.Scalar) -> Bool) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !drop($0) }), let last = scalars.lastIndex(where: { !drop($0) })
        else { return "" }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    // MARK: Ordinal comparison

    /// `a == b` in C#: the same scalars.
    static func ordinalEquals(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// `text.StartsWith(prefix, StringComparison.Ordinal)`.
    static func startsWith(_ text: String, _ prefix: String) -> Bool {
        text.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `text.Contains(value, StringComparison.Ordinal)`.
    static func contains(_ text: String, _ value: String) -> Bool { contains(ordinal(text), ordinal(value)) }

    /// `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`: scalar by scalar after the simple uppercase mapping.
    static func equalsOrdinalIgnoreCase(_ a: String, _ b: String) -> Bool {
        ordinalIgnoreCase(a) == ordinalIgnoreCase(b)
    }

    /// `text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)`.
    static func startsWithOrdinalIgnoreCase(_ text: String, _ prefix: String) -> Bool {
        ordinalIgnoreCase(text).starts(with: ordinalIgnoreCase(prefix))
    }

    /// `text.Contains(value, StringComparison.OrdinalIgnoreCase)`.
    static func containsOrdinalIgnoreCase(_ text: String, _ value: String) -> Bool {
        contains(ordinalIgnoreCase(text), ordinalIgnoreCase(value))
    }

    /// A key for a `Set` or `Dictionary` that compares as `StringComparer.Ordinal` does.
    static func ordinal(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    /// A key for a `Set` or `Dictionary` that compares as `StringComparer.OrdinalIgnoreCase` does.
    static func ordinalIgnoreCase(_ text: String) -> [Unicode.Scalar] { text.unicodeScalars.map { ordinalUpper($0) } }

    /// Whether `target` occurs in `source`.
    private static func contains(_ source: [Unicode.Scalar], _ target: [Unicode.Scalar]) -> Bool {
        if target.isEmpty {
            return true
        }

        guard source.count >= target.count else { return false }
        return (0...(source.count - target.count)).contains { source[$0..<($0 + target.count)].elementsEqual(target) }
    }

    /// A string of `scalars`.
    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// A regular expression from the C# code, on NSRegularExpression (ICU). Where ICU means something else, the patterns
/// spell out .NET's meaning: `\b` is `wordStart` or `wordEnd` (ICU's word characters include all marks and letter
/// numbers), `.` is `[^\n]` (ICU's `.` also stops at \r and the other line ends), and no group name is used twice
/// (ICU refuses that; .NET shares one group between the alternatives). `\s` and `\d` are the same in both.
///
/// Two differences remain, which dictated text rarely meets:
/// - Ignoring case, ICU folds case fully and the same in every language, while the C# patterns (IgnoreCase without
///   CultureInvariant) use .NET's case table and the current culture. "İ" matches `i` in .NET (in en-US) but not
///   here; "ſ" matches `s`, "meßage" `message` and "ﬁve" `five` here but not in .NET. So "in ﬁve minutes" is a
///   reminder in a minute here (an amount that isn't a number counts as 1), where C# finds no time.
/// - A letter outside the Basic Multilingual Plane ("𝐀") is a letter here, for `wordStart`, `wordEnd` and the word
///   pattern `[\p{L}\p{N}]`. .NET sees its two UTF-16 surrogates, which aren't letters.
struct DotNetRegex: @unchecked Sendable {
    /// .NET's `\b` before a word: the character before isn't a letter, non-spacing mark, decimal digit, connector or
    /// zero-width (non-)joiner, the characters .NET's `\b` counts.
    static let wordStart = #"(?<![\p{L}\p{Mn}\p{Nd}\p{Pc}\u200C\u200D])"#

    /// .NET's `\b` after a word.
    static let wordEnd = #"(?![\p{L}\p{Mn}\p{Nd}\p{Pc}\u200C\u200D])"#

    private let regex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Bad pattern \(pattern): \(error)")
        }
    }

    /// `Regex.Match`: the first match, or nil.
    func match(_ text: String) -> DotNetMatch? {
        let string = text as NSString
        guard let result = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: string.length))
        else { return nil }
        return DotNetMatch(result: result, string: string)
    }

    /// `Regex.IsMatch`.
    func isMatch(_ text: String) -> Bool { match(text) != nil }

    /// `Regex.Matches`: the text of every match.
    func matches(_ text: String) -> [String] {
        let string = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: string.length))
            .map { string.substring(with: $0.range) }
    }

    /// `Regex.Replace(text, evaluator)`: every match replaced.
    func replace(_ text: String, _ replacement: (DotNetMatch) -> String) -> String {
        let string = text as NSString
        let result = NSMutableString(string: text)
        let found = regex.matches(in: text, options: [], range: NSRange(location: 0, length: string.length))
        for match in found.reversed() {
            result.replaceCharacters(in: match.range, with: replacement(DotNetMatch(result: match, string: string)))
        }

        return result as String
    }
}

/// A successful match and its groups (`Match.Groups`).
struct DotNetMatch {
    let result: NSTextCheckingResult
    let string: NSString

    /// The named group's text, or nil when it took no part in the match (`Group.Success` is false).
    subscript(_ name: String) -> String? { text(result.range(withName: name)) }

    /// The numbered group's text, or nil.
    subscript(_ index: Int) -> String? { text(result.range(at: index)) }

    private func text(_ range: NSRange) -> String? {
        range.location == NSNotFound ? nil : string.substring(with: range)
    }
}
