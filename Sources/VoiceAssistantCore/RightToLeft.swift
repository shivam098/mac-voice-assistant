import Foundation
import ThumbFreeCore

/// A search with .NET's `RegexOptions.RightToLeft`, which NetRegex doesn't have, for the core's two right-to-left
/// patterns (TextEditing's phrase finder and the parser's spoken replacement). The pattern is in .NET's syntax and is
/// translated as NetRegex translates it.
///
/// .NET tries the positions where a match could end from the end of the text backwards, so it returns the match that
/// ends last, and its quantifiers, greedy towards the left, make that the one of those that starts first. The last
/// left-to-right match isn't the same: a left-to-right search skips matches that overlap one it found ("a a" in
/// "a a a" is found at the start, while .NET finds the last two words). So every match is found, overlapping ones
/// too, by searching again from just after each match's start, and the one that ends last (of those, the first) is
/// taken. For both patterns a match's start fixes its end, and its end its start, so that is .NET's match. Only the
/// split inside it can differ: of the spaces between "with" and the replacement, .NET's `rest` group would keep all
/// but the first, which the parser trims anyway (and the transcript has single spaces).
struct RightToLeftRegex {
    private let regex: NSRegularExpression

    /// Nil if the translated pattern is invalid (patterns made from spoken words are escaped, so they never are).
    init?(_ pattern: String, _ options: NetRegex.Options = []) {
        var icuOptions: NSRegularExpression.Options = [.useUnixLineSeparators]
        if options.contains(.ignoreCase) {
            icuOptions.insert(.caseInsensitive)
        }

        if options.contains(.singleline) {
            icuOptions.insert(.dotMatchesLineSeparators)
        }

        guard let regex = try? NSRegularExpression(pattern: NetRegex.translate(pattern), options: icuOptions) else {
            return nil
        }

        self.regex = regex
    }

    /// The match .NET's right-to-left `Regex.Match` finds, or nil.
    func match(_ text: String) -> RightToLeftMatch? {
        let string = NSString(string: text)
        let length = string.length
        var best: NSTextCheckingResult?
        var from = 0
        while from <= length {
            let range = NSRange(location: from, length: length - from)
            guard let found = regex.firstMatch(
                in: string as String, options: [.withTransparentBounds, .withoutAnchoringBounds], range: range)
            else { break }

            if best.map({ NSMaxRange(found.range) > NSMaxRange($0.range) }) ?? true {
                best = found
            }

            // On to the next start: one scalar on (a surrogate pair is one).
            let start = found.range.location
            let pair = start + 1 < length && UTF16.isLeadSurrogate(string.character(at: start))
                && UTF16.isTrailSurrogate(string.character(at: start + 1))
            from = start + (pair ? 2 : 1)
        }

        return best.map { RightToLeftMatch(text, $0) }
    }
}

/// A match from `RightToLeftRegex`, with its bounds as UTF-16 offsets into the text, as C#'s `Index` and `Length`.
struct RightToLeftMatch {
    let text: String
    private let result: NSTextCheckingResult

    init(_ text: String, _ result: NSTextCheckingResult) {
        self.text = text
        self.result = result
    }

    /// `Match.Index`.
    var start: Int { result.range.location }

    /// `Match.Length`.
    var length: Int { result.range.length }

    /// `Groups[name].Value`: "" for a group that took no part.
    func group(named name: String) -> String {
        let range = result.range(withName: name)
        guard range.location != NSNotFound else { return "" }
        return NetText.string(utf16: Array(text.utf16)[range.location..<NSMaxRange(range)])
    }
}
