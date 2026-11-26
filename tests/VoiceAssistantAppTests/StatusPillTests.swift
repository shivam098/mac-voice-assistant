import AppKit
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// What the pill shows, without a window: the same states, texts, colours and timings as the Windows pill
/// (windows-voice-assistant src/VoiceAssistant.App/UI/OverlayWindow.xaml.cs); and the panel's minimizing.
final class StatusPillTests: XCTestCase {
    func testItSaysStartingThenEachModeWithTheDictationKey() {
        var pill = StatusPill.Model()
        XCTAssertEqual(pill.display.mode, "Starting…")
        XCTAssertEqual(pill.display.dot, Colour(0x9AA0A6))
        XCTAssertTrue(pill.isShown)

        let modes: [(InteractionMode, String, UInt32)] = [
            (.standby, "Say “Hey Jarvis” · tap Fn to dictate", 0x8AB4F8),
            (.command, "Listening for a command", 0x4C8DF6),
            (.dictation, "Typing — say “stop typing” when done", 0xEA4335),
            (.paused, "Paused · tap Fn to dictate", 0x9AA0A6),
        ]
        for (mode, text, colour) in modes {
            pill.showMode(mode)
            let display = pill.display
            XCTAssertEqual(display.mode, text)
            XCTAssertEqual(display.dot, Colour(colour), text)
            XCTAssertFalse(display.dotPulses)
            XCTAssertNil(display.bars)
            XCTAssertNil(display.hint)
            XCTAssertNil(display.dots)
        }

        var other = StatusPill.Model(keyName: "Right Option")
        other.showMode(.standby)
        XCTAssertEqual(other.display.mode, "Say “Hey Jarvis” · tap Right Option to dictate")

        // Any other activity shows in amber.
        pill.showMode(.standby, activity: "Loading speech model…")
        XCTAssertEqual(pill.display.mode, "Loading speech model…")
        XCTAssertEqual(pill.display.dot, Colour(0xFBBC04))
        XCTAssertFalse(pill.display.dotPulses)
    }

    func testMinimizedItShowsOnlyWhileThereIsSomethingToShow() {
        var pill = StatusPill.Model()
        pill.showMode(.standby)
        XCTAssertTrue(pill.isShown, "always on screen unless minimized")
        XCTAssertTrue(pill.setMinimized(true))
        XCTAssertFalse(pill.setMinimized(true), "no change")
        XCTAssertFalse(pill.isShown)

        pill.showMode(.command)
        XCTAssertTrue(pill.isShown, "listening for a command")
        pill.showMode(.standby, activity: "Hearing you…")
        XCTAssertTrue(pill.isShown, "an activity")
        pill.showMode(.standby)
        XCTAssertFalse(pill.isShown)
        pill.showMode(.dictation)
        XCTAssertTrue(pill.isShown, "typing")
        pill.showStatus(AssistantStatus(mode: .paused, kind: .info, message: "Listening paused."))
        XCTAssertTrue(pill.isShown, "a message")
        pill.fadeStatus()
        XCTAssertFalse(pill.isShown, "the message went")
        pill.showStatus(AssistantStatus(mode: .standby, kind: .info, message: "", place: "Chrome"))
        XCTAssertEqual(pill.display.place, "📍 Chrome")
        XCTAssertFalse(pill.isShown, "a place alone doesn't keep it up")

        XCTAssertTrue(pill.setMinimized(false))
        XCTAssertTrue(pill.isShown)

        // Without a wake word, listening for a command is the resting state.
        var idle = StatusPill.Model(commandModeIsIdle: true, minimized: true)
        XCTAssertFalse(idle.isShown, "starts minimized without showing first")
        idle.showMode(.command)
        XCTAssertFalse(idle.isShown)
        idle.showMode(.dictation)
        XCTAssertTrue(idle.isShown)
    }

    func testTheMinimizeButtonHidesItAtOnceUntilTheNextChange() {
        var pill = StatusPill.Model()
        pill.showMode(.dictation)
        XCTAssertTrue(pill.minimizeNow())
        XCTAssertTrue(pill.minimized)
        XCTAssertFalse(pill.isShown, "hidden although it's typing")

        pill.showMode(.dictation)
        XCTAssertTrue(pill.isShown, "the next change brings it back while it's busy")
        XCTAssertFalse(pill.minimizeNow(), "minimized already")
        XCTAssertFalse(pill.isShown)
    }

