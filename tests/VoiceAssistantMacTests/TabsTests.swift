import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// Browser tabs on fake browsers (C#'s `ScanTabs` and `SelectTabAsync`): Chromium's through Accessibility, Safari's
/// through AppleScript.
final class TabsTests: XCTestCase {
    private static let listing = "W\u{1F}70\u{1F}2\u{1F}Nav Lab\u{1E}"
        + "T\u{1F}Lab Videos - YouTube\u{1F}file:///lab/videos.html\u{1E}"
        + "T\u{1F}Nav Lab\u{1F}file:///lab/lab.html\u{1E}"

    private func tab(_ title: String, x: Double, pid: pid_t = 9, selected: Bool = false) -> FakeElement {
        let tab = FakeElement(
            pid: pid, role: kAXRadioButtonRole, title: title, frame: CGRect(x: x, y: 5, width: 200, height: 30))
        tab.actionNames = [kAXPressAction]
        if selected {
            tab[kAXValueAttribute] = 1
        }

        return tab
    }

    /// A Chrome window with a tab strip, and a page with a tab control of its own.
    @discardableResult
    private func chrome(_ rig: Rig, number: Int, title: String, tabs: [FakeElement]) -> FakeElement {
        let window = FakeElement.window(pid: 9, title: title, number: number)
        let strip = FakeElement(pid: 9, role: kAXTabGroupRole, frame: CGRect(x: 0, y: 0, width: 1000, height: 40))
        strip.children = tabs
        let page = FakeElement(pid: 9, role: AXName.webArea, frame: CGRect(x: 0, y: 80, width: 1000, height: 700))
        let settings = tab("Settings", x: 10)
        settings[kAXSubroleAttribute] = AXName.tabButton
        settings.frame = CGRect(x: 10, y: 100, width: 100, height: 30)
        page.children = [settings]
        window.children = [strip, page]
        rig.front(9, "com.google.Chrome", "Google Chrome", window: window)
        return window
    }

