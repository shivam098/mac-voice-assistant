import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// WakeWordAndActionTests.cs's desktop: it records what it was asked to do.
private final class ActionDesktop: JarvisDesktop {
    var actions: [String] = []
    var openResults: [String: WindowInfo] = [:]
    var foreground: WindowInfo?
    var field = AssistantFieldCheck.safe
    var searchBoxFound = true
    var trailingNonWhitespace: Bool?
    var newWindowRequests: [Bool] = []
    var focusIsEditable: Bool? = true

    /// Windows', as in the C#; the Mac's for the Mac's back and forward rule.
    var brainPlatform = BrainPlatform.windows

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        actions.append("open:\(app.name)")
        newWindowRequests.append(newWindow)
        foreground = openResults[app.name]
        return .ok("ok", window: foreground)
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        actions.append("prepare:\(window.processName):\(profile?.textArea ?? "none")")
        return TextTargetResult(success: true, message: "", hasTrailingText: nil, focusIsEditable: focusIsEditable)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        actions.append("searchbox:\(window.processName)")
        return TextTargetResult(success: searchBoxFound, message: searchBoxFound ? "" : "no search box")
    }

    func checkFocusedField() -> AssistantFieldCheck { field }

    func focusedTextEndsWithNonWhitespace() -> Bool? { trailingNonWhitespace }

    func typeText(_ text: String) throws { actions.append("type:\(text)") }

    func pressKeys(_ chord: String) throws { actions.append("keys:\(chord)") }

    func backspace(_ count: Int) throws { actions.append("backspace:\(count)") }
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/WakeWordAndActionTests.cs: the wake word, standby's quick
/// pass, the command window, search boxes, shortcuts and push-to-talk.
final class WakeWordAndActionTests: XCTestCase {
    private static let chrome = windowRef(400, 4, "chrome", "New Tab - Google Chrome")
    private static let outlook = windowRef(500, 5, "olk", "Inbox - Outlook")
    private static let notepadWindow = windowRef(300, 3, "Notepad", "Untitled - Notepad")
    private static let chromeApp = AppEntry(
        name: "Google Chrome", aliases: ["chrome"], launch: "chrome.exe", processNames: ["chrome"],
        searchKeys: "Ctrl+L", addressBarKeys: "Ctrl+L")
    private static let notepadApp = AppEntry(
        name: "Notepad", launch: "notepad.exe", processNames: ["Notepad"], submitKeys: "", newLineKeys: "Enter",
        textArea: "Largest")

    private let clock = TestClock(utc(2026, 11, 4, 12))
    private var desktop: ActionDesktop!
    private var controller: InteractionController!
    private var statuses: StatusLog!

    override func setUp() {
        super.setUp()
        let made = makeController()
        desktop = made.desktop
        controller = made.controller
        statuses = made.statuses
    }

    /// The C# test class's constructor, also for each case of a theory and for the Mac's keys.
    private func makeController(_ parser: CommandParser = CommandParser())
        -> (desktop: ActionDesktop, controller: InteractionController, statuses: StatusLog) {
        let desktop = ActionDesktop()
        desktop.openResults["Google Chrome"] = Self.chrome
        desktop.openResults["Notepad"] = Self.notepadWindow
        let clock = self.clock
        let controller = InteractionController(
            desktop, AppCatalog([Self.chromeApp, Self.notepadApp]), parser,
            options: ControllerOptions(awakeTimeout: 8, clock: { clock.now }))
        let statuses = StatusLog()
        controller.onStatus = statuses.add
        controller.setListening(true)
        return (desktop, controller, statuses)
    }

    private func say(_ text: String) async throws {
        try await controller.handleTranscript(text, 0.9)
    }

    func testListeningStartsInStandby() {
        XCTAssertEqual(.standby, controller.mode)
        XCTAssertTrue(statuses.last?.message.contains("Hey Jarvis") == true)
    }

    // Standby's quick pass: only phrases that may hold the wake word, or a command said without it, get a full
    // transcription.
    func testStandbyQuickPassKeepsOnlyWakeWordsAndCommands() {
        check([
            ("Hey Jarvis, open", true), ("Hey Jervis", true), ("hey jar vis open", true), ("Jarvi, open Note", true),
            ("Open Notepad", true), ("Go to the second tab", true), ("So the quarterly numbers look", false),
            ("Thanks everyone for joining", false), ("Yes", false), ("Two", false), ("", false),
        ]) { controller.worthTranscribingInStandby($0) }
    }

    func testCustomWakeWordsAreCheckedToo() {
        let parser = CommandParser(wakeWords: ["hey friday"])
        XCTAssertTrue(parser.mayContainWakeWord("Hey Fryday, open"))
        XCTAssertFalse(parser.mayContainWakeWord("Hey Jarvis, open"))
    }

    func testAWakeWordWithoutANameSkipsTheQuickPass() {
        XCTAssertTrue(CommandParser(wakeWords: ["hey pc"]).mayContainWakeWord("Hey PC"))
    }

