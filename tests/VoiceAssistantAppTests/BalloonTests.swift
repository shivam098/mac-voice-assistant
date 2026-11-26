import XCTest
@testable import VoiceAssistantApp

/// The balloons by the menu bar icon (Windows' tray balloons): one at a time, each for its 4 seconds or until it's
/// clicked, the next when it has gone; no message twice; at most 3 waiting; and none once the app quits.
final class BalloonTests: XCTestCase {
    @MainActor
    func testNoticesSaidTogetherShowOneAfterAnotherEachForItsTime() {
        let rig = BalloonRig()
        let taken = "⌃⇧Space (pause/resume) is used by another app."
        let fn = "Voice Assistant can't see the Fn key yet: allow it in System Settings › Privacy & Security."
        rig.balloon.show(taken, warning: true, anchor: nil)
        rig.balloon.show(fn, warning: true, anchor: nil)
        rig.balloon.show("ThumbFree uses Fn too.", warning: false, anchor: nil)
        XCTAssertEqual(rig.shown, [taken], "the first at once; a later one doesn't take its place")
        XCTAssertEqual(rig.balloon.waiting.map(\.message), [fn, "ThumbFree uses Fn too."])
        XCTAssertEqual(rig.waits, [Balloon.shownFor])

        rig.timeUp()
        XCTAssertEqual(rig.shown, [taken], "it fades out first")
        rig.panels[0].fadeEnds()
        XCTAssertTrue(rig.panels[0].gone)
        XCTAssertEqual(rig.shown, [taken, fn], "the next once it has gone")
        XCTAssertEqual(rig.waits, [Balloon.shownFor, Balloon.shownFor], "for its own 4 seconds")

        rig.clicks[1]()
        rig.panels[1].fadeEnds()
        XCTAssertEqual(rig.shown, [taken, fn, "ThumbFree uses Fn too."], "a click takes one away sooner")
        XCTAssertEqual(rig.signs, [true, true, false])
        rig.timeUp(at: 1)
        XCTAssertFalse(rig.panels[2].fading, "the clicked one's time running out doesn't cut the next one short")
        rig.timeUp()
        rig.panels[2].fadeEnds()
        XCTAssertNil(rig.balloon.showing)

        rig.balloon.show(taken, warning: true, anchor: nil)
        XCTAssertEqual(rig.shown.last, taken, "said again once it has gone")
    }

    @MainActor
    func testAMessageIsntSaidTwiceAndAtMostThreeWait() {
        let rig = BalloonRig()
        rig.balloon.show("One", warning: true, anchor: nil)
        rig.balloon.show("One", warning: true, anchor: nil)
        rig.balloon.show("Two", warning: true, anchor: nil)
        rig.balloon.show("Two", warning: true, anchor: nil)
        XCTAssertEqual(rig.shown, ["One"])
        XCTAssertEqual(rig.balloon.waiting.map(\.message), ["Two"], "the same message showing or waiting is dropped")
        rig.balloon.show("Two", warning: false, anchor: nil)
        XCTAssertEqual(rig.balloon.waiting.count, 2, "with the other sign it's another notice")

        for message in ["Three", "Four", "Five"] {
            rig.balloon.show(message, warning: true, anchor: nil)
        }

        XCTAssertEqual(rig.balloon.waiting.map(\.message), ["Three", "Four", "Five"], "the oldest waiting go first")
    }

    @MainActor
    func testQuittingTakesTheBalloonAwayAndTheOnesWaiting() {
        let rig = BalloonRig()
        rig.balloon.show("One", warning: true, anchor: nil)
        rig.balloon.show("Two", warning: true, anchor: nil)
        rig.timeUp()
        rig.balloon.close()
        rig.panels[0].fadeEnds()
        XCTAssertEqual(rig.shown, ["One"], "nothing shows after the app quits")
        XCTAssertNil(rig.balloon.showing)
        XCTAssertEqual(rig.balloon.waiting, [])

        rig.balloon.show("Three", warning: true, anchor: nil)
        rig.balloon.close()
        XCTAssertTrue(rig.panels[1].gone, "at once")
    }
}

/// A balloon on fakes: panels that record their fade, and time that runs out when a test says.
@MainActor
final class BalloonRig {
    private(set) var shown: [String] = []
    private(set) var signs: [Bool] = []
    private(set) var clicks: [@MainActor () -> Void] = []
    private(set) var panels: [PanelRecorder] = []
    private(set) var timers: [@MainActor @Sendable () -> Void] = []
    private(set) var waits: [TimeInterval] = []
    private(set) var balloon: Balloon!

    init() {
        balloon = Balloon(
            present: { [unowned self] (notice: Balloon.Notice, _: CGRect?, clicked: @escaping @MainActor () -> Void) in
                self.shown.append(notice.message)
                self.signs.append(notice.warning)
                self.clicks.append(clicked)
                let panel = PanelRecorder()
                self.panels.append(panel)
                return panel
            },
            after: { [unowned self] (seconds: TimeInterval, body: @escaping @MainActor @Sendable () -> Void) in
                self.waits.append(seconds)
                self.timers.append(body)
            })
    }

    /// The time of the balloon shown `at` (the latest by default) runs out.
    func timeUp(at index: Int? = nil) {
        timers[index ?? timers.count - 1]()
    }

    /// A balloon's panel: whether it's fading out, and gone.
    @MainActor
    final class PanelRecorder: BalloonPanel {
        private(set) var fading = false
        private(set) var gone = false
        private var faded: (@MainActor () -> Void)?

        func fadeOut(milliseconds: Int, then done: @escaping @MainActor () -> Void) {
            fading = true
            faded = done
        }

        func orderOut(_ sender: Any?) {
            gone = true
        }

        /// The fade-out ends.
        func fadeEnds() {
            let done = faded
            faded = nil
            done?()
        }
    }
}
