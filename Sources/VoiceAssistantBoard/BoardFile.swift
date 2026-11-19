import Foundation

/// board.json as the Windows app writes it with System.Text.Json (BoardStore.cs: indented, camelCase names, lists by
/// name, times in ISO 8601 with their offset), byte for byte: the same property order, numbers, escapes and CRLF line
/// ends (System.Text.Json ends lines with Windows' `Environment.NewLine`). So a board file can move between Windows
/// and the Mac, and a file from Windows is written back unchanged.
enum BoardFile {
    /// A time as read from the file, so it's written back as it was while the note keeps it.
    struct Stamp {
        let value: DateTimeOffset
        let date: Date

        init(_ value: DateTimeOffset) {
            self.value = value
            date = value.date
        }
    }

    /// The times of one note as read from the file.
    struct Stamps {
        let created: Stamp
        let due: Stamp?
    }

    /// The file can't be read where C# throws a JsonException; the store then keeps it aside.
    struct Unreadable: Error {}

    // MARK: Reading

    /// The notes in `data`, and their times as written (by id). A time without an offset is read in `localZone`.
    static func read(_ data: Data, localZone: TimeZone) throws -> (items: [BoardItem], stamps: [String: Stamps]) {
        let json = utf8(data)
        guard isStrictJSON([UInt8](json)) else { throw Unreadable() }
        guard let file = try JSONDecoder().decode(FileModel?.self, from: json) else { return ([], [:]) }
        var items: [BoardItem] = []
        var stamps: [String: Stamps] = [:]
        // A null in the list is skipped (C# keeps it as a null note, which then fails wherever it's used).
        for model in file.items.compactMap({ $0 }) {
            let created = try model.created.map { try stamp($0, localZone) } ?? Stamp(.zero)
            let due = try model.due.map { try stamp($0, localZone) }
            let item = BoardItem(
                id: model.id ?? BoardItem.newId(), list: model.list, text: model.text ?? "", created: created.date,
                due: due?.date, done: model.done, notified: model.notified, order: model.order)
            items.append(item)
            if stamps[item.id] == nil {
                stamps[item.id] = Stamps(created: created, due: due)
            }
        }

        return (items, stamps)
    }

