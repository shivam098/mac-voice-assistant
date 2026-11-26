import Foundation

/// JSON as the Windows app reads and writes its files with System.Text.Json, so settings.json and learned.json can move
/// between the two apps. Foundation's reader can't be used: it keeps neither the order of an object's keys (which
/// decides which of two replacements or snippets wins) nor .NET's rules for comments, trailing commas, depth and
/// numbers, and its writer escapes differently. ThumbFree for Mac has a reader like this one (ThumbFreeApp's
/// `SettingsJSON`), which isn't a library product.
enum NetJSON {
    /// What `JsonSerializer` throws as a `JsonException`, with the line it names (from 0, as `LineNumber`).
    struct Mistake: Error, Equatable {
        let message: String
        let line: Int
    }

    /// The text of a file as .NET's `File.ReadAllText` decodes it: a byte order mark picks UTF-8, UTF-16 or UTF-32 and
    /// is dropped; anything else is UTF-8. What doesn't decode becomes U+FFFD, as in .NET.
    static func text(_ bytes: [UInt8]) -> String {
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return utf32(bytes.dropFirst(4), bigEndian: false)
        }

        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return utf32(bytes.dropFirst(4), bigEndian: true)
        }

        if bytes.starts(with: [0xFF, 0xFE]) {
            return utf16(bytes.dropFirst(2), bigEndian: false)
        }

        if bytes.starts(with: [0xFE, 0xFF]) {
            return utf16(bytes.dropFirst(2), bigEndian: true)
        }

        return String(decoding: bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...], as: UTF8.self)
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        let data = Array(bytes)
        var units: [UInt16] = []
        for i in stride(from: 0, to: data.count - 1, by: 2) {
            let first = UInt16(data[i])
            let second = UInt16(data[i + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
        }

        return String(decoding: units, as: UTF16.self) + (data.count % 2 == 1 ? "\u{FFFD}" : "")
    }

    private static func utf32(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        let data = Array(bytes)
        let units = stride(from: 0, to: data.count - 3, by: 4).map { i -> UInt32 in
            let quad = data[i..<(i + 4)].map { UInt32($0) }
            let b = bigEndian ? quad : Array(quad.reversed())
            return b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }

        return String(decoding: units, as: UTF32.self) + (data.count % 4 != 0 ? "\u{FFFD}" : "")
    }
}

// MARK: Reading

extension NetJSON {
    /// Reads JSON token by token as System.Text.Json's `Utf8JsonReader` does for `JsonSerializer`, so a mistake is
    /// found where .NET finds it: the first in the file, whether it breaks the JSON or is a value of the wrong kind.
    /// `relaxed` skips comments and allows trailing commas (settings.json's options); otherwise the JSON must be strict
    /// (learned.json's). At most 64 objects and arrays deep.
    struct Reader {
        /// The first token of a value: a whole string, number or literal, or the bracket that opens an object or an
        /// array, which is then entered (read its members with `nextMember`, its items with `nextItem`).
        enum Token: Equatable {
            case objectStart
            case arrayStart
            /// The text; nil when an escape leaves half a UTF-16 character, which .NET can't read as text.
            case string(String?)
            /// The number as written.
            case number(String)
            case bool(Bool)
            case null
        }

        enum Member: Equatable {
            /// The next member's name (nil when it can't be read as text); its value comes next.
            case name(String?)
            /// The object's closing brace.
            case end
        }

        static let maxDepth = 64

        private let bytes: [UInt8]
        private let relaxed: Bool
        private var at = 0

        /// Whether each open object or array is still waiting for its first member or item.
        private var waitingForFirst: [Bool] = []

        /// Where line comments ended with a carriage return alone: .NET counts a line there, though a carriage return
        /// elsewhere doesn't count.
        private var commentLineEnds: [Int] = []

        /// Where the last token read started (a closing bracket counts).
        private(set) var tokenStart = 0

        init(_ text: String, relaxed: Bool) {
            bytes = Array(text.utf8)
            self.relaxed = relaxed
        }

