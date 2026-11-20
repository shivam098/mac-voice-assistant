import Foundation
import ThumbFreeCore

/// One HTTP exchange the brain's client asks for.
public struct BrainHTTPRequest: Hashable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct BrainHTTPResponse: Hashable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The HTTP the brain's client needs: URLSession in the app, fakes in tests. `send` throws when no answer came (the
/// server isn't listening yet, the connection broke) and `CancellationError` when its task is cancelled. Timeouts are
/// the client's (`LlamaServerClient.requestTimeout`).
public protocol BrainHTTP: Sendable {
    func send(_ request: BrainHTTPRequest) async throws -> BrainHTTPResponse
}

/// What went wrong talking to llama-server.
public enum LlamaServerError: Error, Hashable, Sendable {
    /// It answered with this status, not 2xx (C#: "llama-server answered 500.").
    case answered(Int)

    /// No answer within the request's time.
    case timedOut

    /// The reply isn't what a chat completion returns.
    case unreadableReply

    /// It didn't answer its health check within the start time (C#: "llama-server didn't get ready in time.").
    case notReady

    /// Its process ended while it was starting.
    case exited
}

/// What llama-server reports about a completion: token counts and times, for the log (which never gets words).
public struct LlamaTimings: Hashable, Sendable {
    public var promptTokens: Double
    public var cachedTokens: Double
    public var promptMs: Double
    public var replyTokens: Double
    public var replyMs: Double

    public init(promptTokens: Double, cachedTokens: Double, promptMs: Double, replyTokens: Double, replyMs: Double) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.promptMs = promptMs
        self.replyTokens = replyTokens
        self.replyMs = replyMs
    }

    /// The Windows app's log line: "brain: prompt 812 tokens (540 cached) in 900 ms, reply 40 tokens in 2000 ms".
    public var logLine: String {
        "brain: prompt \(f0(promptTokens)) tokens (\(f0(cachedTokens)) cached) in \(f0(promptMs)) ms, "
            + "reply \(f0(replyTokens)) tokens in \(f0(replyMs)) ms"
    }

    /// .NET's "F0" (as in English): the exact value rounded to a whole number, halves to even, so 2.5 is "2" and -0.5
    /// is "-0"; infinity (a reply's 1e999) is "∞".
    private func f0(_ value: Double) -> String {
        value.isInfinite ? (value < 0 ? "-∞" : "∞") : String(format: "%.0f", value)
    }
}

/// A completion: the model's text (the plan, in `BrainPrompt.grammar`'s shape) and the server's timings, if it gave
/// them.
public struct LlamaReply: Hashable, Sendable {
    public var content: String
    public var timings: LlamaTimings?

    public init(content: String, timings: LlamaTimings? = nil) {
        self.content = content
        self.timings = timings
    }
}

/// llama.cpp's llama-server, as the brain talks to it (windows-voice-assistant src/VoiceAssistant.App/Brain/
/// LlamaBrain.cs): a chat completion with the plan grammar, temperature 0 and the prompt cache, its reply, the health
/// check and the timeouts. The server runs on 127.0.0.1 with a random port and key; starting and stopping it, and its
/// download, are the app's.
public struct LlamaServerClient: Sendable {
    /// The most one request may take (C#'s `HttpClient.Timeout`).
    public static let requestTimeout: TimeInterval = 120

    /// The most the server may take to load the model and answer its health check.
    public static let startTimeout: TimeInterval = 180

    /// How often the health check is tried while the server starts.
    public static let healthCheckInterval: TimeInterval = 0.25

    /// The context the server gets: one slot of 4,096 tokens, so the shared instructions stay in its prompt cache.
    public static let contextSize = 4096

    /// The longest reply asked for, in tokens.
    public static let maxTokens = 300

    /// The environment variable that gives the server its key (it keeps the key off the command line).
    public static let keyVariable = "LLAMA_API_KEY"

    /// How the app starts the server, as on Windows: the model, 127.0.0.1 and the port, `contextSize` with one slot,
    /// every layer on the graphics chip, the model's own chat template, no web page.
    public static func serverArguments(modelPath: String, port: Int) -> [String] {
        [
            "-m", modelPath, "--host", "127.0.0.1", "--port", String(port), "-c", String(contextSize), "-np", "1",
            "-ngl", "99", "--jinja", "--no-webui",
        ]
    }

    /// What the app sends once the model has loaded, to fill the prompt cache with the instructions and examples.
    public static let warmUpMessages = BrainPrompt.messages(
        "Windows (front first):\n1. \"Untitled - Notepad\" (Notepad), in front", "hello")

    /// "http://127.0.0.1:<port>/".
    public let address: URL
    public let key: String
    private let http: any BrainHTTP

    public init(address: URL, key: String, http: any BrainHTTP) {
        self.address = address
        self.key = key
        self.http = http
    }

    /// The chat completion for these messages: `POST /v1/chat/completions` with the key, temperature 0, at most
    /// `maxTokens`, the prompt cache, the plan grammar, and the model's thinking off (Qwen3 and Gemma 4 templates think
    /// aloud before answering unless it is).
    public func chatRequest(_ messages: [ChatTurn]) -> BrainHTTPRequest {
        let turns = messages.map {
            JSONText.Value.object([("role", .string($0.role)), ("content", .string($0.content))])
        }
        let body = JSONText.write(.object([
            ("messages", .array(turns)),
            ("temperature", .int(0)),
            ("max_tokens", .int(Self.maxTokens)),
            ("cache_prompt", .bool(true)),
            ("grammar", .string(BrainPrompt.grammar)),
            ("chat_template_kwargs", .object([("enable_thinking", .bool(false))])),
        ]))
        return BrainHTTPRequest(
            method: "POST", url: url("v1/chat/completions"),
            headers: ["Authorization": "Bearer \(key)", "Content-Type": "application/json; charset=utf-8"],
            body: Data(body.utf8))
    }

