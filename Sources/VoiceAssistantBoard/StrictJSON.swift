extension BoardFile {
    /// Whether `bytes` is one JSON value as System.Text.Json reads it by default: RFC 8259 JSON, without comments or
    /// trailing commas, nothing after the value, and at most 64 levels deep. JSONDecoder lets some of that through (a
    /// trailing comma), and varies between macOS versions, so a board file is checked with this first.
    static func isStrictJSON(_ bytes: [UInt8]) -> Bool {
        var reader = StrictJSONReader(bytes: bytes)
        return reader.document()
    }
}

private struct StrictJSONReader {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func document() -> Bool {
        skipSpace()
        guard value() else { return false }
        skipSpace()
        return index == bytes.count
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipSpace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func value() -> Bool {
        guard let byte = current else { return false }
        switch byte {
        case UInt8(ascii: "{"): return container(closedBy: UInt8(ascii: "}"), keyed: true)
        case UInt8(ascii: "["): return container(closedBy: UInt8(ascii: "]"), keyed: false)
        case UInt8(ascii: "\""): return string()
        case UInt8(ascii: "t"): return literal("true")
        case UInt8(ascii: "f"): return literal("false")
        case UInt8(ascii: "n"): return literal("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
        default: return false
        }
    }

    /// An object (`keyed`) or an array, from its opening bracket.
    private mutating func container(closedBy close: UInt8, keyed: Bool) -> Bool {
        depth += 1
        guard depth <= 64 else { return false }
        index += 1
        skipSpace()
        if current == close {
            index += 1
            depth -= 1
            return true
        }

        while true {
            if keyed {
                guard current == UInt8(ascii: "\""), string() else { return false }
                skipSpace()
                guard current == UInt8(ascii: ":") else { return false }
                index += 1
                skipSpace()
            }

            guard value() else { return false }
            skipSpace()
            if current == UInt8(ascii: ",") {
                index += 1
                skipSpace()
            } else if current == close {
                index += 1
                depth -= 1
                return true
            } else {
                return false
            }
        }
    }

    /// A string, from its opening quote: escapes must be JSON's, and control characters must be escaped.
    private mutating func string() -> Bool {
        index += 1
        while let byte = current {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return true
            case UInt8(ascii: "\\"):
                guard let escaped = current else { return false }
                index += 1
                if escaped == UInt8(ascii: "u") {
                    for _ in 0..<4 {
                        guard let hex = current, isHexDigit(hex) else { return false }
                        index += 1
                    }
                } else if !Array(#""\/bfnrt"#.utf8).contains(escaped) {
                    return false
                }
            case 0..<0x20:
                return false
            default:
                break
            }
        }

        return false
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
    private mutating func number() -> Bool {
        if current == UInt8(ascii: "-") {
            index += 1
        }

        if current == UInt8(ascii: "0") {
            index += 1
        } else if !digits() {
            return false
        }

        if current == UInt8(ascii: ".") {
            index += 1
            guard digits() else { return false }
        }

        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") {
                index += 1
            }

            guard digits() else { return false }
        }

        return true
    }

    /// One digit or more.
    private mutating func digits() -> Bool {
        let start = index
        while let byte = current, byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
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

    private func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
