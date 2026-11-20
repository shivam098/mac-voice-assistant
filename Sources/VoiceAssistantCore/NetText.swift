import ThumbFreeCore

/// .NET string rules the C# core uses beyond ThumbFreeCore's `DotNet`: string separators, integer parsing, suffixes
/// and UTF-16 positions. Like `DotNet`, they compare ordinally, scalar by scalar.
enum NetText {
    /// `text[..^suffix.Length]`, for a `suffix` that `DotNet.endsWith` found.
    static func dropSuffix(_ text: String, _ suffix: String) -> String {
        String(text[..<text.utf8.index(text.endIndex, offsetBy: -suffix.utf8.count)])
    }

    /// `text.Split(separator, options)` with a string separator: the pieces between its occurrences, left to right.
    static func split(_ text: String, _ separator: String, removeEmpty: Bool = false, trim: Bool = false) -> [String] {
        let source = Array(text.unicodeScalars)
        let target = Array(separator.unicodeScalars)
        var pieces: [String] = []
        var start = 0
        var i = 0
        while !target.isEmpty && i + target.count <= source.count {
            if source[i..<(i + target.count)].elementsEqual(target) {
                pieces.append(DotNet.string(source[start..<i]))
                i += target.count
                start = i
            } else {
                i += 1
            }
        }

        pieces.append(DotNet.string(source[start...]))
        if trim {
            pieces = pieces.map { DotNet.trim($0) }
        }

        return removeEmpty ? pieces.filter { !$0.isEmpty } : pieces
    }

    /// `text.Split(' ', StringSplitOptions.RemoveEmptyEntries)`.
    static func words(_ text: String) -> [String] { DotNet.split(text, [" "]).filter { !$0.isEmpty } }

    /// `int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var value)`: ASCII digits only, nil
    /// past `int.MaxValue`.
    static func parseDigits(_ text: String) -> Int? { digits(text, upTo: Int(Int32.max)) }

    /// `int.TryParse(text, out var value)` (`NumberStyles.Integer`): ASCII digits after an optional sign, with white
    /// space (tab to carriage return, and space) allowed around them.
    static func parseInteger(_ text: String) -> Int? {
        func white(_ c: Unicode.Scalar) -> Bool { c == " " || (0x09...0x0D).contains(c.value) }
        var body = DotNet.trimEnd(DotNet.trimStart(text, while: white), while: white)
        guard let sign = body.unicodeScalars.first, sign == "+" || sign == "-" else {
            return parseDigits(body)
        }

        body = DotNet.string(body.unicodeScalars.dropFirst())
        if sign == "+" {
            return parseDigits(body)
        }

        return digits(body, upTo: Int(Int32.max) + 1).map { -$0 }
    }

    private static func digits(_ text: String, upTo limit: Int) -> Int? {
        var value = 0
        var any = false
        for scalar in text.unicodeScalars {
            guard (0x30...0x39).contains(scalar.value) else { return nil }
            value = value * 10 + Int(scalar.value) - 0x30
            if value > limit {
                return nil
            }

            any = true
        }

        return any ? value : nil
    }

    /// `text.Contains(value, StringComparison.OrdinalIgnoreCase)`.
    static func containsOrdinalIgnoreCase(_ text: String, _ value: String) -> Bool {
        let source = DotNet.ordinalIgnoreCase(text)
        let target = DotNet.ordinalIgnoreCase(value)
        if target.isEmpty {
            return true
        }

        guard source.count >= target.count else { return false }
        return (0...(source.count - target.count)).contains { source[$0..<($0 + target.count)].elementsEqual(target) }
    }

    /// `text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)`.
    static func startsWithOrdinalIgnoreCase(_ text: String, _ prefix: String) -> Bool {
        DotNet.ordinalIgnoreCase(text).starts(with: DotNet.ordinalIgnoreCase(prefix))
    }

    /// `strings.Distinct()`: the first of each, in order, compared ordinally.
    static func distinct(_ strings: [String]) -> [String] {
        var seen = Set<[Unicode.Scalar]>()
        return strings.filter { seen.insert(DotNet.ordinal($0)).inserted }
    }

    /// Whether `strings` holds `text` (`Contains` on a list or array of strings, ordinal).
    static func contains(_ strings: [String], _ text: String) -> Bool {
        strings.contains { DotNet.ordinalEquals($0, text) }
    }

    /// The string of these UTF-16 code units (whole surrogate pairs, as the core's positions always are).
    static func string<C: Collection>(utf16 units: C) -> String where C.Element == UInt16 {
        String(decoding: units, as: UTF16.self)
    }
}

/// Strings compared as C#'s `StringComparer.Ordinal` compares them: scalar by scalar. (Swift's `==` and `Set<String>`
/// treat canonically equivalent strings, such as "é" and "e\u{301}", as the same.)
struct OrdinalSet: Sendable {
    private let members: Set<[Unicode.Scalar]>

    init(_ members: [String]) {
        self.members = Set(members.map(DotNet.ordinal))
    }

    func contains(_ text: String) -> Bool { members.contains(DotNet.ordinal(text)) }
}

/// A C# `Dictionary<string, TValue>` with `StringComparer.Ordinal`, built with indexer initializers: of keys given
/// twice, the last value counts.
struct OrdinalMap<Value: Sendable>: Sendable {
    private let entries: [[Unicode.Scalar]: Value]

    init(_ pairs: [(String, Value)]) {
        var entries: [[Unicode.Scalar]: Value] = [:]
        for (key, value) in pairs {
            entries[DotNet.ordinal(key)] = value
        }

        self.entries = entries
    }

    subscript(_ key: String) -> Value? { entries[DotNet.ordinal(key)] }

    func contains(_ key: String) -> Bool { entries[DotNet.ordinal(key)] != nil }
}
