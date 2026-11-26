import AppKit
import CoreServices

/// Whether this app may control another with Apple events: the Automation permission, in System Settings › Privacy &
/// Security › Automation.
public enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied

    /// Not asked yet: asking shows macOS's prompt.
    case notAsked

    /// It couldn't be told (the app isn't running, say).
    case unknown
}

/// How an AppleScript run went.
public enum ScriptResult: Equatable, Sendable {
    /// Its result, as text.
    case output(String)

    /// It failed: AppleScript's error number when it gave one (-1743: not allowed to control the app; -600: the app
    /// isn't running).
    case failed(Int?)

    case timedOut
}

/// AppleScript, for Safari's tabs, behind a protocol so they can be tested without Safari (`FakeScripts` in the
/// tests).
public protocol ScriptSystem: AnyObject {
    /// Runs `source` (an AppleScript, given `arguments` in its `run` handler) and waits at most `timeout` seconds for it.
    func run(_ source: String, arguments: [String], timeout: TimeInterval) -> ScriptResult

    /// This app's Automation permission for the app with `bundleIdentifier` (AEDeterminePermissionToAutomateTarget).
    /// With `ask`, macOS asks the user first if it hasn't, and this waits for the answer.
    func automation(_ bundleIdentifier: String, ask: Bool) -> AutomationPermission
}

/// osascript and the Apple Event Manager themselves. The script runs in osascript, off the caller's thread and stopped
/// when its time is up; macOS counts its Apple events as this app's, the app osascript runs for.
public final class SystemScripts: ScriptSystem, @unchecked Sendable {
    public init() {}

    public func run(_ source: String, arguments: [String], timeout: TimeInterval) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed(nil)
        }

        let watched = Watched(process)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            watched.stopIfRunning()
        }

        // Its errors are read alongside its output, so neither pipe fills up and holds osascript back.
        let complaint = Background.Answer<Data>()
        let readErrors = DispatchGroup()
        readErrors.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            complaint.set(errors.fileHandleForReading.readDataToEndOfFile())
            readErrors.leave()
        }

        let printed = output.fileHandleForReading.readDataToEndOfFile()
        readErrors.wait()
        process.waitUntilExit()
        if watched.stopped {
            return .timedOut
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed(Self.errorNumber(String(decoding: complaint.value ?? Data(), as: UTF8.self)))
        }

        var text = String(decoding: printed, as: UTF8.self)
        if text.hasSuffix("\n") {
            text.removeLast()
        }

        return .output(text)
    }

    public func automation(_ bundleIdentifier: String, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let status: OSStatus = withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return -600 }
            return AEDeterminePermissionToAutomateTarget(address, Self.anyEvent, Self.anyEvent, ask)
        }

        switch status {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notAsked
        default: return .unknown
        }
    }

    /// typeWildCard ('****'): any event class and ID.
    private static let anyEvent: FourCharCode = 0x2A2A_2A2A

    /// The number at the end of osascript's error ("… execution error: Not authorized to send Apple events to Safari.
    /// (-1743)").
    static func errorNumber(_ complaint: String) -> Int? {
        let text = complaint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        return Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
    }

    /// A running script, stopped by the timer when its time is up: asked to (SIGTERM), then a second later made to.
    private final class Watched: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var didStop = false

        init(_ process: Process) {
            self.process = process
        }

        var stopped: Bool { lock.withLock { didStop } }

        func stopIfRunning() {
            let pid: pid_t? = lock.withLock {
                guard process.isRunning else { return nil }
                didStop = true
                process.terminate()
                return process.processIdentifier
            }

            guard let pid else { return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
    }
}
