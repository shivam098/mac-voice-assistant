import Foundation

/// A value several threads read and write, behind a lock (C#'s volatile fields and `Interlocked`).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value

    init(_ value: Value) {
        current = value
    }

    var value: Value {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Sets `newValue` and returns what was there (`Interlocked.Exchange`).
    @discardableResult
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let old = current
            current = newValue
            return old
        }
    }

    /// Changes the value in place, under the lock; returns what `change` returns.
    @discardableResult
    func update<Result>(_ change: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try change(&current) }
    }
}

/// Blocking work (whisper.cpp, Silero, loading a model) on threads of its own, so the host's tasks never hold up a
/// thread of Swift's pool while a model runs for seconds.
enum Blocking {
    private static let queue = DispatchQueue(
        label: "VoiceAssistant.blocking", qos: .userInitiated, attributes: .concurrent)

    /// What `work` returns or throws. With `cancellable`, cancelling the task that waits returns at once with
    /// `CancellationError` while `work` runs to its end, as Whisper.net's calls return on a cancel while whisper.cpp
    /// carries on; a model's next call waits for it.
    static func run<T: Sendable>(
        cancellable: Bool = true, _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let once = OnceResult<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.set(continuation)
                queue.async {
                    once.resume(Result { try work() })
                }
            }
        } onCancel: {
            if cancellable {
                once.resume(.failure(CancellationError()))
            }
        }
    }

    /// Whether `task` finished within `seconds` (C#'s `Task.Wait(timeout)`); it carries on either way.
    static func finished(_ task: Task<Void, Never>?, within seconds: TimeInterval) async -> Bool {
        guard let task else { return true }
        let once = OnceResult<Bool>()
        let finished = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            once.set(continuation)
            Task.detached {
                await task.value
                once.resume(.success(true))
            }

            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume(.success(false))
            }
        }

        return finished ?? false
    }
}

/// A continuation resumed once, by whatever comes first; a result that comes before the continuation is kept for it.
final class OnceResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<T, Error>) {
        let ready: Result<T, Error>? = lock.withLock {
            if let early {
                resumed = true
                return early
            }

            self.continuation = continuation
            return nil
        }

        if let ready {
            continuation.resume(with: ready)
        }
    }

    func resume(_ result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard !resumed, early == nil else { return nil }
            guard let continuation else {
                early = result
                return nil
            }

            resumed = true
            self.continuation = nil
            return continuation
        }

        waiting?.resume(with: result)
    }
}

/// The host's work queue (C#'s `Channel<Func<Task>>`, read by `ProcessQueueAsync`): one task runs the work in order,
/// awaiting each item before the next.
final class WorkQueue: @unchecked Sendable {
    typealias Work = @Sendable () async throws -> Void

    /// The items, in order, for the one task that runs them.
    let items: AsyncStream<Work>

    private let continuation: AsyncStream<Work>.Continuation

    init() {
        var made: AsyncStream<Work>.Continuation?
        items = AsyncStream { made = $0 }
        continuation = made!
    }

    /// Adds work (C#'s `TryWrite`); false once the queue is finished.
    @discardableResult
    func enqueue(_ work: @escaping Work) -> Bool {
        if case .enqueued = continuation.yield(work) {
            return true
        }

        return false
    }

    /// Takes no more work (C#'s `TryComplete`).
    func finish() {
        continuation.finish()
    }
}

/// The voice action in progress, which pausing or Esc cancels (C#'s `_actionCts`, swapped for a new one by each
/// cancel): one at a time, as the queue runs one item at a time.
final class VoiceActions: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Task<Void, Error>?

    /// Runs `work` as the action in progress and waits for it. Cancelling the waiting task cancels it too.
    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let task: Task<Void, Error> = lock.withLock {
            let task = Task { try await work() }
            current = task
            return task
        }

        defer {
            lock.withLock {
                if current == task {
                    current = nil
                }
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the action in progress, if there is one.
    func cancel() {
        lock.withLock { current }?.cancel()
    }
}

/// One of the host's events (a C# event): every handler runs, in the order it was added, on the thread the host posts
/// to, which is the main thread in the app. Safe from any thread.
public final class HostEvent<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(id: Int, run: (Value) -> Void)] = []
    private var lastId = 0

    public init() {}

    /// Adds a handler (C#'s `+=`); it runs until the subscription is cancelled.
    @discardableResult
    public func subscribe(_ handler: @escaping (Value) -> Void) -> HostSubscription {
        let id: Int = lock.withLock {
            lastId += 1
            handlers.append((id: lastId, run: handler))
            return lastId
        }

        return HostSubscription { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.handlers.removeAll { $0.id == id } }
        }
    }

    /// Runs the handlers with `value`, here and now.
    func send(_ value: Value) {
        let current = lock.withLock { handlers.map { $0.run } }
        for handler in current {
            handler(value)
        }
    }
}

/// A handler added to a `HostEvent`: it runs until `cancel()` (C#'s `-=`).
public final class HostSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        let action: (() -> Void)? = lock.withLock {
            defer { onCancel = nil }
            return onCancel
        }

        action?()
    }
}

/// The app's notices for the UI (Windows' tray balloons): an event like `HostEvent<String>`, except that the notices
/// still in force also reach a handler added later, so a menu or window that starts listening after launch still shows
/// them. A notice sent with a topic is in force until it's withdrawn or another notice of that topic replaces it; one
/// without a topic is sent once. Handlers run on the thread that sends, the main thread in the app. Safe from any
/// thread.
public final class NoticeEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(id: Int, run: (String) -> Void)] = []
    private var lastId = 0
    private var standing: [(topic: String, message: String)] = []

    public init() {}

    /// The notices in force, oldest first.
    public var inForce: [String] { lock.withLock { standing.map { $0.message } } }

    /// Adds a handler (C#'s `+=`): it runs at once with each notice in force, oldest first, then with each notice sent,
    /// until the subscription is cancelled.
    @discardableResult
    public func subscribe(_ handler: @escaping (String) -> Void) -> HostSubscription {
        let (id, replay) = lock.withLock { () -> (Int, [String]) in
            lastId += 1
            handlers.append((id: lastId, run: handler))
            return (lastId, standing.map { $0.message })
        }

        for message in replay {
            handler(message)
        }

        return HostSubscription { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.handlers.removeAll { $0.id == id } }
        }
    }

    /// Runs the handlers with `message`. With a `topic`, the notice stays in force for handlers added later, in place of
    /// that topic's earlier one, until `withdraw(topic)`.
    func send(_ message: String, topic: String? = nil) {
        let current = lock.withLock { () -> [(String) -> Void] in
            if let topic {
                standing.removeAll { $0.topic == topic }
                standing.append((topic: topic, message: message))
            }

            return handlers.map { $0.run }
        }

        for handler in current {
            handler(message)
        }
    }

    /// The topic's notice no longer holds: handlers added later don't get it.
    func withdraw(_ topic: String) {
        lock.withLock { standing.removeAll { $0.topic == topic } }
    }
}
