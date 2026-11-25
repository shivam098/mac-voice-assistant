import XCTest
import VoiceAssistantCore
@testable import VoiceAssistantApp

/// learned.json as Windows reads and writes it. Windows has no tests of LearnedStore; these hold the Mac to what the C#
/// code does (AppVectors.swift, generated from it).
final class LearnedStoreTests: XCTestCase {
    /// Every input Windows' `LearnedStore.Load` was given (learnedReadingVectors), read from a file: the phrases and
    /// app uses it loaded, or that it couldn't read the file and left the memory alone.
    func testLearnedJsonReadsAsWindowsReadsIt() throws {
        let folder = TempFolder()
        defer {
            Log.stop()
            folder.remove()
        }

        Log.start(in: folder.file("logs"))
        let store = LearnedStore(path: folder.file("learned.json"))
        var counts: [String: Int] = [:]
        for line in Escaped.lines(learnedReadingVectors) {
            let fields = Escaped.fields(line)
            let (kind, input) = (fields[0], fields[1])
            counts[kind, default: 0] += 1
            TestFiles.write(store.path, input)
            let memory = PhraseMemory()
            XCTAssertTrue(memory.learn("bring up the editor xcode", "open xcode"))
            memory.recordAppUse("Xcode")
            store.load(into: memory)
            switch kind {
            case "L":
                XCTAssertEqual(Self.phrases(memory), fields[2], input)
                XCTAssertEqual(Self.uses(memory), fields[3], input)
                let loaded = "INFO learned memory loaded: \(memory.phraseCount) phrases"
                XCTAssertEqual(TestFiles.lastLogLine(folder.file("logs")), loaded, input)
            case "U":
                XCTAssertEqual(Self.phrases(memory), "bring up the editor xcode\u{1}open xcode", input)
                XCTAssertEqual(Self.uses(memory), "Xcode\u{1}1", input)
                let logged = TestFiles.lastLogLine(folder.file("logs")) ?? ""
                XCTAssertTrue(logged.hasPrefix("WARN learned memory unreadable: "), "\(input): \(logged)")
            case "X":
                // Windows stops with a NullReferenceException on a null command; the Mac leaves the phrase out.
                XCTAssertEqual(fields[2], "NullReferenceException")
                XCTAssertEqual(input, #"{"Phrases": {"get notepad going": null}}"#)
                XCTAssertEqual(memory.phraseCount, 0)
            default:
                XCTFail(line.description)
            }
        }

        XCTAssertEqual(counts, ["L": 13, "U": 13, "X": 1])
    }

    func testWindowsFileReadsAndWritesBackTheSame() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let store = LearnedStore(path: folder.file("VoiceAssistant/learned.json"))
        TestFiles.write(store.path, windowsLearned)
        let memory = PhraseMemory()

        store.load(into: memory)
        XCTAssertEqual(memory.command(for: "show me \"café\" notes 😀"), "open \"café\" notes")
        XCTAssertEqual(memory.usesOf("notepad"), 3)
        XCTAssertEqual(try LearnedStore.fileText(memory), windowsLearned)

        try FileManager.default.removeItem(atPath: store.path)
        store.save(memory)
        XCTAssertEqual(TestFiles.text(store.path), windowsLearned)
        XCTAssertFalse(TestFiles.exists(store.path + ".tmp"))

        // Windows writes "\r\n".
        TestFiles.write(store.path, windowsLearned.replacingOccurrences(of: "\n", with: "\r\n"))
        let again = PhraseMemory()
        store.load(into: again)
        XCTAssertEqual(again.phrasesInOrder().map { $0.phrase }, memory.phrasesInOrder().map { $0.phrase })
    }

    func testNothingIsLoadedWithoutAFileAndDeleteRemovesItAll() {
        let folder = TempFolder()
        defer { folder.remove() }
        let store = LearnedStore(path: folder.file("learned.json"))
        let memory = PhraseMemory()
        XCTAssertTrue(memory.learn("get notepad going", "open notepad"))

        store.load(into: memory)
        XCTAssertEqual(memory.phraseCount, 1)

        store.save(memory)
        TestFiles.write(store.path + ".tmp", "{")
        store.delete()
        XCTAssertFalse(TestFiles.exists(store.path))
        XCTAssertFalse(TestFiles.exists(store.path + ".tmp"))
        store.delete()
    }

    private static func phrases(_ memory: PhraseMemory) -> String {
        memory.phrasesInOrder().map { $0.phrase + "\u{1}" + $0.command }.joined(separator: "\u{2}")
    }

    private static func uses(_ memory: PhraseMemory) -> String {
        memory.appUses.map { $0.app + "\u{1}" + String($0.uses) }.joined(separator: "\u{2}")
    }
}
