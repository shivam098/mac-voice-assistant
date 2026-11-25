import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// InteractionControllerTests.cs's desktop: it records what it was asked to do ("open:GitHub Copilot", "type:Hello.",
/// "keys:Enter").
private final class FakeDesktop: JarvisDesktop {
    var actions: [String] = []
    var openResults: [String: WindowInfo] = [:]
    var foreground: WindowInfo?
    var prepareSucceeds = true
    var trailingText = false
    var field = AssistantFieldCheck.safe
    var unconfirmedOpen = false

    /// Opening an app cancels the controller's task (C#'s `OnOpen = cts.Cancel`).
    var cancelOnOpen = false
    var newWindowRequests: [Bool] = []
    var focusIsEditable: Bool? = true
    var trailingNonWhitespace: Bool?
    var searchBoxFound = true
    var brainPlatform: BrainPlatform { .windows }

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        actions.append("open:\(app.name)")
        newWindowRequests.append(newWindow)
        if cancelOnOpen {
            cancelCurrentTask()
        }

        if unconfirmedOpen {
            return .ok("Asked Windows to open it.")
        }

        if let window = openResults[app.name] {
            foreground = window
            return .ok("ok", window: window)
        }

        return .fail("nope")
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        actions.append("prepare:\(window.processName):\(profile?.textArea ?? "none")")
        return TextTargetResult(
            success: prepareSucceeds, message: prepareSucceeds ? "" : "no box", hasTrailingText: trailingText,
            focusIsEditable: focusIsEditable)
    }

    func checkFocusedField() -> AssistantFieldCheck { field }

    func focusedTextEndsWithNonWhitespace() -> Bool? { trailingNonWhitespace }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        actions.append("searchbox:\(window.processName)")
        return TextTargetResult(success: searchBoxFound, message: searchBoxFound ? "" : "no search box")
    }

    func typeText(_ text: String) throws { actions.append("type:\(text)") }

    func pressKeys(_ chord: String) throws { actions.append("keys:\(chord)") }

    func backspace(_ count: Int) throws { actions.append("backspace:\(count)") }
}

/// What a typing throws under secure input (ThumbFreeMac's `PasteTyper.Failure.secureInput` on the Mac).
private struct SecureInput: Error {}

/// A desktop that types a typing's line breaks itself, as the Mac's does (`typeText(_:newLineKeys:)`, recorded as
/// "lines(newLineKeys):text"), and can refuse a whole typing, as the Mac's does under secure input. Keys asked for by
/// name still go out.
private final class LineTypingDesktop: JarvisDesktop {
    let brainPlatform: BrainPlatform
    var actions: [String] = []
    var foreground: WindowInfo?

    /// What a typing throws, with nothing sent.
    var typingFailure: Error?

    init(_ platform: BrainPlatform) {
        brainPlatform = platform
    }

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult { .fail("nope") }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "", hasTrailingText: false, focusIsEditable: true)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "no search box")
    }

    func checkFocusedField() -> AssistantFieldCheck { .safe }

    func focusedTextEndsWithNonWhitespace() -> Bool? { false }

    func typeText(_ text: String) throws { actions.append("type:\(text)") }

    func typeText(_ text: String, newLineKeys: String) throws {
        if let typingFailure {
            throw typingFailure
        }

        actions.append("lines(\(newLineKeys)):\(text)")
    }

    func pressKeys(_ chord: String) throws { actions.append("keys:\(chord)") }

    func backspace(_ count: Int) throws { actions.append("backspace:\(count)") }
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/InteractionControllerTests.cs: opening an app, typing into
/// it and sending, "scratch that", what is refused, and the second dictation model.
final class InteractionControllerTests: XCTestCase {
    private static let copilot = windowRef(100, 1, "github", "GitHub Copilot")
    private static let other = windowRef(200, 2, "msedge", "Browser")
    private static let copilotApp = AppEntry(
        name: "GitHub Copilot", launch: "copilot", processNames: ["github"], windowTitleContains: "GitHub Copilot",
        textArea: "Bottom")
    private static let noWake = ControllerOptions(wakeWordEnabled: false)
    private static let notepadApp = AppEntry(
        name: "Notepad", launch: "notepad.exe", processNames: ["Notepad"], submitKeys: "", newLineKeys: "Enter")

    private var desktop: FakeDesktop!
    private var controller: InteractionController!
    private let statuses = StatusLog()

    override func setUp() {
        super.setUp()
        let (newDesktop, newController) = makeController()
        desktop = newDesktop
        controller = newController
        controller.onStatus = statuses.add
        controller.setListening(true)
    }

