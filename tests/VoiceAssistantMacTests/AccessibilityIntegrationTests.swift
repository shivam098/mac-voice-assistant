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

    /// What TextEdit's settings these tests set (`Integration.textEditSettings`) were.
    private var previousSettings: [(key: String, value: [String]?)] = []

    override func setUp() async throws {
        try await super.setUp()
        try Integration.skipUnlessAllowed()
        previousSettings = Integration.setTextEditSettings()
        await Integration.quit("com.apple.TextEdit")
        desktop = MacDesktop(insertMethod: { "Type" }, log: { Integration.report("desktop: \($0)") })
    }

    override func tearDown() async throws {
        if desktop != nil {
            await Integration.quit("com.apple.TextEdit")
            Integration.restoreTextEditSettings(previousSettings)
        }

        try await super.tearDown()
    }

    func testOpensTextEditTypesAndEdits() async throws {
        Integration.report("before TextEdit: system-wide focused application \(Self.systemWideFocus())")
        let opened = try await desktop.openOrActivate(Self.textEdit, newWindow: false)
        Integration.report("after TextEdit: system-wide focused application \(Self.systemWideFocus())")
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
        let nothing = try await caretText { $0?.before == "" }
        XCTAssertEqual(CaretText(before: "", caretKnown: true), nothing)

        try desktop.typeText("Hello from Jarvis")
        try await Self.settle()
        let typed = try await caretText { $0?.before == "Hello from Jarvis" }
        var caret = try XCTUnwrap(typed, "text before the cursor")
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
        let moved = try await caretText { $0?.before == "Hello " }
        caret = try XCTUnwrap(moved)
        XCTAssertEqual("Hello ", caret.before)
        XCTAssertFalse(caret.hasSelection)

        try desktop.pressKeysRepeated("Shift+Left", 3)
        try await Self.settle()
        let selecting = try await caretText { $0?.hasSelection == true }
        XCTAssertEqual(true, selecting?.hasSelection)

        try desktop.pressKeys("Cmd+A")
        try desktop.pressKeys("Right")
        try await Self.settle()
        let ended = try await caretText { $0?.before == "Hello from " && $0?.hasSelection == false }
        XCTAssertEqual(CaretText(before: "Hello from ", caretKnown: true), ended)
        XCTAssertEqual(false, desktop.focusedTextEndsWithNonWhitespace())

        try desktop.pressKeys("Enter")
        try desktop.typeText("Second line")
        try await Self.settle()
        let second = try await caretText { $0?.before == "Hello from \nSecond line" }
        XCTAssertEqual("Hello from \nSecond line", second?.before)

        // A typing with a line break: TextEdit's new-line key between the lines.
        try desktop.typeText("\nThird", newLineKeys: Self.textEdit.newLineKeys)
        try await Self.settle()
        let third = try await caretText { $0?.before == "Hello from \nSecond line\nThird" }
        XCTAssertEqual("Hello from \nSecond line\nThird", third?.before)

        XCTAssertEqual(.noButton, desktop.describeDefaultButton())
        try desktop.pressKeys("Cmd+S")
        var button = DefaultButtonInfo.noButton
        for _ in 0..<30 where button == .noButton {
            try await Task.sleep(nanoseconds: 100_000_000)
            button = desktop.describeDefaultButton()
        }

        // The save panel's buttons are another process's: its sheet is found, its default button can't be read.
        Integration.report("default button with the Save sheet open: \(Self.describe(button))")
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
        Integration.report("the find bar's field is named: \(!(desktop.describeFocus()?.name ?? "").isEmpty)")
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
        Integration.report("zoomed: window \(frame.integral), usable part of its screen \(screen.visibleFrame.integral)")
        XCTAssertEqual(screen.visibleFrame.width, frame.width, accuracy: 2)
        XCTAssertEqual(screen.visibleFrame.minY, frame.minY, accuracy: 2)
    }

    func testFindsTheInstalledApps() {
        let apps = desktop.discoverApps()
        Integration.report("installed apps found: \(apps.count)")
        let workspace = SystemWorkspace()
        let safari = workspace.folderItems(URL(fileURLWithPath: "/Applications", isDirectory: true))
            .first { $0.url.lastPathComponent == "Safari.app" }
        let identifier = safari.flatMap { workspace.appBundle(at: $0.url)?.bundleIdentifier } ?? "none"
        Integration.report("/Applications lists Safari.app: \(safari != nil), its bundle identifier: \(identifier)")
        Integration.report("Safari's entry starts \(apps.first { $0.name == "Safari" }?.launch ?? "nothing")")
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
        Integration.report("the dialog's app in front: \(desktop.foregroundWindow()?.processName ?? "none")")
    }

    // MARK: Helpers

    /// Time for TextEdit to take the keys.
    private static func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// The text before the cursor once `done` says it's what was expected, read every 0.1 s for up to 2 s: TextEdit
    /// can take a moment to show what was typed. The last read when it never is.
    private func caretText(until done: (CaretText?) -> Bool) async throws -> CaretText? {
        var caret = desktop.readTextBeforeCaret()
        for _ in 0..<20 where !done(caret) {
            try await Task.sleep(nanoseconds: 100_000_000)
            caret = desktop.readTextBeforeCaret()
        }

        return caret
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
}
