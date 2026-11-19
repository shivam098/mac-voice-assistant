import Foundation

/// Text rules as .NET applies them, for code ported from windows-voice-assistant `src/VoiceAssistant.Board`. They work
/// on Unicode scalars and UTF-16 code units, as .NET's `char` does, rather than on Swift's `Character` (grapheme
/// clusters, full case mapping, canonically equivalent strings comparing equal).
enum DotNet {
    /// `char.IsWhiteSpace`: Unicode's White_Space property.
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    /// `char.ToUpperInvariant`: the one-to-one mapping, so "ß" stays "ß" instead of becoming "SS".
    static func upperInvariant(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let mapped = scalar.properties.uppercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first! : scalar
    }

    /// `char.ToLowerInvariant`: the one-to-one mapping.
    static func lowerInvariant(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first! : scalar
    }

    /// `string.ToUpperInvariant()`.
    static func toUpperInvariant(_ text: String) -> String { mapScalars(text, upperInvariant) }

    /// `string.ToLowerInvariant()`.
    static func toLowerInvariant(_ text: String) -> String { mapScalars(text, lowerInvariant) }

    /// `string.Replace(char, char)`.
    static func replace(_ text: String, _ old: Unicode.Scalar, with new: Unicode.Scalar) -> String {
        mapScalars(text) { $0 == old ? new : $0 }
    }

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

    /// `a.Contains(b, StringComparison.Ordinal)`: code unit by code unit.
    static func contains(_ text: String, _ part: String) -> Bool {
        let units = Array(text.utf16)
        let wanted = Array(part.utf16)
        guard !wanted.isEmpty else { return true }
        guard wanted.count <= units.count else { return false }
        let last = units.count - wanted.count
        for start in 0...last where units[start..<(start + wanted.count)].elementsEqual(wanted) {
            return true
        }

        return false
    }

    /// `a.Contains(b, StringComparison.OrdinalIgnoreCase)`.
    static func containsIgnoringCase(_ text: String, _ part: String) -> Bool {
        contains(toUpperInvariant(text), toUpperInvariant(part))
    }

    /// `a.StartsWith(b, StringComparison.Ordinal)`.
    static func startsWith(_ text: String, _ prefix: String) -> Bool { text.utf16.starts(with: prefix.utf16) }

    /// `a.StartsWith(b, StringComparison.OrdinalIgnoreCase)`.
    static func startsWithIgnoringCase(_ text: String, _ prefix: String) -> Bool {
        startsWith(toUpperInvariant(text), toUpperInvariant(prefix))
    }

    /// `string.Equals(a, b, StringComparison.Ordinal)`.
    static func equals(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }

    /// `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`.
    static func equalsIgnoringCase(_ a: String, _ b: String) -> Bool {
        equals(toUpperInvariant(a), toUpperInvariant(b))
    }

    private static func trim(_ text: String, while drop: (Unicode.Scalar) -> Bool) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !drop($0) }), let last = scalars.lastIndex(where: { !drop($0) })
        else { return "" }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    private static func mapScalars(_ text: String, _ transform: (Unicode.Scalar) -> Unicode.Scalar) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(transform(scalar))
        }

        return String(scalars)
    }
}

/// A regular expression from the C# code, on NSRegularExpression (ICU). Where ICU means something else, the patterns
/// spell out .NET's meaning: `\b` is `wordStart` or `wordEnd` (ICU's word characters include all marks and letter
/// numbers), `.` is `[^\n]` (ICU's `.` also stops at \r and the other line ends), and no group name is used twice
/// (ICU refuses that; .NET shares one group between the alternatives).
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
