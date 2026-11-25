import CryptoKit
import Darwin
import Foundation
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// A folder of its own under the temporary folder, for one test.
final class BrainTempFolder {
    let path: String

    init() throws {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("brain-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    /// Writes `name` (making its folders), executable if asked; its path.
    @discardableResult
    func write(_ name: String, _ text: String = "", executable: Bool = false) throws -> String {
        let target = file(name)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: target, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        }

        return target
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

enum BrainWait {
    /// Waits until `condition` holds, checking every 10 ms, for at most `seconds`; whether it held.
    static func until(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > deadline {
                return false
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        return true
    }

    /// `until`, without blocking a thread.
    static func eventually(_ seconds: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > deadline {
                return false
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return true
    }
}

/// Things that happen on other threads, in order.
final class BrainRecorder<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Item] = []

    var items: [Item] { lock.withLock { recorded } }

    func add(_ item: Item) {
        lock.withLock { recorded.append(item) }
    }
}

/// llama-server, faked: health checks answer 503 ("Loading model") until it's `loaded`, and completions answer
/// `reply` with `completionStatus`, wait while they're `held`, or throw `failure`. It keeps every request.
final class BrainFakeLlama: BrainHTTP, @unchecked Sendable {
    static let reply = #"{"choices":[{"message":{"content":"{\"steps\":[],\"say\":\"Hi.\"}"}}],"#
        + #""timings":{"prompt_n":812,"cache_n":540,"prompt_ms":900.4,"predicted_n":40,"predicted_ms":2000.5}}"#

    private let lock = NSLock()
    private var isLoaded = true
    private var isHeld = false
    private var status = 200
    private var error: Error?
    private var received: [BrainHTTPRequest] = []

    var loaded: Bool {
        get { lock.withLock { isLoaded } }
        set { lock.withLock { isLoaded = newValue } }
    }

    var held: Bool {
        get { lock.withLock { isHeld } }
        set { lock.withLock { isHeld = newValue } }
    }

    var completionStatus: Int {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }

    var failure: Error? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }

    var requests: [BrainHTTPRequest] { lock.withLock { received } }

    var completions: [BrainHTTPRequest] { requests.filter { $0.method == "POST" } }

    var healthChecks: Int { requests.filter { $0.method == "GET" }.count }

    func send(_ request: BrainHTTPRequest) async throws -> BrainHTTPResponse {
        lock.withLock { received.append(request) }
        if request.method == "GET" {
            return BrainHTTPResponse(status: loaded ? 200 : 503, body: Data())
        }

        while held {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        if let failure {
            throw failure
        }

        return BrainHTTPResponse(status: completionStatus, body: Data(Self.reply.utf8))
    }
}

/// A started llama-server, faked: it runs until it's stopped or told to exit.
final class BrainFakeServer: ServerProcess, @unchecked Sendable {
    let serverID: Int32
    private let lock = NSLock()
    private var status: Int32?
    private var stops = 0

    init(_ id: Int32, exitStatus: Int32? = nil) {
        serverID = id
        status = exitStatus
    }

    var isRunning: Bool { lock.withLock { status == nil } }

    var exitStatus: Int32? { lock.withLock { status } }

    var stopped: Bool { lock.withLock { stops > 0 } }

    func stop() {
        lock.withLock {
            stops += 1
            if status == nil {
                status = 137
            }
        }
    }

    func exit(_ code: Int32) {
        lock.withLock {
            if status == nil {
                status = code
            }
        }
    }
}

/// Starts fake servers and keeps what it was asked to start.
final class BrainFakeLauncher: ServerLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [(command: ServerCommand, server: BrainFakeServer)] = []
    private var nextFailure: Error?
    private var nextExit: Int32?

    var commands: [ServerCommand] { lock.withLock { launched.map { $0.command } } }

    var servers: [BrainFakeServer] { lock.withLock { launched.map { $0.server } } }

    /// The next launch throws this.
    func failNext(_ error: Error) {
        lock.withLock { nextFailure = error }
    }

    /// The next server has ended with this status as soon as it starts.
    func exitNext(_ status: Int32) {
        lock.withLock { nextExit = status }
    }

    func launch(_ command: ServerCommand) throws -> any ServerProcess {
        try lock.withLock {
            if let failure = nextFailure {
                nextFailure = nil
                throw failure
            }

            let server = BrainFakeServer(Int32(1000 + launched.count), exitStatus: nextExit)
            nextExit = nil
            launched.append((command, server))
            return server
        }
    }
}

final class BrainFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    var now: TimeInterval {
        get { lock.withLock { seconds } }
        set { lock.withLock { seconds = newValue } }
    }
}

/// Downloads, faked: a session that gets the bytes served as "https://brain.test/<name>". A Range header gets the rest
/// of the file (206); a file served to stall sends half of what's asked, then nothing more.
final class BrainFakeDownloads: URLProtocol {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: (bytes: Data, stall: Bool)] = [:]
        var log: [String] = []
    }

    private static let registry = Registry()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrainFakeDownloads.self]
        return URLSession(configuration: configuration)
    }

    /// Serves `bytes` as `name` (a name of its own for each test); its URL.
    static func serve(_ name: String, _ bytes: Data, stall: Bool = false) -> String {
        registry.lock.withLock { registry.files[name] = (bytes, stall) }
        return "https://brain.test/\(name)"
    }

    /// The requests for `name` so far: the Range header of each ("-" for none).
    static func requests(_ name: String) -> [String] {
        registry.lock.withLock {
            registry.log.filter { $0.hasPrefix(name + " ") }.map { String($0.dropFirst(name.count + 1)) }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "brain.test" }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let name = String(url.path.drop { $0 == "/" })
        let range = request.value(forHTTPHeaderField: "Range")
        let registry = Self.registry
        let file: (bytes: Data, stall: Bool)? = registry.lock.withLock {
            registry.log.append("\(name) \(range ?? "-")")
            return registry.files[name]
        }

        guard let file else {
            respond(client, url, 404, [:], Data(), end: true)
            return
        }

        var from = 0
        var status = 200
        var headers: [String: String] = [:]
        if let range, range.hasPrefix("bytes="), range.hasSuffix("-"), let start = Int(range.dropFirst(6).dropLast()) {
            guard start < file.bytes.count else {
                respond(client, url, 416, [:], Data(), end: true)
                return
            }

            from = start
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(file.bytes.count - 1)/\(file.bytes.count)"
        }

        let body = file.bytes.subdata(in: from..<file.bytes.count)
        headers["Content-Length"] = String(body.count)
        respond(client, url, status, headers, file.stall ? body.prefix(body.count / 2) : body, end: !file.stall)
    }

    override func stopLoading() {}

    private func respond(
        _ client: URLProtocolClient, _ url: URL, _ status: Int, _ headers: [String: String], _ body: Data, end: Bool
    ) {
        let head = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        if let head {
            client.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
        }

        if !body.isEmpty {
            client.urlProtocol(self, didLoad: body)
        }

        if end {
            client.urlProtocolDidFinishLoading(self)
        }
    }
}

