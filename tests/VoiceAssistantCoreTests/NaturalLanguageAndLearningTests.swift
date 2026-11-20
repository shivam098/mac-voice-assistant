import XCTest
@testable import VoiceAssistantCore

/// The parser, app-catalog and phrase-memory cases of windows-voice-assistant
/// tests/VoiceAssistant.Core.Tests/NaturalLanguageAndLearningTests.cs. Its cases that learn through the interaction
/// controller come with it.
final class NaturalLanguageAndLearningTests: XCTestCase {
    private let chromeApp = AppEntry(
        name: "Google Chrome", aliases: ["chrome"], launch: "chrome.exe", processNames: ["chrome"],
        searchKeys: "Ctrl+L", addressBarKeys: "Ctrl+L")

    private let notepadApp = AppEntry(
        name: "Notepad", launch: "notepad.exe", processNames: ["Notepad"], submitKeys: "", newLineKeys: "Enter",
        textArea: "Largest", newWindowKeys: "Ctrl+Shift+N")

    private let parser = CommandParser()

    func testPoliteAndVariedOpenPhrasing() {
        let cases = [
            ("Can you open Notepad?", "notepad"),
            ("Could you please open Chrome for me.", "chrome"),
            ("Can you please open up a new notepad window", "notepad"),
            ("I want to open notepad", "notepad"),
            ("Fire up Chrome.", "chrome"),
            ("Launch the Chrome browser please", "chrome"),
            ("Okay so just open notepad now", "notepad"),
            ("Start Notepad.", "notepad"),
        ]
        for (heard, app) in cases {
            XCTAssertEqual([VoiceCommand(.openApp, app)], parser.parse(heard, .command).commands, heard)
        }
    }

    func testSwitchingToAnOpenApp() {
        for heard in ["Switch to Notepad.", "Can you go to Notepad?", "Go back to notepad", "Show me notepad"] {
            XCTAssertEqual([VoiceCommand(.switchToApp, "notepad")], parser.parse(heard, .command).commands, heard)
        }
    }

    func testPoliteCommands() {
        let cases: [(String, CommandKind)] = [
            ("Can you start typing?", .startTyping),
            ("Let me type.", .startTyping),
            ("I want to start typing", .startTyping),
            ("Could you go to the search box?", .focusSearch),
            ("Click on the search bar", .focusSearch),
            ("Go to the address bar please", .focusAddressBar),
            ("Could you save this?", .pressKeys),
            ("Press the enter key.", .pressKeys),
            ("Can you refresh the page", .pressKeys),
        ]
        for (heard, kind) in cases {
            XCTAssertEqual(kind, parser.parse(heard, .command).commands.first?.kind, heard)
        }
    }

    func testOpenAndStartTypingVariants() {
        let parsed = parser.parse("Can you open notepad so I can type?", .command)
        XCTAssertEqual([VoiceCommand(.openApp, "notepad"), VoiceCommand(.startTyping)], parsed.commands)
    }

    func testSearchForStripsOnGoogle() {
        let commands = parser.parse("Please search for weather in Bangalore on Google.", .command).commands
        XCTAssertEqual([VoiceCommand(.searchFor, "weather in bangalore")], commands)
    }

    func testDictationStaysStrictWithoutTheWakeWord() {
        let sentences = [
            "Please send it to Sam.", "Can you stop typing", "Could you send it", "That's all.", "I'm done.",
            "Post it.", "Send that.", "Delete everything.", "Be quiet.", "Erase that.",
        ]
        for heard in sentences {
            let parsed = parser.parse(heard, .dictation)
            XCTAssertEqual([], parsed.commands, heard)
            XCTAssertNotNil(parsed.dictationText, heard)
        }
    }

    func testBroaderPhrasingsWorkAfterTheWakeWordWhileTyping() {
        XCTAssertEqual([VoiceCommand(.stopTyping)], parser.parse("Hey Jarvis, that's all.", .dictation).commands)
        XCTAssertEqual([VoiceCommand(.send)], parser.parse("Hey Jarvis, post it.", .dictation).commands)
    }

    func testAPhraseTaughtViaAnotherLearnedPhraseMapsToTheRealCommand() {
        let memory = PhraseMemory()
        memory.learn("get notepad going", "open notepad")
        let parsed = CommandParser(memory: memory).parse("Get notepad going.", .command)
        XCTAssertTrue(parsed.fromLearnedPhrase)
        XCTAssertEqual("open notepad", parsed.commandText)
    }

