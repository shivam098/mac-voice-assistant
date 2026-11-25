import XCTest
@testable import VoiceAssistantApp

final class AppPackageTests: XCTestCase {
    // The app bundle is built with this identifier, and ThumbFree for Mac warns while an app with it runs (both use Fn).
    func testTheBundleIdentifierIsTheOneThumbFreeLooksFor() {
        XCTAssertEqual("io.github.shivam098.voiceassistant", VoiceAssistantApp.bundleIdentifier)
    }
}
