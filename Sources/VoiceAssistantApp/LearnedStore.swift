import Foundation
import ThumbFreeCore
import VoiceAssistantCore

/// Keeps what the assistant has learned (`PhraseMemory`) in learned.json, on this Mac only (windows-voice-assistant
/// `LearnedStore`), in the Windows app's format: {"Phrases": {phrase: command, oldest first}, "AppUses": {app: count}},
/// read and written as .NET's `JsonSerializer` does with its default options (strict JSON, keys in their case).
public struct LearnedStore: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Loads the file into `memory`. Nothing happens when there's no file; a file that can't be read is logged and
    /// leaves `memory` as it was.
    public func load(into memory: PhraseMemory) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else { return }
        do {
            let bytes = try Array(Data(contentsOf: URL(fileURLWithPath: path)))
            let learned = try Self.parse(NetJSON.text(bytes))
            memory.load(learned.phrases, learned.appUses)
            Log.info("learned memory loaded: \(memory.phraseCount) phrases")
        } catch {
            Log.warn("learned memory unreadable: \(Self.logKind(error))")
        }
    }

    /// Saves `memory` through a temporary file; a failure is logged.
    public func save(_ memory: PhraseMemory) {
        do {
            let text = try Self.fileText(memory)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let temp = path + ".tmp"
            try Data(text.utf8).write(to: URL(fileURLWithPath: temp))
            if rename(temp, path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Log.warn("learned memory not saved: \(Log.kind(of: error))")
        }
    }

    /// Removes what was learned from disk, whether or not learning is on now.
    public func delete() {
        for file in [path, path + ".tmp"] {
            if unlink(file) != 0 && errno != ENOENT {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Log.warn("learned memory not deleted: \(Log.kind(of: error))")
            }
        }
    }

    /// What a file holds, as Windows reads it into its record of two dictionaries: each nil when missing or null.
    struct Learned {
        var phrases: [(phrase: String, command: String)]?
        var appUses: [(app: String, uses: Int)]?
    }

    /// The text of learned.json as Windows reads it. Throws a `NetJSON.Mistake` where .NET throws a JsonException.
    /// A phrase whose command is null is left out (Windows stops with an error there).
    static func parse(_ text: String) throws -> Learned {
        var reader = NetJSON.Reader(text, relaxed: false)
        var learned = Learned()
        switch try reader.value() {
        case .null:
            break
        case .objectStart:
            while case .name(let name) = try reader.nextMember() {
                let key = try reader.readable(name)
                if DotNet.ordinalEquals(key, "Phrases") {
                    let entries = try readObject(&reader, "Dictionary<String, String>") {
                        (reader: inout NetJSON.Reader) throws -> String? in
                        switch try reader.value() {
                        case .string(let text): return try reader.readable(text)
                        case .null: return nil
                        default: throw reader.mistake(AppSettings.cannotConvert("System.String"))
                        }
                    }

                    learned.phrases = entries.map { entries in
                        entries.compactMap { entry in entry.value.map { (phrase: entry.key, command: $0) } }
                    }
                } else if DotNet.ordinalEquals(key, "AppUses") {
                    let entries = try readObject(&reader, "Dictionary<String, Int32>") {
                        (reader: inout NetJSON.Reader) throws -> Int in
                        guard case .number(let text) = try reader.value(), let uses = NetJSON.Reader.int(text) else {
                            throw reader.mistake(AppSettings.cannotConvert("System.Int32"))
                        }

                        return uses
                    }

                    learned.appUses = entries.map { entries in entries.map { (app: $0.key, uses: $0.value) } }
                } else {
                    let value = try reader.value()
                    try reader.skip(value)
                }
            }
        default:
            throw reader.mistake(AppSettings.cannotConvert("Data"))
        }

        try reader.end()
        return learned
    }

    /// The text Windows writes for `memory`: indented, the phrases oldest first and the apps in the order they were
    /// first opened.
    static func fileText(_ memory: PhraseMemory) throws -> String {
        let phrases = memory.phrasesInOrder().map { NetJSON.Property($0.phrase, .string($0.command)) }
        let uses = memory.appUses.map { NetJSON.Property($0.app, .int($0.uses)) }
        let file = NetJSON.Value.object([
            NetJSON.Property("Phrases", .object(phrases)), NetJSON.Property("AppUses", .object(uses)),
        ])
        return try NetJSON.write(file, indented: true)
    }

    /// An object read into a .NET `Dictionary<string, T>`: a key written twice keeps its first place and takes its
    /// last value, and keys in different cases are different keys. Nil for null.
    private static func readObject<Value>(
        _ reader: inout NetJSON.Reader,
        _ type: String,
        _ readValue: (inout NetJSON.Reader) throws -> Value
    ) throws -> [(key: String, value: Value)]? {
        switch try reader.value() {
        case .objectStart:
            var entries: [(key: String, value: Value)] = []
            var places: [[Unicode.Scalar]: Int] = [:]
            while case .name(let name) = try reader.nextMember() {
                let key = try reader.readable(name)
                let value = try readValue(&reader)
                if let place = places[DotNet.ordinal(key)] {
                    entries[place].value = value
                } else {
                    places[DotNet.ordinal(key)] = entries.count
                    entries.append((key: key, value: value))
                }
            }

            return entries
        case .null:
            return nil
        default:
            throw reader.mistake(AppSettings.cannotConvert(type))
        }
    }

    /// An error as the log names it: Windows logs a JsonException's type; the Mac says where the mistake is.
    private static func logKind(_ error: Error) -> String {
        (error as? NetJSON.Mistake).map { "JSON mistake near line \($0.line + 1)" } ?? Log.kind(of: error)
    }
}
