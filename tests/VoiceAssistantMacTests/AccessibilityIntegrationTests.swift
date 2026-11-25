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

    private var desktop: MacDesktop!

    override func setUp() async throws {
        try await super.setUp()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GITHUB_ACTIONS"] == "true" || environment["VOICE_ASSISTANT_AX_TESTS"] == "1",
            "Opens, types into and quits TextEdit: set VOICE_ASSISTANT_AX_TESTS=1 to run it here.")
        try XCTSkipUnless(
            AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            "Needs Accessibility and the permission to post events for the test process.")

        // A new document when TextEdit starts, not its Open panel.
        Self.run(
            "/usr/bin/defaults", "write", "com.apple.TextEdit", "NSShowAppCentricOpenPanelInsteadOfUntitledFile",
            "-bool", "false")
        await Self.quitTextEdit()
        desktop = MacDesktop(insertMethod: { "Type" }, log: { Self.report("desktop: \($0)") })
    }

    override func tearDown() async throws {
        if desktop != nil {
            await Self.quitTextEdit()
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
        XCTAssertEqual(false, prepared.hasTrailingText)

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

        XCTAssertEqual(.noButton, desktop.describeDefaultButton())
        try desktop.pressKeys("Cmd+S")
        var button = DefaultButtonInfo.noButton
        for _ in 0..<30 where button == .noButton {
            try await Task.sleep(nanoseconds: 100_000_000)
            button = desktop.describeDefaultButton()
        }

        Self.report("default button with the Save sheet open: \(Self.describe(button))")
        try desktop.pressKeys("Esc")
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
        Self.report("zoomed to the usable part of its screen: \(frame.integral == screen.visibleFrame.integral)")
        XCTAssertEqual(screen.visibleFrame.width, frame.width, accuracy: 2)
        XCTAssertEqual(screen.visibleFrame.minY, frame.minY, accuracy: 2)
    }

    func testFindsTheInstalledApps() {
        let apps = desktop.discoverApps()
        Self.report("installed apps found: \(apps.count)")
        let launches = Set(apps.map(\.launch))
        for app in ["com.apple.TextEdit", "com.apple.Safari", "com.apple.finder", "com.apple.Terminal"] {
            XCTAssertTrue(launches.contains(app), app)
        }
    }

    // MARK: Helpers

    static func report(_ line: String) {
        print("AX test: \(line)")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            report("couldn't run \(tool)")
        }
    }
}
