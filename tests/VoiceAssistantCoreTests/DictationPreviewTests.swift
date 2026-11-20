import ThumbFreeCore
import XCTest

private let rate = 16000

/// `(TimeSpan.FromSeconds(start), TimeSpan.FromSeconds(end))` from the C# test: .NET keeps whole ticks of 100 ns, so
/// the seconds here are the same doubles as there, and every sample position comes out the same.
private func seg(_ start: Double, _ end: Double) -> SpeechRegion { SpeechRegion(start: ticks(start), end: ticks(end)) }

private func ticks(_ seconds: Double) -> Double { Double(Int64(seconds * 10_000_000)) / 10_000_000 }

/// Audio whose sample values are their absolute index, so fakes can tell which part they got.
private func audio(_ seconds: Double) -> [Float] { (0..<Int(Double(rate) * seconds)).map { Float($0) } }

/// Speech detector over absolute regions, answering for any slice of `audio` (as in C#, `from` is single precision).
private func detector(_ absolute: SpeechRegion...) -> ([Float]) -> [SpeechRegion] {
    { slice in
        let from = Double(slice.isEmpty ? 0 : slice[0] / Float(rate))
        let to = from + Double(slice.count) / Double(rate)
        return absolute
            .filter { $0.end > from && $0.start < to }
            .map { seg(max($0.start, from) - from, min($0.end, to) - from) }
    }
}

/// `$"[{slice[0] / Rate:0.#}-{(slice[^1] + 1) / Rate:0.#}]"`.
private func label(_ slice: [Float]) -> String {
    "[\(oneDecimal(slice[0] / Float(rate)))-\(oneDecimal((slice[slice.count - 1] + 1) / Float(rate)))]"
}

/// .NET's "0.#" format: at most one decimal, rounded half away from zero.
private func oneDecimal(_ value: Float) -> String {
    let rounded = (Double(value) * 10).rounded(.toNearestOrAwayFromZero) / 10
    return rounded == rounded.rounded(.towardZero) ? String(Int(rounded)) : String(rounded)
}

/// Calls the fakes saw.
private final class Calls {
    var labels: [String] = []
    var count = 0
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/DictationPreviewTests.cs, run against ThumbFreeCore's
/// `DictationPreview` (Jarvis's C# copy is ThumbFree's without the phrase options). Every case comes out as Jarvis's C#
/// test expects.
final class DictationPreviewTests: XCTestCase {
    func testShortRecordingIsTranscribedWholeEachUpdate() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { calls.labels.append(label($0)); return "hello" },
            detect: detector(seg(0.5, 3)),
            sampleRate: rate)

        let first = try await preview.update(audio(2))
        let second = try await preview.update(audio(4))
        XCTAssertEqual("hello", first)
        XCTAssertEqual("hello", second)
        XCTAssertEqual(["[0-2]", "[0-4]"], calls.labels)
        XCTAssertEqual(0, preview.committedSamples)
    }

    func testSilenceIsNotTranscribed() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { _ in calls.count += 1; return "you" }, detect: detector(), sampleRate: rate)

        let text = try await preview.update(audio(3))
        XCTAssertEqual("", text)
        XCTAssertEqual(0, calls.count)
    }

    func testLongRecordingCommitsTheOldestPartAtAPauseAndKeepsItsText() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { calls.labels.append(label($0)); return label($0) },
            detect: detector(seg(0, 5), seg(6, 11), seg(12.5, 20)),
            sampleRate: rate)

        var text = try await preview.update(audio(16))

        // Latest pause inside the 12 s window is between 11 s and 12.5 s.
        XCTAssertEqual(rate * 23 / 2 + rate * 1 / 4, preview.committedSamples)
        XCTAssertEqual(["[0-11.8]", "[11.8-16]"], calls.labels)
        XCTAssertEqual("[0-11.8] [11.8-16]", text)

        calls.labels.removeAll()
        let longer = audio(18)
        text = try await preview.update(Array(longer[preview.committedSamples...]))
        XCTAssertEqual(["[11.8-18]"], calls.labels)
        XCTAssertEqual("[0-11.8] [11.8-18]", text)
    }

    func testUnbrokenSpeechIsCutAtTheWindow() async throws {
        let preview = DictationPreview(transcribe: { label($0) }, detect: detector(seg(0, 30)), sampleRate: rate)

        let text = try await preview.update(audio(30))

        XCTAssertEqual(rate * 24, preview.committedSamples)
        XCTAssertEqual("[0-12] [12-24] [24-30]", text)
    }

    func testLongSilenceIsDroppedWithoutTranscribing() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { _ in calls.count += 1; return "x" }, detect: detector(), sampleRate: rate)

        let text = try await preview.update(audio(20))
        XCTAssertEqual("", text)
        XCTAssertEqual(rate * 19, preview.committedSamples)
        XCTAssertEqual(0, calls.count)
    }

    func testWithoutADetectorAllAudioCountsAsSpeech() async throws {
        let preview = DictationPreview(transcribe: { label($0) }, detect: nil, sampleRate: rate)

        let text = try await preview.update(audio(2))
        XCTAssertEqual("[0-2]", text)
    }

    func testCommitPointPrefersTheLatestPauseInsideTheWindow() {
        let speech = [seg(0, 2), seg(3, 6), seg(7, 13)]
        let cut = DictationPreview.findCommitPoint(speech, rate * 13, rate, rate * 12, rate * 3)
        XCTAssertEqual(rate * 13 / 2, cut)
    }

    func testCommitPointIgnoresPausesTooEarlyToBeWorthCommitting() {
        let cut = DictationPreview.findCommitPoint([seg(0, 1), seg(1.5, 14)], rate * 14, rate, rate * 12, rate * 3)
        XCTAssertEqual(rate * 12, cut)
    }
}