    func testADictationShowsTheLevelMeterAndHowToFinish() throws {
        var pill = StatusPill.Model()
        pill.showMode(.standby, activity: StatusPill.listening)
        let display = pill.display
        XCTAssertEqual(display.mode, "Listening…")
        XCTAssertNil(display.dot, "the meter takes the dot's place")
        XCTAssertEqual(display.bars, [4, 4, 4, 4, 4])
        XCTAssertEqual(display.hint, "Fn to finish · Esc to cancel")

        pill.showInputLevel(0.5) { 0.5 }
        XCTAssertEqual(pill.level, 0.5, accuracy: 1e-9)
        try assertBars([7.85, 9.6, 11, 9.6, 7.85], pill)
        pill.showInputLevel(0) { 0.5 }
        XCTAssertEqual(pill.level, 0.3, accuracy: 1e-9, "it falls back gently")

        // Full level, wobbling up 20%: no bar grows past 18 points.
        pill.showInputLevel(1) { 1 }
        try assertBars([13.24, 17.44, 18, 17.44, 13.24], pill)

        // The same recording goes on; the level moves only while listening; a new recording starts from silence.
        pill.showMode(.standby, activity: StatusPill.listening)
        XCTAssertEqual(pill.level, 1, accuracy: 1e-9)
        pill.showMode(.standby)
        pill.showInputLevel(0.2) { 0.5 }
        XCTAssertEqual(pill.level, 1, accuracy: 1e-9)
        pill.showMode(.standby, activity: StatusPill.listening)
        XCTAssertEqual(pill.level, 0)
    }

    func testTranscribingAnimatesAndKeepsTheWordsHeardDimmedUntilTheTextIsTyped() {
        var pill = StatusPill.Model()
        pill.showMode(.standby, activity: StatusPill.listening)
        pill.showPreview("Hello there")
        XCTAssertEqual(pill.display.preview, "Hello there")
        XCTAssertEqual(pill.display.previewOpacity, 1)

        pill.showMode(.standby, activity: StatusPill.transcribing)
        var display = pill.display
        XCTAssertEqual(display.mode, "Transcribing")
        XCTAssertEqual(display.dots, "")
        XCTAssertEqual(display.dot, Colour(0xFBBC04))
        XCTAssertTrue(display.dotPulses)
        XCTAssertNil(display.bars)
        XCTAssertNil(display.hint)
        XCTAssertEqual(display.previewOpacity, 0.6)
        XCTAssertTrue(pill.isTranscribing)

        var dots: [String?] = []
        for _ in 0..<4 {
            pill.advanceDots()
            dots.append(pill.display.dots)
        }

        XCTAssertEqual(dots, [".", "..", "...", ""])

        // The last words stay until the text is typed.
        pill.showPreview(nil)
        pill.showPreview("")
        XCTAssertEqual(pill.display.preview, "Hello there")

        pill.showMode(.standby)
        display = pill.display
        XCTAssertNil(display.preview, "the typed text replaces them")
        XCTAssertNil(display.dots)
        XCTAssertEqual(display.mode, "Say “Hey Jarvis” · tap Fn to dictate")
        XCTAssertFalse(pill.isTranscribing)

        // A command is transcribed too, but it isn't a dictation: its dots start afresh, and no words stay.
        pill.advanceDots()
        pill.showMode(.command, activity: StatusPill.transcribing)
        XCTAssertEqual(pill.display.dots, "")
        pill.showPreview("open")
        pill.showPreview(nil)
        XCTAssertNil(pill.display.preview)
    }

    func testADictationOwnsThePillUntilItsTextIsTyped() {
        var pill = StatusPill.Model()
        pill.showMode(.standby, activity: StatusPill.listening)
        pill.showMode(.command, activity: "Hearing you…")
        XCTAssertEqual(pill.display.mode, "Listening…", "the voice's activity doesn't hide the meter")
        XCTAssertNotNil(pill.display.bars)

        pill.showStatus(AssistantStatus(mode: .standby, kind: .info, message: "Waiting for “Hey Jarvis”."))
        XCTAssertEqual(pill.display.mode, "Listening…", "a status keeps the recording on screen")
        XCTAssertEqual(pill.display.message, "Waiting for “Hey Jarvis”.")

        pill.showMode(.standby, activity: StatusPill.transcribing)
        pill.showMode(.standby, activity: "Hearing you…")
        XCTAssertEqual(pill.display.mode, "Transcribing")
        pill.showMode(.standby)
        XCTAssertEqual(pill.display.mode, "Say “Hey Jarvis” · tap Fn to dictate")

        // Without a dictation, a status clears the activity.
        pill.showMode(.command, activity: "Hearing you…")
        pill.showStatus(AssistantStatus(mode: .command, kind: .success, message: "Opened Notes."))
        XCTAssertEqual(pill.display.mode, "Listening for a command")
    }