        /// The next value's first token.
        mutating func value() throws -> Token {
            try skipSpace()
            guard at < bytes.count else {
                throw mistakeHere(
                    waitingForFirst.isEmpty ? "The input does not contain any JSON tokens." : Self.unfinished)
            }

            tokenStart = at
            switch bytes[at] {
            case UInt8(ascii: "{"):
                try enter()
                return .objectStart
            case UInt8(ascii: "["):
                try enter()
                return .arrayStart
            case UInt8(ascii: "\""):
                return try .string(string())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try .number(number())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            default:
                throw mistakeHere("'\(shown(bytes[at]))' is an invalid start of a value.")
            }
        }

        /// The next member of the object entered last: its name, with the reader at its value, or the end.
        mutating func nextMember() throws -> Member {
            if try atEnd(of: UInt8(ascii: "}")) {
                return .end
            }

            guard bytes[at] == UInt8(ascii: "\"") else {
                throw mistakeHere("'\(shown(bytes[at]))' is an invalid start of a property name. Expected a '\"'.")
            }

            tokenStart = at
            let name = try string()

            // Only white space between a name and its colon: .NET takes no comment there.
            while at < bytes.count && Self.isSpace(bytes[at]) {
                at += 1
            }

            guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else {
                throw mistakeHere(at < bytes.count
                    ? "'\(shown(bytes[at]))' is invalid after a property name. Expected a ':'."
                    : Self.unfinished)
            }

            at += 1
            return .name(name)
        }

        /// True when another item of the array entered last follows (read it with `value`); false at its end.
        mutating func nextItem() throws -> Bool { try !atEnd(of: UInt8(ascii: "]")) }

        /// The rest of a value whose first token was `token`: an object or an array to its end.
        mutating func skip(_ token: Token) throws {
            switch token {
            case .objectStart:
                while case .name = try nextMember() {
                    let inner = try value()
                    try skip(inner)
                }
            case .arrayStart:
                while try nextItem() {
                    let inner = try value()
                    try skip(inner)
                }
            default:
                break
            }
        }

        /// Nothing but white space (and comments) may follow the document's value.
        mutating func end() throws {
            try skipSpace()
            if at < bytes.count {
                throw mistakeHere("'\(shown(bytes[at]))' is invalid after a single JSON value. Expected end of data.")
            }
        }

        /// A mistake at the last token, such as a value of the wrong kind.
        func mistake(_ message: String) -> Mistake { Mistake(message: message, line: line(tokenStart)) }

        /// `text`, or a mistake at the last token when it can't be read as text.
        func readable(_ text: String?) throws -> String {
            guard let text else { throw mistake("The JSON text holds half of a UTF-16 character.") }
            return text
        }

        private static let unfinished =
            "Expected depth to be zero at the end of the JSON payload. There is an open JSON object or array that "
            + "should be closed."

        /// Past the separator before the next member or item: true (with the closing bracket read) at the end.
        private mutating func atEnd(of close: UInt8) throws -> Bool {
            try skipSpace()
            guard at < bytes.count, let first = waitingForFirst.last else { throw mistakeHere(Self.unfinished) }
            if bytes[at] == close {
                leave()
                return true
            }

            if !first {
                guard bytes[at] == UInt8(ascii: ",") else {
                    throw mistakeHere(
                        "'\(shown(bytes[at]))' is invalid after a value. Expected either ',', '}', or ']'.")
                }

                at += 1
                try skipSpace()
                guard at < bytes.count else { throw mistakeHere(Self.unfinished) }
                if bytes[at] == close {
                    guard relaxed else {
                        throw mistakeHere("The JSON contains a trailing comma at the end, which isn't allowed here.")
                    }

                    leave()
                    return true
                }
            }

            waitingForFirst[waitingForFirst.count - 1] = false
            return false
        }

        /// Into the object or array whose bracket is here, one level deeper.
        private mutating func enter() throws {
            if waitingForFirst.count >= Self.maxDepth {
                throw mistakeHere("The maximum configured depth of \(Self.maxDepth) has been exceeded.")
            }

            at += 1
            waitingForFirst.append(true)
        }

        /// Past the closing bracket here.
        private mutating func leave() {
            tokenStart = at
            at += 1
            waitingForFirst.removeLast()
        }

