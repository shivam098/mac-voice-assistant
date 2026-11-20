import Foundation
import XCTest
@testable import VoiceAssistantCore

/// `WebLink.url`, the address as the Mac opens it: .NET's `AbsoluteUri` keeps a Unicode host, brackets and a second
/// number sign, which Foundation's `URL` takes escaped and in ASCII.
final class WebLinkTests: XCTestCase {
    func testFoundationGetsTheAddressInASCII() throws {
        let cases: [(input: String, absoluteUri: String, url: String)] = [
            ("b\u{FC}cher.de", "https://b\u{FC}cher.de/", "https://xn--bcher-kva.de/"),
            ("\u{4F8B}\u{3048}.jp/a b", "https://\u{4F8B}\u{3048}.jp/a%20b", "https://xn--r8jz45g.jp/a%20b"),
            ("example.com/[x]?q=[y]", "https://example.com/[x]?q=[y]", "https://example.com/%5Bx%5D?q=%5By%5D"),
            ("example.com#a#b", "https://example.com/#a#b", "https://example.com/#a%23b"),
            ("@example.com", "https://@example.com/", "https://example.com/"),
            ("https://example.com:8080/x?y#z", "https://example.com:8080/x?y#z", "https://example.com:8080/x?y#z"),
        ]
        for test in cases {
            let link = try XCTUnwrap(BrainSafety.normalizeUrl(test.input), test.input)
            XCTAssertEqual(test.absoluteUri, link.absoluteUri, test.input)
            XCTAssertEqual(test.url, link.url.absoluteString, test.input)
        }
    }
}
