import Darwin
import Foundation
import ThumbFreeSpeech
import VoiceAssistantCore

/// The AI brain on this Mac (windows-voice-assistant src/VoiceAssistant.App/Brain/LlamaBrain.cs, and the AI brain parts
/// of AssistantHost.cs): llama.cpp's llama-server running the model on the graphics chip, started on demand on
/// 127.0.0.1 with a random port and key, and ended with the app or after a while unused. A supervisor ends it when the
/// app's process ends, however it ends (`ServerSupervisor`; Windows uses a job object). The core's controller asks it
/// for plans (`BrainModel`) through the core's `LlamaServerClient`: replies are constrained to the plan grammar, and
/// the shared instructions stay in the server's prompt cache. Settings shows `status` and starts or stops the download.
/// Requests and replies are never saved; the log gets timings and token counts only. Safe from any thread.
public final class LlamaBrain: BrainModel, @unchecked Sendable {
    public let files: BrainFiles

    /// Seconds unused before the model is unloaded, to load again on the next request (settings.json's
    /// `brainKeepLoadedMinutes` × 60, an hour by default). 0 keeps it loaded.
    public let keepLoaded: TimeInterval

    private let http: any BrainHTTP
    private let launcher: any ServerLauncher
    private let unavailableReason: String?
    private let startTimeout: TimeInterval
    private let healthCheckInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let requests = BrainGate()
    private let changes = DispatchQueue(label: "VoiceAssistant.LlamaBrain.changes")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var state: ServerState
    private var everLoaded = false
    private var failure = ""
    private var server: (any ServerProcess)?
    private var client: LlamaServerClient?
    private var starting: BrainStart?
    private var lastUsed: TimeInterval
    private var preparing = false
    private var isShutDown = false
    private var downloadTask: Task<Void, Never>?
    private var downloadStopped = false
    private var downloadFailure: String?
    private var progress: (received: Int64, total: Int64) = (0, 0)
    private var progressPosted: Int64 = 0
    private var background: [Int: Task<Void, Never>] = [:]
    private var lastBackground = 0
    private var idleTimer: DispatchSourceTimer?
    private var statusHandler: (@Sendable (BrainStatus) -> Void)?
    private var logHandler: (@Sendable (BrainLogLevel, String) -> Void)?

    // Only on `changes`.
    private var posted: BrainStatus?

    /// - Parameters:
    ///   - files: Where the brain's files are (settings.json's `brainFolder`, `brainServerPath` and `brainModelPath`).
    ///   - keepLoaded: Seconds unused before the model is unloaded; 0 keeps it loaded.
    public convenience init(files: BrainFiles, keepLoaded: TimeInterval = 3600) {
        self.init(
            files: files, keepLoaded: keepLoaded, http: URLSessionBrainHTTP(), launcher: ServerSupervisor(),
            unavailableReason: files.unavailableReason)
    }

