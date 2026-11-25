import Darwin
import Foundation
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// The AI brain end to end with the real llama-server, on this Mac's graphics chip (Windows' `braindownload` and
/// `brainwait` lab steps, automated). It runs when BRAIN_INTEGRATION_FOLDER names a folder for its files, which CI
/// keeps between runs: it downloads the pinned llama.cpp build and a 1 MB model through `LlamaBrain.startDownload`,
/// checks the unpacked server (executable, signed, not quarantined), starts it through the supervisor, gets a
/// completion through the core's client, waits for the idle unload, then kills a stand-in app that started a server
/// and checks that the server went with it. It prints what it measured.
final class BrainIntegrationTests: XCTestCase {
    static let folderVariable = "BRAIN_INTEGRATION_FOLDER"

    /// stories260K, from llama2.c's tiny Llama models (llama.cpp's own server tests use it): 1.2 MB, no chat template
    /// (llama-server then uses ChatML).
    static let tinyModel = ModelFile(
        "stories260K-f32.gguf",
        "https://huggingface.co/ggml-org/test-model-stories260K/resolve/479896ec924af6d40fd419ab8f4d1eb2101de00d/"
            + "stories260K-f32.gguf",
        "270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d", 1_185_376)

    private static var folder: String? {
        let folder = ProcessInfo.processInfo.environment[folderVariable] ?? ""
        return folder.isEmpty ? nil : folder
    }

    private static func files(_ folder: String) -> BrainFiles {
        BrainFiles(
            folder: folder, serverPath: nil, modelPath: nil,
            downloads: BrainFiles.Downloads(server: BrainFiles.pinnedServer, model: tinyModel))
    }

    private static func brain(
        _ files: BrainFiles, keepLoaded: TimeInterval, output: String = "/dev/null"
    ) -> LlamaBrain {
        let brain = LlamaBrain(
            files: files, keepLoaded: keepLoaded, http: URLSessionBrainHTTP(),
            launcher: ServerSupervisor(output: output),
            unavailableReason: files.unavailableReason, idleCheckInterval: 0.5)
        brain.onLog = { _, line in say(line) }
        return brain
    }

