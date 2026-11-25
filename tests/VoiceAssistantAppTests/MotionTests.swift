import AppKit
import SwiftUI
import XCTest
@testable import VoiceAssistantApp

/// Motion's fades on the floating panels (windows-voice-assistant Motion.cs): skipped while Reduce motion is on, and a
/// fade-in cancels a fade-out that hasn't finished, as on Windows.
final class MotionTests: XCTestCase {
    @MainActor
    func testReduceMotionShowsAndHidesAtOnce() {
        _ = NSApplication.shared
        let reduceMotion = Motion.reduceMotion
        defer { Motion.reduceMotion = reduceMotion }
        Motion.reduceMotion = { true }
        XCTAssertFalse(Motion.isEnabled)
        XCTAssertNil(Motion.animation(140))

        let panel = FloatingPanel.make(FirstClickHostingView(rootView: Text(verbatim: "Hello")))
        panel.alphaValue = 0.2
        panel.fadeIn(milliseconds: 140)
        XCTAssertEqual(panel.alphaValue, 1)
        var done = 0
        panel.fadeOut(milliseconds: 220) { done += 1 }
        XCTAssertEqual(done, 1, "at once")
        XCTAssertEqual(panel.alphaValue, 1)

        Motion.reduceMotion = { false }
        XCTAssertTrue(Motion.isEnabled)
        XCTAssertNotNil(Motion.animation(140))
    }

    @MainActor
    func testAFadeInCancelsAFadeOutThatHasntFinished() {
        _ = NSApplication.shared
        let reduceMotion = Motion.reduceMotion
        defer { Motion.reduceMotion = reduceMotion }
        Motion.reduceMotion = { false }
        let panel = FloatingPanel.make(FirstClickHostingView(rootView: Text(verbatim: "Hello")))
        panel.setFrame(CGRect(x: -20_000, y: -20_000, width: 100, height: 40), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        var done = 0
        panel.fadeOut(milliseconds: 100) { done += 1 }
        panel.fadeIn(milliseconds: 100)
        Self.runMainLoop(for: 0.4)
        XCTAssertEqual(done, 0)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)

        panel.fadeOut(milliseconds: 100) { done += 1 }
        let deadline = Date().addingTimeInterval(2)
        while done == 0 && Date() < deadline {
            Self.runMainLoop(for: 0.01)
        }

        XCTAssertEqual(done, 1)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001, "opaque again for the next time it shows")
    }

    @MainActor
    private static func runMainLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
