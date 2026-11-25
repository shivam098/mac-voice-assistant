import AppKit
import ThumbFreeMac
import XCTest
@testable import VoiceAssistantApp

/// The app's startup (windows-voice-assistant App.xaml.cs): its command line, the menu until the UI lands, and the Esc
/// that stops the AI brain.
final class AppControllerTests: XCTestCase {
    @MainActor
    func testTheMenuSaysTheAppIsInDevelopmentAndQuits() throws {
        let items = AppController.menu().items

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "Voice Assistant for Mac — in development")
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertEqual(items[2].title, "Quit Voice Assistant")
        XCTAssertEqual(items[2].keyEquivalent, "q")
        XCTAssertEqual(items[2].action, #selector(NSApplication.terminate(_:)))
    }

    func testTheCommandLineIsReadAsWindowsReadsIt() {
        XCTAssertEqual(
            LaunchOptions(["VoiceAssistant", "--self-test", "lab.txt"]).selfTest,
            LaunchOptions.SelfTestFiles(script: "lab.txt", output: "lab.txt.out.txt"))
        let withOutput = LaunchOptions(["VoiceAssistant", "--self-test", "lab.txt", "out.txt"])
        XCTAssertEqual(withOutput.selfTest?.output, "out.txt")
        XCTAssertNil(LaunchOptions(["VoiceAssistant", "--self-test"]).selfTest)
        XCTAssertNil(LaunchOptions(["VoiceAssistant", "lab.txt", "--self-test"]).selfTest)

        let restarted = LaunchOptions(["VoiceAssistant", "--restarted", "--background"])
        XCTAssertTrue(restarted.restarted)
        XCTAssertTrue(restarted.background)
        XCTAssertFalse(LaunchOptions(["VoiceAssistant"]).background)
        XCTAssertTrue(LaunchOptions(["VoiceAssistant", "--bundle-identifier"]).printBundleIdentifier)
    }

    /// Esc is told before the dictation keys see it, so the app still knows whether it cancels a recording; only a
    /// press counts, and never one this app posted.
    func testEscIsToldBeforeTheDictationKeysSeeIt() {
        let inner = FakeEventSource()
        let seen = Locked<[String]>([])
        let source = EscapeWatchingSource(inner) { seen.update { $0.append("escape") } }
        let mode = source.start { _ in
            seen.update { $0.append("keys") }
            return false
        }

        XCTAssertEqual(mode, .active)
        inner.send(HotkeyTap.Event(.keyDown, keyCode: 0x35))
        XCTAssertEqual(seen.value, ["escape", "keys"])

        inner.send(HotkeyTap.Event(.keyUp, keyCode: 0x35))
        inner.send(HotkeyTap.Event(.keyDown, keyCode: 0x35, fromThisApp: true))
        inner.send(HotkeyTap.Event(.keyDown, keyCode: 0x00))
        XCTAssertEqual(seen.value, ["escape", "keys", "keys", "keys", "keys"])

        source.stop()
        XCTAssertTrue(inner.stopped)
    }
}

/// Key events from the test rather than a Quartz event tap.
final class FakeEventSource: HotkeyTap.EventSource {
    private var handler: (@Sendable (HotkeyTap.Event) -> Bool)?
    private(set) var stopped = false

    func start(_ handler: @escaping @Sendable (HotkeyTap.Event) -> Bool) -> HotkeyTap.Mode {
        self.handler = handler
        return .active
    }

    func stop() {
        stopped = true
    }

    func send(_ event: HotkeyTap.Event) {
        _ = handler?(event)
    }
}
