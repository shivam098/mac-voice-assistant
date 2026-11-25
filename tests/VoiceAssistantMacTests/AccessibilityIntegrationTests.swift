import AppKit
import ApplicationServices
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// The desktop on one of this Mac's own apps, TextEdit, through the real Accessibility API, CGEvent and NSWorkspace:
/// opened, found in front, typed into, edited with keys, its focus and default button read, zoomed. The test process
/// needs Accessibility and the permission to post events, which GitHub's macOS runners give it. They run on GitHub
/// Actions, or anywhere with VOICE_ASSISTANT_AX_TESTS=1, since they open, type into and quit TextEdit. Lines starting
/// "AX test:" say what was found: counts and outcomes, never other apps' names or titles.
final class AccessibilityIntegrationTests: XCTestCase {
    private static let textEdit = AppEntry(
        name: "TextEdit", launch: "com.apple.TextEdit", processNames: ["com.apple.TextEdit"], newLineKeys: "Enter",
        textArea: "Largest")

    /// TextEdit's settings these tests set, and put back afterwards: a new document when it starts, not its Open
    /// panel, and no windows from before restored (a document an earlier test typed into).
    private static let textEditSettings = [
        (key: "NSShowAppCentricOpenPanelInsteadOfUntitledFile", value: false),
        (key: "ApplePersistenceIgnoreState", value: true),
    ]

    private var desktop: MacDesktop!

    /// What those settings were (`defaults write`'s type and value), nil for one that wasn't set.
    private var previousSettings: [(key: String, value: [String]?)] = []

    override func setUp() async throws {
        try await super.setUp()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GITHUB_ACTIONS"] == "true" || environment["VOICE_ASSISTANT_AX_TESTS"] == "1",
            "Opens, types into and quits TextEdit: set VOICE_ASSISTANT_AX_TESTS=1 to run it here.")
        try XCTSkipUnless(
            AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            "Needs Accessibility and the permission to post events for the test process.")

        previousSettings = Self.textEditSettings.map { (key: $0.key, value: Self.textEditSetting($0.key)) }
        for setting in Self.textEditSettings {
            Self.run(
                "/usr/bin/defaults", "write", "com.apple.TextEdit", setting.key, "-bool",
                setting.value ? "true" : "false")
        }