    /// The C# test class's constructor, for each case of a theory.
    private func makeController() -> (FakeDesktop, InteractionController) {
        let desktop = FakeDesktop()
        desktop.openResults["GitHub Copilot"] = Self.copilot
        let controller = InteractionController(
            desktop, AppCatalog([Self.copilotApp, Self.notepadApp]), CommandParser(), options: Self.noWake)
        return (desktop, controller)
    }

    private func say(_ text: String, _ confidence: Float = 0.9, continuation: Bool = false) async throws {
        try await controller.handleTranscript(text, confidence, followsForcedCut: continuation)
    }

    private func startTypingInCopilot(file: StaticString = #filePath, line: UInt = #line) async throws {
        desktop.foreground = Self.copilot
        try await say("Start typing.")
        desktop.actions.removeAll()
        XCTAssertEqual(.dictation, controller.mode, file: file, line: line)
    }

    func testFullCopilotFlowOpensTypesAndSends() async throws {
        desktop.foreground = Self.other
        try await say("Open GitHub Co-Pilot.")
        try await say("Start typing.")
        try await say("Fix the failing test.")
        try await say("And add a regression check.")
        try await say("Send.")

        XCTAssertEqual(
            [
                "open:GitHub Copilot", "prepare:github:Bottom", "type:Fix the failing test.",
                "type: And add a regression check.", "keys:Enter",
            ],
            desktop.actions)
        XCTAssertEqual(.command, controller.mode)
    }

    func testOpenAndStartTypingInOneUtterance() async throws {
        desktop.foreground = Self.other
        try await say("Open GitHub Copilot and start typing.")
        XCTAssertEqual(.dictation, controller.mode)
        XCTAssertEqual(Self.copilot, controller.target)
    }

    func testSentenceContainingSendIsTypedNotSent() async throws {
        try await startTypingInCopilot()
        try await say("Please send me the logs.")
        XCTAssertFalse(desktop.actions.contains("keys:Enter"))
        XCTAssertTrue(desktop.actions.contains("type:Please send me the logs."))
    }

    func testFocusChangeBlocksTypingAndKeepsText() async throws {
        try await startTypingInCopilot()
        desktop.foreground = Self.other
        try await say("Secret plans.")
        try await say("Send.")

        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") || $0.hasPrefix("keys:") })
        XCTAssertEqual("Secret plans.", controller.untypedText)
        XCTAssertEqual(.command, controller.mode)
    }

    func testUntypedTextSurvivesRestartingTypingUntilCopied() async throws {
        try await startTypingInCopilot()
        desktop.foreground = Self.other
        try await say("Keep me.")
        desktop.foreground = Self.copilot
        try await say("Start typing.")
        XCTAssertEqual("Keep me.", controller.untypedText)
        controller.clearUntypedText()
        XCTAssertNil(controller.untypedText)
    }

    func testScratchThatRemovesOnlyTheLastPhrase() async throws {
        try await startTypingInCopilot()
        try await say("Hello.")
        try await say("Wrong words.")
        try await say("Scratch that.")
        XCTAssertEqual("backspace:13", desktop.actions.last)
        try await say("Scratch that.")
        XCTAssertEqual("backspace:6", desktop.actions.last)
        try await say("Scratch that.")
        XCTAssertEqual("backspace:6", desktop.actions.last)
    }

    func testExistingTextInBoxGetsALeadingSpace() async throws {
        desktop.trailingText = true
        try await startTypingInCopilot()
        try await say("More.")
        XCTAssertEqual("type: More.", desktop.actions.last)
    }

    func testNewLineResetsSpacingAndCanBeScratched() async throws {
        try await startTypingInCopilot()
        try await say("One.")
        try await say("New line.")
        try await say("Two.")
        XCTAssertEqual(["keys:Shift+Enter", "type:Two."], desktop.actions.lastItems(2))
        try await say("Scratch that.")
        try await say("Scratch that.")
        XCTAssertEqual("backspace:1", desktop.actions.last)
    }

    func testClearBoxSelectsAllAndDeletes() async throws {
        try await startTypingInCopilot()
        try await say("Draft.")
        try await say("Clear box.")
        XCTAssertEqual(["keys:Ctrl+A", "backspace:1"], desktop.actions.lastItems(2))
        try await say("Fresh.")
        XCTAssertEqual("type:Fresh.", desktop.actions.last)
    }

    func testSendInCommandModeRequiresATarget() async throws {
        desktop.foreground = Self.copilot
        try await say("Send.")
        XCTAssertFalse(desktop.actions.contains("keys:Enter"))
        XCTAssertEqual(.warning, statuses.last?.kind)
    }

    func testSendAfterStopTypingWorksWhenTargetStillInFront() async throws {
        try await startTypingInCopilot()
        try await say("Draft.")
        try await say("Stop typing.")
        XCTAssertEqual(.command, controller.mode)
        try await say("Send.")
        XCTAssertEqual("keys:Enter", desktop.actions.last)
    }