enum BrainArchive {
    /// A stand-in for llama.cpp's macOS archive: "llama-b12483/" holding an executable llama-server, a library and a
    /// link to it, as the real one does.
    static func make(in folder: BrainTempFolder, server: String = "#!/bin/sh\necho llama\n") throws -> Data {
        let stage = folder.file("stage")
        try folder.write("stage/llama-b12483/llama-server", server, executable: true)
        try folder.write("stage/llama-b12483/libllama.1.0.0.dylib", "library")
        try FileManager.default.createSymbolicLink(
            atPath: folder.file("stage/llama-b12483/libllama.1.dylib"), withDestinationPath: "libllama.1.0.0.dylib")
        let archive = folder.file("archive.tar.gz")
        guard run("/usr/bin/tar", ["-c", "-z", "-f", archive, "-C", stage, "llama-b12483"]) == 0 else {
            throw BrainError("tar failed")
        }

        return try Data(contentsOf: URL(fileURLWithPath: archive))
    }

    /// Runs a tool to its end; its exit status.
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

func brainSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum BrainProcesses {
    /// SZOMB in <sys/proc.h>: a process that has ended but hasn't been reaped yet.
    private static let zombie: Int8 = 5

    /// Whether a process with this id runs (one that has ended but hasn't been reaped yet doesn't).
    static func isAlive(_ id: Int32) -> Bool {
        guard id > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, id]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != zombie
    }

    static func waitUntilGone(_ id: Int32, _ seconds: TimeInterval) -> Bool {
        BrainWait.until(seconds) { !isAlive(id) }
    }
}

/// Runs one test method in a new xctest process, which stands in for the app: a test kills it and checks that the
/// server it started went with it.
enum BrainStandIn {
    static let reportVariable = "VOICE_ASSISTANT_BRAIN_STAND_IN"

    /// Where this process, as a stand-in, writes the ids of the server and the supervisor it started; nil when it
    /// isn't a stand-in.
    static var report: String? { ProcessInfo.processInfo.environment[reportVariable] }

    static func start(_ test: String, report: String, log: String) throws -> Process {
        guard let xctest = xctestPath() else { throw XCTSkip("No xctest to run a stand-in app with.") }
        let app = Process()
        app.executableURL = URL(fileURLWithPath: xctest)
        app.arguments = ["-XCTest", test, Bundle(for: BrainSupervisorTests.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment[reportVariable] = report
        app.environment = environment
        FileManager.default.createFile(atPath: log, contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        app.standardInput = FileHandle.nullDevice
        app.standardOutput = output
        app.standardError = output
        try app.run()
        return app
    }

    static func write(_ report: String, server: Int32, supervisor: Int32) throws {
        try "\(server) \(supervisor)\n".write(toFile: report, atomically: true, encoding: .utf8)
    }

    /// The ids the stand-in reported: nil if none came within `seconds`, or it ended first.
    static func read(
        _ report: String, _ seconds: TimeInterval, from app: Process
    ) -> (server: Int32, supervisor: Int32)? {
        var ids: (server: Int32, supervisor: Int32)?
        _ = BrainWait.until(seconds) {
            let text = (try? String(contentsOfFile: report, encoding: .utf8)) ?? ""
            let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            if numbers.count == 2 {
                ids = (numbers[0], numbers[1])
            }

            return ids != nil || !app.isRunning
        }

        return ids
    }

    /// Stands in until it's killed (two minutes at most).
    static func wait() {
        Thread.sleep(forTimeInterval: 120)
    }

    /// Kills the stand-in at once, as a crash would, and waits for it to go.
    static func kill(_ app: Process) {
        if app.isRunning {
            Darwin.kill(app.processIdentifier, SIGKILL)
        }

        app.waitUntilExit()
    }

    private static func xctestPath() -> String? {
        let first = ProcessInfo.processInfo.arguments.first ?? ""
        if (first as NSString).lastPathComponent == "xctest" && FileManager.default.isExecutableFile(atPath: first) {
            return first
        }

        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "xctest"]
        let output = Pipe()
        xcrun.standardOutput = output
        xcrun.standardError = FileHandle.nullDevice
        guard (try? xcrun.run()) != nil else { return nil }
        let found = output.fileHandleForReading.readDataToEndOfFile()
        xcrun.waitUntilExit()
        let path = String(decoding: found, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return xcrun.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
