import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// The brain's code against the C#'s own results (`brainVectors`, made by the C# harness from windows-voice-assistant):
/// U, an address and `normalizeUrl`'s parts, `webAddress` and `isRefusedAddress`; P, a model's reply, its plan and the
/// plan tidied; K, keys and the chord with its limits; F, a chord's limits; C, `cleanText`; N, the checks on a button
/// or file name; S, `searchUrl`; M and B, the messages for a request and the body the Windows app posts for them; L, a
/// llama-server reply and how the Windows app reads it. The addresses and replies are the probe lists the port was
/// written from, then generated ones.
final class BrainVectorsTests: XCTestCase {
    private func vectors(_ kind: String, _ count: Int, _ fields: Int) -> [[String]] {
        let rows = brainVectors.split(separator: "\n").map(String.init).filter { $0.hasPrefix(kind + "\t") }.map {
            Array($0.split(separator: "\t", omittingEmptySubsequences: false).dropFirst().map(String.init))
        }
        XCTAssertEqual(count, rows.count, kind)
        XCTAssertEqual([], rows.filter { $0.count != fields }, kind)
        return rows.filter { $0.count == fields }
    }

    /// Runs `body` on each row's decoded fields; it gives the Swift result and the C# one.
    private func compare(
        _ kind: String, _ count: Int, _ fields: Int, file: StaticString = #filePath, line: UInt = #line,
        _ body: ([String?]) -> (swift: String, csharp: String)
    ) {
        var failures: [String] = []
        for cells in vectors(kind, count, fields) {
            let result = body(cells.map(Escaped.decode))
            if !DotNet.ordinalEquals(result.swift, result.csharp) {
                failures.append(
                    cells.dropLast().joined(separator: " / ") + ":\n  C#    " + Escaped.encode(result.csharp)
                        + "\n  Swift " + Escaped.encode(result.swift))
            }
        }

        XCTAssertTrue(
            failures.isEmpty, "\(failures.count) differ:\n" + failures.prefix(20).joined(separator: "\n"), file: file,
            line: line)
    }

    func testAddressesAreReadAsDotNetReadsThem() {
        compare("U", 400, 4) { cells in
            let input = cells[0] ?? ""
            return (
                Serialized.address(input).joined(separator: "\t"),
                [cells[1], cells[2], cells[3]].map { $0 ?? "" }.joined(separator: "\t")
            )
        }
    }

    func testRepliesAreReadIntoTheSamePlans() {
        compare("P", 146, 3) { cells in
            let reply = cells[0] ?? ""
            let expected = (cells[1] ?? "") + "\t" + (cells[2] ?? "")
            return (Serialized.plan(reply) + "\t" + Serialized.tidied(reply), expected)
        }
    }

    func testWhereTheCSharpThrowsOnAReplyThePlanIsInvalidJSON() {
        let throwing = vectors("P", 146, 3).filter { $0[1] == "!" }.compactMap { Escaped.decode($0[0]) }
        XCTAssertFalse(throwing.isEmpty)
        for reply in throwing {
            XCTAssertEqual(.failure(BrainPlan.Unusable("invalid JSON")), BrainPlan.parse(reply), reply)
        }
    }

    func testKeysAreNormalizedAndLimitedTheSame() {
        compare("K", 300, 2) { cells in (Serialized.keyed(cells[0] ?? ""), cells[1] ?? "") }
        compare("F", 19, 2) { cells in (Serialized.limits(cells[0] ?? ""), cells[1] ?? "") }
    }

    func testTextIsCleanedTheSame() {
        compare("C", 150, 4) { cells in
            let cleaned = BrainSafety.cleanText(cells[0], Int(cells[1] ?? "") ?? -1, keepQuotes: cells[2] == "1")
            return (cleaned, cells[3] ?? "")
        }
    }

    func testNamesAreCheckedTheSame() {
        compare("N", 160, 2) { cells in (Serialized.named(cells[0] ?? ""), cells[1] ?? "") }
    }

    func testSearchesGoToTheSamePages() {
        compare("S", 208, 3) { cells in (Serialized.search(cells[0], cells[1] ?? ""), cells[2] ?? "") }
    }

    func testTheModelIsToldWhatTheWindowsAppTellsIt() {
        compare("M", 2, 3) { cells in
            let messages = BrainPrompt.messages(cells[0] ?? "", cells[1] ?? "")
            return (Serialized.messages(messages), cells[2] ?? "")
        }

        let warmUp = vectors("M", 2, 3).first { Escaped.decode($0[1]) == "hello" }
        XCTAssertEqual(Escaped.decode(warmUp?[2] ?? ""), Serialized.messages(LlamaServerClient.warmUpMessages))
    }

    func testTheRequestBodyIsTheWindowsApps() throws {
        let client = LlamaServerClient(address: URL(string: "http://127.0.0.1:8080/")!, key: "k", http: NoHTTP())
        for cells in vectors("B", 2, 3) {
            let messages = BrainPrompt.messages(Escaped.decode(cells[0]) ?? "", Escaped.decode(cells[1]) ?? "")
            let body = try XCTUnwrap(client.chatRequest(messages).body)
            let swift = try XCTUnwrap(JSONValue.parse(String(decoding: body, as: UTF8.self)))
            let csharp = try XCTUnwrap(JSONValue.parse(Escaped.decode(cells[2]) ?? ""))
            XCTAssertEqual(csharp, swift)
        }
    }

