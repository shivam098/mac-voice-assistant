import Foundation
import ThumbFreeCore
import VoiceAssistantBoard
@testable import VoiceAssistantCore

/// Outputs as text, exactly as the C# harness writes them (session files, jarvis-core-harness, Ser.cs), so the two can
/// be compared.
enum Serialized {
    static func s(_ text: String?) -> String { text ?? "~" }

    static func b(_ value: Bool) -> String { value ? "1" : "0" }

    static func i(_ value: Int?) -> String { value.map { String($0) } ?? "~" }

    static func target(_ t: ElementTarget?) -> String {
        guard let t else { return "~" }
        return t.name + "," + (t.region.map { "\($0)" } ?? "~") + "," + i(t.ordinal)
    }

    static func command(_ c: VoiceCommand) -> String {
        let edit = c.edit.map { "\($0.unit),\(i($0.count)),\(s($0.phrase)),\(s($0.replacement))" } ?? "~"
        let board = c.board.map { intent in
            let due = intent.due.map { String(Int64(floor($0.timeIntervalSince1970))) } ?? "~"
            return "\(intent.action),\(intent.list?.rawValue ?? "~"),\(intent.text),\(due)"
        }
        return ["\(c.kind)", s(c.argument), target(c.target), edit, board ?? "~"].joined(separator: "|")
    }

    static func parsed(_ p: ParsedUtterance) -> String {
        let flags = [
            s(p.dictationText), s(p.unrecognized), s(p.commandText), s(p.spoken), b(p.fromLearnedPhrase), b(p.wokeUp),
            b(p.leavesTyping), b(p.isWakeOnly), b(p.isEmpty),
        ]
        return p.commands.map(command).joined(separator: "\u{2}") + "\u{3}" + flags.joined(separator: "|")
    }

    static func plan(_ p: EditPlan?) -> String {
        guard let p else { return "~" }
        return "\(p.keepAfter)|\(p.delete)|\(p.insert)|\(p.textAfterEdit)|\(p.removed)"
    }

    static func find(_ found: (start: Int, length: Int)?) -> String { found.map { "\($0.start),\($0.length)" } ?? "~" }

    static func app(_ resolution: AppResolution) -> String {
        switch resolution {
        case .found(let app): return "f" + app.name
        case .ambiguous(let names): return "a" + names.joined(separator: ",")
        case .notFound: return "n"
        }
    }

    static func resolution(_ r: Resolution<UiElement>) -> String {
        switch r {
        case .single(let element): return "s\(element.id)"
        case .ambiguous(let elements): return "a" + elements.map { String($0.id) }.joined(separator: ",")
        case .noMatch: return "n"
        }
    }

    static func resolution(_ r: Resolution<BrowserTab>) -> String {
        switch r {
        case .single(let tab): return "s\(tab.id)"
        case .ambiguous(let tabs): return "a" + tabs.map { String($0.id) }.joined(separator: ",")
        case .noMatch: return "n"
        }
    }

    static func ids(_ elements: [UiElement]) -> String { elements.map { String($0.id) }.joined(separator: ",") }

    /// FNV-1a, 64 bits, over UTF-8, as 16 hex digits.
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }

        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
