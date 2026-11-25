import AVFoundation
import XCTest
@testable import VoiceAssistantApp

/// The cues (windows-voice-assistant `SoundFeedback`): Windows' notes, rendered as Windows renders them, in a file
/// macOS plays.
final class SoundFeedbackTests: XCTestCase {
    func testEachCueIsWindowsNotesAtLowVolume() {
        let lengths = [Cue.wake, .startTyping, .stopTyping, .standby].map {
            SoundFeedback.render(SoundFeedback.notes($0)).count
        }

        // 22,050 samples a second: 70 + 90 ms, 110 ms, 70 + 90 ms and 80 ms, each rounded down as C# divides.
        XCTAssertEqual(lengths, [1543 + 1984, 2425, 1543 + 1984, 1764])
        let tone = SoundFeedback.render(SoundFeedback.notes(.startTyping))
        XCTAssertEqual(tone.first, 0)
        let peak = tone.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 3800)
        XCTAssertLessThanOrEqual(peak, 3932)
    }

    func testTheToneIsAWaveFileMacOSPlays() throws {
        let samples = SoundFeedback.render(SoundFeedback.notes(.wake))
        let data = SoundFeedback.wav(samples)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")

        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.format.sampleRate, 22_050)
        XCTAssertEqual(player.format.channelCount, 1)
        XCTAssertEqual(player.duration, Double(samples.count) / 22_050, accuracy: 0.001)
    }
}
