import Darwin
import Foundation
import XCTest
@testable import VoiceAssistantMac

/// The supervisor that keeps llama-server from outliving the app (Windows: a job object), with real processes standing
/// in for the server: stopping goes through it, the server gets its key and folder, an ending is noticed, nothing else
/// the app starts keeps the server alive, and killing the app ends the server.
final class BrainSupervisorTests: XCTestCase {
    private var folder: BrainTempFolder!

    override func setUpWithError() throws {
        folder = try BrainTempFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    private func start(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:], in directory: String = "/"
    ) throws -> any ServerProcess {
        try ServerSupervisor().launch(ServerCommand(
            executable: executable, arguments: arguments, environment: environment, workingDirectory: directory))
    }

    func testStoppingEndsTheServerThroughTheSupervisor() throws {
        let server = try start("/bin/sleep", ["600"])
        XCTAssertGreaterThan(server.serverID, 0)
        XCTAssertTrue(BrainProcesses.isAlive(server.serverID))
        XCTAssertTrue(server.isRunning)
        XCTAssertNil(server.exitStatus)

        let started = Date()
        server.stop()
        // Stopping falls back to killing both itself after 3 seconds; the supervisor takes milliseconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(137, server.exitStatus, "killed (128 + SIGKILL)")
        XCTAssertTrue(BrainProcesses.waitUntilGone(server.serverID, 5))
        server.stop()
    }

    func testTheServerGetsTheKeyInItsEnvironmentAndRunsInItsFolder() throws {
        let server = try start(
            "/bin/sh", ["-c", #"printf '%s' "$LLAMA_API_KEY" > key.txt; exec sleep 600"#],
            environment: ["LLAMA_API_KEY": "0123ABCD"], in: folder.path)
        defer { server.stop() }
        let written = folder.file("key.txt")
        XCTAssertTrue(BrainWait.until(5) { (try? String(contentsOfFile: written, encoding: .utf8)) == "0123ABCD" })
    }

    func testAServerThatEndsByItselfIsNoticed() throws {
        let server = try start("/bin/sh", ["-c", "exit 3"])
        XCTAssertTrue(BrainWait.until(5) { !server.isRunning })
        XCTAssertEqual(3, server.exitStatus)
        server.stop()
    }

    func testAServerThatCanNotRunIsNoticed() throws {
        let program = try folder.write("llama-server", "not a program")
        let server = try start(program, [])
        XCTAssertTrue(BrainWait.until(5) { !server.isRunning })
        XCTAssertTrue([126, 127].contains(server.exitStatus ?? 0), "\(String(describing: server.exitStatus))")
    }

    func testOtherProgramsTheAppStartsDoNotKeepTheServerAlive() throws {
        let server = try start("/bin/sleep", ["600"])

        // Started after the server, as the app starts other programs: through Foundation, and through posix_spawn,
        // which passes on every descriptor that isn't marked close-on-exec.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        var spawned: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { arguments.forEach { free($0) } }
        XCTAssertEqual(0, posix_spawn(&spawned, "/bin/sleep", nil, nil, arguments, nil))
        defer {
            kill(spawned, SIGKILL)
            waitpid(spawned, nil, 0)
        }

        let started = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "another program held the supervisor's pipe open")
        XCTAssertTrue(BrainProcesses.waitUntilGone(server.serverID, 5))
    }

    func testTheServerEndsWhenTheAppIsKilled() throws {
        let report = folder.file("stand-in.txt")
        let log = folder.file("stand-in.log")
        let app = try BrainStandIn.start(
            "VoiceAssistantMacTests.BrainSupervisorTests/testStandInApp", report: report, log: log)
        defer { BrainStandIn.kill(app) }

        let output = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        guard let ids = BrainStandIn.read(report, 60, from: app) else {
            return XCTFail("The stand-in app started no server:\n\(output())")
        }

        XCTAssertTrue(BrainProcesses.isAlive(ids.server))
        XCTAssertTrue(BrainProcesses.isAlive(ids.supervisor))
        BrainStandIn.kill(app)
        XCTAssertEqual(.uncaughtSignal, app.terminationReason)
        XCTAssertTrue(BrainProcesses.waitUntilGone(ids.server, 10), "the server outlived the app")
        XCTAssertTrue(BrainProcesses.waitUntilGone(ids.supervisor, 10), "the supervisor outlived the app")
    }

    /// Not a test by itself: the app that testTheServerEndsWhenTheAppIsKilled kills. It starts a server and waits.
    func testStandInApp() throws {
        guard let report = BrainStandIn.report else {
            throw XCTSkip("testTheServerEndsWhenTheAppIsKilled runs this as its stand-in app.")
        }

        let server = try XCTUnwrap(try start("/bin/sleep", ["600"]) as? SupervisedServer)
        try BrainStandIn.write(report, server: server.serverID, supervisor: server.supervisorID)
        withExtendedLifetime(server) { BrainStandIn.wait() }
    }
}
