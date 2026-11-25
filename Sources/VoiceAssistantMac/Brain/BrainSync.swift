import Foundation

/// One holder at a time for async code, waiting in order (C#'s `SemaphoreSlim(1, 1)` with `WaitAsync(token)` and
/// `Wait(0)`): a task cancelled while it waits stops waiting with `CancellationError`. ThumbFreeSpeech's `AsyncGate`
/// (internal there) with `tryAcquire`.
final class BrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var lastWaiter = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id: Int = lock.withLock {
            lastWaiter += 1
            return lastWaiter
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }

            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Takes the gate if it's free.
    func tryAcquire() -> Bool {
        lock.withLock {
            guard !held else { return false }
            held = true
            return true
        }
    }

    /// Hands the gate to the next waiter, or opens it.
    func release() {
        let next: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !waiters.isEmpty else {
                held = false
                return nil
            }

            return waiters.removeFirst().continuation
        }

        next?.resume()
    }
}

/// One start of llama-server, which any number of callers wait for (C#'s `_starting` task). A caller cancelled while it
/// waits stops waiting with `CancellationError`, and the start carries on, so the next request is quick (C#'s
/// `WaitAsync(token)`).
final class BrainStart: @unchecked Sendable {
    /// The start's own task, so that `LlamaBrain.shutdown` can stop it. Guarded by the brain's lock.
    var task: Task<Void, Never>?

    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var lastWaiter = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    init(outcome: Result<Void, Error>? = nil) {
        self.outcome = outcome
    }

    /// Ends every wait, and the ones to come, with the start's outcome.
    func finish(_ result: Result<Void, Error>) {
        let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard outcome == nil else { return [] }
            outcome = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }

        waiting.forEach { $0.resume(with: result) }
    }

    func wait() async throws {
        let id: Int = lock.withLock {
            lastWaiter += 1
            return lastWaiter
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
