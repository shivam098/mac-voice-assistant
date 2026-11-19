import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

final class PackageTests: XCTestCase {
    // Until the port lands: the core builds against thumbfree-mac's ThumbFreeCore, the dictation it will use.
    func testTheCoreUsesThumbFreesDictation() {
        XCTAssertEqual(VoiceAssistantCore.thumbFreeCoreVersion, ThumbFreeCore.version)
    }
}
