import CoreGraphics
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// Where the overlay's panel goes and what it draws (C#'s `MarkerOverlay.Render`), without AppKit.
final class OverlayLayoutTests: XCTestCase {
    /// The panel covers every badge's rectangle with 40 points around; each badge sits 6 points above and left of its
    /// element's corner.
    func testCoversTheBadgesWithRoomAround() throws {
        let badges = [
            ChoiceBadge(number: 1, rect: ScreenRect(x: 100, y: 200, width: 50, height: 20), label: "New"),
            ChoiceBadge(number: 2, rect: ScreenRect(x: 400, y: 300, width: 80, height: 30), label: "Delete"),
        ]
        let layout = try XCTUnwrap(OverlayLayout(badges: badges, flash: nil))
        XCTAssertEqual(ScreenRect(x: 60, y: 160, width: 460, height: 210), layout.area)
        XCTAssertEqual(
            [
                OverlayLayout.Badge(number: 1, origin: CGPoint(x: 34, y: 34)),
                OverlayLayout.Badge(number: 2, origin: CGPoint(x: 334, y: 134)),
            ],
            layout.badges)
        XCTAssertNil(layout.outline)
    }

    /// The outline goes 4 points around what was clicked, with the badges if there are some.
    func testOutlinesWhatWasClicked() throws {
        let flash = ScreenRect(x: 10, y: 20, width: 30, height: 40)
        var layout = try XCTUnwrap(OverlayLayout(badges: nil, flash: flash))
        XCTAssertEqual(ScreenRect(x: -30, y: -20, width: 110, height: 120), layout.area)
        XCTAssertEqual(CGRect(x: 36, y: 36, width: 38, height: 48), layout.outline)
        XCTAssertTrue(layout.badges.isEmpty)

        let badge = ChoiceBadge(number: 3, rect: ScreenRect(x: 200, y: 20, width: 10, height: 10), label: "Go")
        layout = try XCTUnwrap(OverlayLayout(badges: [badge], flash: flash))
        XCTAssertEqual(ScreenRect(x: -30, y: -20, width: 280, height: 120), layout.area)
        XCTAssertEqual([OverlayLayout.Badge(number: 3, origin: CGPoint(x: 224, y: 34))], layout.badges)
    }

    /// Nothing to show: no panel. A badge without a place isn't shown.
    func testNothingToShow() {
        XCTAssertNil(OverlayLayout(badges: nil, flash: nil))
        XCTAssertNil(OverlayLayout(badges: [], flash: nil))
        let unplaced = ChoiceBadge(number: 1, rect: ScreenRect(x: 0, y: 0, width: 0, height: 0), label: "Tab")
        XCTAssertNil(OverlayLayout(badges: [unplaced], flash: nil))
    }

    /// AppKit's frames start at the bottom left of the main display: the area turned over.
    func testThePanelsFrame() throws {
        let badge = ChoiceBadge(number: 1, rect: ScreenRect(x: 100, y: 200, width: 50, height: 20), label: "New")
        let layout = try XCTUnwrap(OverlayLayout(badges: [badge], flash: nil))
        XCTAssertEqual(CGRect(x: 60, y: 1080 - 260, width: 130, height: 100), layout.panelFrame(mainTop: 1080))
    }
}