        /// From the opening quote to just after the closing one.
        private mutating func string() throws -> String? {
            at += 1
            var units: [UInt16] = []
            while true {
                guard at < bytes.count else {
                    throw mistakeHere("Expected end of string, but instead reached end of data.")
                }

                let byte = bytes[at]
                switch byte {
                case UInt8(ascii: "\""):
                    at += 1
                    return Self.text(units)
                case UInt8(ascii: "\\"):
                    try units.append(escape())
                case 0..<0x20:
                    let hex = String(byte, radix: 16, uppercase: true)
                    throw mistakeHere("'0x\(hex)' is invalid within a JSON string.")
                case 0x20..<0x80:
                    units.append(UInt16(byte))
                    at += 1
                default:
                    // The text came from a Swift string, so this is a whole UTF-8 character.
                    let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                    var value = UInt32(byte) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
                    for next in bytes[(at + 1)..<min(at + length, bytes.count)] {
                        value = value << 6 | UInt32(next & 0x3F)
                    }

                    units += String(Character(Unicode.Scalar(value) ?? "\u{FFFD}")).utf16
                    at += length
                }
            }
        }

        /// The UTF-16 unit an escape stands for, from its backslash to just after it.
        private mutating func escape() throws -> UInt16 {
            guard at + 1 < bytes.count else {
                throw mistakeHere("Expected end of string, but instead reached end of data.")
            }

            let simple: [UInt8: UInt16] = [
                UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "/"): 0x2F, UInt8(ascii: "b"): 0x08,
                UInt8(ascii: "f"): 0x0C, UInt8(ascii: "n"): 0x0A, UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09,
            ]
            let escaped = bytes[at + 1]
            if let unit = simple[escaped] {
                at += 2
                return unit
            }

            at += 1
            guard escaped == UInt8(ascii: "u") else {
                throw mistakeHere("'\(shown(escaped))' is an invalid escapable character within a JSON string.")
            }

            var unit: UInt16 = 0
            for _ in 0..<4 {
                at += 1
                guard at < bytes.count, let digit = Self.hexDigit(bytes[at]) else {
                    throw mistakeHere("Expected a hex digit following '\\u' within a JSON string.")
                }

                unit = unit << 4 | UInt16(digit)
            }

            at += 1
            return unit
        }

        /// -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?, as written. What follows is judged by what comes next.
        private mutating func number() throws -> String {
            let start = at
            if bytes[at] == UInt8(ascii: "-") {
                at += 1
            }

            if at < bytes.count && bytes[at] == UInt8(ascii: "0") {
                at += 1
            } else {
                try digits()
            }

            if at < bytes.count && bytes[at] == UInt8(ascii: ".") {
                at += 1
                try digits()
            }

            if at < bytes.count && (bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E")) {
                at += 1
                if at < bytes.count && (bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-")) {
                    at += 1
                }

                try digits()
            }

            return String(decoding: bytes[start..<at], as: UTF8.self)
        }

        private mutating func digits() throws {
            guard at < bytes.count, Self.isDigit(bytes[at]) else { throw mistakeHere("Expected a digit ('0'-'9').") }
            while at < bytes.count && Self.isDigit(bytes[at]) {
                at += 1
            }
        }

        private mutating func literal(_ word: String) throws {
            for expected in word.utf8 {
                guard at < bytes.count, bytes[at] == expected else {
                    throw mistakeHere("An invalid JSON literal. Expected the literal '\(word)'.")
                }

                at += 1
            }
        }

