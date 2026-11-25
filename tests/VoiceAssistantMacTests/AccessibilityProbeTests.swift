import AppKit
import ApplicationServices
import XCTest

/// What the Mac running the tests lets this process do. GitHub's macOS runner image grants Accessibility to /bin/bash
/// and to its agent in TCC.db (actions/runner-images, configure-tccdb-macos.sh), and the agent starts the job's
/// processes. This reports whether the test process is trusted for Accessibility and may post events, the processes
/// that started it, and whether it can read the Dock and Finder, in lines starting "AX probe:": counts, roles and
/// outcomes, never other apps' names or titles. It never fails.
///
/// A window of the test process itself can't be read: AppKit doesn't serve Accessibility in a process that hasn't
/// launched as an app (the first run read "notImplemented" and the window never became key), and launching it in the
/// test process (`finishLaunching`) stopped the tests. AccessibilityIntegrationTests uses TextEdit instead.
final class AccessibilityProbeTests: XCTestCase {
    func testWhatThisMacAllows() {
        Probe.report("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        Probe.report("CGPreflightPostEventAccess: \(CGPreflightPostEventAccess())")
        Probe.report("CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())")
        Probe.report("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Probe.report("processes, this one first: \(Probe.processChain())")
        Probe.report("app in front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        for browser in ["/Applications/Safari.app", "/Applications/Google Chrome.app", "/Applications/Firefox.app"] {
            Probe.report("\(browser) installed: \(FileManager.default.fileExists(atPath: browser))")
        }

        Probe.report(Probe.focusedApplication())
        Probe.report(Probe.describeApp("com.apple.dock"))
        Probe.report(Probe.describeApp("com.apple.finder"))
    }
}

private enum Probe {
    /// Written at once, so a test that stops the process can't lose it.
    static func report(_ line: String) {
        print("AX probe: \(line)")
        fflush(stdout)
    }

    static func focusedApplication() -> String {
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, 3)
        let (error, value) = copy(kAXFocusedApplicationAttribute, of: systemWide)
        guard let app = value.flatMap(element) else { return "system-wide focused application: \(name(error))" }
        var pid: pid_t = 0
        _ = AXUIElementGetPid(app, &pid)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        return "system-wide focused application: \(name(error)), \(bundle)"
    }

    /// The app's role, its windows' and children's roles and counts (never their titles).
    static func describeApp(_ bundleIdentifier: String) -> String {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return "\(bundleIdentifier): not running" }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(app, 3)
        let (roleError, role) = copy(kAXRoleAttribute, of: app)
        let windows = elements(kAXWindowsAttribute, of: app)
        let children = elements(kAXChildrenAttribute, of: app)
        let childRoles = children.elements.prefix(6).map { string(kAXRoleAttribute, of: $0) ?? "?" }
        var grandchildren = 0
        for child in children.elements.prefix(6) {
            grandchildren += elements(kAXChildrenAttribute, of: child).elements.count
        }

        return "\(bundleIdentifier): role \(name(roleError)) \(role as? String ?? "?"), "
            + "\(windows.elements.count) window(s) (\(name(windows.error))), "
            + "\(children.elements.count) child(ren) (\(name(children.error))) with roles \(childRoles), "
            + "\(grandchildren) grandchild(ren)"
    }

    /// This process and the ones that started it, as `ps` names them.
    static func processChain() -> String {
        var chain: [String] = []
        var pid = Int(getpid())
        for _ in 0..<10 where pid > 1 {
            let fields = run("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let space = fields.firstIndex(of: " "), let parent = Int(fields[..<space]) else { break }
            chain.append("\(fields[space...].trimmingCharacters(in: .whitespaces)) (\(pid))")
            pid = parent
        }

        return chain.joined(separator: " <- ")
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func copy(_ attribute: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        copy(attribute, of: element).1 as? String
    }

    private static func elements(_ attribute: String, of element: AXUIElement)
        -> (error: AXError, elements: [AXUIElement])
    {
        let (error, value) = copy(attribute, of: element)
        let items = (value as? [AnyObject]) ?? []
        return (error, items.compactMap(Probe.element))
    }

    private static func element(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeBitCast(value, to: AXUIElement.self) : nil
    }

    static func name(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .apiDisabled: return "apiDisabled"
        case .cannotComplete: return "cannotComplete"
        case .noValue: return "noValue"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .invalidUIElement: return "invalidUIElement"
        case .illegalArgument: return "illegalArgument"
        case .failure: return "failure"
        case .notImplemented: return "notImplemented"
        default: return "AXError \(error.rawValue)"
        }
    }
}