    func testRepliesAreReadAsTheWindowsAppReadsThem() {
        compare("L", 71, 3) { cells in
            let status = Int(cells[0] ?? "") ?? 0
            let expected = cells[2] ?? ""
            do {
                let reply = try LlamaServerClient.readReply(status: status, body: Data((cells[1] ?? "").utf8))
                return (reply.content + "\u{1}" + (reply.timings?.logLine ?? "~"), expected)
            } catch let error as LlamaServerError {
                // C# throws HttpRequestException for the status, and JsonException or InvalidOperationException for the
                // reply.
                let thrown = expected.hasPrefix("throws ") ? (expected == "throws HttpRequestException"
                    ? LlamaServerError.answered(status) : .unreadableReply) : nil
                return (error == thrown ? expected : "throws \(error)", expected)
            } catch {
                return ("throws \(error)", expected)
            }
        }
    }
}

/// A transport for requests that are only looked at.
private struct NoHTTP: BrainHTTP {
    func send(_ request: BrainHTTPRequest) async throws -> BrainHTTPResponse { throw URLError(.notConnectedToInternet) }
}

// The harness's BrainCorpus.cs serializers.
extension Serialized {
    /// `normalizeUrl`'s parts (or ~), `webAddress` (or ~) and `isRefusedAddress`.
    static func address(_ input: String) -> [String] {
        let normalized = BrainSafety.normalizeUrl(input).map {
            [$0.absoluteUri, $0.host, $0.idnHost, $0.absolutePath, $0.query, $0.fragment].joined(separator: "\u{3}")
        }
        let web = BrainSafety.webAddress(input)?.absoluteUri
        return [normalized ?? "~", web ?? "~", b(BrainSafety.isRefusedAddress(input))]
    }

    static func steps(_ steps: [BrainStep]) -> String {
        steps.map { BrainPlan.nameOf($0.tool) + "\u{3}" + $0.target + "\u{3}" + $0.text }.joined(separator: "\u{2}")
    }

    /// ok|steps|say, err|reason, or ! where the C# throws.
    static func plan(_ reply: String) -> String {
        switch BrainPlan.parse(reply) {
        case .success(let plan):
            return "ok|" + steps(plan.steps) + "|" + plan.say
        case .failure(let error):
            return throwsInCSharp(reply, error) ? "!" : "err|" + error.reason
        }
    }

    /// `tidy`'s steps|`onlyPages`' steps (or ~), for a reply that is a plan; ~ otherwise, or ! where the C# throws.
    static func tidied(_ reply: String) -> String {
        switch BrainPlan.parse(reply) {
        case .success(let plan):
            return steps(BrainPlan.tidy(plan.steps)) + "|" + (BrainPlan.onlyPages(plan.steps).map { steps($0) } ?? "~")
        case .failure(let error):
            return throwsInCSharp(reply, error) ? "!" : "~"
        }
    }

    /// Where the C# throws (a field it reads holds half of a surrogate pair), the port fails with "invalid JSON" on
    /// JSON that reads.
    static func throwsInCSharp(_ reply: String, _ error: BrainPlan.Unusable) -> Bool {
        let units = Array(reply.utf16)
        guard error.reason == "invalid JSON", let start = units.firstIndex(of: 0x7B),
              let end = units.lastIndex(of: 0x7D), end > start
        else { return false }

        return JSONValue.parse(NetText.string(utf16: units[start...end])) != nil
    }

    /// The limits on a chord: why it's refused (or ~), blocked, needs a yes, submits, types a character.
    static func limits(_ chord: String) -> String {
        [
            s(BrainSafety.refusalReason(chord)), b(BrainSafety.isBlockedChord(chord)),
            b(BrainSafety.needsConfirmation(chord)), b(BrainSafety.isSubmitChord(chord)),
            b(BrainSafety.isCharacterKey(chord)),
        ].joined(separator: "|")
    }

    static func keyed(_ keys: String) -> String {
        guard let chord = BrainSafety.normalizeChord(keys) else { return "~" }
        return chord + "|" + limits(chord)
    }

    static func named(_ name: String) -> String {
        [
            b(BrainSafety.isSendLike(name)), b(BrainSafety.runsProgram(name)), b(BrainSafety.isSearchBox(name)),
            b(BrainSafety.isCommandBox(name)), b(TargetResolver.isDestructive(name)),
        ].joined(separator: "|")
    }

    static func search(_ site: String?, _ query: String) -> String {
        let found = BrainSafety.searchUrl(site, query)
        return found.url.absoluteUri + "|" + found.site
    }

    static func messages(_ messages: [ChatTurn]) -> String {
        messages.map { $0.role + "\u{2}" + $0.content }.joined(separator: "\u{1}")
    }
}
