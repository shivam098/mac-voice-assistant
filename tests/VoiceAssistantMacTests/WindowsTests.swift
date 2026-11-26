import ApplicationServices
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// The AI brain's windows on fakes (C#'s `ListWindows`, `Describe` and `ActivateWindowAsync`), and the core's contract:
/// no requirement of `JarvisDesktop` is left to the core's defaults.
final class WindowsTests: XCTestCase {
    // MARK: Listing

    /// The other apps' standard windows, front-most first by the window server's order and the one taking the keys
    /// first of all; not this app's, not panels, and not an app outside the Dock unless it's taking the keys.
    func testListsTheOtherAppsWindowsFrontMostFirst() async throws {
        let rig = Rig()
        let notes = FakeElement.window(title: "Notes.txt", number: 420)
        let draft = FakeElement.window(title: "", number: 421)
        let fonts = FakeElement.window(title: "Fonts", number: 422)
        fonts[kAXSubroleAttribute] = kAXFloatingWindowSubrole
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: notes)
        rig.ax.apps[42]?[kAXWindowsAttribute] = [notes, draft, fonts]
        let own = FakeElement.window(pid: Rig.own, title: "Voice Assistant", number: 10)
        rig.front(Rig.own, "io.github.shivam098.voiceassistant", "Voice Assistant", window: own)
        let agentWindow = FakeElement.window(pid: 5, title: "Agent", number: 50)
        let agent = FakeElement.app(pid: 5)
        agent[kAXWindowsAttribute] = [agentWindow]
        rig.ax.apps[5] = agent
        rig.workspace.running.append(
            RunningApp(processIdentifier: 5, bundleIdentifier: "com.example.agent", name: "Agent", isRegular: false))
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, title: "Documents", number: 80))
        rig.workspace.windowOrder = [10, 50, 422, 421, 80, 420]

        let desktop: JarvisDesktop = rig.desktop
        var listed = try await desktop.listWindows()
        XCTAssertEqual([80, 421, 420], listed.map(\.window.handle))
        let finder = WindowInfo(
            handle: 80, processId: 8, processName: "com.apple.finder", title: "Documents", appName: "Finder")
        XCTAssertEqual(finder, listed.first?.window)
        XCTAssertEqual("window list: 3 windows, 0 ms", rig.log.lines.last)

        // An app outside the Dock taking the keys (a menu bar app's settings window).
        rig.ax.focus(agent, window: agentWindow)
        listed = try await desktop.listWindows()
        XCTAssertEqual([50, 421, 80, 420], listed.map(\.window.handle))
    }

    /// How each window shows (C#'s `Describe`): minimized, also when its app is hidden; maximized in full screen; else
    /// normal. Its frame, and the usable part of the screen it's on: the one with its centre, else the one it covers
    /// most. macOS calls a minimized window, and a hidden app's, a dialog (AXDialog); an alert, which is one, isn't
    /// listed.
    func testSaysHowEachWindowShowsAndWhere() async throws {
        let rig = Rig()
        let main = ScreenArea(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800))
        let side = ScreenArea(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1040))
        rig.workspace.screenAreas = [main, side]
        let notes = FakeElement.window(
            title: "Notes.txt", number: 420, frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let movie = FakeElement.window(title: "Movie", number: 421, frame: side.frame)
        movie[AXName.fullScreen] = true
        let draft = FakeElement.window(
            title: "Draft.txt", number: 422, frame: CGRect(x: -300, y: 100, width: 400, height: 300))
        let old = FakeElement.window(title: "Old.txt", number: 423)
        old[kAXSubroleAttribute] = kAXDialogSubrole
        old[kAXMinimizedAttribute] = true
        let alert = FakeElement.window(title: "", number: 424)
        alert[kAXSubroleAttribute] = kAXDialogSubrole
        let music = FakeElement.window(pid: 7, title: "Music", number: 70)
        music[kAXSubroleAttribute] = kAXDialogSubrole
        rig.front(7, "com.apple.Music", "Music", window: music)
        rig.ax.apps[7]?[kAXHiddenAttribute] = true
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: notes)
        rig.ax.apps[42]?[kAXWindowsAttribute] = [notes, movie, draft, old, alert]
        rig.workspace.windowOrder = [424, 420, 421, 422]

        let listed = try await rig.desktop.listWindows()
        XCTAssertEqual([420, 421, 422, 70, 423], listed.map(\.window.handle))
        let shows: [WindowShow] = [.normal, .maximized, .normal, .minimized, .minimized]
        XCTAssertEqual(shows, listed.map(\.show))
        let rects: [ScreenRect?] = [
            ScreenRect(x: 100, y: 100, width: 600, height: 400), ScreenRect(side.frame),
            ScreenRect(x: -300, y: 100, width: 400, height: 300), ScreenRect(x: 0, y: 0, width: 1000, height: 800),
            ScreenRect(x: 0, y: 0, width: 1000, height: 800),
        ]
        XCTAssertEqual(rects, listed.map(\.rect))
        let mainArea = ScreenRect(main.visibleFrame)
        let areas: [ScreenRect?] = [mainArea, ScreenRect(side.visibleFrame), mainArea, mainArea, mainArea]
        XCTAssertEqual(areas, listed.map(\.workArea))
        XCTAssertEqual("maximized", ScreenSummary.placement(listed[1]))
    }

    /// The first twelve by the window server's order (C#'s `MaxListedWindows`), the one taking the keys moved first
    /// when it's among them.
    func testListsTwelveAtMost() async throws {
        let rig = Rig()
        let windows: [FakeElement] = (1...15).map { (number: Int) -> FakeElement in
            FakeElement.window(title: "Note \(number)", number: number)
        }
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: windows[4])
        rig.ax.apps[42]?[kAXWindowsAttribute] = windows
        rig.workspace.windowOrder = Array(1...15)

        var listed = try await rig.desktop.listWindows()
        XCTAssertEqual([5, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12], listed.map(\.window.handle))

        rig.ax.apps[42]?[kAXFocusedWindowAttribute] = windows[13]
        listed = try await rig.desktop.listWindows()
        XCTAssertEqual(Array(1...12), listed.map(\.window.handle))
        XCTAssertEqual("window list: 12 windows, 0 ms", rig.log.lines.last)
    }

    // MARK: Bringing one forward

    /// A listed window behind another app's comes to the front, named by its title.
    func testBringsAWindowForward() async throws {
        let rig = Rig()
        rig.activates()
        let notes = FakeElement.window(title: "Notes.txt", number: 420)
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: notes)
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, title: "Documents", number: 80))
        rig.workspace.windowOrder = [80, 420]
        let listed = try await rig.desktop.listWindows()
        let target = try XCTUnwrap(listed.first { $0.window.handle == 420 }?.window)

        let result = try await rig.desktop.activateWindow(target)
        XCTAssertEqual(DesktopResult.ok("“Notes.txt” is ready.", window: target), result)
        XCTAssertEqual([kAXRaiseAction], notes.actions)
        XCTAssertEqual([42], rig.workspace.activated)
        XCTAssertTrue(target.sameWindow(rig.desktop.foregroundWindow()))
    }

    /// A minimized window of a hidden app: the app is unhidden and the window restored before it's brought forward.
    func testRestoresAMinimizedWindowOfAHiddenApp() async throws {
        let rig = Rig()
        rig.activates()
        let notes = FakeElement.window(title: "Notes.txt", number: 420)
        notes[kAXMinimizedAttribute] = true
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: notes)
        rig.ax.apps[42]?[kAXHiddenAttribute] = true
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, title: "Documents", number: 80))
        let target = WindowInfo(
            handle: 420, processId: 42, processName: "com.apple.TextEdit", title: "Notes.txt", appName: "TextEdit")

        let result = try await rig.desktop.activateWindow(target)
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual("AXHidden=false", rig.ax.apps[42]?.changes.first)
        XCTAssertEqual(false, rig.ax.apps[42]?[kAXHiddenAttribute] as? Bool)
        XCTAssertEqual("AXMinimized=false", notes.changes.first)
    }

    /// A title longer than 40 characters, or none, is "that window" in messages, and never in the log.
    func testNamesALongOrUntitledWindowThatWindow() async throws {
        let rig = Rig()
        let title = String(repeating: "Quarterly plan ", count: 3)
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: .window(title: title, number: 420))
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, title: "Documents", number: 80))
        let start = rig.time.now
        let target = WindowInfo(
            handle: 420, processId: 42, processName: "com.apple.TextEdit", title: title, appName: "TextEdit")

        let result = try await rig.desktop.activateWindow(target)
        XCTAssertEqual(
            DesktopResult.fail(
                "macOS didn't let me bring that window to the front. Click it once, then say “start typing”."),
            result)
        XCTAssertEqual(1.5, rig.time.now - start, accuracy: 0.001)
        XCTAssertEqual("activation of a window refused by macOS", rig.log.lines.last)
        XCTAssertFalse(rig.log.lines.contains { $0.contains("Quarterly") })

        var untitled = target
        untitled.title = ""
        let again = try await rig.desktop.activateWindow(untitled)
        XCTAssertTrue(again.message.hasPrefix("macOS didn't let me bring that window to the front."), again.message)
    }

    /// A window that has closed since it was listed fails at once.
    func testAWindowThatClosedFailsAtOnce() async throws {
        let rig = Rig()
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: .window(title: "Notes.txt", number: 420))
        let start = rig.time.now
        let gone = WindowInfo(
            handle: 421, processId: 42, processName: "com.apple.TextEdit", title: "Draft.txt", appName: "TextEdit")

        let result = try await rig.desktop.activateWindow(gone)
        XCTAssertEqual(DesktopResult.fail("I couldn't find “Draft.txt” any more."), result)
        XCTAssertEqual(0, rig.time.now - start)
        XCTAssertEqual("activation of a window: not found", rig.log.lines.last)
    }

    // MARK: The contract

    /// The core gives some of `JarvisDesktop`'s requirements defaults that do nothing, or say "… isn't supported here".
    /// Each is MacDesktop's own: called through the protocol, as the core calls them, so that a requirement whose
    /// signature slipped can't fall back to its default unnoticed.
    func testNoRequirementIsLeftToTheCoresDefaults() async throws {
        let rig = Rig()
        rig.activates()
        rig.workspace.screenAreas = [
            ScreenArea(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800)),
        ]
        let save = FakeElement(role: kAXButtonRole, title: "Save", frame: CGRect(x: 400, y: 10, width: 80, height: 24))
        save.actionNames = [kAXPressAction]
        let field = FakeElement.textField(name: "Message")
        field.holds("Hello")
        let notes = FakeElement.window(title: "Notes", number: 420)
        notes.children = [save]
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: notes, focus: field)
        chromeBehind(rig)
        rig.workspace.windowOrder = [420, 90]
        rig.workspace.run(3, "com.apple.Terminal", "Terminal")

        let desktop: JarvisDesktop = rig.desktop
        let unsupported = "isn't supported here"
        let front = try XCTUnwrap(desktop.foregroundWindow())
        XCTAssertEqual(ScreenRect(x: 0, y: 0, width: 1000, height: 800), desktop.windowRect(front))
        XCTAssertEqual("Hello", desktop.readTextBeforeCaret()?.before)
        XCTAssertEqual("Message", desktop.describeFocus()?.name)
        XCTAssertEqual(.noButton, desktop.describeDefaultButton())
        XCTAssertEqual("TextEdit", desktop.appName(front))
        XCTAssertTrue(desktop.isCommandWindow(WindowInfo(handle: 1, processId: 3, processName: "Terminal", title: "")))

        let clickable = try await desktop.listClickable(front)
        let button = try XCTUnwrap(clickable.first { $0.name == "Save" })
        let boxes = try await desktop.listTextBoxes(front)
        let box = try XCTUnwrap(boxes.first { $0.name == "Message" })
        let clicked = try await desktop.click(button)
        XCTAssertFalse(clicked.message.contains(unsupported), clicked.message)
        let focused = try await desktop.focusTextBox(box)
        XCTAssertFalse(focused.message.contains(unsupported), focused.message)
        let windows = try await desktop.listWindows()
        XCTAssertEqual([420, 90], windows.map(\.window.handle))
        let zoomed = try await desktop.zoom(front)
        XCTAssertFalse(zoomed.message.contains(unsupported), zoomed.message)
        let opened = try await desktop.openURL(BrainSafety.normalizeUrl("example.com")!)
        XCTAssertFalse(opened.message.contains(unsupported), opened.message)

        // MacDesktop's typing checks for secure input before any key, the new-line keys too; the core's default
        // would press them first.
        rig.keys.posted.removeAll()
        rig.keys.secureInput = .on
        XCTAssertThrowsError(try desktop.typeText("\nls", newLineKeys: "Shift+Enter"))
        XCTAssertTrue(rig.keys.posted.isEmpty)
        rig.keys.secureInput = .off
        try desktop.pressKeysRepeated("Tab", 3)
        XCTAssertEqual(3, rig.keys.posted.count)

        let listedTabs = try await desktop.listTabs()
        XCTAssertEqual(["Inbox", "News"], listedTabs.map(\.title))
        let selected = try await desktop.selectTab(listedTabs[1])
        XCTAssertFalse(selected.message.contains(unsupported), selected.message)
        let activated = try await desktop.activateWindow(front)
        XCTAssertTrue(activated.success, activated.message)
    }

    /// Chrome's window 90, behind, with a tab strip of two tabs, the first one showing.
    private func chromeBehind(_ rig: Rig) {
        let tabs = ["Inbox", "News"].enumerated().map { index, title -> FakeElement in
            let tab = FakeElement(
                pid: 9, role: kAXRadioButtonRole, title: title,
                frame: CGRect(x: 10 + 210 * Double(index), y: 5, width: 200, height: 30))
            tab.actionNames = [kAXPressAction]
            tab[kAXValueAttribute] = index == 0 ? 1 : 0
            return tab
        }
        let strip = FakeElement(pid: 9, role: kAXTabGroupRole, frame: CGRect(x: 0, y: 0, width: 1000, height: 40))
        strip.children = tabs
        let window = FakeElement.window(pid: 9, title: "Inbox", number: 90)
        window.children = [strip]
        let chrome = FakeElement.app(pid: 9)
        chrome[kAXWindowsAttribute] = [window]
        rig.ax.apps[9] = chrome
        rig.workspace.run(9, "com.google.Chrome", "Google Chrome")
    }
}
