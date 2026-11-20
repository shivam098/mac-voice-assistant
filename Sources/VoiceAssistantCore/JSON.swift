import Foundation
import ThumbFreeCore

/// A JSON value as System.Text.Json's `JsonDocument` reads one by default: RFC 8259 JSON, no comments or trailing
/// commas, at most 64 levels deep, nothing but white space after it. Numbers aren't read (nothing here needs one as a
/// number); the timings in a llama-server reply are read with `doubleValue`.
enum JSONValue: Equatable {
    /// The properties in order, names given more than once included.
    case object([(String, JSONValue)])
    case array([JSONValue])

    /// A string, or nil when it holds half of a surrogate pair (`\uD800` alone): .NET's `GetString` throws there.
    case string(String?)

    /// A number, as written.
    case number(String)
    case bool(Bool)
    case null

    /// `TryGetProperty`: of a name given more than once, the last.
    subscript(_ name: String) -> JSONValue? {
        guard case .object(let properties) = self else { return nil }
        return properties.last { DotNet.ordinalEquals($0.0, name) }?.1
    }

    /// The number this is (`TryGetValue<double>`): the nearest `Double`, infinite past its range as in .NET.
    var doubleValue: Double? {
        guard case .number(let text) = self else { return nil }
        return Double(text)
    }

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { DotNet.ordinalEquals($0.0, $1.0) && $0.1 == $1.1 }
        case (.array(let x), .array(let y)):
            return x == y
        case (.string(let x), .string(let y)):
            if let x, let y {
                return DotNet.ordinalEquals(x, y)
            }

            return x == nil && y == nil
        case (.number(let x), .number(let y)):
            return x == y
        case (.bool(let x), .bool(let y)):
            return x == y
        case (.null, .null):
            return true
        default:
            return false
        }
    }

    /// The document `text` holds, or nil where `JsonDocument.Parse` throws `JsonException`.
    static func parse(_ text: String) -> JSONValue? {
        var reader = Reader(bytes: Array(text.utf8))
        reader.skipSpace()
        guard let value = reader.value() else { return nil }
        reader.skipSpace()
        return reader.index == reader.bytes.count ? value : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSpace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        mutating func value() -> JSONValue? {
            guard let byte = current else { return nil }
            switch byte {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
            default: return nil
            }
        }

        private mutating func object() -> JSONValue? {
            guard enter() else { return nil }
            var properties: [(String, JSONValue)] = []
            if current == UInt8(ascii: "}") {
                return leave(.object(properties))
            }

            while true {
                guard current == UInt8(ascii: "\""), let name = string() else { return nil }
                skipSpace()
                guard current == UInt8(ascii: ":") else { return nil }
                index += 1
                skipSpace()
                guard let value = value() else { return nil }
                // A name with half a surrogate pair matches no name asked for.
                properties.append((name ?? "\u{FFFD}", value))
                skipSpace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    skipSpace()
                } else if current == UInt8(ascii: "}") {
                    return leave(.object(properties))
                } else {
                    return nil
                }
            }
        }

        private mutating func array() -> JSONValue? {
            guard enter() else { return nil }
            var items: [JSONValue] = []
            if current == UInt8(ascii: "]") {
                return leave(.array(items))
            }

            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipSpace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    skipSpace()
                } else if current == UInt8(ascii: "]") {
                    return leave(.array(items))
                } else {
                    return nil
                }
            }
        }

        /// Past an opening bracket, one level deeper (at most 64).
        private mutating func enter() -> Bool {
            depth += 1
            guard depth <= 64 else { return false }
            index += 1
            skipSpace()
            return true
        }

        /// Past a closing bracket.
        private mutating func leave(_ value: JSONValue) -> JSONValue {
            index += 1
            depth -= 1
            return value
        }

        /// A string from its opening quote: nil if it isn't valid JSON; `.some(nil)` if it is, but holds half of a
        /// surrogate pair.
        private mutating func string() -> String?? {
            index += 1
            var units: [UInt16] = []
            var raw: [UInt8] = []
            func flush() {
                units.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16)
                raw.removeAll()
            }

            while let byte = current {
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    flush()
                    return Self.isPaired(units) ? .some(String(decoding: units, as: UTF16.self)) : .some(nil)
                case UInt8(ascii: "\\"):
                    flush()
                    guard let escaped = current else { return nil }
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count else { return nil }
                        let hex = bytes[index..<(index + 4)]
                        guard hex.allSatisfy({ Self.isHexDigit($0) }),
                              let unit = UInt16(String(decoding: hex, as: UTF8.self), radix: 16)
                        else { return nil }
                        index += 4
                        units.append(unit)
                    default:
                        return nil
                    }
                case 0..<0x20:
                    return nil
                default:
                    raw.append(byte)
                }
            }

            return nil
        }

        /// Every surrogate is half of a pair.
        private static func isPaired(_ units: [UInt16]) -> Bool {
            var i = 0
            while i < units.count {
                if UTF16.isLeadSurrogate(units[i]) {
                    guard i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) else { return false }
                    i += 2
                } else if UTF16.isTrailSurrogate(units[i]) {
                    return false
                } else {
                    i += 1
                }
            }

            return true
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
        private mutating func number() -> JSONValue? {
            let start = index
            if current == UInt8(ascii: "-") {
                index += 1
            }

            if current == UInt8(ascii: "0") {
                index += 1
            } else if !digits() {
                return nil
            }

            if current == UInt8(ascii: ".") {
                index += 1
                guard digits() else { return nil }
            }

            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") {
                    index += 1
                }

                guard digits() else { return nil }
            }

            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func digits() -> Bool {
            let start = index
            while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            }

            return index > start
        }

        private mutating func literal(_ word: String) -> Bool {
            for byte in word.utf8 {
                guard current == byte else { return false }
                index += 1
            }

            return true
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

/// JSON text from values, for requests: keys in the order given, strings escaped as JSON requires (System.Text.Json
/// also escapes non-ASCII characters and <, >, &, ', + as \uXXXX, which reads the same).
enum JSONText {
    indirect enum Value {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case int(Int)
        case bool(Bool)
    }

    static func write(_ value: Value) -> String {
        switch value {
        case .object(let properties):
            return "{" + properties.map { quote($0.0) + ":" + write($0.1) }.joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map(write).joined(separator: ",") + "]"
        case .string(let text):
            return quote(text)
        case .int(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16, uppercase: true)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }

        return out + "\""
    }
}
