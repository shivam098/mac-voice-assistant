import Foundation
import XCTest

/// A temporary folder per test, deleted afterwards.
final class TempFolder {
    let path: String

    init() {
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        path = FileManager.default.temporaryDirectory.appendingPathComponent("voice-assistant-app-tests/\(name)").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Files as the tests write and read them.
enum TestFiles {
    static func write(_ path: String, _ text: String) {
        write(path, bytes: Array(text.utf8))
    }

    static func write(_ path: String, bytes: [UInt8]) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertNoThrow(try Data(bytes).write(to: URL(fileURLWithPath: path)))
    }

    static func text(_ path: String) -> String { String(decoding: bytes(path), as: UTF8.self) }

    static func bytes(_ path: String) -> [UInt8] {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { Array($0) } ?? []
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The last line of the day's log in `folder`, without its time.
    static func lastLogLine(_ folder: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".log") }
        guard let name = names?.sorted().last else { return nil }
        let line = text((folder as NSString).appendingPathComponent(name)).split(separator: "\n").last.map(String.init)
        return line.map { String($0.drop { $0 != " " }.dropFirst()) }
    }
}

/// The C# harness's escaping (session files, jarvis-app-harness), as the core's tests read it: printable ASCII as is,
/// a backslash doubled, anything else as `\u{HEX}` scalar by scalar, and `\N` for null.
enum Escaped {
    static func decode(_ text: String) -> String? {
        if text == #"\N"# {
            return nil
        }

        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\" && i + 1 < scalars.count && scalars[i + 1] == "\\" {
                out.append("\\")
                i += 2
            } else if scalars[i] == "\\" && i + 2 < scalars.count && scalars[i + 1] == "u" && scalars[i + 2] == "{",
                      let close = scalars[(i + 3)...].firstIndex(of: "}"),
                      let value = UInt32(String(String.UnicodeScalarView(scalars[(i + 3)..<close])), radix: 16),
                      let scalar = Unicode.Scalar(value) {
                out.append(scalar)
                i = close + 1
            } else {
                out.append(scalars[i])
                i += 1
            }
        }

        return String(out)
    }

    /// The fields of one line of a vectors block, decoded.
    static func fields(_ line: Substring) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map { decode(String($0)) ?? "" }
    }

    /// The lines of a vectors block.
    static func lines(_ block: String) -> [Substring] { block.split(separator: "\n") }
}

/// A value several threads write and read.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value

    init(_ value: Value) {
        current = value
    }

    var value: Value { lock.withLock { current } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&current) }
    }
}
