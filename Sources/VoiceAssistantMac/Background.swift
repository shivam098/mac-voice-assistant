import Foundation

/// The clock and the waits the desktop uses (C#'s `DateTime.UtcNow`, `Task.Delay` and `Thread.Sleep`); tests give it
/// a fake clock that moves only when it waits.
public struct DesktopClock: Sendable {
    /// Seconds on a clock that only goes forward.
    public var now: @Sendable () -> TimeInterval

    /// Waits, and throws `CancellationError` when the task is cancelled (C#'s `Task.Delay(ms, token)`).
    public var pause: @Sendable (TimeInterval) async throws -> Void

    /// Blocks the thread (C#'s `Thread.Sleep`), in work that runs off the caller's thread.
    public var sleep: @Sendable (TimeInterval) -> Void

    public init(
        now: @escaping @Sendable () -> TimeInterval,
        pause: @escaping @Sendable (TimeInterval) async throws -> Void,
        sleep: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.now = now
        self.pause = pause
        self.sleep = sleep
    }

    public static let system = DesktopClock(
        now: { ProcessInfo.processInfo.systemUptime },
        pause: { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
        sleep: { Thread.sleep(forTimeInterval: $0) })
}

/// What work with a time limit came to.
enum Timed<Value> {
    case finished(Value)
    case timedOut
}

extension Timed: Sendable where Value: Sendable {}

/// Set when work's time ran out or its task was cancelled, so work still running (an app slow to answer) never acts
/// for real after the user was told it timed out: the C# work's cancellation token.
final class WorkToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Accessibility work, which waits while apps answer, done off the caller's thread with a time limit, as the C# runs
/// UI Automation in `Task.Run` with a timeout.
enum Background {
    /// Runs `work` on another thread and waits at most `seconds` for it (C#'s `Task.Run(…).Wait(ms)`). Work that takes
    /// longer goes on until its own calls time out, and what it finds is dropped.
    static func wait<Value: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> Value)
        -> Timed<Value>
    {
        let answer = Answer<Value>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.set(work())
            done.signal()
        }

        guard done.wait(timeout: .now() + seconds) == .success, let value = answer.value else { return .timedOut }
        return .finished(value)
    }

    /// Runs `work` on another thread and waits at most `seconds` for it (C#'s `Task.Run(…).WaitAsync(timeout, token)`):
    /// when time runs out, `work`'s token is cancelled first. Throws `CancellationError` when the calling task is
    /// cancelled, which cancels the token too.
    static func run<Value: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable (WorkToken) -> Value)
        async throws -> Timed<Value>
    {
        let token = WorkToken()
        let gate = Gate<Timed<Value>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Timed<Value>, Error>) in
                guard gate.start(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    gate.finish(.success(.finished(work(token))))
                }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                    guard gate.isPending else { return }
                    token.cancel()
                    gate.finish(.success(.timedOut))
                }
            }
        } onCancel: {
            token.cancel()
            gate.finish(.failure(CancellationError()))
        }
    }

    /// A value written on one thread and read on another.
    final class Answer<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?

        var value: Value? { lock.withLock { stored } }

        func set(_ value: Value) {
            lock.withLock { stored = value }
        }
    }

    /// The first of the work, the time limit and the cancellation to finish resumes the caller; the others do nothing.
    final class Gate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var early: Result<Value, Error>?
        private var finished = false

        var isPending: Bool { lock.withLock { !finished } }

        /// Keeps `continuation` for the result; false when the task was cancelled first (it's resumed already).
        func start(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(with: early)
                return false
            }

            self.continuation = continuation
            lock.unlock()
            return true
        }

        @discardableResult
        func finish(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return false
            }

            finished = true
            guard let continuation else {
                early = result
                lock.unlock()
                return true
            }

            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return true
        }
    }
}