    init(
        files: BrainFiles,
        keepLoaded: TimeInterval,
        http: any BrainHTTP,
        launcher: any ServerLauncher,
        unavailableReason: String?,
        startTimeout: TimeInterval = LlamaServerClient.startTimeout,
        healthCheckInterval: TimeInterval = LlamaServerClient.healthCheckInterval,
        idleCheckInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> TimeInterval = { LlamaBrain.monotonicNow() }
    ) {
        self.files = files
        self.keepLoaded = keepLoaded
        self.http = http
        self.launcher = launcher
        self.unavailableReason = unavailableReason
        self.startTimeout = startTimeout
        self.healthCheckInterval = healthCheckInterval
        self.now = now
        state = files.isInstalled ? .sleeping : .notInstalled
        lastUsed = now()
        if idleCheckInterval > 0 {
            // Windows checks once a minute too.
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + idleCheckInterval, repeating: idleCheckInterval)
            timer.setEventHandler { [weak self] in self?.unloadIfIdle() }
            idleTimer = timer
            timer.resume()
        }
    }

    deinit {
        idleTimer?.cancel()
    }

    /// For the core's controller: `.off` on a Mac that can't run the brain.
    public var availability: BrainAvailability { lock.withLock { availabilityLocked } }

    public var status: BrainStatus { lock.withLock { statusLocked } }

    /// Whether Settings offers the download: this Mac can run the brain, something is missing at the default paths, and
    /// no download is running.
    public var canDownload: Bool {
        let missing = files.missingBytes
        return missing > 0 && lock.withLock { unavailableReason == nil && downloadTask == nil && !isShutDown }
    }

    /// Runs on a background queue after `status` changes, in order (while downloading, about every 8 MB).
    public var onStatusChange: (@Sendable (BrainStatus) -> Void)? {
        get { lock.withLock { statusHandler } }
        set { lock.withLock { statusHandler = newValue } }
    }

    /// Gets the brain's log lines ("brain: …"), on any thread: states, timings, token counts and kinds of errors, never
    /// words.
    public var onLog: (@Sendable (BrainLogLevel, String) -> Void)? {
        get { lock.withLock { logHandler } }
        set { lock.withLock { logHandler = newValue } }
    }

    /// Downloads the brain's missing files in the background, resuming a download that stopped, then loads the model
    /// (Settings' Download button; AssistantHost.StartBrainDownload). Joins a download that's running; does nothing on
    /// a Mac that can't run the brain. The task ends with the download and never fails: `status` says how it went.
    @discardableResult
    public func startDownload() -> Task<Void, Never> {
        let missing = files.missingBytes
        lock.lock()
        if let running = downloadTask {
            lock.unlock()
            return running
        }

        guard unavailableReason == nil, !isShutDown else {
            lock.unlock()
            return Task {}
        }

        downloadFailure = nil
        downloadStopped = false
        progress = (0, missing)
        progressPosted = 0
        let task = Task.detached(priority: .utility) { [self] in await self.runDownload(missing) }
        downloadTask = task
        lock.unlock()
        postChange()
        return task
    }

    /// Stops the download (Settings' Stop button); the next one carries on where it stopped.
    public func cancelDownload() {
        let task: Task<Void, Never>? = lock.withLock {
            downloadStopped = downloadTask != nil
            return downloadTask
        }

        task?.cancel()
    }

    /// Loads the model if it isn't loaded and waits until llama-server answers. A caller cancelled while it waits stops
    /// waiting; the loading carries on. Throws `BrainError` when it can't start, or `CancellationError`.
    public func ensureReady() async throws {
        if let unavailableReason {
            throw BrainError(unavailableReason)
        }

        if let start = ensureStarted() {
            try await start.wait()
        }

        lock.withLock { lastUsed = now() }
    }

    /// The model's reply (`BrainModel`): waits for the request before it, loads the model if needed (a cancelled
    /// request doesn't stop the loading, so the next one is quick), then asks llama-server.
    public func complete(_ messages: [ChatTurn]) async throws -> String {
        if let unavailableReason {
            throw BrainError(unavailableReason)
        }

        try await requests.acquire()
        defer {
            lock.withLock { lastUsed = now() }
            requests.release()
        }

        if let start = ensureStarted() {
            try await start.wait()
        }

        return try await send(messages)
    }

    /// "Hey Jarvis" on its own (`BrainModel`): a sleeping model starts loading, and fills its prompt cache, while the
    /// request is said instead of after it.
    public func prepare() {
        let starts: Bool = lock.withLock {
            guard unavailableReason == nil, state == .sleeping, !preparing, !isShutDown else { return false }
            preparing = true
            return true
        }

        guard starts else { return }
        log(.info, "brain: loading ahead of a request")
        runInBackground { [self] in
            await self.warmUpNow()
            self.lock.withLock { self.preparing = false }
        }
    }

    /// Loads the model and fills its prompt cache in the background, so the first request is quick. The app calls it
    /// once its speech models are ready, if the brain is installed; a download calls it when it's done.
    public func warmUp() {
        runInBackground { [self] in await self.warmUpNow() }
    }

    /// Stops the server and whatever the brain is doing, for good (C#'s `Dispose`). The app calls it as it quits; if it
    /// can't, the supervisor ends the server with the app anyway.
    public func shutdown() {
        lock.lock()
        isShutDown = true
        downloadStopped = true
        let tasks = Array(background.values) + [starting?.task, downloadTask].compactMap { $0 }
        background.removeAll()
        let timer = idleTimer
        idleTimer = nil
        if state == .loading || state == .ready {
            state = .sleeping
        }

        lock.unlock()
        timer?.cancel()
        tasks.forEach { $0.cancel() }
        stopServer()
        postChange()
    }

    /// The running server (tests).
    var serverProcess: (any ServerProcess)? { lock.withLock { server } }

    /// Unloads the model once it has been unused for `keepLoaded` and no request is running (C#'s `UnloadIfIdle`).
    func unloadIfIdle() {
        guard keepLoaded > 0, lock.withLock({ state == .ready && now() - lastUsed >= keepLoaded }) else { return }
        guard requests.tryAcquire() else { return }
        defer { requests.release() }
        guard lock.withLock({ state == .ready && starting == nil }) else { return }
        stopServer()
        setState(.sleeping)
        log(.info, "brain: unloaded after \(String(format: "%.0f", keepLoaded / 60)) minutes unused")
    }

    /// Seconds on a clock that carries on while the Mac sleeps, as Windows' `Environment.TickCount64` does.
    static func monotonicNow() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// The start under way, a new one, or nil when the server is ready (C#'s `EnsureStarted`).
    private func ensureStarted() -> BrainStart? {
        lock.withLock {
            if let starting {
                return starting
            }

            if isShutDown {
                return BrainStart(outcome: .failure(CancellationError()))
            }

            if let server, server.isRunning, state == .ready {
                return nil
            }

            let start = BrainStart()
            starting = start
            start.task = Task.detached { [self] in await self.run(start) }
            return start
        }
    }

    private func run(_ start: BrainStart) async {
        let outcome: Result<Void, Error>
        do {
            try await startServer()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }

        lock.withLock {
            if starting === start {
                starting = nil
            }
        }

        start.finish(outcome)
    }

    /// Starts llama-server and waits until it answers its health check (C#'s `StartServerAsync`).
    private func startServer() async throws {
        stopServer()
        guard files.isInstalled else {
            setState(.notInstalled)
            throw BrainError("The AI brain's files aren't on this Mac.")
        }

        setState(.loading)
        let started = now()
        do {
            let port = try Self.freePort()

            // The key keeps other programs (and web pages) off the server; the environment keeps it off command lines.
            let key = Self.newKey()
            let server = try launcher.launch(ServerCommand(
                executable: files.serverPath,
                arguments: LlamaServerClient.serverArguments(modelPath: files.modelPath, port: port),
                environment: [LlamaServerClient.keyVariable: key],
                workingDirectory: (files.serverPath as NSString).deletingLastPathComponent))
            let client = LlamaServerClient(address: Self.address(port), key: key, http: http)
            lock.withLock {
                self.server = server
                self.client = client
            }

            do {
                try await client.waitUntilReady(timeout: startTimeout, interval: healthCheckInterval) {
                    server.isRunning
                }
            } catch LlamaServerError.exited {
                throw BrainError("llama-server exited with code \(Self.code(server)).")
            } catch LlamaServerError.notReady {
                throw BrainError("llama-server didn't get ready in time.")
            }

            try Task.checkCancellation()
            lock.withLock { lastUsed = now() }
            setState(.ready)
            let elapsed = Int(((now() - started) * 1000).rounded())
            log(
                .info,
                "brain: \(BrainFiles.modelName) ready in \(elapsed) ms (llama.cpp \(BrainFiles.llamaBuild), "
                    + "\(Self.architecture))")
        } catch is CancellationError {
            stopServer()
            setState(files.isInstalled ? .sleeping : .notInstalled)
            throw CancellationError()
        } catch {
            log(.error, "brain: couldn't start: \(Self.kind(of: error))")
            stopServer()
            setState(.failed, failure: "It couldn't start: \(Self.detail(error)) It tries again when you next ask.")
            throw error
        }
    }

    private func send(_ messages: [ChatTurn]) async throws -> String {
        let (client, server) = lock.withLock { (self.client, self.server) }
        guard let client else { throw BrainError("The AI brain isn't running.") }
        let reply: LlamaReply
        do {
            reply = try await client.complete(messages)
        } catch let error as LlamaServerError {
            if case .answered(let status) = error {
                log(.warning, "brain: server answered \(status)")
            }

            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let server, !server.isRunning {
                log(.error, "brain: server stopped (code \(Self.code(server)))")
                setState(
                    .failed,
                    failure: "It stopped: llama-server exited with code \(Self.code(server)). It starts again when you "
                        + "next ask.")
            }

            throw error
        }

        if let timings = reply.timings {
            log(.info, timings.logLine)
        }

        return reply.content
    }

    private func warmUpNow() async {
        guard unavailableReason == nil, files.isInstalled, !lock.withLock({ isShutDown }) else { return }
        do {
            _ = try await complete(LlamaServerClient.warmUpMessages)
            log(.info, "brain: warmed up")
        } catch is CancellationError {
        } catch {
            log(.warning, "brain: warm-up failed: \(Self.kind(of: error))")
        }
    }

    private func runDownload(_ total: Int64) async {
        log(.info, "brain: downloading \(total / (1 << 20)) MB")
        var problem: String?
        var finished = false
        do {
            try await files.download { [weak self] received, total in self?.downloaded(received, of: total) }
            log(.info, "brain: downloaded and verified")
            finished = true
        } catch is CancellationError where lock.withLock({ downloadStopped }) {
            log(.info, "brain: download paused")
        } catch {
            log(.error, "brain: download failed: \(Self.kind(of: error))")
            problem = Self.downloadProblem(error)
        }

        if finished {
            refresh()
        }

        lock.withLock {
            downloadTask = nil
            downloadFailure = problem
        }

        postChange()
        if finished {
            warmUp()
        }
    }

    /// Download progress: `status` follows it, and Settings hears about it every 8 MB and at the end, as on Windows.
    private func downloaded(_ received: Int64, of total: Int64) {
        let post: Bool = lock.withLock {
            progress = (received, total)
            guard received - progressPosted >= 8 << 20 || received == total else { return false }
            progressPosted = received
            return true
        }

        if post {
            postChange()
        }
    }

    /// After a download: notices the files (C#'s `Refresh`).
    private func refresh() {
        let installed = files.isInstalled
        let changed: Bool = lock.withLock {
            guard installed, state == .notInstalled else { return false }
            state = .sleeping
            return true
        }

        if changed {
            postChange()
        }
    }

    private func stopServer() {
        let server: (any ServerProcess)? = lock.withLock {
            defer {
                self.server = nil
                client = nil
            }

            return self.server
        }

        server?.stop()
    }

    private func setState(_ newState: ServerState, failure reason: String = "") {
        lock.withLock {
            state = newState
            failure = reason
            if newState == .ready {
                everLoaded = true
            }
        }

        postChange()
    }

    private var statusLocked: BrainStatus {
        if let unavailableReason {
            return .unavailable(unavailableReason)
        }

        if downloadTask != nil {
            return .downloading(received: progress.received, total: progress.total)
        }

        if let downloadFailure {
            return .failed(downloadFailure)
        }

        switch state {
        case .notInstalled:
            return .notInstalled
        case .sleeping:
            return everLoaded ? .unloaded : .installed
        case .loading:
            return .starting
        case .ready:
            return .ready
        case .failed:
            return .failed(failure)
        }
    }

    private var availabilityLocked: BrainAvailability {
        guard unavailableReason == nil else { return .off }
        switch state {
        case .notInstalled:
            return .notInstalled
        case .sleeping:
            return .sleeping
        case .loading:
            return .loading
        case .ready:
            return .ready
        case .failed:
            return .failed
        }
    }

    /// Tells `onStatusChange` the status, in order, once per change.
    private func postChange() {
        changes.async { [weak self] in
            guard let self else { return }
            let (status, handler) = self.lock.withLock { (self.statusLocked, self.statusHandler) }
            guard status != self.posted else { return }
            self.posted = status
            handler?(status)
        }
    }

    private func log(_ level: BrainLogLevel, _ line: String) {
        let handler = lock.withLock { logHandler }
        handler?(level, line)
    }

    /// Runs work that `shutdown` cancels (C#'s `_shutdown` token).
    private func runInBackground(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown else { return }
        lastBackground += 1
        let id = lastBackground
        background[id] = Task.detached { [self] in
            await work()
            _ = self.lock.withLock { self.background.removeValue(forKey: id) }
        }
    }

    /// A free TCP port on 127.0.0.1 (C#'s `TcpListener` on port 0).
    static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrainError("No free port for llama-server.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }

        guard found, address.sin_port != 0 else { throw BrainError("No free port for llama-server.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// 16 random bytes in hex (C#'s `Convert.ToHexString(RandomNumberGenerator.GetBytes(16))`).
    static func newKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02X", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// What Settings shows when a download fails: the model store's own words, as ThumbFree for Mac shows them.
    static func downloadProblem(_ error: Error) -> String {
        switch error {
        case let error as BrainError:
            return error.message
        case let error as DownloadError:
            return error.message
        default:
            return "The download stopped. Check the internet connection and try again (it carries on where it stopped)."
        }
    }

    /// An error for a log line, as Windows logs it: its type and code, with the message only for the brain's own
    /// errors (other messages can hold a file's name).
    static func kind(of error: Error) -> String {
        if let error = error as? BrainError {
            return error.message
        }

        if let error = error as? LlamaServerError {
            return "LlamaServerError.\(error)"
        }

        let code = (error as NSError).code
        let type = String(describing: Swift.type(of: error))
        return type == "NSError" ? "\((error as NSError).domain) \(code)" : "\(type) \(code)"
    }

    /// A start failure for Settings.
    private static func detail(_ error: Error) -> String {
        (error as? BrainError)?.message ?? "llama-server didn't start."
    }

    private static func code(_ server: any ServerProcess) -> String {
        server.exitStatus.map { String($0) } ?? "unknown"
    }

    private static func address(_ port: Int) -> URL {
        // A literal address with a number: always a URL.
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

private enum ServerState {
    case notInstalled
    case sleeping
    case loading
    case ready
    case failed
}
