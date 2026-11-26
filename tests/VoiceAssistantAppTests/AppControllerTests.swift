import AppKit
import ThumbFreeMac
import XCTest
@testable import VoiceAssistantApp

/// The app's startup (windows-voice-assistant App.xaml.cs): its command line, its notices, and the Esc that stops the
/// AI brain. Its UI's wiring is in AppUITests.
final class AppControllerTests: XCTestCase {
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

    /// The notices still in force reach a handler added after launch too, oldest first: a notice of a topic replaces
    /// the topic's earlier one, and one withdrawn, or told once, isn't sent again.
    func testNoticesInForceReachAHandlerAddedLater() {
        let notices = NoticeEvent()
        let early = Locked<[String]>([])
        notices.subscribe { message in early.update { $0.append(message) } }
        let hotkey = "⌃⇧Z (paste last dictation) is used by another app."
        let fnKey = "Voice Assistant can't see the Fn key yet: allow it in System Settings."
        let rightOption = "Voice Assistant can't see the Right Option key yet: allow it in System Settings."
        notices.send(hotkey, topic: AppController.NoticeTopic.hotkey("paste last dictation"))
        notices.send(fnKey, topic: AppController.NoticeTopic.dictationKey)
        notices.send(AppController.thumbFreeNote, topic: AppController.NoticeTopic.thumbFree)
        notices.send("Couldn't restart. Quit from the menu bar and start Voice Assistant again.")
        notices.withdraw(AppController.NoticeTopic.thumbFree)
        notices.send(rightOption, topic: AppController.NoticeTopic.dictationKey)

        let late = Locked<[String]>([])
        notices.subscribe { message in late.update { $0.append(message) } }

        XCTAssertEqual(early.value.count, 5)
        XCTAssertEqual(late.value, [hotkey, rightOption])
        XCTAssertEqual(notices.inForce, [hotkey, rightOption])
    }

    /// A hotkey in settings.json that the Mac can't read (a Windows one such as F24) is told to a UI that subscribes
    /// after launch too.
    @MainActor
    func testAHotkeyItCantReadIsToldToAUIThatListensLater() {
        let folder = TempFolder()
        defer { folder.remove() }
        let controller = AppController(
            paths: AppPaths(data: folder.path, logs: folder.file("logs")), parts: AppParts(desktop: nil, brain: nil),
            options: LaunchOptions(["VoiceAssistant"]))
        controller.register("Ctrl+Alt+F24", "pause/resume") {}

        let told = Locked<[String]>([])
        controller.notice.subscribe { message in told.update { $0.append(message) } }
        XCTAssertEqual(told.value, ["Unknown key 'F24'."])
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