    func testStatusesShowTheMessageWhatWasHeardAndWhereInTheirColoursThenFade() {
        var pill = StatusPill.Model()
        let kinds: [(StatusKind, UInt32)] = [
            (.info, 0xE8EAED), (.success, 0x81C995), (.warning, 0xFDD663), (.error, 0xF28B82),
        ]
        for (kind, colour) in kinds {
            pill.showStatus(AssistantStatus(mode: .standby, kind: kind, message: "Opened Chrome."))
            XCTAssertEqual(pill.display.message, "Opened Chrome.")
            XCTAssertEqual(pill.display.messageColour, Colour(colour))
        }

        pill.showStatus(
            AssistantStatus(
                mode: .command, kind: .warning, message: "Say that again?", heard: "open crom",
                place: "Chrome › YouTube"))
        XCTAssertEqual(pill.display.heard, "Heard: “open crom”")
        XCTAssertEqual(pill.display.place, "📍 Chrome › YouTube")

        pill.showStatus(AssistantStatus(mode: .command, kind: .success, message: "Typed.", heard: "hello"))
        XCTAssertEqual(pill.display.message, "Typed.", "every message shows, as on Windows")
        XCTAssertEqual(pill.display.heard, "Heard: “hello”")
        XCTAssertNil(pill.display.place, "the place goes with the message that put the assistant there")

        pill.fadeStatus()
        XCTAssertNil(pill.display.message)
        XCTAssertNil(pill.display.heard)
        XCTAssertNil(pill.display.place)
    }

    func testTheWordsHeardKeepTheLatestOnesAndHideTheMessage() {
        var pill = StatusPill.Model()
        pill.showMode(.standby, activity: StatusPill.listening)
        pill.showStatus(
            AssistantStatus(
                mode: .standby, kind: .warning, message: "No sound from the microphone.", heard: "um", place: "Notes"))

        let a = String(repeating: "a", count: 100)
        let b = String(repeating: "b", count: 100)
        pill.showPreview(a + " " + b)
        XCTAssertEqual(pill.display.preview, "…" + b, "from the first word in the last 150")
        XCTAssertNil(pill.display.message)
        XCTAssertNil(pill.display.heard)
        XCTAssertEqual(pill.display.place, "📍 Notes", "the place stays until the status fades")

        let c = String(repeating: "c", count: 160)
        pill.showPreview(c)
        XCTAssertEqual(pill.display.preview, "…" + String(repeating: "c", count: 150), "no word starts there")

        // A cut inside an emoji's two units starts after it.
        pill.showPreview(String(repeating: "😀", count: 80) + "y")
        XCTAssertEqual(pill.display.preview, "…" + String(repeating: "😀", count: 74) + "y")

        pill.showPreview("Hi Sam,\nThanks")
        XCTAssertEqual(pill.display.preview, "Hi Sam,\nThanks", "a line break stays, as on Windows")

        pill.showPreview(nil)
        XCTAssertNil(pill.display.preview)
    }

    func testTheLanguageBadge() {
        var pill = StatusPill.Model()
        XCTAssertNil(pill.display.badge)

        pill.setDictationLanguage(hinglish: true, accurate: false)
        XCTAssertEqual(pill.display.badge, "HI + EN")

        pill.setDictationLanguage(hinglish: true, accurate: true)
        XCTAssertEqual(pill.display.badge, "HI + EN · accurate")

        pill.setDictationLanguage(hinglish: false, accurate: true)
        XCTAssertNil(pill.display.badge)
    }

    /// The panel on screen, with Reduce motion on so it shows and hides at once.
    @MainActor
    func testThePanelSaysWhenItsMinimizedAndItsButtonTakesItAway() {
        _ = NSApplication.shared
        let reduceMotion = Motion.reduceMotion
        Motion.reduceMotion = { true }
        defer { Motion.reduceMotion = reduceMotion }
        let pill = StatusPill.Panel()
        defer { pill.close() }
        var changes: [Bool] = []
        pill.onMinimizedChanged = { changes.append($0) }

        pill.showMode(.standby)
        XCTAssertTrue(pill.isOnScreen)
        pill.minimized = true
        XCTAssertFalse(pill.isOnScreen)
        pill.minimized = true
        pill.minimized = false
        XCTAssertTrue(pill.isOnScreen)
        XCTAssertEqual(changes, [true, false])

        pill.showMode(.dictation)
        pill.minimizeClicked()
        XCTAssertFalse(pill.isOnScreen, "the button takes it away although it's typing")
        XCTAssertEqual(changes, [true, false, true])
        pill.showStatus(AssistantStatus(mode: .dictation, kind: .info, message: "Typing into Notes."))
        XCTAssertTrue(pill.isOnScreen, "the next change brings it back")
    }

    /// AppKit shows tooltips only in the active app unless the window allows them, and the app is never active while the
    /// pill, the cards or the balloon are used: their panels allow them, so the badge and the minimize button have
    /// theirs, as on Windows.
    @MainActor
    func testTheFloatingPanelsShowTooltipsWhileTheAppIsInactive() {
        _ = NSApplication.shared
        let panel = FloatingPanel.make(FirstClickHostingView(rootView: StatusPill.MinimizeButton(action: {})))
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive)
        XCTAssertFalse(panel.canBecomeKey, "and they never take the keyboard")
    }

    private func assertBars(_ expected: [Double], _ pill: StatusPill.Model, line: UInt = #line) throws {
        let bars = try XCTUnwrap(pill.display.bars, line: line)
        XCTAssertEqual(expected.count, bars.count, line: line)
        for (want, got) in zip(expected, bars) {
            XCTAssertEqual(want, got, accuracy: 1e-6, line: line)
        }
    }
}