        /// White space and, when relaxed, comments. A comment that isn't closed, or a line comment with a line or
        /// paragraph separator in it, is a mistake where the comment starts.
        private mutating func skipSpace() throws {
            while at < bytes.count {
                if Self.isSpace(bytes[at]) {
                    at += 1
                    continue
                }

                guard relaxed && bytes[at] == UInt8(ascii: "/") else { return }
                let start = at
                if at + 1 < bytes.count && bytes[at + 1] == UInt8(ascii: "/") {
                    at += 2
                    while at < bytes.count && bytes[at] != 0x0A && bytes[at] != 0x0D {
                        // U+2028 and U+2029 (E2 80 A8 and E2 80 A9), which end a line in JavaScript.
                        if bytes[at] == 0xE2 && at + 2 < bytes.count && bytes[at + 1] == 0x80
                            && (bytes[at + 2] == 0xA8 || bytes[at + 2] == 0xA9) {
                            at = start
                            throw mistakeHere(
                                "Found invalid line or paragraph separator character while reading a comment.")
                        }

                        at += 1
                    }

                    if at < bytes.count && bytes[at] == 0x0D && (at + 1 == bytes.count || bytes[at + 1] != 0x0A) {
                        commentLineEnds.append(at)
                    }
                } else if at + 1 < bytes.count && bytes[at + 1] == UInt8(ascii: "*") {
                    guard let close = Self.find(bytes, [UInt8(ascii: "*"), UInt8(ascii: "/")], from: at + 2) else {
                        throw mistakeHere("Expected end of comment, but instead reached end of data.")
                    }

                    at = close + 2
                } else {
                    throw mistakeHere("'/' is an invalid start of a value.")
                }
            }
        }

        private func mistakeHere(_ message: String) -> Mistake { Mistake(message: message, line: line(at)) }

        /// The line of `position` as .NET counts it: the line feeds before it, and the line comments before it that
        /// ended with a carriage return alone.
        private func line(_ position: Int) -> Int {
            let end = min(position, bytes.count)
            return bytes[..<end].lazy.filter { $0 == 0x0A }.count + commentLineEnds.filter { $0 < end }.count
        }

        private func shown(_ byte: UInt8) -> String {
            byte >= 0x20 && byte < 0x7F ? String(UnicodeScalar(byte)) : "0x" + String(byte, radix: 16, uppercase: true)
        }

        /// JSON's white space: space, tab, line feed and carriage return.
        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

        private static func hexDigit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }

        /// The text of UTF-16 units, or nil when a surrogate isn't paired.
        private static func text(_ units: [UInt16]) -> String? {
            var i = 0
            while i < units.count {
                if UTF16.isLeadSurrogate(units[i]) {
                    guard i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) else { return nil }
                    i += 2
                } else if UTF16.isTrailSurrogate(units[i]) {
                    return nil
                } else {
                    i += 1
                }
            }

            return String(decoding: units, as: UTF16.self)
        }

        private static func find(_ bytes: [UInt8], _ part: [UInt8], from: Int) -> Int? {
            guard bytes.count >= part.count, from <= bytes.count - part.count else { return nil }
            return (from...(bytes.count - part.count)).first { bytes[$0..<($0 + part.count)].elementsEqual(part) }
        }
    }
}

// MARK: Reading values

extension NetJSON.Reader {
    /// A whole number as .NET reads an `int`: digits that fit in 32 bits, no fraction or exponent.
    static func int(_ text: String) -> Int? { Int32(text).map { Int($0) } }

    /// A number as .NET reads a `float`: rounded to the nearest, infinite past the range (which .NET reads, though it
    /// can't write it back), and zero below it.
    static func float(_ text: String) -> Float {
        if let value = Float(text) {
            return value
        }

        // Swift's parser gives up where the C library reports a value out of range.
        if let value = Double(text), value.isFinite {
            return Float(value)
        }

        let negative = text.hasPrefix("-")
        let parts = text.lowercased().split(separator: "e", maxSplits: 1)
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].drop { $0 == "-" }
        let whole = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integer = whole[0].drop { $0 == "0" }
        let fraction = whole.count > 1 ? whole[1] : ""
        let leadingZeros = integer.isEmpty ? fraction.prefix { $0 == "0" }.count : 0
        let magnitude = integer.isEmpty ? exponent - leadingZeros : exponent + integer.count
        let value: Float = magnitude > 0 ? .infinity : 0
        return negative ? -value : value
    }
}

// MARK: Writing

extension NetJSON {
    /// A value to write.
    indirect enum Value: Equatable {
        case object([Property])
        case array([Value])
        case string(String)
        case int(Int)
        case float(Float)
        case bool(Bool)
    }

