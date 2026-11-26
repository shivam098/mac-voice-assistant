import Foundation

/// One Voice Assistant at a time (windows-voice-assistant App.xaml.cs's single-instance mutex): two would each listen,
/// type every dictation and save the board. The running copy holds an exclusive lock (flock) on a file in its folder,
/// which macOS lets go of when the process ends, however it ends. A second copy asks the first to show itself, then
/// quits.
public final class SingleInstance: @unchecked Sendable {
    /// Posted to this user's apps by a second copy: the running one shows itself (Windows' ShowWindow event).
    public static let showNotification = Notification.Name("io.github.shivam098.voiceassistant.show")

    public let path: String

    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit {
        release()
    }

    /// Takes the lock, waiting up to `timeout` for a copy that is quitting (Windows waits 3 s, and 15 s after "Save and
    /// restart"). True when this is the only copy, until `release` or the end of the process. Throws when the lock
    /// file can't be made or opened.
    public func acquire(waiting timeout: TimeInterval) throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if try tryAcquire() {
                return true
            }

            if Date() >= deadline {
                return false
            }

            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Lets go of the lock (closing the file does).
    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Asks the copy that holds the lock to show itself; it's delivered at once, though that copy isn't the active app.
    public static func showRunningCopy() {
        DistributedNotificationCenter.default().postNotificationName(
            showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func tryAcquire() throws -> Bool {
        try lock.withLock {
            if descriptor >= 0 {
                return true
            }

            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard opened >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if flock(opened, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                Darwin.close(opened)
                if code == EWOULDBLOCK {
                    return false
                }

                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }

            descriptor = opened
            return true
        }
    }
}
