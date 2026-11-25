import AppKit
import XCTest
@testable import VoiceAssistantApp

/// The menu-bar placeholder the test build runs until the real app lands.
final class AppLauncherTests: XCTestCase {
    @MainActor
    func testTheMenuSaysTheAppIsInDevelopmentAndQuits() throws {
        let items = AppLauncher.menu().items

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "Voice Assistant for Mac — in development")
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertEqual(items[2].title, "Quit Voice Assistant")
        XCTAssertEqual(items[2].keyEquivalent, "q")
        XCTAssertEqual(items[2].action, #selector(NSApplication.terminate(_:)))
    }
}