    struct Property: Equatable {
        let key: String
        let value: Value

        init(_ key: String, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// .NET can't write a number that isn't finite (it throws an `ArgumentException`).
    struct NotANumber: Error {}

    /// `value` as `JsonSerializer` writes it with the default options: compact, or indented by two spaces with "\n"
    /// line ends (`Environment.NewLine` on a Mac; Windows writes "\r\n").
    static func write(_ value: Value, indented: Bool) throws -> String {
        var out = ""
        try write(value, indented ? "" : nil, &out)
        return out
    }

    private static func write(_ value: Value, _ indent: String?, _ out: inout String) throws {
        switch value {
        case .object(let properties):
            try container("{", "}", properties, indent, &out) { property, inner, out in
                out += quote(property.key) + (inner == nil ? ":" : ": ")
                try write(property.value, inner, &out)
            }
        case .array(let items):
            try container("[", "]", items, indent, &out) { item, inner, out in try write(item, inner, &out) }
        case .string(let text):
            out += quote(text)
        case .int(let number):
            out += String(number)
        case .float(let number):
            out += try self.number(number)
        case .bool(let flag):
            out += flag ? "true" : "false"
        }
    }

    private static func container<Element>(
        _ open: String,
        _ close: String,
        _ elements: [Element],
        _ indent: String?,
        _ out: inout String,
        _ writeElement: (Element, String?, inout String) throws -> Void
    ) throws {
        out += open
        guard !elements.isEmpty else {
            out += close
            return
        }

        let inner = indent.map { $0 + "  " }
        for (i, element) in elements.enumerated() {
            if i > 0 {
                out += ","
            }

            if let inner {
                out += "\n" + inner
            }

            try writeElement(element, inner, &out)
        }

        if let indent {
            out += "\n" + indent
        }

        out += close
    }

    /// `text` as a JSON string, escaped as System.Text.Json's default encoder escapes it: printable ASCII as it is,
    /// except `"` (\u0022), `\` (\\), and `&`, `'`, `+`, `<`, `>` and `` ` ``, which HTML treats specially; the usual
    /// short escapes for line feeds, carriage returns, tabs, backspaces and form feeds; and everything else, all
    /// characters beyond ASCII included, as \uXXXX in UTF-16.
    static func quote(_ text: String) -> String {
        var out = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x22, 0x26, 0x27, 0x2B, 0x3C, 0x3E, 0x60:
                out += hexEscape(unit)
            case 0x20..<0x7F:
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                out += hexEscape(unit)
            }
        }

        return out + "\""
    }

    private static func hexEscape(_ unit: UInt16) -> String {
        let hex = String(unit, radix: 16, uppercase: true)
        return "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
    }

    /// A float as .NET writes one: the shortest digits that read back the same (Swift's `description` has the same
    /// ones), laid out as .NET's general format lays them out: plainly unless the decimal point would be more than
    /// nine places (or than the digits) to the right of the first digit, or more than three to its left, then as
    /// "1E-05" or "2.5E+15".
    static func number(_ value: Float) throws -> String {
        guard value.isFinite else { throw NotANumber() }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 {
            return sign + "0"
        }

        var text = "\(value.magnitude)"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(parts[0]) + (parts.count > 1 ? Array(parts[1]) : [])
        // The value is 0.d₁d₂… × 10^scale.
        var scale = parts[0].count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            scale -= 1
        }

        while digits.last == "0" {
            digits.removeLast()
        }

        if scale > max(digits.count, 9) || scale < -3 {
            let mantissa = String(digits[0]) + (digits.count > 1 ? "." + String(digits[1...]) : "")
            let power = scale - 1
            let magnitude = String(abs(power))
            return sign + mantissa + "E" + (power < 0 ? "-" : "+") + (magnitude.count < 2 ? "0" : "") + magnitude
        }

        if scale <= 0 {
            return sign + "0." + String(repeating: "0", count: -scale) + String(digits)
        }

        if scale >= digits.count {
            return sign + String(digits) + String(repeating: "0", count: scale - digits.count)
        }

        return sign + String(digits[..<scale]) + "." + String(digits[scale...])
    }
}
