import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// The two searches C# runs right to left (`RegexOptions.RightToLeft`, which NetRegex doesn't have): the phrase an edit
/// finds before the cursor, and the replacement as it was said.
final class RightToLeftTests: XCTestCase {
    private func vectors(_ kind: String) -> [[String]] {
        rightToLeftVectors.split(separator: "\n").map(String.init).filter { $0.hasPrefix(kind + "\t") }.map {
            Array($0.split(separator: "\t", omittingEmptySubsequences: false).dropFirst().map(String.init))
        }
    }

    func testTheLastMatchIsTheOneThatEndsLastNotTheLastLeftToRight() {
        // A left-to-right search finds "a a" at the start and goes on after it, so it never sees the last two words.
        XCTAssertEqual(2, TextEditing.findLast("a a a", "a a")?.start)
        XCTAssertEqual("a b", TextEditing.replaceLast("a a a", "a a", "b")?.textAfterEdit)
        XCTAssertEqual("go on x", TextEditing.replaceLast("go on go on go", "go on go", "x")?.textAfterEdit)
    }

    func testFindLastMatchesDotNetOnGeneratedTexts() {
        let cases = vectors("F")
        XCTAssertEqual(600, cases.count)
        var failures: [String] = []
        for cells in cases {
            guard cells.count == 3, let text = Escaped.decode(cells[0]), let phrase = Escaped.decode(cells[1]) else {
                failures.append("bad row: \(cells)")
                continue
            }

            let found = Serialized.find(TextEditing.findLast(text, phrase))
            if found != cells[2] {
                failures.append("\(cells[0]) / \(cells[1]): C# \(cells[2]), Swift \(found)")
            }
        }

        XCTAssertTrue(failures.isEmpty, "\(failures.count) differ:\n" + failures.prefix(20).joined(separator: "\n"))
    }

    func testSpokenReplacementsMatchDotNet() {
        let cases = vectors("P")
        XCTAssertEqual(400, cases.count)
        let parser = CommandParser()
        var failures: [String] = []
        for cells in cases {
            guard cells.count == 3, let said = Escaped.decode(cells[0]), let expected = Escaped.decode(cells[2]) else {
                failures.append("bad row: \(cells)")
                continue
            }

            let parsed = Serialized.parsed(parser.parse(said, cells[1] == "d" ? .dictation : .command))
            if !DotNet.ordinalEquals(parsed, expected) {
                failures.append("\(cells[0]) (\(cells[1])):\n  C#    \(cells[2])\n  Swift \(Escaped.encode(parsed))")
            }
        }

        XCTAssertTrue(failures.isEmpty, "\(failures.count) differ:\n" + failures.prefix(20).joined(separator: "\n"))
    }
}