    /// Safari's window in front, listing `listing` through AppleScript; its tab bar's buttons when given.
    @discardableResult
    private func safari(_ rig: Rig, buttons: [FakeElement] = []) -> FakeElement {
        let window = FakeElement.window(pid: 7, title: "Nav Lab", number: 70)
        if !buttons.isEmpty {
            let bar = FakeElement(pid: 7, role: kAXTabGroupRole, frame: CGRect(x: 0, y: 40, width: 1000, height: 30))
            bar.children = buttons
            window.children = [bar]
        }

        rig.front(7, "com.apple.Safari", "Safari", window: window)
        rig.workspace.windowOrder = [70]
        rig.scripts.onRun = { source, _ in source.contains("set listing") ? .output(Self.listing) : .failed(nil) }
        return window
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Chromium

    /// The tab strip's tabs of each window on screen, the front-most window first, in reading order, numbered from 1 in
    /// each; not a page's tab controls, nor a window that isn't on screen.
    func testListsChromiumTabsInReadingOrder() async throws {
        let rig = Rig()
        chrome(rig, number: 91, title: "Docs", tabs: [tab("Docs", x: 10, selected: true)])
        chrome(rig, number: 92, title: "Hidden", tabs: [tab("Hidden", x: 10, selected: true)])
        chrome(rig, number: 90, title: "News - Example", tabs: [
            tab("News - Example", x: 220, selected: true), tab("Inbox (3) - Gmail", x: 10),
        ])
        rig.workspace.windowOrder = [90, 91]

        let tabs = try await rig.desktop.listTabs()
        XCTAssertEqual(["Inbox (3) - Gmail", "News - Example", "Docs"], tabs.map(\.title))
        XCTAssertEqual([1, 2, 1], tabs.map(\.index))
        XCTAssertEqual([false, true, true], tabs.map(\.isSelected))
        XCTAssertEqual([90, 90, 91], tabs.map(\.window.handle))
        XCTAssertEqual(ScreenRect(x: 10, y: 5, width: 200, height: 30), tabs[0].rect)
        XCTAssertEqual([1, 2, 3], tabs.map(\.id))
        XCTAssertEqual("tab scan: 3 tabs in 2 windows, 0 ms", rig.log.lines.last)

        // Chrome is woken once (AXEnhancedUserInterface), and its tab strip didn't need waiting for.
        XCTAssertEqual(["AXEnhancedUserInterface=true"], rig.ax.apps[9]?.changes)
        XCTAssertEqual(1, rig.log.lines.filter { $0 == "page descriptions asked for" }.count)
    }

    /// A Chromium browser that the scan has just woken may describe its tab strip only then: it's read again until it
    /// is, for up to 2.5 s from the scan's start.
    func testWaitsForAJustWokenBrowsersTabStrip() async throws {
        let rig = Rig()
        let window = chrome(rig, number: 90, title: "Docs", tabs: [])
        rig.workspace.windowOrder = [90]
        let strip = window.children[0]
        let docs = tab("Docs", x: 10, selected: true)
        let time = rig.time
        let start = time.now
        rig.ax.onNode = { element in
            if element === strip, strip.children.isEmpty, time.now >= start + 0.5 {
                strip.children = [docs]
            }
        }

        let tabs = try await rig.desktop.listTabs()
        XCTAssertEqual(["Docs"], tabs.map(\.title))
        XCTAssertEqual(0.5, time.now - start, accuracy: 0.001)
    }

    /// The tab is pressed, and the window's title follows it.
    func testSelectsATabAndChecksTheTitle() async throws {
        let rig = Rig()
        let inbox = tab("Inbox (3) - Gmail", x: 10)
        let window = chrome(rig, number: 90, title: "News - Example", tabs: [
            tab("News - Example", x: 220, selected: true), inbox,
        ])
        rig.workspace.windowOrder = [90]
        let tabs = try await rig.desktop.listTabs()
        rig.ax.onPerform = { element, action in
            if element === inbox, action == kAXPressAction {
                window[kAXTitleAttribute] = "Inbox (3) - Gmail"
            }
        }

        let result = try await rig.desktop.selectTab(tabs[0])
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual("Switched tab.", result.message)
        XCTAssertEqual("Inbox (3) - Gmail", result.window?.title)
        XCTAssertEqual([kAXPressAction], inbox.actions)
        XCTAssertEqual("tab select ok after 0 ms", rig.log.lines.last)
    }

    /// The title doesn't follow within 1.5 s: it didn't change.
    func testATabThatDidntChange() async throws {
        let rig = Rig()
        chrome(rig, number: 90, title: "News - Example", tabs: [
            tab("News - Example", x: 220, selected: true), tab("Inbox - Gmail", x: 10),
        ])
        rig.workspace.windowOrder = [90]
        let tabs = try await rig.desktop.listTabs()
        let start = rig.time.now

        let result = try await rig.desktop.selectTab(tabs[0])
        XCTAssertEqual(.fail("The tab didn't change. Click it once, or try “next tab”."), result)
        XCTAssertEqual(1.5, rig.time.now - start, accuracy: 0.001)
        XCTAssertEqual("tab select not verified", rig.log.lines.last)

        var gone = tabs[0]
        gone.id = 999
        let unknown = try await rig.desktop.selectTab(gone)
        XCTAssertEqual(.fail("That tab changed. Try again."), unknown)
    }

    /// A browser that doesn't answer the press may switch all the same: the title says whether it did, and nothing is
    /// clicked instead.
    func testATabWhoseBrowserDidntAnswer() async throws {
        let rig = Rig()
        let inbox = tab("Inbox (3) - Gmail", x: 10)
        let window = chrome(rig, number: 90, title: "News - Example", tabs: [
            tab("News - Example", x: 220, selected: true), inbox,
        ])
        rig.workspace.windowOrder = [90]
        let tabs = try await rig.desktop.listTabs()
        inbox.outcome = .noAnswer
        window[kAXTitleAttribute] = "Inbox (3) - Gmail"

        var result = try await rig.desktop.selectTab(tabs[0])
        XCTAssertEqual("Switched tab.", result.message)
        XCTAssertTrue(result.success)

        window[kAXTitleAttribute] = "News - Example"
        result = try await rig.desktop.selectTab(tabs[0])
        XCTAssertEqual(.fail("The tab didn't change. Click it once, or try “next tab”."), result)
        XCTAssertTrue(rig.pointer.clicks.isEmpty)
    }

    /// A tab in a window behind: the window comes to the front first.
    func testBringsTheTabsWindowForwardFirst() async throws {
        let rig = Rig()
        let window = chrome(rig, number: 90, title: "Inbox - Gmail", tabs: [tab("Inbox - Gmail", x: 10)])
        rig.workspace.windowOrder = [90]
        let tabs = try await rig.desktop.listTabs()
        let app = try XCTUnwrap(rig.ax.apps[9])
        rig.front()
        rig.ax.onSet = { element, attribute, _ in
            if attribute == kAXFrontmostAttribute, element === app {
                rig.ax.focus(app, window: window)
            }
        }

        let result = try await rig.desktop.selectTab(tabs[0])
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual([9], rig.workspace.activated)
    }

    // MARK: Safari

    /// Safari's tabs from AppleScript, with its window matched by number; without buttons in Accessibility, no place.
    func testListsSafarisTabsThroughAppleScript() async throws {
        let rig = Rig()
        safari(rig)
        let tabs = try await rig.desktop.listTabs()
        let front = try XCTUnwrap(rig.desktop.foregroundWindow())
        XCTAssertEqual(["Lab Videos - YouTube", "Nav Lab"], tabs.map(\.title))
        XCTAssertEqual([1, 2], tabs.map(\.index))
        XCTAssertEqual([false, true], tabs.map(\.isSelected))
        XCTAssertTrue(tabs.allSatisfy { $0.window.sameWindow(front) && $0.rect.isEmpty })
        XCTAssertEqual([false], rig.scripts.asked)
        XCTAssertEqual(1, rig.scripts.ran.count)
        XCTAssertTrue(rig.scripts.ran[0].source.contains("tell application id \"com.apple.Safari\""))
        XCTAssertEqual(0, rig.ax.apps[7]?.changes.count)
    }

    /// A tab's place is its tab bar button's when Accessibility shows as many.
    func testSafarisTabsTakeTheirButtonsPlaces() async throws {
        let rig = Rig()
        safari(rig, buttons: [tab("Lab Videos", x: 10, pid: 7), tab("Nav Lab", x: 220, pid: 7)])
        let tabs = try await rig.desktop.listTabs()
        XCTAssertEqual([10, 220], tabs.map(\.rect.x))
    }

    /// AppleScript's window is matched by title when its id isn't the window's number.
    func testMatchesSafarisWindowsByTitle() async throws {
        let rig = Rig()
        safari(rig)
        let sameTitle = "W\u{1F}5\u{1F}1\u{1F}Nav Lab\u{1E}T\u{1F}Nav Lab\u{1F}file:///lab.html\u{1E}"
        rig.scripts.onRun = { _, _ in .output(sameTitle) }
        var tabs = try await rig.desktop.listTabs()
        XCTAssertEqual(["Nav Lab"], tabs.map(\.title))

        let otherTitle = "W\u{1F}5\u{1F}1\u{1F}Other\u{1E}T\u{1F}Other\u{1F}file:///o.html\u{1E}"
        rig.scripts.onRun = { _, _ in .output(otherTitle) }
        tabs = try await rig.desktop.listTabs()
        XCTAssertTrue(tabs.isEmpty)
    }

    /// The Automation permission is asked for once, off the caller's thread; the tabs come from the next time.
    /// Refused, there are none.
    func testAsksForTheAutomationPermissionFirst() async throws {
        let rig = Rig()
        safari(rig)
        rig.scripts.automationPermission = .notAsked
        var tabs = try await rig.desktop.listTabs()
        XCTAssertTrue(tabs.isEmpty)
        try await waitUntil { rig.log.lines.contains("Automation permission given") }
        XCTAssertEqual([false, true], rig.scripts.asked)
        XCTAssertTrue(rig.log.lines.contains("tab scan: asking for permission to control the browser (Automation)"))
        XCTAssertTrue(rig.scripts.ran.isEmpty)

        tabs = try await rig.desktop.listTabs()
        XCTAssertEqual(2, tabs.count)

        rig.scripts.automationPermission = .denied
        tabs = try await rig.desktop.listTabs()
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertTrue(rig.log.lines.contains("tab scan: not allowed to control the browser (Automation)"))
        XCTAssertEqual([false, true, false, false], rig.scripts.asked)
    }

    /// A Safari tab is made the current tab through AppleScript, found by its address, and the title is checked.
    func testSelectsASafariTab() async throws {
        let rig = Rig()
        let window = safari(rig)
        let tabs = try await rig.desktop.listTabs()
        rig.scripts.onRun = { source, _ in
            guard source.contains("set current tab") else { return .failed(nil) }
            window[kAXTitleAttribute] = "Lab Videos - YouTube"
            return .output("ok")
        }

        var result = try await rig.desktop.selectTab(tabs[0])
        XCTAssertEqual("Switched tab.", result.message)
        XCTAssertEqual(
            ["70", "1", "file:///lab/videos.html", "Lab Videos - YouTube"], rig.scripts.ran.last?.arguments)

        rig.scripts.onRun = { _, _ in .output("changed") }
        result = try await rig.desktop.selectTab(tabs[1])
        XCTAssertEqual(.fail("I couldn't switch to that tab (that changed on screen)."), result)

        rig.scripts.onRun = { _, _ in .failed(-1743) }
        result = try await rig.desktop.selectTab(tabs[1])
        XCTAssertEqual(.fail("I couldn't switch to that tab (it needs the Automation permission)."), result)
    }

    /// What the list script prints: a line per window and per tab, its fields parted by control characters.
    func testReadsTheListScriptsOutput() {
        let text = "junk\u{1E}T\u{1F}orphan\u{1F}x\u{1E}W\u{1F}1\u{1F}1\u{1F}A\u{1F}B\u{1E}T\u{1F}t\u{1F}u\u{1E}"
            + "W\u{1F}x\u{1F}1\u{1F}bad\u{1E}\n"
        XCTAssertEqual(
            [
                MacDesktop.ScriptedWindow(
                    id: 1, title: "A\u{1F}B", current: 1, tabs: [MacDesktop.ScriptedPage(title: "t", url: "u")]),
            ],
            MacDesktop.parseWindows(text))
        XCTAssertTrue(MacDesktop.isBundleIdentifier("com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(MacDesktop.isBundleIdentifier("com.apple.Safari\" to do shell script \"x"))
        XCTAssertFalse(MacDesktop.isBundleIdentifier(""))
        let refused = "0:12: execution error: Not authorized to send Apple events to Safari. (-1743)\n"
        XCTAssertEqual(-1743, SystemScripts.errorNumber(refused))
        XCTAssertNil(SystemScripts.errorNumber("oops"))
    }
}
