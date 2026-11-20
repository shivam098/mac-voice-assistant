import Foundation
import ThumbFreeCore

/// Whether the on-device AI brain can take a request now (windows-voice-assistant docs/design/ai-brain.md).
public enum BrainAvailability: Sendable {
    /// Switched off in Settings: requests the fixed commands don't know get the usual "not a command I know".
    case off

    /// Switched on, but its files aren't on this computer yet (Settings downloads them).
    case notInstalled

    /// Installed but not loaded (it unloads after a while unused): the next request loads it first.
    case sleeping

    case loading
    case ready

    /// It couldn't start; the next request tries again.
    case failed
}

/// One message of the conversation the model is given: its role ("system", "user" or "assistant") and its text.
public struct ChatTurn: Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// The language model that turns a request and a screen summary into a plan (C#'s `IBrainModel`): llama-server in the
/// app, through `LlamaServerClient`; fakes in tests.
public protocol BrainModel: AnyObject {
    var availability: BrainAvailability { get }

    /// The model's reply to the conversation, constrained to `BrainPrompt.grammar`. Loads the model first when it is
    /// sleeping. Throws `CancellationError` when its task is cancelled.
    func complete(_ messages: [ChatTurn]) async throws -> String

    /// A request is probably coming ("Hey Jarvis" on its own): if the model is sleeping, it starts loading in the
    /// background so the request waits less. Never throws. Default: nothing.
    func prepare()
}

extension BrainModel {
    public func prepare() {}
}

/// The tools the brain may use. Each one is an ability the assistant already has.
public enum BrainTool: CaseIterable, Sendable {
    case focusWindow
    case openApp
    case openUrl
    case webSearch
    case click
    case typeText
    case press
    case scroll
    case ask
}

public struct BrainStep: Hashable, Sendable {
    public var tool: BrainTool
    public var target: String
    public var text: String

    public init(tool: BrainTool, target: String = "", text: String = "") {
        self.tool = tool
        self.target = target
        self.text = text
    }
}

/// What the brain decided: steps to run in order, and one short sentence to show.
public struct BrainPlan: Hashable, Sendable {
    public var steps: [BrainStep]
    public var say: String

    public init(steps: [BrainStep], say: String) {
        self.steps = steps
        self.say = say
    }

    public static let maxSteps = 8
    public static let maxFieldLength = 300

    /// The tools by the names the model uses, in the C#'s order (a reply's names are read ignoring case).
    public static let toolNames: [(name: String, tool: BrainTool)] = [
        ("focus_window", .focusWindow), ("open_app", .openApp), ("open_url", .openUrl), ("web_search", .webSearch),
        ("click", .click), ("type_text", .typeText), ("press", .press), ("scroll", .scroll), ("ask", .ask),
    ]

    private static let tools = IgnoreCaseMap(toolNames.map { ($0.name, $0.tool) })

    public static func nameOf(_ tool: BrainTool) -> String {
        toolNames.first { $0.tool == tool }?.name ?? ""
    }

    private static let newTabChords = IgnoreCaseSet(["Ctrl+T", "Ctrl+N"])

    private static let newTabButtons = OrdinalSet(["new tab", "new window", "open new tab", "open a new tab"])

    /// The steps as they will run: open_url and web_search open their own tab, so a step that only opens an empty tab
    /// or window right before one (Ctrl+T, clicking "New Tab") is dropped rather than leaving it behind.
    public static func tidy(_ steps: [BrainStep]) -> [BrainStep] {
        steps.enumerated().filter { i, step in
            !(i + 1 < steps.count && [BrainTool.openUrl, .webSearch].contains(steps[i + 1].tool) && opensEmptyTab(step))
        }.map(\.element)
    }

    /// For "open X in a new tab" and tab names that match no tab: only the steps that open a page, as nothing else was
    /// asked for. Nil when the plan opens no page ("a new GitHub tab" planned as switching to the GitHub app and
    /// clicking there; an answer with no steps), so the request falls back to the fixed handling; a question is kept.
    public static func onlyPages(_ steps: [BrainStep]) -> [BrainStep]? {
        let pages = steps.filter { $0.tool == .openUrl || $0.tool == .webSearch }
        if !pages.isEmpty {
            return pages
        }

        return !steps.isEmpty && steps.allSatisfy({ $0.tool == .ask }) ? steps : nil
    }

    private static func opensEmptyTab(_ step: BrainStep) -> Bool {
        let named = step.target.isEmpty ? step.text : step.target
        switch step.tool {
        case .press:
            return BrainSafety.normalizeChord(named).map { newTabChords.contains($0) } ?? false
        case .click:
            return newTabButtons.contains(TranscriptText.normalize(NameMatcher.cleanElementName(named)))
        default:
            return false
        }
    }

    /// Why a reply isn't a usable plan. The reason never contains the reply (it is logged).
    public struct Unusable: Error, Hashable, Sendable {
        public let reason: String

        public init(_ reason: String) {
            self.reason = reason
        }
    }

    /// Reads the model's reply leniently: the JSON object inside it, missing fields empty. A failure when it isn't a
    /// usable plan. Where the C# throws (a field that holds half of a surrogate pair, `\uD800`, which .NET's GetString
    /// can't read), this fails with "invalid JSON".
    public static func parse(_ reply: String?) -> Result<BrainPlan, Unusable> {
        let units = Array((reply ?? "").utf16)
        guard reply != nil, let start = units.firstIndex(of: 0x7B), let end = units.lastIndex(of: 0x7D), end > start
        else { return .failure(Unusable("no JSON object")) }

        guard let root = JSONValue.parse(NetText.string(utf16: units[start...end])) else {
            return .failure(Unusable("invalid JSON"))
        }

        guard case .object = root else { return .failure(Unusable("not an object")) }
        do {
            var steps: [BrainStep] = []
            if let list = root["steps"] {
                guard case .array(let items) = list else { return .failure(Unusable("steps is not a list")) }
                for item in items {
                    let name = try text(item, "tool", 40)
                    guard case .object = item, let tool = tools[name] else { return .failure(Unusable("unknown tool")) }
                    let target = try text(item, "target", maxFieldLength)
                    let words = try text(item, "text", maxFieldLength)
                    steps.append(BrainStep(tool: tool, target: target, text: words))
                }
            }

            if steps.count > maxSteps {
                return .failure(Unusable("too many steps"))
            }

            let say = try text(root, "say", 200)
            return .success(BrainPlan(steps: steps, say: say))
        } catch {
            return .failure(Unusable("invalid JSON"))
        }
    }

    private struct UnreadableString: Error {}

    /// The field's text, cleaned to one line of at most `max` characters; "" if it's missing or not a string.
    private static func text(_ element: JSONValue, _ name: String, _ max: Int) throws -> String {
        guard case .string(let field)? = element[name] else { return "" }
        guard let value = field else { throw UnreadableString() }
        return BrainSafety.cleanText(value, max, keepQuotes: true)
    }
}
