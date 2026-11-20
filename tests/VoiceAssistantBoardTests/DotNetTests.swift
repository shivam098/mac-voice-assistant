import XCTest
@testable import VoiceAssistantBoard

/// .NET's case rules, as .NET 11 applies them (and as thumbfree-mac's copy of DotNet.swift does).
final class DotNetTests: XCTestCase {
    private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    func testUpperAndLowerCaseAreDotNetsInvariantMappings() {
        // char.ToUpperInvariant: the dotless "ı" keeps its case, and where Unicode's full mapping is two letters (ᾳ →
        // ΑΙ) the one-letter title case is used (ᾼ), or else the letter stays (ß, ﬁ).
        XCTAssertEqual(DotNet.toUpperInvariant("\u{131}"), "\u{131}")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{1FB3}"), "\u{1FBC}")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{1F80}"), "\u{1F88}")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{1FF3}"), "\u{1FFC}")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{17F}"), "S")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{DF}"), "\u{DF}")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{FB01}"), "\u{FB01}")
        XCTAssertEqual(DotNet.toUpperInvariant("\u{1C6}"), "\u{1C4}")
        // char.ToLowerInvariant: "İ" keeps its case.
        XCTAssertEqual(DotNet.toLowerInvariant("\u{130}"), "\u{130}")
        XCTAssertEqual(DotNet.toLowerInvariant("\u{212A}"), "k")
        XCTAssertEqual(scalars(DotNet.upperInvariant("\u{131}dea\u{1FB3}")), scalars("\u{131}DEA\u{1FBC}"))
    }

    func testIgnoringCaseIsOrdinalIgnoreCase() {
        // "ı", "ſ", "İ" and the Kelvin sign match no ASCII letter; ᾳ and ᾼ, or ǅ and ǆ, are the same letter.
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{131}", "I"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{131}", "i"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{17F}", "S"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{17F}", "s"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{130}", "i"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{212A}", "k"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{DF}", "SS"))
        XCTAssertTrue(DotNet.equalsOrdinalIgnoreCase("\u{1FB3}", "\u{1FBC}"))
        XCTAssertTrue(DotNet.equalsOrdinalIgnoreCase("\u{1F80}", "\u{1F88}"))
        XCTAssertTrue(DotNet.equalsOrdinalIgnoreCase("\u{1C5}", "\u{1C6}"))
        XCTAssertTrue(DotNet.equalsOrdinalIgnoreCase("Brainstorm", "bRAINSTORM"))
        XCTAssertFalse(DotNet.containsOrdinalIgnoreCase("my \u{131}dea", "IDEA"))
        XCTAssertTrue(DotNet.containsOrdinalIgnoreCase("my Idea list", "IDEA"))
        XCTAssertTrue(DotNet.startsWithOrdinalIgnoreCase("A few", "a "))
        XCTAssertFalse(DotNet.startsWithOrdinalIgnoreCase("\u{17F}ix", "S"))
    }
}