    /// The file's text as UTF-8, as File.ReadAllText reads it: a byte-order mark picks UTF-8, UTF-16 or UTF-32 and is
    /// dropped; without one it's UTF-8, with bad bytes replaced.
    private static func utf8(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        func decoded(_ encoding: String.Encoding, bomLength: Int) -> Data {
            Data((String(data: Data(bytes.dropFirst(bomLength)), encoding: encoding) ?? "").utf8)
        }

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return Data(String(decoding: bytes.dropFirst(3), as: UTF8.self).utf8)
        } else if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return decoded(.utf32LittleEndian, bomLength: 4)
        } else if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return decoded(.utf32BigEndian, bomLength: 4)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            return decoded(.utf16LittleEndian, bomLength: 2)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            return decoded(.utf16BigEndian, bomLength: 2)
        }

        return Data(String(decoding: bytes, as: UTF8.self).utf8)
    }

    private static func stamp(_ text: String, _ zone: TimeZone) throws -> Stamp {
        guard let value = DateTimeOffset(iso: text, localZone: zone) else { throw Unreadable() }
        return Stamp(value)
    }

    /// `{ "version": 1, "items": [...] }`. Missing values keep C#'s defaults; a wrong type is unreadable, as it is for
    /// System.Text.Json (but a null id or text is taken as missing: C# keeps the null, and then fails on it).
    private struct FileModel: Decodable {
        var items: [ItemModel?] = []

        private enum Key: String, CodingKey { case version, items }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if container.contains(.version) {
                _ = try container.decode(Int32.self, forKey: .version)
            }

            items = try container.decodeIfPresent([ItemModel?].self, forKey: .items) ?? []
        }
    }

    private struct ItemModel: Decodable {
        var id: String?
        var list = BoardList.ideas
        var text: String?
        var created: String?
        var due: String?
        var done = false
        var notified = false
        var order = 0.0

        private enum Key: String, CodingKey { case id, list, text, created, due, done, notified, order }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            due = try container.decodeIfPresent(String.self, forKey: .due)
            if container.contains(.list) {
                list = try Self.readList(container)
            }

            if container.contains(.created) {
                created = try container.decode(String.self, forKey: .created)
            }

            if container.contains(.done) {
                done = try container.decode(Bool.self, forKey: .done)
            }

            if container.contains(.notified) {
                notified = try container.decode(Bool.self, forKey: .notified)
            }

            if container.contains(.order) {
                order = try container.decode(Double.self, forKey: .order)
            }
        }

        /// JsonStringEnumConverter's reading: a list's name in any case, or its number (0 to 3), bare or in a string.
        private static func readList(_ container: KeyedDecodingContainer<Key>) throws -> BoardList {
            if let name = try? container.decode(String.self, forKey: .list) {
                if let list = BoardList.allCases.first(where: { DotNet.equalsIgnoringCase($0.rawValue, name) }) {
                    return list
                }

                if let number = Int32(name), let list = BoardList(number: Int(number)) {
                    return list
                }
            } else if let number = try? container.decode(Int32.self, forKey: .list),
                      let list = BoardList(number: Int(number)) {
                return list
            }

            throw DecodingError.dataCorruptedError(forKey: .list, in: container, debugDescription: "Not a board list")
        }
    }

    // MARK: Writing

    /// The file for `items`. A note's time is written as read while it's unchanged (`stamps`); other times are written
    /// with the offset `zone` has at them, as C# writes `DateTimeOffset.Now`.
    static func write(_ items: [BoardItem], stamps: [String: Stamps], zone: TimeZone) -> String {
        var lines = ["{", #"  "version": 1,"#]
        if items.isEmpty {
            lines.append(#"  "items": []"#)
        } else {
            lines.append(#"  "items": ["#)
            for (index, item) in items.enumerated() {
                let stamp = stamps[item.id]
                // System.Text.Json writes a DateTimeOffset as is: its "+" isn't escaped as a string's would be.
                let created = "\"" + time(item.created, stamp?.created, zone) + "\""
                let due = item.due.map { "\"" + time($0, stamp?.due, zone) + "\"" } ?? "null"
                lines.append("    {")
                lines.append(#"      "id": "# + string(item.id) + ",")
                lines.append(#"      "list": "# + string(item.list.rawValue) + ",")
                lines.append(#"      "text": "# + string(item.text) + ",")
                lines.append(#"      "created": "# + created + ",")
                lines.append(#"      "due": "# + due + ",")
                lines.append(#"      "done": "# + (item.done ? "true" : "false") + ",")
                lines.append(#"      "notified": "# + (item.notified ? "true" : "false") + ",")
                lines.append(#"      "order": "# + number(item.order))
                lines.append(index == items.count - 1 ? "    }" : "    },")
            }

            lines.append("  ]")
        }

        lines.append("}")
        return lines.joined(separator: "\r\n")
    }

    private static func time(_ date: Date, _ stamp: Stamp?, _ zone: TimeZone) -> String {
        if let stamp, stamp.date == date {
            return stamp.value.iso
        }

        return DateTimeOffset(date, in: zone).iso
    }

    /// Characters System.Text.Json's default encoder escapes even in printable ASCII: " & ' + < > `.
    private static let htmlSensitive: Set<UInt16> = [0x22, 0x26, 0x27, 0x2B, 0x3C, 0x3E, 0x60]

    /// A JSON string as System.Text.Json writes it: \\ \b \f \n \r \t as short escapes; the rest of the control
    /// characters, " & ' + < > ` and everything outside ASCII as \uXXXX (UTF-16 code units, capital hex digits).
    static func string(_ text: String) -> String {
        var json = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: json += #"\\"#
            case 0x08: json += #"\b"#
            case 0x0C: json += #"\f"#
            case 0x0A: json += #"\n"#
            case 0x0D: json += #"\r"#
            case 0x09: json += #"\t"#
            case 0x20...0x7E where !htmlSensitive.contains(unit):
                json.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                let hex = String(unit, radix: 16, uppercase: true)
                json += #"\u"# + String(repeating: "0", count: 4 - hex.count) + hex
            }
        }

        return json + "\""
    }

    /// A double as .NET writes it (`double.ToString()`, shortest round-trip digits): plain from 0.0001 up to 17 integer
    /// digits, otherwise "1.5E-05" or "1E+17"; "-0" for negative zero. The board's positions are whole numbers in
    /// practice.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 {
            return value.sign == .minus ? "-0" : "0"
        }

        // Swift's description has the same shortest round-trip digits: "1.5e-05", "100.0", "1e+16".
        var mantissa = Substring(value.magnitude.description)
        var exponent = 0
        if let e = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(mantissa[mantissa.index(after: e)...]) ?? 0
            mantissa = mantissa[..<e]
        }

        // value = 0.digits × 10^scale (.NET's Number.Scale: the digits before the decimal point)
        let point = mantissa.firstIndex(of: ".") ?? mantissa.endIndex
        var scale = mantissa.distance(from: mantissa.startIndex, to: point) + exponent
        var digits = Array(mantissa.filter { $0 != "." })
        while digits.first == "0" {
            digits.removeFirst()
            scale -= 1
        }

        while digits.last == "0" {
            digits.removeLast()
        }

        let sign = value < 0 ? "-" : ""
        if scale > 17 || scale < -3 {
            let power = scale - 1
            let fraction = digits.count > 1 ? "." + String(digits[1...]) : ""
            let powerDigits = String(abs(power))
            let paddedPower = powerDigits.count < 2 ? "0" + powerDigits : powerDigits
            return "\(sign)\(digits[0])\(fraction)E\(power < 0 ? "-" : "+")\(paddedPower)"
        }

        if scale <= 0 {
            return "\(sign)0.\(String(repeating: "0", count: -scale))\(String(digits))"
        }

        if scale >= digits.count {
            return "\(sign)\(String(digits))\(String(repeating: "0", count: scale - digits.count))"
        }

        return "\(sign)\(String(digits[..<scale])).\(String(digits[scale...]))"
    }
}

/// When a board file can't be read, the copy kept next to it is named after this time.
extension BoardFile {
    static func unreadableName(_ path: String, at date: Date, in zone: TimeZone) -> String {
        path + ".unreadable-" + DateTimeOffset(date, in: zone).compact
    }
}
