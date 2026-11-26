import AppKit
import ApplicationServices
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// AppleScript that never asks for the Automation permission: a test can't answer macOS's prompt, which would stay in
/// front of the apps the next tests use.
final class UnaskingScripts: ScriptSystem, @unchecked Sendable {
    private let system = SystemScripts()

    func run(_ source: String, arguments: [String], timeout: TimeInterval) -> ScriptResult {
        system.run(source, arguments: arguments, timeout: timeout)
    }

    func automation(_ bundleIdentifier: String, ask: Bool) -> AutomationPermission {
        system.automation(bundleIdentifier, ask: false)
    }
}

/// What the navigation integration tests share: whether they may run, their report lines, the NavigationLab pages,
/// waiting, AppleScript, and starting and quitting apps.
enum Integration {
    /// They run on GitHub Actions, or anywhere with VOICE_ASSISTANT_AX_TESTS=1, with Accessibility and the permission
    /// to post events for the test process.
    static func skipUnlessAllowed() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GITHUB_ACTIONS"] == "true" || environment["VOICE_ASSISTANT_AX_TESTS"] == "1",
            "Opens apps, clicks in them and quits them: set VOICE_ASSISTANT_AX_TESTS=1 to run it here.")
        try skipUnlessTrusted()
    }

    /// The navigation integration tests drive browsers and other apps for a few minutes: they run with
    /// VOICE_ASSISTANT_NAVIGATION_TESTS=1 (CI's step of their own) or VOICE_ASSISTANT_AX_TESTS=1.
    static func skipUnlessNavigationAllowed() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["VOICE_ASSISTANT_NAVIGATION_TESTS"] == "1" || environment["VOICE_ASSISTANT_AX_TESTS"] == "1",
            "Drives browsers, Finder, TextEdit and System Settings: set VOICE_ASSISTANT_AX_TESTS=1 to run it here.")
        try skipUnlessTrusted()
    }

    private static func skipUnlessTrusted() throws {
        try XCTSkipUnless(
            AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            "Needs Accessibility and the permission to post events for the test process.")
    }

    static func report(_ line: String) {
        print("AX test: \(line)")
        fflush(stdout)
    }

    /// A NavigationLab page (tests/NavigationLab, copied from windows-voice-assistant).
    static func page(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NavigationLab").appendingPathComponent("\(name).html")
    }

    /// Waits up to `seconds` for `condition`, looking every quarter of a second; whether it came.
    @discardableResult
    static func waitUntil(_ seconds: Double, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() {
                return true
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        return try await condition()
    }

    static func script(_ source: String, timeout: TimeInterval = 30) -> ScriptResult {
        SystemScripts().run(source, arguments: [], timeout: timeout)
    }

    /// Starts the app through Launch Services (`open`), in front, with `arguments`; with `newInstance`, a process of its
    /// own even when the app is running already. Its running app, nil when it didn't start within 15 s.
    static func launch(_ app: URL, arguments: [String] = [], newInstance: Bool = false) async throws
        -> NSRunningApplication? {
        guard let bundle = Bundle(url: app)?.bundleIdentifier else { return nil }
        let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        var command: [String] = ["/usr/bin/open"]
        if newInstance {
            command.append("-n")
        }

        command += ["-a", app.path]
        if !arguments.isEmpty {
            command += ["--args"] + arguments
        }

        guard run(command, timeout: 15) else { return nil }
        var found: NSRunningApplication?
        _ = try await waitUntil(15) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            found = running.first { !$0.isTerminated && (!newInstance || !before.contains($0.processIdentifier)) }
            return found != nil
        }

        return found
    }

    /// Runs a tool and waits at most `timeout` for it; whether it ended in time, and well.
    @discardableResult
    static func run(_ command: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
        } catch {
            report("couldn't run \(command[0])")
            return false
        }

        guard ended.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            report("\(command[0]) didn't end in \(Int(timeout)) s (app in front: \(front))")
            return false
        }

        return process.terminationStatus == 0
    }

    /// Stops an app a test started: asked to quit (SIGTERM, not an Apple event, which would need the Automation
    /// permission), then 5 s later made to.
    static func stop(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        _ = kill(pid, SIGTERM)
        for _ in 0..<50 where kill(pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
    }

    /// The app in front and what takes the keys, for when bringing a window forward fails: NSWorkspace's front app, the
    /// system-wide focused application (or Accessibility's error), and its focused window's number, role, subrole and
    /// title.
    static func keys(_ desktop: MacDesktop) -> String {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        guard error == .success, let app = value, CFGetTypeID(app) == AXUIElementGetTypeID() else {
            return "app in front \(front), system-wide focused application: AXError \(error.rawValue)"
        }

        let ax = desktop.ax
        let pid: pid_t = (try? ax.processIdentifier(of: app)) ?? 0
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        guard let window = try? ax.element(kAXFocusedWindowAttribute, of: app) else {
            return "app in front \(front), keys with \(bundle), no focused window"
        }

        let role: String = (try? ax.role(of: window)) ?? "?"
        let subrole: String = (try? ax.subrole(of: window)) ?? "?"
        let title: String = (try? ax.string(kAXTitleAttribute, of: window)) ?? ""
        let number: String = ax.windowNumber(of: window).map { String($0) } ?? "?"
        return "app in front \(front), keys with \(bundle) window \(number) (\(role)/\(subrole) \"\(title)\")"
    }

    /// What `csrutil status` says about System Integrity Protection.
    static func integrityProtection() -> String {
        output(["/usr/bin/csrutil", "status"]) ?? "csrutil didn't answer"
    }

    /// The apps whose windows are on screen at the normal level, and how many each has, front-most first, for when a
    /// window of another app covers a click point.
    static func screenWindows() -> String {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return "none" }
        var owners: [String] = []
        var counts: [String: Int] = [:]
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            let owner: String = info[kCGWindowOwnerName as String] as? String ?? "?"
            if counts[owner] == nil {
                owners.append(owner)
            }

            counts[owner, default: 0] += 1
        }

        return owners.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    /// A window of the window server: its number, whose it is, its layer and frame, for when something covers a click
    /// point.
    static func describeServerWindow(_ number: Int?) -> String {
        guard let number, let id = CGWindowID(exactly: number),
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first else { return "none" }
        let pid: Int = info[kCGWindowOwnerPID as String] as? Int ?? 0
        let name: String = info[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
        let owner: String = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? name
        let layer: Int = info[kCGWindowLayer as String] as? Int ?? 0
        var frame = "no frame"
        if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            frame = "\(rect)"
        }

        return "\(number) of \(owner), layer \(layer), \(frame)"
    }

    /// What Accessibility's system-wide hit test finds at a point: whose element it is, its role and its window's
    /// number.
    static func describeHit(_ desktop: MacDesktop, at point: CGPoint) -> String {
        let ax = desktop.ax
        let found: AnyObject?
        do {
            found = try ax.elementAtPoint(point)
        } catch {
            return "no answer"
        }

        guard let element = found else { return "nothing" }
        let pid: pid_t = (try? ax.processIdentifier(of: element)) ?? 0
        let owner: String = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        let role: String = (try? ax.role(of: element)) ?? "?"
        var number = "?"
        if let window = try? ax.element(kAXWindowAttribute, of: element), let known = ax.windowNumber(of: window) {
            number = String(known)
        }

        return "\(owner)'s \(role) in window \(number)"
    }

    /// Seconds since `start`, to a tenth, for the reports.
    static func seconds(since start: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(start))
    }

    static func isRunning(_ bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
    }

    static func quit(_ bundleIdentifier: String) async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.forceTerminate()
        }

        for _ in 0..<50 where isRunning(bundleIdentifier) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How many elements of each role, for the reports.
    static func roles(_ elements: [UiElement]) -> String {
        var counts: [String: Int] = [:]
        for element in elements {
            counts["\(element.role)", default: 0] += 1
        }

        let names: [String] = counts.keys.sorted()
        return names.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    /// Tabs as the reports list them: their numbers and titles, and which one shows.
    static func describe(_ tabs: [BrowserTab]) -> String {
        tabs.map { "\($0.index) \($0.title)" + ($0.isSelected ? " (shown)" : "") }.joined(separator: " | ")
    }

    /// Windows as the reports list them: number, app, title, how each shows, its frame and its screen's usable part.
    static func describe(_ windows: [DesktopWindow]) -> String {
        func text(_ rect: ScreenRect?) -> String {
            guard let rect else { return "-" }
            return "\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height))"
        }

        let lines: [String] = windows.map { (listed: DesktopWindow) -> String in
            let window = listed.window
            return "\(window.handle) \(window.processName) \"\(window.title)\" \(listed.show) \(text(listed.rect)) in "
                + text(listed.workArea)
        }
        return lines.joined(separator: " | ")
    }

    /// An app's windows as Accessibility lists them (AXWindows): number, role and subrole, whether minimized, its
    /// minimize button (enabled, disabled or none), title.
    static func describeAppWindows(_ desktop: MacDesktop, _ pid: pid_t) -> String {
        let ax = desktop.ax
        let windows = (try? ax.elements(kAXWindowsAttribute, of: ax.application(pid))) ?? []
        let lines: [String] = windows.map { (window: AnyObject) -> String in
            let number = ax.windowNumber(of: window) ?? 0
            let role = (try? ax.role(of: window)) ?? "-"
            let subrole = (try? ax.subrole(of: window)) ?? "-"
            let minimized = (try? ax.number(kAXMinimizedAttribute, of: window)).map { "\($0)" } ?? "-"
            var button = "none"
            if let found = try? ax.element(kAXMinimizeButtonAttribute, of: window) {
                button = (try? ax.number(kAXEnabledAttribute, of: found)) == 0 ? "disabled" : "enabled"
            }

            let title = (try? ax.string(kAXTitleAttribute, of: window)) ?? "-"
            return "\(number) \(role)/\(subrole) minimized \(minimized) minimize button \(button) \"\(title)\""
        }
        return "\(windows.count) windows: " + lines.joined(separator: " | ")
    }

    /// What a scan of `root` walks (outside its pages unless `pages`): roles, subroles, names, whether each shows and
    /// its parent's role, for when something isn't found.
    static func dump(_ desktop: MacDesktop, _ root: AnyObject, pages: Bool = false, limit: Int = 150) {
        var lines: [String] = []
        desktop.scan(root, WorkToken(), pages: pages) { _, node, place in
            let name = String((node.title ?? node.label ?? "").prefix(40))
            let parent = place.parentRole ?? "-"
            lines.append("\(node.role ?? "-")/\(node.subrole ?? "-") \"\(name)\" shows \(place.shows) in \(parent)")
            return lines.count < limit
        }

        report("\(lines.count) elements:\n" + lines.joined(separator: "\n"))
    }

    /// The element the core would pick for `name` (and `region`) in `window`, as "click …" does.
    static func resolve(
        _ elements: [UiElement], _ name: String, _ region: ScreenRegion? = nil, in window: ScreenRect?
    ) -> UiElement? {
        if case .single(let element) = TargetResolver.resolveElement(
            elements, ElementTarget(name: name, region: region), window) {
            return element
        }

        return nil
    }

    // MARK: TextEdit's settings

    /// TextEdit's settings the tests set, and put back afterwards: a new document when it starts, not its Open panel,
    /// and no windows from before restored.
    static let textEditSettings = [
        (key: "NSShowAppCentricOpenPanelInsteadOfUntitledFile", value: false),
        (key: "ApplePersistenceIgnoreState", value: true),
    ]

    /// Sets them, and returns what they were (`defaults write`'s type and value; nil for one that wasn't set).
    static func setTextEditSettings() -> [(key: String, value: [String]?)] {
        let previous = textEditSettings.map { (key: $0.key, value: textEditSetting($0.key)) }
        for setting in textEditSettings {
            let value = setting.value ? "true" : "false"
            run(["/usr/bin/defaults", "write", "com.apple.TextEdit", setting.key, "-bool", value])
        }

        return previous
    }

    static func restoreTextEditSettings(_ previous: [(key: String, value: [String]?)]) {
        for setting in previous {
            if let value = setting.value {
                run(["/usr/bin/defaults", "write", "com.apple.TextEdit", setting.key] + value)
            } else {
                run(["/usr/bin/defaults", "delete", "com.apple.TextEdit", setting.key])
            }
        }
    }

    private static func textEditSetting(_ key: String) -> [String]? {
        guard let value = output(["/usr/bin/defaults", "read", "com.apple.TextEdit", key]),
              let type = output(["/usr/bin/defaults", "read-type", "com.apple.TextEdit", key]) else { return nil }
        switch type {
        case "Type is boolean": return ["-bool", value == "1" ? "true" : "false"]
        case "Type is integer": return ["-int", value]
        case "Type is float": return ["-float", value]
        default: return ["-string", value]
        }
    }

    static func run(_ command: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            report("couldn't run \(command[0])")
        }
    }

    /// What a tool prints, trimmed; nil when it fails.
    private static func output(_ command: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let printed = Pipe()
        process.standardOutput = printed
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let data = printed.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