    private static func say(_ line: String) {
        print("brain integration: \(line)")
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    func testLlamaServerOnThisMac() async throws {
        guard let folder = Self.folder else {
            throw XCTSkip("Set \(Self.folderVariable) to a folder for llama.cpp and a small model to run this.")
        }

        let files = Self.files(folder)
        XCTAssertNil(files.unavailableReason)

        // 1. The files, once: CI keeps the folder.
        if files.isInstalled {
            Self.say("llama.cpp \(BrainFiles.llamaBuild) and the model are already in \(folder)")
        } else {
            let downloader = Self.brain(files, keepLoaded: 3600)
            let started = Date()
            await downloader.startDownload().value
            downloader.shutdown()
            XCTAssertTrue(files.isInstalled, "\(downloader.status)")
            Self.say("downloaded \(files.downloads.server.bytes + files.downloads.model.bytes) bytes and unpacked "
                + "llama.cpp in \(Self.milliseconds(since: started)) ms")
        }

        try checkServer(files)

        // 2. Start, ask, unload.
        let log = (NSTemporaryDirectory() as NSString).appendingPathComponent("llama-server-\(UUID().uuidString).log")
        let brain = Self.brain(files, keepLoaded: 2, output: log)
        defer {
            brain.shutdown()
            Self.printServerLog(log)
        }

        var started = Date()
        try await brain.ensureReady()
        let server = try XCTUnwrap(brain.serverProcess)
        Self.say("llama-server (pid \(server.serverID)) ready in \(Self.milliseconds(since: started)) ms")
        XCTAssertEqual(.ready, brain.status)

        started = Date()
        let reply = try await brain.complete(LlamaServerClient.warmUpMessages)
        Self.say("completion in \(Self.milliseconds(since: started)) ms: \(reply.prefix(100))")
        XCTAssertTrue(reply.hasPrefix(#"{"steps":["#), reply)

        started = Date()
        let unloaded = await BrainWait.eventually(30) { brain.status == .unloaded }
        XCTAssertTrue(unloaded, "\(brain.status)")
        XCTAssertTrue(BrainProcesses.waitUntilGone(server.serverID, 5), "llama-server still runs after the unload")
        Self.say("unloaded after \(Self.milliseconds(since: started)) ms unused; pid \(server.serverID) is gone")

        // 3. The app is killed: the server goes with it.
        let report = (NSTemporaryDirectory() as NSString).appendingPathComponent("stand-in-\(UUID().uuidString).txt")
        let standInLog = report + ".log"
        let app = try BrainStandIn.start(
            "VoiceAssistantMacTests.BrainIntegrationTests/testStandInAppWithLlamaServer", report: report,
            log: standInLog)
        guard let ids = BrainStandIn.read(report, 180, from: app) else {
            BrainStandIn.kill(app)
            let output = (try? String(contentsOfFile: standInLog, encoding: .utf8)) ?? ""
            return XCTFail("The stand-in app started no llama-server:\n\(output)")
        }

        XCTAssertTrue(BrainProcesses.isAlive(ids.server))
        Self.say("stand-in app (pid \(app.processIdentifier)) runs llama-server (pid \(ids.server)) under its "
            + "supervisor (pid \(ids.supervisor)); killing the app with SIGKILL")
        let killed = Date()
        BrainStandIn.kill(app)
        XCTAssertTrue(BrainProcesses.waitUntilGone(ids.server, 10), "llama-server outlived the app")
        XCTAssertTrue(BrainProcesses.waitUntilGone(ids.supervisor, 10), "the supervisor outlived the app")
        let after = Self.milliseconds(since: killed)
        Self.say("llama-server (pid \(ids.server)) ended \(after) ms after the app was killed")
    }

    /// Not a test by itself: the app that testLlamaServerOnThisMac kills. It starts llama-server and waits.
    func testStandInAppWithLlamaServer() async throws {
        guard let report = BrainStandIn.report, let folder = Self.folder else {
            throw XCTSkip("testLlamaServerOnThisMac runs this as its stand-in app.")
        }

        let brain = Self.brain(Self.files(folder), keepLoaded: 3600)
        try await brain.ensureReady()
        let server = try XCTUnwrap(brain.serverProcess as? SupervisedServer)
        try BrainStandIn.write(report, server: server.serverID, supervisor: server.supervisorID)
        withExtendedLifetime(brain) { BrainStandIn.wait() }
    }

    /// The unpacked server: executable, with its libraries, signed (ad hoc is enough on Apple silicon) and not
    /// quarantined (macOS would refuse an unnotarized program that is).
    private func checkServer(_ files: BrainFiles) throws {
        let folder = (files.serverPath as NSString).deletingLastPathComponent
        let names = try FileManager.default.contentsOfDirectory(atPath: folder)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: files.serverPath))
        for name in ["libllama-server-impl.dylib", "libllama.1.dylib", "libggml-metal.1.dylib"] {
            XCTAssertTrue(names.contains(name), "\(name) missing from \(names.sorted())")
        }

        let signature = Self.capture("/usr/bin/codesign", ["--verify", "--verbose=2", files.serverPath])
        XCTAssertEqual(0, signature.status, signature.output)
        let details = Self.capture("/usr/bin/codesign", ["-d", "--verbose=2", files.serverPath]).output
        let shown = details.split(separator: "\n").filter {
            $0.hasPrefix("Signature") || $0.hasPrefix("CodeDirectory") || $0.hasPrefix("Format")
        }

        let verified = signature.output.split(separator: "\n").joined(separator: "; ")
        Self.say("llama-server: \(names.count) files; codesign: \(verified); \(shown.joined(separator: "; "))")
        for name in names {
            let quarantined = getxattr(
                (folder as NSString).appendingPathComponent(name), "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            XCTAssertLessThan(quarantined, 0, "\(name) is quarantined")
        }

        Self.say("quarantine: none of the \(names.count) files has it")
    }

    /// A tool's exit status and what it wrote.
    private static func capture(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return (-1, "\(tool) didn't start") }
        let text = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: text, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    /// What llama-server said about the graphics chip and the model (never a request: it doesn't log them).
    private static func printServerLog(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let pattern = #"metal|gpu|offload|error|fail|model loaded|listening|build"#
        let lines = text.split(separator: "\n").filter {
            $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }

        for line in lines.prefix(40) {
            say("llama-server: \(line)")
        }

        try? FileManager.default.removeItem(atPath: path)
    }
}
