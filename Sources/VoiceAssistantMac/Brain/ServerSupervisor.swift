import Darwin
import Foundation

/// How llama-server is started: the program, its arguments, what's added to its environment and its working folder.
struct ServerCommand: Hashable, Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
}

/// A started llama-server.
protocol ServerProcess: AnyObject, Sendable {
    /// The server's process id, for the log and tests.
    var serverID: Int32 { get }

    var isRunning: Bool { get }

    /// How it ended: its exit status, or 128 + the signal that ended it. Nil while it runs.
    var exitStatus: Int32? { get }

    /// Ends the server and waits for it to go (C#'s `Kill` and `WaitForExit(3000)`).
    func stop()
}

/// Starts llama-server: `ServerSupervisor` in the app, fakes in tests.
protocol ServerLauncher: Sendable {
    func launch(_ command: ServerCommand) throws -> any ServerProcess
}

/// Starts llama-server under a supervisor, so the server never outlives this app, even when the app crashes or is
/// killed (Windows puts it in a job object, which the system closes with the app).
///
/// The supervisor is a few lines of /bin/sh. It starts the server, then waits on a pipe whose writing end only this app
/// holds. The system closes that end when the app's process goes, however it goes, and the supervisor then kills the
/// server at once. A pipe rather than polling the app's process id, which the system can give to a new process, and
/// rather than a helper program, which the app would have to ship. Stopping the server closes the pipe too, so every
/// unload goes the way a crash does.
struct ServerSupervisor: ServerLauncher {
    /// Where the server's output goes: nowhere, as on Windows (it could echo part of a request). Tests keep it.
    var output = "/dev/null"

    func launch(_ command: ServerCommand) throws -> any ServerProcess {
        try SupervisedServer.start(command, output: output)
    }
}

/// llama-server under its supervisor (see `ServerSupervisor`).
final class SupervisedServer: ServerProcess, @unchecked Sendable {
    /// The supervisor. Its arguments are where the server's output goes, then the server and the server's arguments;
    /// its standard input is the pipe from this app. It starts the server, then a watcher that waits until the pipe
    /// closes and kills the server, and only then writes the server's process id for this app. Watcher first, so a
    /// dead app can't orphan the server: writing to an app that is already gone (it crashed or quit while the server
    /// started, or stopped waiting for the id) kills the supervisor with SIGPIPE, and a watcher due after that write
    /// would never start, leaving the server running with the model loaded. The watcher writes nowhere, so it doesn't
    /// hold the pipe the id is read from. The supervisor ends when the server ends, with the server's exit status.
    static let script = """
        output=$1
        shift
        exec 3<&0 </dev/null
        "$@" 3<&- >>"$output" 2>&1 &
        server=$!
        { while read -r line <&3; do :; done; kill -s KILL "$server" 2>/dev/null; } >/dev/null &
        watcher=$!
        exec 3<&-
        echo "$server"
        exec >/dev/null
        wait "$server"
        status=$?
        kill -s KILL "$watcher" 2>/dev/null
        exit "$status"
        """

    private static let didNotStart = "llama-server didn't start."

    private let shell: Process

    // Guarded by `ending`.
    private let ending = NSCondition()
    private var lifeline: FileHandle?
    private var status: Int32?
    private var id: Int32 = 0

    private init(shell: Process, lifeline: FileHandle) {
        self.shell = shell
        self.lifeline = lifeline
    }

    deinit {
        closeLifeline()
    }

    var serverID: Int32 { ending.withLock { id } }

    /// The supervisor's process id (tests).
    var supervisorID: Int32 { shell.processIdentifier }

    var isRunning: Bool { ending.withLock { status == nil } }

    var exitStatus: Int32? { ending.withLock { status } }

    /// Starts the supervisor, which starts the server, and reads the server's process id from it.
    static func start(_ command: ServerCommand, output: String) throws -> SupervisedServer {
        let lifeline = Pipe()
        let report = Pipe()

        // Only the supervisor gets these: it receives its own copies as it starts, and nothing else this app starts
        // inherits them, so nothing else can hold the pipe open.
        for handle in [lifeline.fileHandleForReading, lifeline.fileHandleForWriting, report.fileHandleForReading,
                       report.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "llama-server-supervisor", output, command.executable] + command.arguments
        shell.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
        shell.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
        shell.standardInput = lifeline
        shell.standardOutput = report
        shell.standardError = FileHandle.nullDevice
        let server = SupervisedServer(shell: shell, lifeline: lifeline.fileHandleForWriting)
        shell.terminationHandler = { [weak server] process in
            let signal = process.terminationReason == .uncaughtSignal
            server?.ended(signal ? 128 + process.terminationStatus : process.terminationStatus)
        }

        do {
            try shell.run()
        } catch {
            shell.terminationHandler = nil
            server.closeLifeline()
            throw BrainError(didNotStart)
        }

        let id = readServerID(report.fileHandleForReading.fileDescriptor)
        try? report.fileHandleForReading.close()
        guard id > 0 else {
            server.stop()
            throw BrainError(didNotStart)
        }

        server.ending.withLock { server.id = id }
        return server
    }

    func stop() {
        closeLifeline()
        if waitUntilEnded(3) {
            return
        }

        // The supervisor didn't end it: end both directly.
        // Known gap: a supervisor stalled >13 s between starting the server and its watcher leaves the server running.
        let server = serverID
        if server > 0 {
            kill(server, SIGKILL)
        }

        kill(shell.processIdentifier, SIGKILL)
        _ = waitUntilEnded(1)
    }

    private func ended(_ status: Int32) {
        ending.withLock {
            self.status = status
            ending.broadcast()
        }

        // The server is gone; whatever the supervisor left watching goes too.
        closeLifeline()
    }

    private func closeLifeline() {
        let handle: FileHandle? = ending.withLock {
            defer { lifeline = nil }
            return lifeline
        }

        try? handle?.close()
    }

    private func waitUntilEnded(_ seconds: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        ending.lock()
        defer { ending.unlock() }
        while status == nil {
            if !ending.wait(until: deadline) {
                return status != nil
            }
        }

        return true
    }

    /// The supervisor's first line: the server's process id. 0 if the supervisor ended first or wrote nothing in 10
    /// seconds.
    private static func readServerID(_ descriptor: Int32) -> Int32 {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < 32 {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 10_000)
            if ready < 0 && errno == EINTR {
                continue
            }

            guard ready > 0, read(descriptor, &byte, 1) == 1, byte != 0x0A else { break }
            line.append(byte)
        }

        return Int32(String(decoding: line, as: UTF8.self)) ?? 0
    }
}
