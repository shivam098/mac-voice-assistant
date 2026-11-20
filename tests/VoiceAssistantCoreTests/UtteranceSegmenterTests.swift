import Foundation
import XCTest
@testable import VoiceAssistantCore

private let rate = 16000

/// Background hiss: `level` times uniform noise from .NET's `new Random(ms)`, so the samples are the C# test's.
private func silence(_ ms: Int, _ level: Float = 0.0005) -> [Float] {
    var random = DotNetRandom(ms)
    return (0..<(rate * ms / 1000)).map { _ in Float((random.nextDouble() * 2 - 1) * Double(level)) }
}

private func tone(_ ms: Int, _ amplitude: Float = 0.2) -> [Float] {
    (0..<(rate * ms / 1000)).map { i in
        Float(Double(amplitude) * sin(2 * Double.pi * 220 * Double(i) / Double(rate)) * syllable(i))
    }
}

/// Speech-like loudness: about 4 syllables a second with deep dips between them (a wide dynamic range).
private func syllable(_ i: Int) -> Double { 0.03 + (0.97 * pow(sin(Double.pi * 4 * Double(i) / Double(rate)), 2)) }

/// The utterances, fed in odd-sized pieces to exercise frame reassembly.
private func feed(_ segmenter: UtteranceSegmenter, _ chunks: [Float]...) -> [Utterance] {
    var output: [Utterance] = []
    segmenter.onUtteranceReady = { output.append($0) }
    for chunk in chunks {
        var i = 0
        while i < chunk.count {
            segmenter.push(chunk[i..<min(i + 777, chunk.count)])
            i += 777
        }
    }

    return output
}

/// Each utterance's length and whether it follows a forced cut.
private func shape(_ utterances: [Utterance]) -> [String] {
    utterances.map { "\($0.samples.count)\($0.followsForcedCut ? " after a cut" : "")" }
}

/// The same cases as windows-voice-assistant tests/VoiceAssistant.Core.Tests/UtteranceSegmenterTests.cs. Each also
/// checks the exact utterances the C# segmenter gives on the same audio (from the harness, `misc`).
final class UtteranceSegmenterTests: XCTestCase {
    func testSpeechFollowedByPauseEmitsOneUtterance() {
        let output = feed(UtteranceSegmenter(), silence(1000), tone(800), silence(900))
        XCTAssertEqual(1, output.count)
        XCTAssertTrue((rate * 800 / 1000...rate * 1800 / 1000).contains(output.first?.samples.count ?? 0))
        XCTAssertEqual(["24000"], shape(output))
    }

    func testTwoPhrasesSeparatedByALongPauseAreSplit() {
        let output = feed(UtteranceSegmenter(), silence(1000), tone(1500), silence(800), tone(400), silence(800))
        XCTAssertEqual(2, output.count)
        XCTAssertEqual(["35520", "17760"], shape(output))
    }

    func testShortPauseInsideASentenceDoesNotSplit() {
        let output = feed(UtteranceSegmenter(), silence(1000), tone(700), silence(300), tone(700), silence(900))
        XCTAssertEqual(1, output.count)
        XCTAssertEqual(["38400"], shape(output))
    }

    func testWhileTypingAThinkingPauseDoesNotSplitTheSentence() {
        let typing = UtteranceSegmenter()
        typing.longPauseMs = 1100
        let typed = feed(typing, silence(1000), tone(1500), silence(800), tone(1000), silence(1500))
        XCTAssertEqual(1, typed.count)
        XCTAssertEqual(["70560"], shape(typed))

        // The same audio in command mode is two phrases.
        let commands = feed(UtteranceSegmenter(), silence(1000), tone(1500), silence(800), tone(1000), silence(1500))
        XCTAssertEqual(2, commands.count)
        XCTAssertEqual(["35520", "27360"], shape(commands))
    }

    func testWhileTypingALongPauseStillEndsThePhrase() {
        let typing = UtteranceSegmenter()
        typing.longPauseMs = 1100
        let output = feed(typing, silence(1000), tone(1500), silence(1500), tone(1000), silence(1500))
        XCTAssertEqual(2, output.count)
        XCTAssertEqual(["41760", "33600"], shape(output))
    }

    func testClicksShorterThanMinimumSpeechAreDropped() {
        XCTAssertEqual([], feed(UtteranceSegmenter(), silence(1000), tone(120), silence(900)))
    }