    func testALongPhraseCutShortThatStartsLikeACommandGetsTheFullPass() {
        check([("Open the downloads folder in", true), ("So the quarterly numbers look", false)]) {
            controller.worthTranscribingInStandby($0, cutShort: true)
        }
    }

    func testStandbyIgnoresSpeechWithoutTheWakeWordSilently() async throws {
        let before = statuses.all.count
        try await say("What's for lunch?")
        try await say("I opened the report yesterday.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual(before, statuses.all.count)
        XCTAssertEqual(.standby, controller.mode)
    }

    func testWakeWordWithCommandRunsIt() async throws {
        for heard in ["Hey Jarvis, open Notepad.", "Hey, Jarvis! Open Notepad", "Jarvis open notepad",
                      "Hi Jarvis, open notepad."] {
            let (desktop, controller, _) = makeController()
            try await controller.handleTranscript(heard, 0.9)
            XCTAssertEqual(["open:Notepad"], desktop.actions, heard)
            XCTAssertEqual(.command, controller.mode, heard)
        }
    }

    func testWakeWordAloneThenCommandWithoutIt() async throws {
        try await say("Hey Jarvis.")
        XCTAssertEqual(.command, controller.mode)
        clock.advance(5)
        try await say("Open Chrome.")
        XCTAssertEqual(["open:Google Chrome"], desktop.actions)
    }

    func testCommandWindowExpiresBackToStandby() async throws {
        try await say("Hey Jarvis.")
        clock.advance(9)
        try await say("Open Chrome.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual(.standby, controller.mode)
    }

    func testEachCommandExtendsTheWindow() async throws {
        try await say("Hey Jarvis, open Notepad.")
        clock.advance(6)
        try await say("Start typing.")
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testTickReportsReturnToStandby() async throws {
        try await say("Hey Jarvis.")
        clock.advance(9)
        controller.tick()
        XCTAssertEqual(.standby, statuses.last?.mode)
    }

    func testDictationNeedsNoWakeWordAndStaysUntilStopTyping() async throws {
        try await say("Hey Jarvis, open Notepad and start typing.")
        clock.advance(5 * 60)
        try await say("Dear team.")
        try await say("Stop typing.")
        XCTAssertEqual(["open:Notepad", "prepare:Notepad:Largest", "type:Dear team."], desktop.actions)
        XCTAssertEqual(.command, controller.mode)
    }

    func testWakeWordInsideDictationForcesACommand() async throws {
        try await say("Hey Jarvis, open Notepad and start typing.")
        try await say("Hey Jarvis, stop typing.")
        XCTAssertEqual(.command, controller.mode)
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
    }

    func testChromeSearchBoxFlowTypesQueryAndSearches() async throws {
        try await say("Hey Jarvis, open Chrome.")
        try await say("Go to the search box.")
        XCTAssertEqual(.dictation, controller.mode)
        try await say("Weather in Bangalore.")
        try await say("Search.")

        XCTAssertEqual(
            ["open:Google Chrome", "keys:Ctrl+L", "type:Weather in Bangalore", "keys:Enter"], desktop.actions)
        XCTAssertEqual(.command, controller.mode)
    }

    func testSearchForDoesEverythingInOneCommand() async throws {
        desktop.foreground = Self.chrome
        try await say("Hey Jarvis, search for best pizza near me.")
        XCTAssertEqual(["keys:Ctrl+L", "type:Best pizza near me", "keys:Enter"], desktop.actions)
    }

    func testSearchBoxInOtherAppsUsesAccessibilityLookup() async throws {
        desktop.foreground = Self.outlook
        try await say("Hey Jarvis, go to the search box.")
        XCTAssertEqual(["searchbox:olk"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testMissingSearchBoxStaysInCommandMode() async throws {
        desktop.foreground = Self.outlook
        desktop.searchBoxFound = false
        try await say("Hey Jarvis, go to the search box.")
        XCTAssertEqual(.command, controller.mode)
    }

    func testAddressBarNeedsABrowser() async throws {
        desktop.foreground = Self.notepadWindow
        try await say("Hey Jarvis, go to the address bar.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(statuses.last?.message.contains("address bar") == true)
    }

    func testShortcutsPressKeys() async throws {
        let cases = [
            ("New tab.", "Ctrl+T"), ("Go back.", "Alt+Left"), ("Go to the previous page.", "Alt+Left"),
            ("Previous page.", "Alt+Left"), ("Go back one page.", "Alt+Left"), ("Go to the next page.", "Alt+Right"),
            ("Next page.", "Alt+Right"), ("Go forward.", "Alt+Right"), ("Go up one level.", "Alt+Up"),
            ("Go to the parent folder.", "Alt+Up"), ("Can you go back please?", "Alt+Left"), ("Press enter.", "Enter"),
            ("Press the tab key.", "Tab"), ("Copy that.", "Ctrl+C"), ("Scroll down.", "PageDown"),
        ]
        for (heard, chord) in cases {
            let (desktop, controller, _) = makeController()
            desktop.foreground = Self.chrome
            try await controller.handleTranscript("Hey Jarvis, " + heard, 0.9)
            XCTAssertEqual(["keys:\(chord)"], desktop.actions, heard)
        }
    }

    func testPressKeyWhileTypingTargetsTheBoundWindow() async throws {
        try await say("Hey Jarvis, open Notepad and start typing.")
        try await say("Press tab.")
        XCTAssertEqual("keys:Tab", desktop.actions.last)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testKeysAreRefusedForAdministratorWindows() async throws {
        desktop.foreground = Self.chrome
        desktop.field = .elevated
        try await say("Hey Jarvis, new tab.")
        XCTAssertEqual([], desktop.actions)
    }

    func testNotepadNewLineUsesEnterAndDictationIsFormatted() async throws {
        try await say("Hey Jarvis, open Notepad and start typing.")
        try await say("Um, shopping list colon milk new line eggs")
        XCTAssertEqual(["type:Shopping list: milk", "keys:Enter", "type:Eggs"], desktop.actions.lastItems(3))
    }

    func testPushToTalkTypesIntoWhateverIsFocused() throws {
        desktop.foreground = Self.outlook
        desktop.field = .unknown
        desktop.trailingNonWhitespace = true
        try controller.insertDictation("uh thanks for the update new line talk soon")
        XCTAssertEqual(["type: Thanks for the update", "keys:Shift+Enter", "type:Talk soon"], desktop.actions)
        XCTAssertEqual("Thanks for the update\nTalk soon", controller.lastTranscript)
    }

    func testPushToTalkRefusesPasswordFields() throws {
        desktop.foreground = Self.outlook
        desktop.field = .password
        try controller.insertDictation("hunter2")
        XCTAssertEqual([], desktop.actions)
    }

    func testPasteLastTranscriptRetypesIt() throws {
        desktop.foreground = Self.outlook
        try controller.insertDictation("Hello there.")
        desktop.actions.removeAll()
        try controller.repeatLastTranscript()
        XCTAssertEqual(["type:Hello there."], desktop.actions)
    }

    // MARK: Beyond the C# tests

    func testTheDefaultWakeWordsSurviveRecognitionSlips() {
        // The controller's standby pass (C#'s WorthTranscribingInStandby) asks the parser these.
        let parser = CommandParser()
        let cases = [
            ("Hey Jarvis, open", true), ("Hey Jervis", true), ("hey jar vis open", true), ("Jarvi, open Note", true),
            ("So the quarterly numbers look", false), ("Thanks everyone for joining", false), ("Yes", false),
            ("", false),
        ]
        check(cases) { parser.mayContainWakeWord($0) }
        check([("Open the downloads folder in", true), ("So the quarterly numbers look", false)]) {
            CommandParser.mayStartCommand($0)
        }
    }

    // The Mac's back and forward (ShortcutKeys.backForwardInBrowsersOnly): ⌘[ and ⌘] change the indentation or list
    // level in other apps.
    private static let notes = windowRef(600, 6, "com.apple.Notes", "Notes")
    private static let safari = windowRef(700, 7, "com.apple.Safari", "Apple")
    private static let finder = windowRef(800, 8, "com.apple.finder", "Downloads")

    func testOnTheMacBackAndForwardArePressedOnlyInBrowsersAndFinder() async throws {
        // Chrome is a browser by its app profile here; Safari by the Mac's list.
        for (window, pressed) in [(Self.safari, true), (Self.finder, true), (Self.chrome, true), (Self.notes, false)] {
            for (heard, chord, word) in [("Go back.", "Cmd+[", "Back"), ("Go forward.", "Cmd+]", "Forward")] {
                let (desktop, controller, statuses) = makeController(CommandParser(keys: .mac))
                desktop.brainPlatform = .mac
                desktop.foreground = window
                try await controller.handleTranscript("Hey Jarvis, " + heard, 0.9)
                let label = "\(window.processName): \(heard)"
                XCTAssertEqual(pressed ? ["keys:\(chord)"] : [], desktop.actions, label)
                if !pressed {
                    XCTAssertEqual(.warning, statuses.last?.kind, label)
                    XCTAssertEqual("\(word) works in browsers and Finder.", statuses.last?.message, label)
                }
            }
        }
    }

    func testOnWindowsBackAndForwardArePressedAnywhereAsInTheCSharp() async throws {
        desktop.foreground = Self.notepadWindow
        try await say("Hey Jarvis, go back.")
        XCTAssertEqual(["keys:Alt+Left"], desktop.actions)
    }

    func testABackTheMacRefusesLeavesTheTypingTargetBound() async throws {
        let (desktop, controller, _) = makeController(CommandParser(keys: .mac))
        desktop.brainPlatform = .mac
        desktop.foreground = Self.notes
        try await controller.handleTranscript("Hey Jarvis, start typing.", 0.9)
        XCTAssertEqual(Self.notes, controller.target)
        try await controller.handleTranscript("Hey Jarvis, go back.", 0.9)
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("keys:") })
        XCTAssertEqual(Self.notes, controller.target)
    }
}