        await Self.quitTextEdit()
        desktop = MacDesktop(insertMethod: { "Type" }, log: { Self.report("desktop: \($0)") })
    }

    override func tearDown() async throws {
        if desktop != nil {
            await Self.quitTextEdit()
            for setting in previousSettings {
                if let value = setting.value {
                    Self.run(["/usr/bin/defaults", "write", "com.apple.TextEdit", setting.key] + value)
                } else {
                    Self.run(["/usr/bin/defaults", "delete", "com.apple.TextEdit", setting.key])
                }
            }
        }

        try await super.tearDown()
    }

    func testOpensTextEditTypesAndEdits() async throws {
        Self.report("before TextEdit: system-wide focused application \(Self.systemWideFocus())")
        let opened = try await desktop.openOrActivate(Self.textEdit, newWindow: false)
        Self.report("after TextEdit: system-wide focused application \(Self.systemWideFocus())")
        XCTAssertTrue(opened.success, opened.message)
        let window = try XCTUnwrap(opened.window, opened.message)
        let front = try XCTUnwrap(desktop.foregroundWindow(), "no window in front")
        XCTAssertEqual("com.apple.TextEdit", front.processName)
        XCTAssertTrue(window.sameWindow(front))
        XCTAssertNotEqual(0, front.handle, "the window's number")
        XCTAssertEqual("TextEdit", desktop.appName(front))
        XCTAssertFalse(desktop.isCommandWindow(front))
        XCTAssertEqual(.safe, desktop.checkFocusedField())

        let prepared = try await desktop.prepareTextTarget(front, profile: Self.textEdit)
        XCTAssertTrue(prepared.success, prepared.message)
        XCTAssertEqual(true, prepared.focusIsEditable)

        // An empty document, whatever TextEdit kept from before.
        try desktop.pressKeys("Cmd+A")
        try desktop.backspace(1)
        try await Self.settle()
        let empty = try await desktop.prepareTextTarget(front, profile: Self.textEdit)
        XCTAssertEqual(false, empty.hasTrailingText)
        XCTAssertEqual(CaretText(before: "", caretKnown: true), desktop.readTextBeforeCaret())

        try desktop.typeText("Hello from Jarvis")
        try await Self.settle()
        var caret = try XCTUnwrap(desktop.readTextBeforeCaret(), "text before the cursor")
        XCTAssertEqual(CaretText(before: "Hello from Jarvis", caretKnown: true), caret)
        XCTAssertEqual(true, desktop.focusedTextEndsWithNonWhitespace())
        let focus = try XCTUnwrap(desktop.describeFocus(), "the focus")
        XCTAssertTrue(focus.editable)
        XCTAssertFalse(focus.inPage)
        XCTAssertFalse(focus.addressBar)

        // Backspace, the arrows and Shift, and ⌘A pressed as keys of the layout in use.
        try desktop.backspace(6)
        try desktop.pressKeysRepeated("Left", 5)
        try await Self.settle()
        caret = try XCTUnwrap(desktop.readTextBeforeCaret())
        XCTAssertEqual("Hello ", caret.before)
        XCTAssertFalse(caret.hasSelection)

        try desktop.pressKeysRepeated("Shift+Left", 3)
        try await Self.settle()
        XCTAssertEqual(true, desktop.readTextBeforeCaret()?.hasSelection)

        try desktop.pressKeys("Cmd+A")
        try desktop.pressKeys("Right")
        try await Self.settle()
        XCTAssertEqual(CaretText(before: "Hello from ", caretKnown: true), desktop.readTextBeforeCaret())
        XCTAssertEqual(false, desktop.focusedTextEndsWithNonWhitespace())

        try desktop.pressKeys("Enter")
        try desktop.typeText("Second line")
        try await Self.settle()
        XCTAssertEqual("Hello from \nSecond line", desktop.readTextBeforeCaret()?.before)

        // A typing with a line break: TextEdit's new-line key between the lines.
        try desktop.typeText("\nThird", newLineKeys: Self.textEdit.newLineKeys)
        try await Self.settle()
        XCTAssertEqual("Hello from \nSecond line\nThird", desktop.readTextBeforeCaret()?.before)

        XCTAssertEqual(.noButton, desktop.describeDefaultButton())
        try desktop.pressKeys("Cmd+S")
        var button = DefaultButtonInfo.noButton
        for _ in 0..<30 where button == .noButton {
            try await Task.sleep(nanoseconds: 100_000_000)
            button = desktop.describeDefaultButton()
        }

        // The save panel's buttons are another process's: its sheet is found, its default button can't be read.
        Self.report("default button with the Save sheet open: \(Self.describe(button))")
        XCTAssertNotEqual(.noButton, button)
        try desktop.pressKeys("Esc")

        // Nothing typed is left for TextEdit to keep.
        try await Self.settle()
        try desktop.pressKeys("Cmd+A")
        try desktop.backspace(1)
    }

    /// "Open TextEdit" with TextEdit open, wanting a new window: its new-window keys (⌘N, as the layout types N), then
    /// the window that wasn't there, told apart by its number.
    func testOpensANewTextEditWindow() async throws {
        let first = try await desktop.openOrActivate(Self.textEdit, newWindow: false)
        let window = try XCTUnwrap(first.window, first.message)
        var withKeys = Self.textEdit
        withKeys.newWindowKeys = "Cmd+N"
        let second = try await desktop.openOrActivate(withKeys, newWindow: true)
        XCTAssertEqual("Opened a new TextEdit window.", second.message)
        let fresh = try XCTUnwrap(second.window)
        XCTAssertFalse(fresh.sameWindow(window))
        XCTAssertTrue(fresh.sameWindow(desktop.foregroundWindow()))
    }

    /// TextEdit's find bar has a search field, which the scan finds and focuses; its document is the largest text area.
    func testFindsTheSearchFieldAndTheTextArea() async throws {
        let opened = try await desktop.openOrActivate(Self.textEdit, newWindow: false)
        let window = try XCTUnwrap(opened.window, opened.message)
        try desktop.pressKeys("Cmd+F")
        try await Self.settle()

        let token = WorkToken()
        let area = try XCTUnwrap(desktop.findTextArea(window, "Largest", nil, token), "the document")
        XCTAssertEqual(kAXTextAreaRole, try desktop.ax.role(of: area))
        XCTAssertNotNil(desktop.findSearchBox(window, token), "the find bar's search field")

        XCTAssertEqual(.done, desktop.ax.set(kAXFocusedAttribute, true, of: area))
        try await Self.settle()
        XCTAssertEqual(true, desktop.describeFocus()?.editable)
        let searched = try await desktop.focusSearchBox(window)
        XCTAssertTrue(searched.success, searched.message)
        XCTAssertFalse(desktop.ax.isSame(try XCTUnwrap(desktop.focus()), as: area))
        Self.report("the find bar's field is named: \(!(desktop.describeFocus()?.name ?? "").isEmpty)")
    }

    /// The window fills the part of the screen apps use.
    func testZoomsTextEdit() async throws {
        let opened = try await desktop.openOrActivate(Self.textEdit, newWindow: false)
        let window = try XCTUnwrap(opened.window, opened.message)
        let zoomed = try await desktop.zoom(window)
        XCTAssertTrue(zoomed.success, zoomed.message)
        try await Self.settle()

        let screens = await SystemWorkspace().screens()
        let element = try XCTUnwrap(desktop.windowElement(window))
        let frame = try XCTUnwrap(desktop.ax.frame(of: element))
        let screen = try XCTUnwrap(screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
        Self.report("zoomed: window \(frame.integral), usable part of its screen \(screen.visibleFrame.integral)")
        XCTAssertEqual(screen.visibleFrame.width, frame.width, accuracy: 2)
        XCTAssertEqual(screen.visibleFrame.minY, frame.minY, accuracy: 2)
    }

    func testFindsTheInstalledApps() {
        let apps = desktop.discoverApps()
        Self.report("installed apps found: \(apps.count)")
        let workspace = SystemWorkspace()
        let safari = workspace.folderItems(URL(fileURLWithPath: "/Applications", isDirectory: true))
            .first { $0.url.lastPathComponent == "Safari.app" }
        let identifier = safari.flatMap { workspace.appBundle(at: $0.url)?.bundleIdentifier } ?? "none"
        Self.report("/Applications lists Safari.app: \(safari != nil), its bundle identifier: \(identifier)")
        Self.report("Safari's entry starts \(apps.first { $0.name == "Safari" }?.launch ?? "nothing")")
        let launches = Set(apps.map(\.launch))
        for app in ["com.apple.TextEdit", "com.apple.Safari", "com.apple.finder", "com.apple.Terminal"] {
            XCTAssertTrue(launches.contains(app), app)
        }
    }

    /// A dialog's default button, which Return presses whatever has the focus: osascript's, in a process of its own.
    func testReadsADialogsDefaultButton() async throws {
        let dialog = Process()
        dialog.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        dialog.arguments = [
            "-e", "activate",
            "-e", "display dialog \"Voice Assistant test\" buttons {\"Cancel\", \"Erase\"} default button \"Erase\" "
                + "giving up after 20",
        ]
        try dialog.run()
        defer { dialog.terminate() }

        var button = DefaultButtonInfo.unknown
        for _ in 0..<50 where button != .named("Erase") {
            try await Task.sleep(nanoseconds: 200_000_000)
            button = desktop.describeDefaultButton()
        }

        XCTAssertEqual(.named("Erase"), button)
        Self.report("the dialog's app in front: \(desktop.foregroundWindow()?.processName ?? "none")")
    }

    // MARK: Helpers

    static func report(_ line: String) {
        print("AX test: \(line)")
        fflush(stdout)
    }

    /// Time for TextEdit to take the keys.
    private static func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private static func systemWideFocus() -> String {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        return "AXError \(error.rawValue), app in front \(front)"
    }

    private static func describe(_ button: DefaultButtonInfo) -> String {
        switch button {
        case .noButton: return "none"
        case .unknown: return "unknown"
        case .named(let name): return name.isEmpty ? "unnamed" : "named \(name)"
        }
    }

    private static func quitTextEdit() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit") {
            app.forceTerminate()
        }

        for _ in 0..<50 where !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
            .allSatisfy(\.isTerminated) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func run(_ tool: String, _ arguments: String...) {
        run([tool] + arguments)
    }

    private static func run(_ command: [String]) {
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

    /// A TextEdit setting as `defaults write` takes it back (its type and value), or nil when it isn't set.
    private static func textEditSetting(_ key: String) -> [String]? {
        guard let value = output("/usr/bin/defaults", "read", "com.apple.TextEdit", key),
              let type = output("/usr/bin/defaults", "read-type", "com.apple.TextEdit", key) else { return nil }
        switch type {
        case "Type is boolean": return ["-bool", value == "1" ? "true" : "false"]
        case "Type is integer": return ["-int", value]
        case "Type is float": return ["-float", value]
        default: return ["-string", value]
        }
    }

    /// What a tool prints, trimmed; nil when it fails (`defaults read` of a setting that isn't there).
    private static func output(_ tool: String, _ arguments: String...) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
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