    /// `GET /health`: 2xx once the model has loaded.
    public var healthRequest: BrainHTTPRequest { BrainHTTPRequest(method: "GET", url: url("health")) }

    /// The model's reply to the messages. Throws `LlamaServerError`, the transport's error, or `CancellationError`.
    public func complete(
        _ messages: [ChatTurn], timeout: TimeInterval = LlamaServerClient.requestTimeout
    ) async throws -> LlamaReply {
        let response = try await send(chatRequest(messages), timeout)
        return try Self.readReply(status: response.status, body: response.body)
    }

    /// Whether the server answers its health check with 2xx: false while it isn't listening yet. A health check that
    /// hangs past the request time fails (throws), as in C#.
    public func isHealthy(timeout: TimeInterval = LlamaServerClient.requestTimeout) async throws -> Bool {
        do {
            let response = try await send(healthRequest, timeout)
            return (200..<300).contains(response.status)
        } catch let error as LlamaServerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// Waits for the server to answer its health check, trying every `interval` seconds: `exited` if `isRunning` says
    /// its process ended, `notReady` after `timeout`.
    public func waitUntilReady(
        timeout: TimeInterval = LlamaServerClient.startTimeout,
        interval: TimeInterval = LlamaServerClient.healthCheckInterval,
        isRunning: () -> Bool = { true }
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            try Task.checkCancellation()
            guard isRunning() else { throw LlamaServerError.exited }
            if try await isHealthy() {
                return
            }

            if clock.now - start > .seconds(timeout) {
                throw LlamaServerError.notReady
            }

            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    }

    /// The completion in a reply, read as C# reads it with `JsonNode`: `choices[0].message.content` ("" if missing) and
    /// `timings`. Where C# throws (another status, JSON it can't read, a field of the wrong kind, a name given twice in
    /// an object it reads), this throws.
    public static func readReply(status: Int, body: Data) throws -> LlamaReply {
        guard (200..<300).contains(status) else { throw LlamaServerError.answered(status) }
        let bytes = body.starts(with: [0xEF, 0xBB, 0xBF]) ? body.dropFirst(3) : body[...]
        guard let json = JSONValue.parse(String(decoding: bytes, as: UTF8.self)) else {
            throw LlamaServerError.unreadableReply
        }

        var timings: LlamaTimings?
        if let t = try property(json, "timings") {
            timings = LlamaTimings(
                promptTokens: try value(property(t, "prompt_n")), cachedTokens: try value(property(t, "cache_n")),
                promptMs: try value(property(t, "prompt_ms")), replyTokens: try value(property(t, "predicted_n")),
                replyMs: try value(property(t, "predicted_ms")))
        }

        let content = try property(property(item(property(json, "choices"), 0), "message"), "content")
        guard let found = content else { return LlamaReply(content: "", timings: timings) }
        guard case .string(let text?) = found else { throw LlamaServerError.unreadableReply }
        return LlamaReply(content: text, timings: timings)
    }

    /// `node?[name]` on a JsonNode: nil for a missing node or JSON null; throws unless it's an object without a name
    /// given twice (`JsonObject` throws `ArgumentException` when it reads one).
    private static func property(_ node: JSONValue?, _ name: String) throws -> JSONValue? {
        guard let node, node != .null else { return nil }
        guard case .object(let properties) = node, isUnique(properties) else { throw LlamaServerError.unreadableReply }
        let found = properties.first { DotNet.ordinalEquals($0.0, name) }?.1
        return found == .null ? nil : found
    }

    /// `node?[index]`: an array's item, or the value of an object's property in that place; throws unless there is one.
    private static func item(_ node: JSONValue?, _ index: Int) throws -> JSONValue? {
        guard let node, node != .null else { return nil }
        let items: [JSONValue]
        switch node {
        case .array(let values):
            items = values
        case .object(let properties) where isUnique(properties):
            items = properties.map { $0.1 }
        default:
            throw LlamaServerError.unreadableReply
        }

        guard index < items.count else { throw LlamaServerError.unreadableReply }
        return items[index] == .null ? nil : items[index]
    }

    private static func isUnique(_ properties: [(String, JSONValue)]) -> Bool {
        var names = Set<[Unicode.Scalar]>()
        return properties.allSatisfy { names.insert(DotNet.ordinal($0.0)).inserted }
    }

    /// A number for the log; 0 for anything else.
    private static func value(_ node: JSONValue?) -> Double { node?.doubleValue ?? 0 }

    private func url(_ path: String) -> URL { URL(string: path, relativeTo: address)?.absoluteURL ?? address }

    /// The exchange, or `timedOut` once `timeout` seconds have passed.
    private func send(_ request: BrainHTTPRequest, _ timeout: TimeInterval) async throws -> BrainHTTPResponse {
        let http = self.http
        return try await withThrowingTaskGroup(of: BrainHTTPResponse?.self) { group in
            group.addTask { try await http.send(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }

            defer { group.cancelAll() }
            guard let first = try await group.next(), let response = first else { throw LlamaServerError.timedOut }
            return response
        }
    }
}
