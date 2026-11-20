import XCTest
@testable import VoiceAssistantCore

/// The wake-word pre-check cases of windows-voice-assistant tests/VoiceAssistant.Core.Tests/WakeWordAndActionTests.cs
/// that need only the parser. The rest drive the interaction controller and come with it.
final class WakeWordAndActionTests: XCTestCase {
    func testCustomWakeWordsAreCheckedToo() {
        let parser = CommandParser(wakeWords: ["hey friday"])
        XCTAssertTrue(parser.mayContainWakeWord("Hey Fryday, open"))
        XCTAssertFalse(parser.mayContainWakeWord("Hey Jarvis, open"))
    }

    func testAWakeWordWithoutANameSkipsTheQuickPass() {
        XCTAssertTrue(CommandParser(wakeWords: ["hey pc"]).mayContainWakeWord("Hey PC"))
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
}