    func testFullMemoryEvictsTheOldestPhrase() {
        let memory = PhraseMemory()
        for i in 0..<(PhraseMemory.maxPhrases + 2) {
            XCTAssertTrue(memory.learn("notepad thing \(i)", "open notepad"))
        }

        XCTAssertEqual(PhraseMemory.maxPhrases, memory.phraseCount)
        XCTAssertNil(memory.command(for: "notepad thing 0"))
        XCTAssertNil(memory.command(for: "notepad thing 1"))
        XCTAssertNotNil(memory.command(for: "notepad thing 2"))
        XCTAssertNotNil(memory.command(for: "notepad thing \(PhraseMemory.maxPhrases)"))
        XCTAssertNotNil(memory.command(for: "notepad thing \(PhraseMemory.maxPhrases + 1)"))
    }

    func testWakeWordMakesPoliteDictationCommandsWork() {
        let commands = parser.parse("Hey Jarvis, can you please stop typing?", .dictation).commands
        XCTAssertEqual([VoiceCommand(.stopTyping)], commands)
    }

    func testBareStopDoesNotPauseListening() {
        XCTAssertEqual([], parser.parse("Stop.", .command).commands)
    }

    func testAppNamesTolerateMishearingAndDecoration() {
        let cases = [
            ("notpad", "Notepad"), ("note pad", "Notepad"), ("crome", "Google Chrome"), ("outlook", "Outlook (new)"),
            ("teams", "Microsoft Teams"), ("visual studio", "Visual Studio 2022"),
        ]
        for (spoken, expected) in cases {
            let catalog = AppCatalog([chromeApp, notepadApp])
            catalog.setDiscoveredApps([
                AppEntry(name: "Outlook (new)", launch: "olk"), AppEntry(name: "Microsoft Teams", launch: "teams"),
                AppEntry(name: "Visual Studio 2022", launch: "vs"),
            ])
            guard case .found(let app) = catalog.resolve(spoken) else {
                XCTFail("\(spoken) not found")
                continue
            }

            XCTAssertEqual(expected, app.name, spoken)
        }
    }

    func testAmbiguousNamesPreferTheAppUsedMost() {
        let memory = PhraseMemory()
        let catalog = AppCatalog([], memory: memory)
        catalog.setDiscoveredApps([
            AppEntry(name: "Terminal", launch: "a"), AppEntry(name: "Terminal Preview", launch: "b"),
            AppEntry(name: "Terminal", launch: "c"),
        ])
        XCTAssertTrue(isAmbiguous(catalog.resolve("terminal")))
        memory.recordAppUse("Terminal")
        XCTAssertTrue(isAmbiguous(catalog.resolve("terminal")))
    }

    func testMemoryOnlyLearnsPairsThatShareAMeaningfulWord() {
        let memory = PhraseMemory()
        XCTAssertTrue(memory.learn("get notepad going", "open notepad"))
        XCTAssertFalse(memory.learn("what time is it", "open notepad"))
        XCTAssertFalse(memory.learn("open it up", "open notepad"))
        XCTAssertEqual("open notepad", memory.command(for: "get notepad going"))
    }

    // MARK: Beyond the C# tests

    func testMemoryKeepsItsOrderAndAppNamesForSaving() {
        let memory = PhraseMemory()
        memory.load(
            [("get notepad going", "open notepad"), ("", "x"), ("fire up chrome now", "open chrome")],
            [("Notepad", 2), ("notepad", 5), ("Terminal", -1)])
        memory.learn("get notepad going", "switch to notepad")
        XCTAssertEqual(
            ["fire up chrome now=open chrome", "get notepad going=switch to notepad"],
            memory.phrasesInOrder().map { "\($0.phrase)=\($0.command)" })

        // Names in any case are one app, saved under the name it was first recorded with.
        XCTAssertEqual(["Notepad=5", "Terminal=0"], memory.appUses.map { "\($0.app)=\($0.uses)" })
        memory.recordAppUse("NOTEPAD")
        XCTAssertEqual(6, memory.usesOf("notepad"))
        XCTAssertTrue(memory.forget("get notepad going"))
        XCTAssertEqual(1, memory.phraseCount)
    }

    private func isAmbiguous(_ resolution: AppResolution) -> Bool {
        guard case .ambiguous = resolution else { return false }
        return true
    }
}