    func testAppWithoutSendActionRefusesSend() async throws {
        desktop.foreground = windowRef(300, 3, "Notepad", "Untitled - Notepad")
        try await say("Start typing.")
        try await say("Note.")
        try await say("Send.")
        XCTAssertFalse(desktop.actions.contains("keys:Enter"))
        XCTAssertTrue(statuses.last?.message.contains("no send action") == true)
    }

    func testPasswordFieldIsNeverTypedInto() async throws {
        try await startTypingInCopilot()
        desktop.field = .password
        try await say("hunter2")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
    }

    func testLowConfidenceCommandIsIgnoredEntirely() async throws {
        try await startTypingInCopilot()
        try await say("Send.", 0.2)
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("keys:") || $0.hasPrefix("type:") })
    }

    func testFailedPreparationStaysInCommandMode() async throws {
        desktop.foreground = Self.copilot
        desktop.prepareSucceeds = false
        try await say("Start typing.")
        XCTAssertEqual(.command, controller.mode)
        try await say("Hello.")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
    }

    func testChainedStartTypingIsSkippedWhenOpenFails() async throws {
        try await say("Open Photoshop and start typing.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual(.command, controller.mode)
    }

    func testPauseCommandRaisesPauseAndIgnoresFurtherSpeech() async throws {
        var paused = false
        controller.onPauseRequested = { paused = true }
        try await startTypingInCopilot()
        try await say("Pause listening.")
        XCTAssertTrue(paused)
        XCTAssertEqual(.paused, controller.mode)
        try await say("Hello.")
        XCTAssertFalse(desktop.actions.contains("type:Hello."))
    }

    func testStatusMessagesNeverIncludeDictatedTextExceptHeardField() async throws {
        try await startTypingInCopilot()
        try await say("Confidential roadmap.")
        for message in statuses.messages {
            XCTAssertFalse(message.contains("Confidential"), message)
        }
    }

    func testUnverifiableFieldIsNotTypedIntoAndTextIsKept() async throws {
        try await startTypingInCopilot()
        desktop.field = .unknown
        try await say("Maybe a password.")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
        XCTAssertEqual("Maybe a password.", controller.untypedText)
    }

    func testUnconfirmedOpenDoesNotChainIntoStartTyping() async throws {
        let catalog = AppCatalog([Self.copilotApp])
        catalog.setDiscoveredApps([AppEntry(name: "Outlook", launch: "outlook")])
        let controller = InteractionController(desktop, catalog, CommandParser(), options: Self.noWake)
        controller.setListening(true)
        desktop.foreground = Self.other
        desktop.unconfirmedOpen = true

        try await controller.handleTranscript("Open Outlook and start typing.", 0.9)

        XCTAssertEqual(["open:Outlook"], desktop.actions)
        XCTAssertEqual(.command, controller.mode)
        XCTAssertNil(controller.target)
    }

    func testContinuationAfterForcedCutIsTypedNeverExecuted() async throws {
        for tail in ["Send.", "Pause listening.", "Clear box."] {
            let (desktop, controller) = makeController()
            controller.setListening(true)
            desktop.foreground = Self.copilot
            try await controller.handleTranscript("Start typing.", 0.9)
            desktop.actions.removeAll()
            XCTAssertEqual(.dictation, controller.mode)

            try await controller.handleTranscript(tail, 0.9, followsForcedCut: true)
            XCTAssertEqual(["type:\(tail)"], desktop.actions, tail)
            XCTAssertEqual(.dictation, controller.mode, tail)
        }
    }

    func testContinuationOutsideTypingIsParsedNormally() async throws {
        // Only dictation needs protecting from a sentence tail; a stuck flag must not swallow commands.
        desktop.foreground = Self.copilot
        try await say("Start typing.", continuation: true)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testCancellationStopsAChainedCommand() async throws {
        desktop.foreground = Self.other
        desktop.cancelOnOpen = true
        let controller: InteractionController = self.controller
        let run = Task { try await controller.handleTranscript("Open GitHub Copilot and start typing.", 0.9) }
        do {
            try await run.value
            XCTFail("The chained command wasn't cancelled.")
        } catch is CancellationError {
        }

        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("prepare:") })
    }

    func testSecondModelTextIsTypedWhileDictating() async throws {
        try await startTypingInCopilot()
        try await controller.handleTranscript(
            "Kia discuss word achahe.", 0.9, dictationTranscript: { "Kya iska svaad achchha hai?" })
        XCTAssertEqual(["type:Kya iska svaad achchha hai?"], desktop.actions)
    }

    func testSecondModelIsUsedWhenTheEnglishModelHeardNothing() async throws {
        try await startTypingInCopilot()
        try await controller.handleTranscript("[INAUDIBLE]", 0.9, dictationTranscript: { "Kal milte hain." })
        XCTAssertEqual(["type:Kal milte hain."], desktop.actions)
    }

    func testCommandsWhileDictatingSkipTheSecondModel() async throws {
        try await startTypingInCopilot()
        var called = false
        try await controller.handleTranscript("Send.", 0.9, dictationTranscript: {
            called = true
            return "Sand."
        })
        XCTAssertFalse(called)
        XCTAssertTrue(desktop.actions.contains("keys:Enter"))
    }

    func testSecondModelIsIgnoredOutsideDictation() async throws {
        var called = false
        try await controller.handleTranscript("Hello there.", 0.9, dictationTranscript: {
            called = true
            return "Namaste."
        })
        XCTAssertFalse(called)
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
    }

    func testSecondModelTypesTheTailOfACutSentence() async throws {
        try await startTypingInCopilot()
        try await controller.handleTranscript(
            "garbled", 0.9, followsForcedCut: true, dictationTranscript: { "aur phir hum chalenge" })
        XCTAssertEqual(["type:Aur phir hum chalenge"], desktop.actions.map { DotNet.trim($0) })
    }

    // MARK: Beyond the C# tests

    private static let platforms: [(BrainPlatform, ShortcutKeys)] = [(.windows, .windows), (.mac, .mac)]

    /// Typing into GitHub Copilot on a desktop that types a typing's line breaks itself.
    private func startTypingOnLineTypingDesktop(_ platform: BrainPlatform, _ keys: ShortcutKeys) async throws
        -> (LineTypingDesktop, InteractionController) {
        let desktop = LineTypingDesktop(platform)
        desktop.foreground = Self.copilot
        let controller = InteractionController(
            desktop, AppCatalog([Self.copilotApp]), CommandParser(keys: keys), options: Self.noWake)
        controller.setListening(true)
        try await controller.handleTranscript("Start typing.", 0.9)
        XCTAssertEqual(.dictation, controller.mode)
        return (desktop, controller)
    }

    /// A typing with line breaks (dictated or push-to-talk), "new line" and "new paragraph" each reach the desktop as
    /// one typing with the app's new-line keys, so the desktop can refuse it whole. (The C# tests above check the
    /// protocol's default, which types each line and presses the keys between them, as before.)
    func testTypingsWithLineBreaksAndNewLinesReachTheDesktopAsOneTyping() async throws {
        for (platform, keys) in Self.platforms {
            let (desktop, controller) = try await startTypingOnLineTypingDesktop(platform, keys)
            try await controller.handleTranscript("Um, shopping list colon milk new line eggs", 0.9)
            try await controller.handleTranscript("New line.", 0.9)
            try await controller.handleTranscript("New paragraph.", 0.9)
            try controller.insertDictation("uh thanks for the update new line talk soon")
            let typed = [
                "lines(Shift+Enter):Shopping list: milk\nEggs", "lines(Shift+Enter):\n", "lines(Shift+Enter):\n\n",
                "lines(Shift+Enter):Thanks for the update\nTalk soon",
            ]
            XCTAssertEqual(typed, desktop.actions, "\(platform.kind)")

            // A typing can start with a line break, as "new line ls -la" does: still one typing.
            try await controller.handleTranscript("New line ls -la", 0.9)
            XCTAssertEqual(5, desktop.actions.count, "\(platform.kind)")
            XCTAssertTrue(desktop.actions.last?.hasPrefix("lines(Shift+Enter):\n") == true, desktop.actions.last ?? "")
        }
    }

    /// Where the desktop refuses a typing (the Mac's, under secure input), nothing of it goes out, not even the line
    /// break a typing starts with (Return would run Terminal's command line), and the failure reaches the host as
    /// typing failures do. Keys asked for by name ("press enter") still go out, as on Windows.
    func testATypingTheDesktopRefusesSendsNothingButPressEnterStillPresses() async throws {
        for (platform, keys) in Self.platforms {
            let (desktop, controller) = try await startTypingOnLineTypingDesktop(platform, keys)
            desktop.typingFailure = SecureInput()
            for spoken in ["New line ls -la", "New line.", "New paragraph."] {
                do {
                    try await controller.handleTranscript(spoken, 0.9)
                    XCTFail("\(platform.kind): “\(spoken)” wasn't refused.")
                } catch {
                    XCTAssertTrue(error is SecureInput, "\(platform.kind): \(spoken): \(error)")
                }
            }

            XCTAssertThrowsError(try controller.insertDictation("new line rm -rf build")) { error in
                XCTAssertTrue(error is SecureInput, "\(platform.kind): \(error)")
            }

            XCTAssertEqual([], desktop.actions, "\(platform.kind)")
            try await controller.handleTranscript("Press enter.", 0.9)
            XCTAssertEqual(["keys:Enter"], desktop.actions, "\(platform.kind)")
        }
    }
}
