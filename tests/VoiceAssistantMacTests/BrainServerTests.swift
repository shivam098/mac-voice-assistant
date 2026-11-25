import Foundation
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// LlamaBrain's server side (windows-voice-assistant src/VoiceAssistant.App/Brain/LlamaBrain.cs) with a fake
/// llama-server: how it's started, what Settings sees, one request at a time, loading ahead of a request, the idle
/// unload, failures and starting again after them.
final class BrainServerTests: XCTestCase {
    private var folder: BrainTempFolder!
    private var files: BrainFiles!
    private var launcher: BrainFakeLauncher!
    private var llama: BrainFakeLlama!
    private var clock: BrainFakeClock!
    private var logs: BrainRecorder<(BrainLogLevel, String)>!
    private var brains: [LlamaBrain] = []
    private let messages = BrainPrompt.messages("Windows (front first):\n(no windows open)", "hello")

    override func setUpWithError() throws {
        folder = try BrainTempFolder()
        try folder.write("llama.cpp-b12483/llama-server", "#!/bin/sh\n", executable: true)
        try folder.write("model.gguf", "GGUF")
        let downloads = BrainFiles.Downloads(
            server: ModelFile("llama-b12483-bin-macos-arm64.tar.gz", "https://brain.test/none", "00", 1),
            model: ModelFile("model.gguf", "https://brain.test/none", "00", 4))
        files = BrainFiles(folder: folder.path, serverPath: nil, modelPath: nil, downloads: downloads)
        launcher = BrainFakeLauncher()
        llama = BrainFakeLlama()
        clock = BrainFakeClock()
        logs = BrainRecorder()
    }

    override func tearDown() {
        brains.forEach { $0.shutdown() }
        brains = []
        folder.remove()
    }

    private func makeBrain(
        keepLoaded: TimeInterval = 3600,
        unavailable: String? = nil,
        startTimeout: TimeInterval = 10,
        idleCheckInterval: TimeInterval = 0,
        realClock: Bool = false
    ) -> LlamaBrain {
        let clock = self.clock!
        let now: @Sendable () -> TimeInterval = realClock ? { LlamaBrain.monotonicNow() } : { clock.now }
        let brain = LlamaBrain(
            files: files, keepLoaded: keepLoaded, http: llama, launcher: launcher, unavailableReason: unavailable,
            startTimeout: startTimeout, healthCheckInterval: 0.002, idleCheckInterval: idleCheckInterval, now: now)
        let logs = self.logs!
        brain.onLog = { level, line in logs.add((level, line)) }
        brains.append(brain)
        return brain
    }

    private var logLines: [String] { logs.items.map { $0.1 } }

    private func logged(_ level: BrainLogLevel, _ line: String) -> Bool {
        logs.items.contains { $0.0 == level && $0.1 == line }
    }

    /// The port in the server's arguments.
    private func port(_ command: ServerCommand) -> Int? {
        guard let index = command.arguments.firstIndex(of: "--port"), index + 1 < command.arguments.count else {
            return nil
        }

        return Int(command.arguments[index + 1])
    }

    func testTheServerStartsAsOnWindows() async throws {
        let brain = makeBrain()
        try await brain.ensureReady()

        let command = try XCTUnwrap(launcher.commands.first)
        let port = try XCTUnwrap(port(command))
        XCTAssertTrue((1...65535).contains(port))
        XCTAssertEqual(folder.file("llama.cpp-b12483/llama-server"), command.executable)
        XCTAssertEqual(folder.file("llama.cpp-b12483"), command.workingDirectory)
        XCTAssertEqual(
            LlamaServerClient.serverArguments(modelPath: folder.file("model.gguf"), port: port), command.arguments)

        // The key: 16 random bytes in hex, in the server's environment and nowhere on its command line.
        XCTAssertEqual(["LLAMA_API_KEY"], Array(command.environment.keys))
        let key = try XCTUnwrap(command.environment["LLAMA_API_KEY"])
        XCTAssertEqual(32, key.count)
        XCTAssertTrue(key.allSatisfy { "0123456789ABCDEF".contains($0) }, key)
        XCTAssertFalse(command.arguments.contains { $0.contains(key) })

        XCTAssertEqual("http://127.0.0.1:\(port)/health", llama.requests.last?.url.absoluteString)
        _ = try await brain.complete(messages)
        let request = try XCTUnwrap(llama.completions.last)
        XCTAssertEqual("http://127.0.0.1:\(port)/v1/chat/completions", request.url.absoluteString)
        XCTAssertEqual("Bearer \(key)", request.headers["Authorization"])
    }

