import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// The same cases as windows-voice-assistant tests/VoiceAssistant.Core.Tests/CommandParserTests.cs.
final class CommandParserTests: XCTestCase {
    private let parser = CommandParser()

    func testStandaloneSendWhileTypingIsACommand() {
        for heard in ["Send.", "send it", " Submit! ", "Computer, send."] {
            let parsed = parser.parse(heard, .dictation)
            XCTAssertEqual([VoiceCommand(.send)], parsed.commands, heard)
            XCTAssertNil(parsed.dictationText, heard)
        }
    }

    func testSendInsideASentenceIsTyped() {
        let sentences = [
            "Please send me the latest build logs.", "Send it to the team after review.", "Click send when ready.",
            "I will send",
        ]
        for heard in sentences {
            let parsed = parser.parse(heard, .dictation)
            XCTAssertEqual([], parsed.commands, heard)
            XCTAssertEqual(DotNet.trim(heard), parsed.dictationText, heard)
        }
    }

    func testDictationCommands() {
        let cases: [(String, CommandKind)] = [
            ("Scratch that.", .scratchThat), ("Clear box", .clearBox), ("New line.", .newLine),
            ("New paragraph", .newParagraph), ("Stop typing.", .stopTyping), ("Pause listening.", .pauseListening),
        ]
        for (heard, kind) in cases {
            XCTAssertEqual(kind, single(heard), heard)
        }
    }

    func testOpenAppInCommandMode() {
        let cases = [
            ("Open GitHub Co-Pilot.", "github copilot"), ("open github copilot", "github copilot"),
            ("Launch Microsoft Teams", "microsoft teams"),
        ]
        for (heard, app) in cases {
            let commands = parser.parse(heard, .command).commands
            XCTAssertEqual([VoiceCommand(.openApp, app)], commands, heard)
        }
    }

    func testOpenAndStartTypingIsChained() {
        let parsed = parser.parse("Open GitHub Co-pilot and start typing.", .command)
        XCTAssertEqual([VoiceCommand(.openApp, "github copilot"), VoiceCommand(.startTyping)], parsed.commands)
    }

    func testOpenInDictationModeIsTypedNotExecuted() {
        let parsed = parser.parse("Open GitHub Copilot.", .dictation)
        XCTAssertEqual([], parsed.commands)
        XCTAssertEqual("Open GitHub Copilot.", parsed.dictationText)
    }

    func testStartTypingIsNotParsedAsOpeningAnAppNamedTyping() {
        XCTAssertEqual([VoiceCommand(.startTyping)], parser.parse("Start typing.", .command).commands)
    }

    func testUnknownCommandModeSpeechIsUnrecognizedNotTyped() {
        for heard in ["What's the weather like", "open"] {
            let parsed = parser.parse(heard, .command)
            XCTAssertEqual([], parsed.commands, heard)
            XCTAssertNil(parsed.dictationText, heard)
            XCTAssertNotNil(parsed.unrecognized, heard)
        }
    }

    func testNonSpeechIsIgnored() {
        for heard in ["[BLANK_AUDIO]", "(upbeat music)", " . ", ""] {
            XCTAssertTrue(parser.parse(heard, .dictation).isEmpty, heard)
            XCTAssertTrue(parser.parse(heard, .command).isEmpty, heard)
        }
    }

    func testPausedIgnoresEverything() {
        XCTAssertTrue(parser.parse("Send.", .paused).isEmpty)
    }

    func testStrictPrefixModeTypesBareCommandWords() {
        let strict = CommandParser(requirePrefixWhileTyping: true)
        XCTAssertEqual("Send.", strict.parse("Send.", .dictation).dictationText)
        XCTAssertEqual([VoiceCommand(.send)], strict.parse("Computer, send.", .dictation).commands)
    }

    func testPrefixedUnknownCommandIsNotTyped() {
        let parsed = parser.parse("Computer, make coffee.", .dictation)
        XCTAssertNil(parsed.dictationText)
        XCTAssertEqual("make coffee", parsed.unrecognized)
    }

    func testAnnotationsAreRemovedFromDictation() {
        XCTAssertEqual("Hello there.", parser.parse("[MUSIC] Hello there.", .dictation).dictationText)
    }

    /// `Assert.Single(commands).Kind`: the kind of the only command, nil when there isn't exactly one.
    private func single(_ heard: String) -> CommandKind? {
        let commands = parser.parse(heard, .dictation).commands
        return commands.count == 1 ? commands[0].kind : nil
    }
}
