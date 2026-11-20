import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

private let chromeWindow = windowRef(400, 4, "chrome", "Google - Google Chrome")
private let notepadWindow = windowRef(300, 3, "Notepad", "Untitled - Notepad")

/// NaturalLanguageAndLearningTests.cs's desktop: it records what it was asked to do, and opens Notepad or Chrome.
private final class LearningDesktop: JarvisDesktop {
    var actions: [String] = []
    var newWindowRequests: [Bool] = []
    var foreground: WindowInfo?
    var focusIsEditable: Bool? = true
    var brainPlatform: BrainPlatform { .windows }

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        actions.append("open:\(app.name)")
        newWindowRequests.append(newWindow)
        foreground = app.name == "Notepad" ? notepadWindow : chromeWindow
        return .ok("ok", window: foreground)
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        actions.append("prepare:\(window.processName)")
        return TextTargetResult(success: true, message: "", hasTrailingText: nil, focusIsEditable: focusIsEditable)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "")
    }

    func checkFocusedField() -> AssistantFieldCheck { .safe }

    func focusedTextEndsWithNonWhitespace() -> Bool? { nil }

    func typeText(_ text: String) throws { actions.append("type:\(text)") }

    func pressKeys(_ chord: String) throws { actions.append("keys:\(chord)") }

    func backspace(_ count: Int) throws { actions.append("backspace:\(count)") }
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/NaturalLanguageAndLearningTests.cs: the parser, the app
/// catalog and phrase memory, and learning a rephrasing through the interaction controller.
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

    // MARK: Learning through the interaction controller

    private func create() -> (
        controller: InteractionController, desktop: LearningDesktop, statuses: StatusLog, memory: PhraseMemory
    ) {
        let memory = PhraseMemory()
        let desktop = LearningDesktop()
        let statuses = StatusLog()
        let controller = InteractionController(
            desktop, AppCatalog([chromeApp, notepadApp], memory: memory), CommandParser(memory: memory),
            memory: memory)
        controller.onStatus = statuses.add
        controller.setListening(true)
        return (controller, desktop, statuses, memory)
    }

    func testRephrasingAfterAnUnknownPhraseIsLearnedAndReused() async throws {
        let (controller, desktop, statuses, memory) = create()
        try await controller.handleTranscript("Hey Jarvis, get notepad going.", 0.9)
        XCTAssertEqual([], desktop.actions)
        try await controller.handleTranscript("Open notepad.", 0.9)
        XCTAssertTrue(statuses.messages.contains { $0.hasPrefix("Got it") })
        XCTAssertEqual(1, memory.phraseCount)

        desktop.actions.removeAll()
        try await controller.handleTranscript("Get notepad going.", 0.9)
        XCTAssertEqual(["open:Notepad"], desktop.actions)
    }

    func testUnrelatedPhraseBeforeACommandIsNotLearned() async throws {
        let (controller, _, _, memory) = create()
        try await controller.handleTranscript("Hey Jarvis, what time is it?", 0.9)
        try await controller.handleTranscript("Open notepad.", 0.9)
        XCTAssertEqual(0, memory.phraseCount)
    }

    func testSuccessfulOpensAreCounted() async throws {
        let (controller, _, _, memory) = create()
        try await controller.handleTranscript("Hey Jarvis, open notepad.", 0.9)
        try await controller.handleTranscript("Switch to notepad.", 0.9)
        XCTAssertEqual(2, memory.usesOf("Notepad"))
    }

    func testOpenAsksForANewWindowButSwitchDoesNot() async throws {
        let (controller, desktop, _, _) = create()
        try await controller.handleTranscript("Hey Jarvis, can you open notepad?", 0.9)
        try await controller.handleTranscript("Switch to notepad.", 0.9)
        XCTAssertEqual([true, false], desktop.newWindowRequests)
    }

    func testCommandWithoutWakeWordGetsAHintInsteadOfSilence() async throws {
        let (controller, desktop, statuses, _) = create()
        let before = statuses.all.count
        try await controller.handleTranscript("Can you open notepad?", 0.9)
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual(before + 1, statuses.all.count)
        XCTAssertTrue(statuses.last?.message.contains("Hey Jarvis") == true)
    }

    func testOrdinarySpeechInStandbyStaysSilent() async throws {
        let (controller, _, statuses, _) = create()
        let before = statuses.all.count
        try await controller.handleTranscript("I'll grab lunch at one.", 0.9)
        XCTAssertEqual(before, statuses.all.count)
    }

    func testStartTypingInABrowserPageGoesToTheAddressBar() async throws {
        let (controller, desktop, _, _) = create()
        desktop.foreground = chromeWindow
        desktop.focusIsEditable = false
        try await controller.handleTranscript("Hey Jarvis, start typing.", 0.9)
        XCTAssertEqual(["prepare:chrome", "keys:Ctrl+L"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testStartTypingInAWebTextBoxTypesThere() async throws {
        let (controller, desktop, _, _) = create()
        desktop.foreground = chromeWindow
        desktop.focusIsEditable = true
        try await controller.handleTranscript("Hey Jarvis, start typing.", 0.9)
        XCTAssertEqual(["prepare:chrome"], desktop.actions)
    }

    func testCommandWindowLastsThirtySecondsByDefault() async throws {
        let clock = TestClock(utc(2026, 11, 4, 12))
        let memory = PhraseMemory()
        let desktop = LearningDesktop()
        let controller = InteractionController(
            desktop, AppCatalog([chromeApp, notepadApp], memory: memory), CommandParser(memory: memory),
            options: ControllerOptions(clock: { clock.now }), memory: memory)
        controller.setListening(true)
        try await controller.handleTranscript("Hey Jarvis.", 0.9)
        clock.advance(25)
        try await controller.handleTranscript("Open notepad.", 0.9)
        XCTAssertEqual(["open:Notepad"], desktop.actions)
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
