import AppKit
import ApplicationServices
import Carbon.HIToolbox
import XCTest

/// What the Mac running the tests lets this process do (GitHub's macOS runner image grants Accessibility to /bin/bash
/// and to its agent in TCC.db): whether it's trusted for Accessibility and may post events, and whether it can read the
/// Dock, Finder and a window of its own, press that window's button and type into its box. It reports what worked in
/// lines starting "AX probe:", as counts, roles and outcomes, never other apps' names or titles, and never fails.
final class AccessibilityProbeTests: XCTestCase {
    @MainActor
    func testWhatThisMacAllows() {
        let trusted = AXIsProcessTrusted()
        let mayPost = CGPreflightPostEventAccess()
        Probe.report("AXIsProcessTrusted: \(trusted)")
        Probe.report("CGPreflightPostEventAccess: \(mayPost)")
        Probe.report("CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())")
        Probe.report("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Probe.report("processes, this one first: \(Probe.processChain())")
        Probe.report("app in front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        for browser in ["/Applications/Safari.app", "/Applications/Google Chrome.app", "/Applications/Firefox.app"] {
            Probe.report("\(browser) installed: \(FileManager.default.fileExists(atPath: browser))")
        }

        let others = Probe.Box()
        Probe.runOffMain(others) { box in
            box.add(Probe.focusedApplication())
            box.add(Probe.describeApp("com.apple.dock"))
            box.add(Probe.describeApp("com.apple.finder"))
        }

        others.lines.forEach(Probe.report)
        probeOwnWindow(mayPost: mayPost)
    }

    /// A window of this process with a button and a text box: read through Accessibility from another thread while
    /// the main thread handles events (Accessibility asks the main thread), its button pressed (AXPress) and its box
    /// given a value, then a key posted to it. The first run, without `finishLaunching` and with only the run loop
    /// running, found Accessibility not implemented for this process and its window not key; this one launches the app
    /// and handles its events.
    @MainActor
    private func probeOwnWindow(mayPost: Bool) {
        let app = NSApplication.shared
        Probe.report("activation policy set: \(app.setActivationPolicy(.accessory))")
        app.finishLaunching()
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 420, height: 160), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Voice Assistant probe"
        let clicks = Clicks()
        let button = NSButton(title: "Probe button", target: clicks, action: #selector(Clicks.clicked(_:)))
        button.frame = NSRect(x: 20, y: 100, width: 160, height: 32)
        let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 300, height: 24))
        field.placeholderString = "Probe box"
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        _ = window.makeFirstResponder(field)
        Probe.handleEvents(1)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        Probe.report("own app active: \(app.isActive), its window key: \(window.isKeyWindow), in front: \(front)")

        let own = Probe.Box()
        let pid = getpid()
        Probe.runOffMain(own, handlingEvents: true) { box in Probe.readOwnApp(pid, box) }
        own.lines.forEach(Probe.report)
        Probe.handleEvents(0.5)
        Probe.report("button's action ran after AXPress: \(clicks.count) time(s)")
        Probe.report("box shows the value Accessibility set: \(field.stringValue == Probe.setValue)")

        if mayPost {
            _ = window.makeFirstResponder(field)
            field.stringValue = ""
            Probe.handleEvents(0.3)
            Probe.postKey(CGKeyCode(kVK_ANSI_X))
            Probe.handleEvents(1)
            let typed = field.stringValue
            let outcome = typed == "x" ? "arrived in the box" : typed.isEmpty ? "nothing arrived" : "other text"
            Probe.report("posted key x: \(outcome)")
        }

        window.orderOut(nil)
        window.close()
        app.deactivate()
        Probe.handleEvents(0.3)
    }
}

/// Counts presses of the probe's button.
private final class Clicks: NSObject {
    private(set) var count = 0

    @objc func clicked(_ sender: Any?) {
        count += 1
    }
}

private enum Probe {
    static let setValue = "set by Accessibility"

    /// Lines written by another thread, read on the main thread once it's done.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        private var finished = false

        func add(_ line: String) {
            lock.withLock { written.append(line) }
        }

        func finish() {
            lock.withLock { finished = true }
        }

        var isFinished: Bool { lock.withLock { finished } }

        var lines: [String] { lock.withLock { written } }
    }

    static func report(_ line: String) {
        print("AX probe: \(line)")
    }

    /// Handles this app's events for `seconds`, as NSApplication.run does.
    @MainActor
    static func handleEvents(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            handleEvent(until: min(end, Date(timeIntervalSinceNow: 0.05)))
        }
    }

    @MainActor
    private static func handleEvent(until date: Date) {
        let app = NSApplication.shared
        if let event = app.nextEvent(matching: .any, until: date, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }

    /// Runs `work` on another thread while the main thread runs its run loop or, `handlingEvents`, handles this app's
    /// events; 30 s at most.
    @MainActor
    static func runOffMain(_ box: Box, handlingEvents: Bool = false, _ work: @escaping @Sendable (Box) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            work(box)
            box.finish()
        }

        let end = Date(timeIntervalSinceNow: 30)
        while !box.isFinished, Date() < end {
            if handlingEvents {
                handleEvent(until: Date(timeIntervalSinceNow: 0.05))
            } else {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }

        if !box.isFinished {
            box.add("gave up waiting after 30 s")
        }
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

    /// This process's own window through Accessibility: its button and box found by their title and placeholder,
    /// the button pressed, the box given a value.
    static func readOwnApp(_ pid: pid_t, _ box: Box) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 5)
        let windows = elements(kAXWindowsAttribute, of: app)
        box.add("own app: \(windows.elements.count) window(s) (\(name(windows.error)))")
        let (focusedError, focused) = copy(kAXFocusedUIElementAttribute, of: app)
        box.add(
            "own app's focused element: \(name(focusedError)) "
                + (focused.flatMap(element).flatMap { string(kAXRoleAttribute, of: $0) } ?? "none"))

        var button: AXUIElement?
        var field: AXUIElement?
        var roles: [String: Int] = [:]
        var queue = windows.elements
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let node = queue.removeFirst()
            visited += 1
            let role = string(kAXRoleAttribute, of: node) ?? "?"
            roles[role, default: 0] += 1
            if role == kAXButtonRole, string(kAXTitleAttribute, of: node) == "Probe button" {
                button = node
            }

            if role == kAXTextFieldRole, string("AXPlaceholderValue", of: node) == "Probe box" {
                field = node
            }

            queue += elements(kAXChildrenAttribute, of: node).elements
        }

        box.add("own window's elements by role: \(roles.sorted { $0.key < $1.key })")
        box.add("found its button: \(button != nil), its box: \(field != nil)")
        if let button {
            box.add("AXPress on the button: \(name(AXUIElementPerformAction(button, kAXPressAction as CFString)))")
            var frame = "?"
            if let position = copy(kAXPositionAttribute, of: button).1,
               let size = copy(kAXSizeAttribute, of: button).1 {
                frame = "\(CFGetTypeID(position) == AXValueGetTypeID()), \(CFGetTypeID(size) == AXValueGetTypeID())"
            }

            box.add("button's position and size are AXValues: \(frame)")
        }

        if let field {
            let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, setValue as CFString)
            box.add("set the box's AXValue: \(name(set))")
            let focus = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, NSNumber(value: true))
            box.add("set the box's AXFocused: \(name(focus))")
        }
    }

    /// A key down and up for `key`, posted at the HID level, as a person's key would arrive.
    static func postKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            report("couldn't make key events")
            return
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