    func testEveryStartGetsANewKey() async throws {
        let brain = makeBrain()
        try await brain.ensureReady()
        clock.now = 3600
        brain.unloadIfIdle()
        try await brain.ensureReady()

        let keys = launcher.commands.compactMap { $0.environment["LLAMA_API_KEY"] }
        XCTAssertEqual(2, keys.count)
        XCTAssertNotEqual(keys.first, keys.last)
    }

    func testSettingsSeeItInstalledThenStartingReadyAndUnloaded() async throws {
        let brain = makeBrain()
        let seen = BrainRecorder<BrainStatus>()
        brain.onStatusChange = { seen.add($0) }
        XCTAssertEqual(.installed, brain.status)
        XCTAssertEqual(.sleeping, brain.availability)

        llama.loaded = false
        let loading = Task { try await brain.ensureReady() }
        let starting = await BrainWait.eventually { seen.items.last == .starting }
        XCTAssertTrue(starting)
        XCTAssertEqual(.loading, brain.availability)

        llama.loaded = true
        try await loading.value
        let ready = await BrainWait.eventually { seen.items.last == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(.ready, brain.availability)

        clock.now = 3600
        brain.unloadIfIdle()
        let unloaded = await BrainWait.eventually { seen.items.last == .unloaded }
        XCTAssertTrue(unloaded)
        XCTAssertEqual(.sleeping, brain.availability)
        XCTAssertEqual([.starting, .ready, .unloaded], seen.items)
        XCTAssertEqual([true], launcher.servers.map { $0.stopped })
    }

    func testARequestLoadsTheModelThenAsksIt() async throws {
        let brain = makeBrain()
        let reply = try await brain.complete(messages)
        XCTAssertEqual(#"{"steps":[],"say":"Hi."}"#, reply)
        XCTAssertEqual(1, launcher.commands.count)
        XCTAssertEqual(.ready, brain.status)
        XCTAssertTrue(
            logged(.info, "brain: prompt 812 tokens (540 cached) in 900 ms, reply 40 tokens in 2000 ms"), "\(logLines)")
        XCTAssertTrue(
            logLines.contains { $0.hasPrefix("brain: Qwen3 4B ready in ") && $0.contains(" ms (llama.cpp b12483, ") },
            "\(logLines)")

        _ = try await brain.complete(messages)
        XCTAssertEqual(1, launcher.commands.count, "loaded once")
        XCTAssertEqual(2, llama.completions.count)
    }

    func testRequestsAreAnsweredOneAtATime() async throws {
        let brain = makeBrain()
        try await brain.ensureReady()
        llama.held = true
        let messages = self.messages
        let first = Task { try await brain.complete(messages) }
        let asked = await BrainWait.eventually { self.llama.completions.count == 1 }
        XCTAssertTrue(asked)

        let second = Task { try await brain.complete(messages) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(1, llama.completions.count, "the second request went out before the first was answered")
        llama.held = false
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(2, llama.completions.count)
    }

    func testACancelledRequestLeavesTheModelLoading() async throws {
        let brain = makeBrain()
        llama.loaded = false
        let messages = self.messages
        let request = Task { try await brain.complete(messages) }
        let checking = await BrainWait.eventually { self.llama.healthChecks > 0 }
        XCTAssertTrue(checking)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual(.starting, brain.status)
        llama.loaded = true
        let ready = await BrainWait.eventually { brain.status == .ready }
        XCTAssertTrue(ready)
        _ = try await brain.complete(messages)
        XCTAssertEqual(1, launcher.commands.count)
        XCTAssertEqual([false], launcher.servers.map { $0.stopped })
    }

    func testHeyJarvisLoadsASleepingModelAheadOfTheRequest() async throws {
        let brain = makeBrain()
        brain.prepare()
        brain.prepare()
        let warmed = await BrainWait.eventually { self.logLines.contains("brain: warmed up") }
        XCTAssertTrue(warmed)
        XCTAssertEqual(.ready, brain.status)
        XCTAssertEqual(1, launcher.commands.count)
        XCTAssertEqual(1, logLines.filter { $0 == "brain: loading ahead of a request" }.count)

        // It asks what the app asks first, so the instructions and examples are in the prompt cache.
        let client = LlamaServerClient(address: URL(string: "http://127.0.0.1:1/")!, key: "k", http: llama)
        XCTAssertEqual([client.chatRequest(LlamaServerClient.warmUpMessages).body], llama.completions.map { $0.body })

        // Only a sleeping model loads ahead.
        brain.prepare()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(1, llama.completions.count)
    }

    func testWarmingUpLoadsTheModelAndFillsItsCache() async throws {
        let brain = makeBrain()
        brain.warmUp()
        let warmed = await BrainWait.eventually { self.logLines.contains("brain: warmed up") }
        XCTAssertTrue(warmed)
        XCTAssertEqual(.ready, brain.status)
        XCTAssertEqual(1, llama.completions.count)
    }

    func testTheModelUnloadsAfterTheTimeUnusedAndLoadsAgainForTheNextRequest() async throws {
        let brain = makeBrain(keepLoaded: 3600)
        _ = try await brain.complete(messages)
        clock.now = 3599
        brain.unloadIfIdle()
        XCTAssertEqual(.ready, brain.status)
        XCTAssertEqual([false], launcher.servers.map { $0.stopped })

        clock.now = 3600
        brain.unloadIfIdle()
        XCTAssertEqual(.unloaded, brain.status)
        XCTAssertEqual(.sleeping, brain.availability)
        XCTAssertEqual([true], launcher.servers.map { $0.stopped })
        XCTAssertTrue(logged(.info, "brain: unloaded after 60 minutes unused"), "\(logLines)")

        _ = try await brain.complete(messages)
        XCTAssertEqual(2, launcher.commands.count)
        XCTAssertEqual(.ready, brain.status)
    }

    func testNoUnloadWhileARequestRunsOrWhenKeptLoaded() async throws {
        let kept = makeBrain(keepLoaded: 0)
        _ = try await kept.complete(messages)
        clock.now = 1_000_000
        kept.unloadIfIdle()
        XCTAssertEqual(.ready, kept.status)

        let brain = makeBrain(keepLoaded: 60)
        try await brain.ensureReady()
        llama.held = true
        let messages = self.messages
        let request = Task { try await brain.complete(messages) }
        let asked = await BrainWait.eventually { self.llama.completions.count == 2 }
        XCTAssertTrue(asked)
        clock.now = 2_000_000
        brain.unloadIfIdle()
        XCTAssertEqual(.ready, brain.status)
        llama.held = false
        _ = try await request.value
        XCTAssertEqual([false, false], launcher.servers.map { $0.stopped })
    }

    func testTheIdleCheckRunsByItself() async throws {
        let brain = makeBrain(keepLoaded: 0.05, idleCheckInterval: 0.02, realClock: true)
        _ = try await brain.complete(messages)
        let unloaded = await BrainWait.eventually { brain.status == .unloaded }
        XCTAssertTrue(unloaded)
        XCTAssertEqual([true], launcher.servers.map { $0.stopped })
    }

    func testAServerThatExitsAsItStartsFailsAndTheNextRequestTriesAgain() async throws {
        let brain = makeBrain()
        launcher.exitNext(1)
        do {
            try await brain.ensureReady()
            XCTFail("ready")
        } catch {
            XCTAssertEqual(BrainError("llama-server exited with code 1."), error as? BrainError)
        }

        XCTAssertEqual(
            .failed("It couldn't start: llama-server exited with code 1. It tries again when you next ask."),
            brain.status)
        XCTAssertEqual(.failed, brain.availability)
        XCTAssertEqual([true], launcher.servers.map { $0.stopped })
        XCTAssertTrue(logged(.error, "brain: couldn't start: llama-server exited with code 1."), "\(logLines)")

        let reply = try await brain.complete(messages)
        XCTAssertFalse(reply.isEmpty)
        XCTAssertEqual(2, launcher.commands.count)
        XCTAssertEqual(.ready, brain.status)
    }

    func testAServerThatNeverAnswersFails() async throws {
        llama.loaded = false
        let brain = makeBrain(startTimeout: 0.05)
        do {
            try await brain.ensureReady()
            XCTFail("ready")
        } catch {
            XCTAssertEqual(BrainError("llama-server didn't get ready in time."), error as? BrainError)
        }

        XCTAssertEqual(
            .failed("It couldn't start: llama-server didn't get ready in time. It tries again when you next ask."),
            brain.status)
        XCTAssertEqual([true], launcher.servers.map { $0.stopped })
    }

    func testAServerThatCanNotBeStartedFails() async throws {
        launcher.failNext(BrainError("llama-server didn't start."))
        let brain = makeBrain()
        do {
            try await brain.ensureReady()
            XCTFail("ready")
        } catch {
            XCTAssertEqual(BrainError("llama-server didn't start."), error as? BrainError)
        }

        XCTAssertEqual(
            .failed("It couldn't start: llama-server didn't start. It tries again when you next ask."), brain.status)
    }

    func testAServerThatStopsDuringARequestFailsAndStartsAgainForTheNext() async throws {
        let brain = makeBrain()
        try await brain.ensureReady()
        llama.held = true
        let messages = self.messages
        let request = Task { try await brain.complete(messages) }
        let asked = await BrainWait.eventually { self.llama.completions.count == 1 }
        XCTAssertTrue(asked)
        launcher.servers[0].exit(9)
        llama.failure = URLError(.networkConnectionLost)
        llama.held = false
        do {
            _ = try await request.value
            XCTFail("answered")
        } catch {
            XCTAssertEqual(.networkConnectionLost, (error as? URLError)?.code)
        }

        XCTAssertEqual(
            .failed("It stopped: llama-server exited with code 9. It starts again when you next ask."), brain.status)
        XCTAssertTrue(logged(.error, "brain: server stopped (code 9)"), "\(logLines)")

        llama.failure = nil
        _ = try await brain.complete(messages)
        XCTAssertEqual(2, launcher.commands.count)
        XCTAssertEqual(.ready, brain.status)
    }

    func testAnErrorAnswerIsLoggedAndTheModelStaysLoaded() async throws {
        let brain = makeBrain()
        llama.completionStatus = 503
        do {
            _ = try await brain.complete(messages)
            XCTFail("answered")
        } catch {
            XCTAssertEqual(.answered(503), error as? LlamaServerError)
        }

        XCTAssertTrue(logged(.warning, "brain: server answered 503"), "\(logLines)")
        XCTAssertEqual(.ready, brain.status)
    }

    func testWithoutItsFilesItIsNotInstalled() async throws {
        folder.remove()
        let brain = makeBrain()
        XCTAssertEqual(.notInstalled, brain.status)
        XCTAssertEqual(.notInstalled, brain.availability)
        XCTAssertTrue(brain.canDownload)
        brain.prepare()
        do {
            try await brain.ensureReady()
            XCTFail("ready")
        } catch {
            XCTAssertEqual(BrainError("The AI brain's files aren't on this Mac."), error as? BrainError)
        }

        XCTAssertEqual(.notInstalled, brain.status)
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    func testOnAMacThatCanNotRunItTheBrainIsUnavailable() async throws {
        let reason = "The AI brain needs a Mac with Apple silicon. It isn't available on Intel Macs yet."
        let brain = makeBrain(unavailable: reason)
        XCTAssertEqual(.unavailable(reason), brain.status)
        XCTAssertEqual(.off, brain.availability)
        XCTAssertFalse(brain.canDownload)

        brain.prepare()
        brain.warmUp()
        await brain.startDownload().value
        do {
            _ = try await brain.complete(messages)
            XCTFail("answered")
        } catch {
            XCTAssertEqual(BrainError(reason), error as? BrainError)
        }

        do {
            try await brain.ensureReady()
            XCTFail("ready")
        } catch {
            XCTAssertEqual(BrainError(reason), error as? BrainError)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(launcher.commands.isEmpty)
        XCTAssertTrue(llama.requests.isEmpty)
        XCTAssertEqual(.unavailable(reason), brain.status)
    }

    func testShuttingDownStopsTheServerAndALoadingForGood() async throws {
        let brain = makeBrain()
        try await brain.ensureReady()
        brain.shutdown()
        XCTAssertEqual([true], launcher.servers.map { $0.stopped })
        do {
            _ = try await brain.complete(messages)
            XCTFail("answered")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual(1, launcher.commands.count)

        llama.loaded = false
        let loading = makeBrain()
        let start = Task { try await loading.ensureReady() }
        let checking = await BrainWait.eventually { self.llama.healthChecks > 1 }
        XCTAssertTrue(checking)
        loading.shutdown()
        do {
            try await start.value
            XCTFail("ready")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual([true, true], launcher.servers.map { $0.stopped })
    }
}
