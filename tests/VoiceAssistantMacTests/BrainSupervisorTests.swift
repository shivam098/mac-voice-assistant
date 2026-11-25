import Darwin
import Foundation
import XCTest
@testable import VoiceAssistantMac

/// The supervisor that keeps llama-server from outliving the app (Windows: a job object), with real processes standing
/// in for the server: stopping goes through it, the server gets its key and folder, an ending is noticed, nothing else
/// the app starts keeps the server alive, and killing the app ends the server, even when the app is gone before the
/// supervisor has told it the server's id.
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

    /// The app is gone before the supervisor tells it the server's id (it crashed or quit while the server started):
    /// the app's end of the id's pipe is closed from the start, so writing the id kills the supervisor with SIGPIPE.
    /// Its watcher must be running by then and end the server when the lifeline closes. With the id written before
    /// the watcher started (the first version of the script), the supervisor died first and the server ran on, so this
    /// failed. The lifeline closes once the stand-in server has written its id, not at once, so that the watcher can't
    /// kill it before the test knows its id; the old order fails either way, as its watcher never starts.
    func testTheServerEndsWhenTheAppIsGoneBeforeTheSupervisorWritesItsID() throws {
        let idFile = folder.file("server.pid")
        let lifeline = Pipe()
        let report = Pipe()
        for handle in [lifeline.fileHandleForReading, lifeline.fileHandleForWriting, report.fileHandleForReading,
                       report.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }

        try report.fileHandleForReading.close()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", SupervisedServer.script, "llama-server-supervisor", "/dev/null",
            "/bin/sh", "-c", #"echo $$ >"$SERVER_ID_FILE"; exec sleep 600"#,
        ]
        shell.environment = ProcessInfo.processInfo.environment.merging(["SERVER_ID_FILE": idFile]) { $1 }
        shell.standardInput = lifeline
        shell.standardOutput = report
        shell.standardError = FileHandle.nullDevice
        try shell.run()

        var server: Int32 = 0
        var lifelineClosed = false
        defer {
            if !lifelineClosed {
                try? lifeline.fileHandleForWriting.close()
            }

            if server > 0 && BrainProcesses.isAlive(server) {
                kill(server, SIGKILL)
            }

            if shell.isRunning {
                kill(shell.processIdentifier, SIGKILL)
            }
        }

        let serverStarted = BrainWait.until(10) {
            let text = (try? String(contentsOfFile: idFile, encoding: .utf8)) ?? ""
            server = text.hasSuffix("\n") ? Int32(text.dropLast()) ?? 0 : 0
            return server > 0
        }

        XCTAssertTrue(serverStarted, "the stand-in server didn't start")

        // Writing the id to the app that's gone ended the supervisor.
        XCTAssertTrue(BrainWait.until(10) { !shell.isRunning }, "the supervisor didn't end")
        if !shell.isRunning {
            XCTAssertEqual(.uncaughtSignal, shell.terminationReason)
            XCTAssertEqual(SIGPIPE, shell.terminationStatus)
        }

        lifelineClosed = true
        try lifeline.fileHandleForWriting.close()
        XCTAssertTrue(BrainWait.until(5) { kill(server, 0) == -1 && errno == ESRCH }, "the server outlived the app")
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
