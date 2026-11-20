import Foundation
import XCTest
@testable import VoiceAssistantCore

/// llama-server, faked: it answers with the next of its answers (the last one again once they run out) and keeps the
/// requests it got.
private final class FakeLlamaServer: BrainHTTP, @unchecked Sendable {
    enum Answer {
        case status(Int, String)
        case failure(Error)

        /// No answer until the request is cancelled.
        case hang
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var received: [BrainHTTPRequest] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    var requests: [BrainHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func send(_ request: BrainHTTPRequest) async throws -> BrainHTTPResponse {
        switch take(request) {
        case .status(let status, let body):
            return BrainHTTPResponse(status: status, body: Data(body.utf8))
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        }
    }

    private func take(_ request: BrainHTTPRequest) -> Answer {
        lock.lock()
        defer { lock.unlock() }
        received.append(request)
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// The client side of the brain's llama-server (windows-voice-assistant src/VoiceAssistant.App/Brain/LlamaBrain.cs):
/// the requests, the timeouts and waiting for the server to start. BrainVectorsTests compares the request body and the
/// reading of replies with the Windows app's.
final class LlamaServerTests: XCTestCase {
    private let address = URL(string: "http://127.0.0.1:8123/")!
    private let messages = BrainPrompt.messages("Windows (front first):\n(no windows open)", "hello")

    private func client(_ answers: [FakeLlamaServer.Answer]) -> (LlamaServerClient, FakeLlamaServer) {
        let server = FakeLlamaServer(answers)
        return (LlamaServerClient(address: address, key: "0123ABCD", http: server), server)
    }

    func testTheServerStartsAsOnWindows() {
        XCTAssertEqual(
            [
                "-m", "/models/brain.gguf", "--host", "127.0.0.1", "--port", "8123", "-c", "4096", "-np", "1", "-ngl",
                "99", "--jinja", "--no-webui",
            ],
            LlamaServerClient.serverArguments(modelPath: "/models/brain.gguf", port: 8123))
    }

    func testACompletionPostsTheMessagesWithTheKey() async throws {
        let answer = #"{"choices":[{"message":{"content":"{\"steps\":[],\"say\":\"Hi.\"}"}}],"#
            + #""timings":{"prompt_n":812,"cache_n":540,"prompt_ms":900.4,"predicted_n":40,"predicted_ms":2000.5}}"#
        let (llama, server) = client([.status(200, answer)])
        let reply = try await llama.complete(messages)
        XCTAssertEqual(#"{"steps":[],"say":"Hi."}"#, reply.content)
        XCTAssertEqual(
            "brain: prompt 812 tokens (540 cached) in 900 ms, reply 40 tokens in 2000 ms", reply.timings?.logLine)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(1, server.requests.count)
        XCTAssertEqual("POST", request.method)
        XCTAssertEqual("http://127.0.0.1:8123/v1/chat/completions", request.url.absoluteString)
        XCTAssertEqual("Bearer 0123ABCD", request.headers["Authorization"])
        XCTAssertEqual("application/json; charset=utf-8", request.headers["Content-Type"])
        let body = try XCTUnwrap(request.body)
        let sent = try XCTUnwrap(JSONValue.parse(String(decoding: body, as: UTF8.self)))
        guard case .array(let turns)? = sent["messages"] else { return XCTFail("no messages") }
        XCTAssertEqual(messages.count, turns.count)
        XCTAssertEqual(.string("user"), turns.last?["role"])
        XCTAssertEqual(.string(messages.last?.content), turns.last?["content"])
    }

    func testAServerErrorIsAnError() async {
        let (llama, _) = client([.status(503, #"{"error":"busy"}"#)])
        do {
            _ = try await llama.complete(messages)
            XCTFail("no error")
        } catch {
            XCTAssertEqual(.answered(503), error as? LlamaServerError)
        }
    }

    func testARequestThatTakesTooLongTimesOut() async {
        let (llama, _) = client([.hang])
        do {
            _ = try await llama.complete(messages, timeout: 0.05)
            XCTFail("no timeout")
        } catch {
            XCTAssertEqual(.timedOut, error as? LlamaServerError)
        }
    }

    func testCancellingARequestStopsIt() async throws {
        let (llama, server) = client([.hang])
        let messages = self.messages
        let task = Task { try await llama.complete(messages) }
        while server.requests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testTheHealthCheckIsFalseUntilTheServerAnswersWithSuccess() async throws {
        let (llama, server) = client([
            .failure(URLError(.cannotConnectToHost)), .status(503, "Loading model"), .status(200, "{}"),
        ])
        let first = try await llama.isHealthy()
        let second = try await llama.isHealthy()
        let third = try await llama.isHealthy()
        XCTAssertEqual([false, false, true], [first, second, third])
        let sent = Set(server.requests.map { $0.method + " " + $0.url.absoluteString })
        XCTAssertEqual(["GET http://127.0.0.1:8123/health"], sent)
    }

    func testAHealthCheckThatHangsOrIsCancelledThrows() async {
        let (hanging, _) = client([.hang])
        do {
            _ = try await hanging.isHealthy(timeout: 0.05)
            XCTFail("no timeout")
        } catch {
            XCTAssertEqual(.timedOut, error as? LlamaServerError)
        }

        let (cancelled, _) = client([.failure(CancellationError())])
        do {
            _ = try await cancelled.isHealthy()
            XCTFail("not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testStartingWaitsUntilTheServerIsHealthy() async throws {
        let (llama, server) = client([
            .failure(URLError(.cannotConnectToHost)), .status(503, ""), .status(503, ""), .status(200, ""),
        ])
        try await llama.waitUntilReady(timeout: 30, interval: 0.001)
        XCTAssertEqual(4, server.requests.count)
    }

    func testAServerThatNeverGetsHealthyIsNotReady() async {
        let (llama, _) = client([.status(503, "")])
        do {
            try await llama.waitUntilReady(timeout: 0.05, interval: 0.005)
            XCTFail("ready")
        } catch {
            XCTAssertEqual(.notReady, error as? LlamaServerError)
        }
    }

    func testAServerWhoseProcessEndedIsNotWaitedFor() async {
        let (llama, server) = client([.status(503, "")])
        var checks = 0
        do {
            try await llama.waitUntilReady(timeout: 30, interval: 0.001) {
                checks += 1
                return checks < 3
            }
            XCTFail("ready")
        } catch {
            XCTAssertEqual(.exited, error as? LlamaServerError)
        }

        XCTAssertEqual(2, server.requests.count)
    }
}