    func testContinuousSpeechIsCapped() {
        let capped = UtteranceSegmenter(SegmenterOptions(maxUtteranceMs: 3000))
        let output = feed(capped, silence(500), tone(7000), silence(900))
        XCTAssertTrue(output.count >= 2, "continuous speech keeps producing capped utterances")
        XCTAssertTrue(output.allSatisfy { Double($0.samples.count) <= Double(rate) * 3.1 })
        XCTAssertEqual(["48000", "48000 after a cut", "27360 after a cut"], shape(output))
    }

    func testPreRollKeepsTheStartOfSpeech() {
        let output = feed(UtteranceSegmenter(), silence(1000), tone(500), silence(900))
        XCTAssertEqual(1, output.count)
        let first = output.first?.samples ?? []
        let level = UtteranceSegmenter.levelDbfs(first.prefix(480))
        XCTAssertTrue(level < -40, "utterance should begin with pre-roll silence")
        XCTAssertEqual(19200, first.count)
        XCTAssertEqual(-71.26630488306182, level, accuracy: 1e-9)
    }

    func testSteadyBackgroundNoiseDoesNotTrigger() {
        XCTAssertEqual([], feed(UtteranceSegmenter(), silence(5000, 0.003)))
    }

    func testLoudRoomAtStartupIsLearnedAsBackground() {
        // Steady -40 dBFS noise (fan, mic boost) must not become endless 14 s utterances.
        XCTAssertEqual([], feed(UtteranceSegmenter(), silence(20000, 0.017)))
    }

    func testNoiseThatStartsLaterIsAdaptedToAfterOneCappedCut() {
        let capped = UtteranceSegmenter(SegmenterOptions(maxUtteranceMs: 3000))
        let output = feed(capped, silence(2000), silence(30000, 0.03))
        XCTAssertTrue((1...2).contains(output.count))
        XCTAssertEqual(["48000"], shape(output))
    }

    func testSpeechIsStillDetectedAfterAdaptingToNoise() {
        let output = feed(
            UtteranceSegmenter(SegmenterOptions(maxUtteranceMs: 3000)),
            silence(2000), silence(10000, 0.01), tone(800, 0.3), silence(1500, 0.01))
        XCTAssertTrue(output.contains { $0.samples.count < rate * 2 })
        XCTAssertEqual(["48000", "23520"], shape(output))
    }

    func testUtteranceAfterAForcedCutIsFlaggedAsContinuation() {
        let segmenter = UtteranceSegmenter(SegmenterOptions(maxUtteranceMs: 3000))
        var output: [Utterance] = []
        segmenter.onUtteranceReady = { output.append($0) }
        segmenter.push(silence(500))
        segmenter.push(tone(4000))
        segmenter.push(silence(900))
        segmenter.push(tone(500))
        segmenter.push(silence(900))

        XCTAssertEqual([false, true, false], output.map { $0.followsForcedCut })
        XCTAssertEqual(["48000", "27360 after a cut", "19200"], shape(output))
    }

    func testRealPauseAfterAForcedCutClearsTheContinuationFlag() {
        // Speech that ends just as the cap is hit, then a long pause, then "send".
        let segmenter = UtteranceSegmenter(SegmenterOptions(maxUtteranceMs: 3000))
        var output: [Utterance] = []
        segmenter.onUtteranceReady = { output.append($0) }
        segmenter.push(silence(500))
        segmenter.push(tone(2750))
        segmenter.push(silence(2000))
        segmenter.push(tone(500))
        segmenter.push(silence(900))

        XCTAssertEqual(2, output.count)
        XCTAssertEqual(false, output.last?.followsForcedCut)
        XCTAssertEqual(["48000", "19200"], shape(output))
    }

    func testResetDiscardsPartialSpeech() {
        let segmenter = UtteranceSegmenter()
        var output: [[Float]] = []
        segmenter.onUtteranceReady = { output.append($0.samples) }
        segmenter.push(silence(1000))
        segmenter.push(tone(600))
        segmenter.reset()
        segmenter.push(silence(1000))
        XCTAssertEqual([], output)
    }

    // MARK: Beyond the C# tests

    func testTheTestAudioIsTheCSharpTests() {
        // .NET's Random(1000) and the samples the C# helpers make (from the harness, `misc`).
        var random = DotNetRandom(1000)
        XCTAssertEqual(
            [0.15155745910087481, 0.2359429496507826, 0.7560131669770987, 0.0010917768818753664],
            (0..<4).map { _ in random.nextDouble() })
        var other = DotNetRandom(20000)
        XCTAssertEqual(
            [0.2325270526262592, 0.1896771607872458, 0.5278322410433703, 0.41677290034330117],
            (0..<4).map { _ in other.nextDouble() })
        XCTAssertEqual(Float(5.946032e-05), silence(1000)[77])
        XCTAssertEqual(Float(-0.027955547), tone(800)[1234])
    }
}
