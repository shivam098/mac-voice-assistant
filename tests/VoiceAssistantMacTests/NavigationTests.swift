import ApplicationServices
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// Navigation on fake apps (C#'s `WindowsDesktop.Navigation`): what a scan lists and where, clicking, and choosing a
/// text box.
final class NavigationTests: XCTestCase {
    private func make(
        _ role: String, _ name: String? = nil, subrole: String? = nil, x: Double = 10, y: Double = 10,
        width: Double = 100, height: Double = 30
    ) -> FakeElement {
        FakeElement(role: role, subrole: subrole, title: name, frame: CGRect(x: x, y: y, width: width, height: height))
    }

    private func text(_ value: String, x: Double = 10, y: Double = 10) -> FakeElement {
        let text = make(kAXStaticTextRole, x: x, y: y)
        text[kAXValueAttribute] = value
        return text
    }

    /// TextEdit's window in front holding `children`, as the core knows it.
    private func front(_ rig: Rig, _ children: [FakeElement]) throws -> WindowInfo {
        let window = rig.front()
        window.children = children
        return try XCTUnwrap(rig.desktop.foregroundWindow())
    }

    // MARK: Scans

    /// Buttons, links, tabs, radio buttons, checkboxes, pop-up buttons, menu items and an outline's rows, enabled,
    /// named and in the window; a row named by its first cell.
    func testListsWhatCanBeClicked() async throws {
        let rig = Rig()
        let strip = make(kAXTabGroupRole, x: 0, y: 0, width: 1000, height: 40)
        strip.children = [make(kAXRadioButtonRole, "Inbox", x: 10, y: 5)]
        let link = make(AXName.link, y: 90)
        link[kAXDescriptionAttribute] = "Library"
        let disabled = make(kAXButtonRole, "Delete", y: 130)
        disabled[kAXEnabledAttribute] = false
        let group = make(kAXGroupRole, x: 0, y: 40, width: 1000, height: 300)
        group.children = [
            make(kAXButtonRole, "New", y: 50), link, make(kAXRadioButtonRole, "Large", y: 170),
            make(kAXCheckBoxRole, "Bold", y: 210), make(kAXPopUpButtonRole, "Font", y: 250),
            make(kAXMenuItemRole, "Copy", y: 290), disabled, make(kAXButtonRole, y: 330),
            make(kAXButtonRole, "Far", x: 2000),
        ]
        let row = make(kAXRowRole, subrole: kAXOutlineRowSubrole, x: 0, y: 400, width: 200, height: 20)
        let cell = make(kAXCellRole, x: 0, y: 400, width: 200, height: 20)
        let date = make(kAXCellRole, x: 200, y: 400, width: 100, height: 20)
        cell.children = [make(kAXImageRole), text("Documents", y: 400)]
        date.children = [text("Today", x: 200, y: 400)]
        row.children = [cell, date]
        let outline = make(kAXOutlineRole, x: 0, y: 400, width: 300, height: 300)
        outline.children = [row]
        let window = try front(rig, [strip, group, outline])

        let found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(["Inbox", "New", "Library", "Large", "Bold", "Font", "Copy", "Documents"], found.map(\.name))
        let roles: [ElementRole] = [.tab, .button, .link, .radioButton, .checkBox, .comboBox, .menuItem, .treeItem]
        XCTAssertEqual(roles, found.map(\.role))
        XCTAssertEqual(ScreenRect(x: 10, y: 50, width: 100, height: 30), found[1].rect)
        XCTAssertEqual(Array(1...8), found.map(\.id))
        XCTAssertEqual(["clickable scan: 8 of 9 in 0 ms"], rig.log.lines)
    }

    /// Only what shows: inside the scroll areas around it, not in a row or a scroll area out of view, and only a
    /// table's visible rows when it says which.
    func testListsOnlyWhatShows() async throws {
        let rig = Rig()
        let scroll = make(kAXScrollAreaRole, x: 0, y: 100, width: 500, height: 200)
        let hiddenRow = make(kAXRowRole, x: 0, y: 900, width: 500, height: 20)
        hiddenRow.children = [make(kAXButtonRole, "In a hidden row", y: 150)]
        let shownRow = make(kAXRowRole, subrole: kAXTableRowSubrole, x: 0, y: 120, width: 500, height: 20)
        shownRow.children = [text("Report", y: 120)]
        let table = make(kAXTableRole, x: 0, y: 100, width: 500, height: 2000)
        table.children = [shownRow, hiddenRow]
        scroll.children = [make(kAXButtonRole, "Seen", y: 150), make(kAXButtonRole, "Scrolled away", y: 400), table]
        let away = make(kAXScrollAreaRole, x: 0, y: 900, width: 500, height: 200)
        away.children = [make(kAXButtonRole, "Below the window", y: 150)]
        let otherRow = make(kAXRowRole, x: 0, y: 140, width: 500, height: 20)
        otherRow.children = [text("Not visible", y: 140)]
        let rows = make(kAXOutlineRole, x: 500, y: 100, width: 400, height: 200)
        let visibleRow = make(kAXRowRole, subrole: kAXOutlineRowSubrole, x: 500, y: 100, width: 400, height: 20)
        visibleRow.children = [text("Visible", x: 500, y: 100)]
        rows.children = [visibleRow, otherRow]
        rows[kAXVisibleRowsAttribute] = [visibleRow]
        let window = try front(rig, [scroll, away, rows])

        let found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(["Seen", "Visible", "Report"], found.map(\.name))
        let roles: [ElementRole] = [.button, .treeItem, .listItem]
        XCTAssertEqual(roles, found.map(\.role))
    }

    /// In a web page a row is named by all its text, as Chromium names WhatsApp's chat rows, and its cells count too;
    /// a Mac app's table cells don't.
    func testWebRowsAndCells() async throws {
        let rig = Rig()
        let name = make(kAXCellRole, x: 0, y: 120, width: 600, height: 30)
        name.children = [text("Family", y: 120)]
        let row = make(kAXRowRole, x: 0, y: 120, width: 600, height: 60)
        row.children = [name, text("11:25 am", x: 230, y: 120), text("Papa: a link", y: 150)]
        let grid = make(kAXTableRole, x: 0, y: 100, width: 600, height: 400)
        grid.children = [row]
        let page = make(AXName.webArea, x: 0, y: 80, width: 1000, height: 700)
        page.children = [grid]
        let nativeCell = make(kAXCellRole, x: 0, y: 10, width: 100, height: 20)
        nativeCell.children = [text("Name")]
        let window = try front(rig, [page, nativeCell])

        let found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(["Family 11:25 am Papa: a link", "Family"], found.map(\.name))
        let roles: [ElementRole] = [.listItem, .listItem]
        XCTAssertEqual(roles, found.map(\.role))
    }

    /// At most 1,500 elements (C#'s `MaxElements`).
    func testListsAtMost1500() async throws {
        let rig = Rig()
        let buttons = (0..<1600).map { make(kAXButtonRole, "Button \($0)", y: Double($0 % 700)) }
        let window = try front(rig, buttons)
        let found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(1500, found.count)
        XCTAssertEqual("Button 1499", found.last?.name)
    }

    /// Text fields, editable text areas and combo boxes, at least 40 points wide, that can take the focus: not
    /// password boxes, read-only ones, disabled ones, or a text area that doesn't take text.
    func testListsTextBoxes() async throws {
        let rig = Rig()
        let readOnly = FakeElement.textField(name: "Read only")
        readOnly.settable[kAXValueAttribute] = false
        let password = FakeElement.textField(name: "Password")
        password[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        let label = FakeElement.textField(name: "Label")
        label.settable[kAXFocusedAttribute] = false
        let off = FakeElement.textField(name: "Off")
        off[kAXEnabledAttribute] = false
        let font = make(kAXComboBoxRole, y: 600, width: 200)
        font[kAXDescriptionAttribute] = "Font"
        font.settable[kAXValueAttribute] = true
        let narrow = FakeElement.textField(name: "Narrow", frame: CGRect(x: 10, y: 50, width: 30, height: 24))
        let window = try front(rig, [
            FakeElement.textField(name: "To"), readOnly, narrow, password, label, FakeElement.textArea(name: "Body"),
            FakeElement.textArea(name: "Log", editable: false), font, off,
        ])

        let boxes = try await rig.desktop.listTextBoxes(window)
        XCTAssertEqual(["To", "Body", "Font"], boxes.map(\.name))
        XCTAssertTrue(boxes.allSatisfy { $0.role == .textBox })
        XCTAssertEqual(["text box scan: 3 of 7 in 0 ms"], rig.log.lines)
    }

    /// The window server's frame, else Accessibility's.
    func testWindowRect() throws {
        let rig = Rig()
        let window = try front(rig, [])
        XCTAssertEqual(ScreenRect(x: 0, y: 0, width: 1000, height: 800), rig.desktop.windowRect(window))
        rig.workspace.serverWindows[420] = ServerWindow(
            number: 420, owner: 42, bounds: CGRect(x: 5, y: 6, width: 700, height: 500))
        XCTAssertEqual(ScreenRect(x: 5, y: 6, width: 700, height: 500), rig.desktop.windowRect(window))
    }

    /// Ids from old scans go once there are more than 6,000, those 4,000 older than the newest.
    func testForgetsOldIDs() {
        let registry = ElementRegistry()
        let element = FakeElement()
        for _ in 0..<6001 {
            _ = registry.register(element)
        }

        XCTAssertNil(registry.lookup(2000))
        XCTAssertNotNil(registry.lookup(2001))
        XCTAssertNotNil(registry.lookup(6001))
    }

    // MARK: Waking pages

    /// Chrome's window in front, holding an empty page.
    private func chrome(_ rig: Rig, _ bundleIdentifier: String = "com.google.Chrome") throws
        -> (window: WindowInfo, page: FakeElement) {
        let page = FakeElement(pid: 9, role: AXName.webArea, frame: CGRect(x: 0, y: 80, width: 1000, height: 700))
        let window = FakeElement.window(pid: 9, title: "Nav Lab", number: 90)
        window.children = [page]
        rig.front(9, bundleIdentifier, "Google Chrome", window: window)
        return (try XCTUnwrap(rig.desktop.foregroundWindow()), page)
    }

    /// A Chromium browser's page is described only once it's asked (AXEnhancedUserInterface): the first scan asks, then
    /// waits for the page; later scans don't ask again.
    func testWakesAChromiumBrowserAndWaitsForItsPage() async throws {
        let rig = Rig()
        let (window, page) = try chrome(rig)
        let button = FakeElement(
            pid: 9, role: kAXButtonRole, title: "New", frame: CGRect(x: 10, y: 100, width: 80, height: 30))
        let time = rig.time
        let start = time.now
        rig.ax.onNode = { element in
            if element === page, page.children.isEmpty, time.now >= start + 1 {
                page.children = [button]
            }
        }

        var found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(["New"], found.map(\.name))
        XCTAssertEqual(["AXEnhancedUserInterface=true"], rig.ax.apps[9]?.changes)
        XCTAssertEqual(1, time.now - start, accuracy: 0.001)
        XCTAssertEqual(
            ["page descriptions asked for", "page described 1000 ms after waking", "clickable scan: 1 of 1 in 1000 ms"],
            rig.log.lines)

        found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(["New"], found.map(\.name))
        XCTAssertEqual(["AXEnhancedUserInterface=true"], rig.ax.apps[9]?.changes)
        XCTAssertEqual(1, time.now - start, accuracy: 0.001)
    }

    /// A page that isn't described in time: the scan waits 2.5 s from its start, then reads what's there. A Chrome
    /// channel (its bundle identifier after a dot) is a Chromium browser too.
    func testWaitsAtMostTwoAndAHalfSecondsForAPage() async throws {
        let rig = Rig()
        let (window, _) = try chrome(rig, "com.google.Chrome.canary")
        let start = rig.time.now
        let boxes = try await rig.desktop.listTextBoxes(window)
        XCTAssertTrue(boxes.isEmpty)
        XCTAssertEqual(2.5, rig.time.now - start, accuracy: 0.001)
        XCTAssertTrue(rig.log.lines.contains("page not described 2500 ms after waking"))
    }

    /// Chromium acts on AXEnhancedUserInterface while answering that it has no such attribute: that counts as woken,
    /// and later scans don't ask again (each ask restarts the 2 s it waits before describing its pages). Electron apps
    /// are asked with AXManualAccessibility; one that doesn't answer is asked again next time; Safari and AppKit apps,
    /// which describe their pages anyway, never.
    func testAsksEachAppThatNeedsWakingOnce() async throws {
        let chromeRig = Rig()
        let (window, page) = try chrome(chromeRig)
        let chromeApp = try XCTUnwrap(chromeRig.ax.apps[9])
        chromeApp.outcome = .unsupported
        let button = FakeElement(
            pid: 9, role: kAXButtonRole, title: "New", frame: CGRect(x: 10, y: 100, width: 80, height: 30))
        let time = chromeRig.time
        let start = time.now
        chromeRig.ax.onNode = { element in
            if element === page, page.children.isEmpty, time.now >= start + 2 {
                page.children = [button]
            }
        }

        var found = try await chromeRig.desktop.listClickable(window)
        XCTAssertEqual(["New"], found.map(\.name))
        found = try await chromeRig.desktop.listClickable(window)
        XCTAssertEqual(["New"], found.map(\.name))
        XCTAssertEqual(["AXEnhancedUserInterface=true"], chromeApp.tried)
        XCTAssertEqual(2, time.now - start, accuracy: 0.001)
        XCTAssertEqual(
            ["page descriptions asked for (the app says it has no such setting)", "page described 2000 ms after waking"],
            Array(chromeRig.log.lines.prefix(2)))

        let rig = Rig()
        let slackPage = FakeElement(pid: 11, role: AXName.webArea, frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        slackPage.children = [
            FakeElement(
                pid: 11, role: kAXButtonRole, title: "Huddle", frame: CGRect(x: 10, y: 10, width: 60, height: 20)),
        ]
        rig.front(11, "com.tinyspeck.slackmacgap", "Slack").children = [slackPage]
        rig.workspace.electronApps = [11]
        let app = try XCTUnwrap(rig.ax.apps[11])
        app.outcome = .noAnswer
        let slackWindow = try XCTUnwrap(rig.desktop.foregroundWindow())

        _ = try await rig.desktop.listClickable(slackWindow)
        _ = try await rig.desktop.listClickable(slackWindow)
        let unanswered = "page descriptions not asked for: the app didn't answer (noAnswer)"
        XCTAssertEqual(1, rig.log.lines.filter { $0 == unanswered }.count)

        app.outcome = .done
        let huddle = try await rig.desktop.listClickable(slackWindow)
        XCTAssertEqual(["Huddle"], huddle.map(\.name))
        _ = try await rig.desktop.listClickable(slackWindow)
        XCTAssertEqual(Array(repeating: "AXManualAccessibility=true", count: 3), app.tried)
        XCTAssertEqual(["AXManualAccessibility=true"], app.changes)

        let safari = Rig()
        safari.front(7, "com.apple.Safari", "Safari").children = [
            FakeElement(pid: 7, role: AXName.webArea, frame: CGRect(x: 0, y: 0, width: 900, height: 700)),
        ]
        _ = try await safari.desktop.listClickable(try XCTUnwrap(safari.desktop.foregroundWindow()))
        XCTAssertEqual(0, safari.ax.apps[7]?.tried.count)
        XCTAssertFalse(safari.log.lines.contains { $0.hasPrefix("page") })
    }

    // MARK: Clicking

    func testPressesWhatItClicks() async throws {
        let rig = Rig()
        let new = make(kAXButtonRole, "New", y: 50)
        new.actionNames = [kAXPressAction]
        let window = try front(rig, [new])
        let found = try await rig.desktop.listClickable(window)
        let button = try XCTUnwrap(found.first)

        let result = try await rig.desktop.click(button)
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual([kAXPressAction], new.actions)
        XCTAssertTrue(rig.pointer.clicks.isEmpty)
    }

    /// The confirmed name must still be the element's: a page drawn again mustn't turn "click 7" into a click on
    /// something else.
    func testRefusesWhatChangedOnScreen() async throws {
        let rig = Rig()
        let new = make(kAXButtonRole, "New", y: 50)
        new.actionNames = [kAXPressAction]
        let window = try front(rig, [new])
        let list = try await rig.desktop.listClickable(window)
        let found = try XCTUnwrap(list.first)

        new[kAXTitleAttribute] = "Delete account"
        var result = try await rig.desktop.click(found)
        XCTAssertEqual(.fail("I couldn't click that (that changed on screen)."), result)
        XCTAssertTrue(new.actions.isEmpty)

        result = try await rig.desktop.click(UiElement(id: 999, name: "New", role: .button, rect: found.rect))
        XCTAssertEqual(.fail("That changed on screen. Try again."), result)

        new[kAXTitleAttribute] = "New"
        new.outcome = .gone
        result = try await rig.desktop.click(found)
        XCTAssertEqual(.fail("I couldn't click that (that changed on screen)."), result)
        XCTAssertTrue(rig.pointer.clicks.isEmpty)
    }

    /// A row is selected (when a real click wouldn't land on it), a tab selected rather than pressed, a disclosure
    /// triangle opened, as the C# selects, toggles and expands.
    func testSelectsRowsAndTabsAndOpensDisclosures() async throws {
        let rig = Rig()
        let row = make(kAXRowRole, x: 0, y: 100, width: 300, height: 20)
        row.children = [text("Alpha.txt", y: 100)]
        row.settable[kAXSelectedAttribute] = true
        let strip = make(kAXTabGroupRole, x: 0, y: 0, width: 1000, height: 40)
        let tab = make(kAXRadioButtonRole, "Inbox", y: 5)
        tab.actionNames = [kAXPressAction]
        tab.settable[kAXSelectedAttribute] = true
        strip.children = [tab]
        let triangle = make(kAXDisclosureTriangleRole, "Details", y: 200)
        triangle.settable[kAXDisclosingAttribute] = true
        triangle[kAXDisclosingAttribute] = false
        let window = try front(rig, [strip, row, triangle])
        let found = try await rig.desktop.listClickable(window)
        XCTAssertEqual(["Alpha.txt", "Details", "Inbox"], found.map(\.name))

        for element in found {
            let result = try await rig.desktop.click(element)
            XCTAssertEqual(.ok("Clicked."), result, element.name)
        }

        XCTAssertEqual(["AXSelected=true"], tab.changes)
        XCTAssertTrue(tab.actions.isEmpty)
        XCTAssertEqual(["AXSelected=true"], row.changes)
        XCTAssertEqual(["AXDisclosing=true"], triangle.changes)
        XCTAssertTrue(rig.pointer.clicks.isEmpty)
    }

    /// With no way through Accessibility, or when it's refused, a real click on the centre once modifier keys are let
    /// go, only where it lands in the window: past this app's own panels, or on a sheet of the window.
    func testClicksForRealOnlyWhereItLandsInTheWindow() async throws {
        let rig = Rig()
        let box = make(kAXCheckBoxRole, "Bold", x: 100, y: 200, width: 40, height: 20)
        let refused = make(kAXButtonRole, "Save", x: 300, y: 200, width: 60, height: 20)
        refused.actionNames = [kAXPressAction]
        let sheet = make(kAXSheetRole, x: 0, y: 0, width: 400, height: 300)
        sheet.windowNumber = 430
        let window = try front(rig, [box, refused, sheet])
        let found = try await rig.desktop.listClickable(window)
        rig.log.clear()

        rig.pointer.windowsAtPoint = [420]
        rig.keys.held = [.command]
        var result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual([CGPoint(x: 120, y: 210)], rig.pointer.clicks)
        XCTAssertTrue(rig.keys.held.isEmpty)

        refused.outcome = .unsupported
        result = try await rig.desktop.click(found[1])
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual(CGPoint(x: 330, y: 210), rig.pointer.clicks.last)
        XCTAssertEqual(["accessibility action failed, clicking instead"], rig.log.lines)

        rig.workspace.serverWindows[999] = ServerWindow(number: 999, owner: 77, bounds: .zero)
        rig.pointer.windowsAtPoint = [999, 420]
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.fail("I couldn't click that (something else is on top of it)."), result)
        XCTAssertEqual(2, rig.pointer.clicks.count)
        XCTAssertEqual("click point is not in the target window: another app's window there", rig.log.lines.last)

        rig.workspace.serverWindows[421] = ServerWindow(number: 421, owner: 42, bounds: .zero)
        rig.pointer.windowsAtPoint = [421, 420]
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual("click point is not in the target window: another window of its app there", rig.log.lines.last)
        rig.pointer.windowsAtPoint = []
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual("click point is not in the target window: no window there", rig.log.lines.last)
        XCTAssertEqual(2, rig.pointer.clicks.count)

        rig.workspace.serverWindows[500] = ServerWindow(number: 500, owner: Rig.own, bounds: .zero)
        rig.pointer.windowsAtPoint = [500, 420]
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.ok("Clicked."), result)

        rig.pointer.windowsAtPoint = [430]
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual(4, rig.pointer.clicks.count)

        rig.permissions.mayPost = false
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.fail("I couldn't click that (it needs the Accessibility permission)."), result)
        XCTAssertEqual(4, rig.pointer.clicks.count)
    }

    /// A web grid's row (a chat list's) opens only on a real click: scrolled into view, then clicked on its centre when
    /// that's the row or inside it (the time drawn over it), never when something else is there.
    func testClicksAWebGridRowForReal() async throws {
        let rig = Rig()
        let time = text("11:25 am", x: 230, y: 130)
        let row = make(kAXRowRole, x: 0, y: 120, width: 600, height: 60)
        row.actionNames = [kAXPressAction, AXName.scrollToVisible]
        row.children = [text("Family", y: 125), time]
        let grid = make(kAXTableRole, x: 0, y: 100, width: 600, height: 400)
        grid.children = [row]
        let page = make(AXName.webArea, x: 0, y: 80, width: 1000, height: 700)
        let search = FakeElement.textField(name: "Search", frame: CGRect(x: 0, y: 80, width: 600, height: 20))
        page.children = [search, grid]
        let window = try front(rig, [page])
        let found = try await rig.desktop.listClickable(window)
        let chat = try XCTUnwrap(found.first { $0.name.hasPrefix("Family") })

        rig.pointer.windowsAtPoint = [420]
        rig.ax.hit = time
        var result = try await rig.desktop.click(chat)
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual([AXName.scrollToVisible], row.actions)
        XCTAssertEqual([CGPoint(x: 300, y: 150)], rig.pointer.clicks)
        XCTAssertEqual([CGPoint(x: 300, y: 150)], rig.ax.pointsHit)

        rig.ax.hit = search
        result = try await rig.desktop.click(chat)
        XCTAssertEqual(.fail("I couldn't click that (something else is on top of it)."), result)
        XCTAssertEqual(1, rig.pointer.clicks.count)
        XCTAssertEqual("grid item centre is covered by something else", rig.log.lines.last)
    }

    /// An app's table or outline row is clicked for real when the click lands on it (Finder's sidebar goes to the
    /// folder only then), and selected through Accessibility when something else is at its centre.
    func testClicksAnAppsRowForRealWhenTheClickLandsOnIt() async throws {
        let rig = Rig()
        let name = text("Applications", y: 100)
        let row = make(kAXRowRole, subrole: kAXOutlineRowSubrole, x: 0, y: 100, width: 200, height: 20)
        row.children = [name]
        row.settable[kAXSelectedAttribute] = true
        let outline = make(kAXOutlineRole, x: 0, y: 90, width: 200, height: 400)
        outline.children = [row]
        let window = try front(rig, [outline])
        let found = try await rig.desktop.listClickable(window)
        let applications = try XCTUnwrap(found.first)
        XCTAssertEqual(.treeItem, applications.role)

        rig.pointer.windowsAtPoint = [420]
        rig.ax.hit = name
        var result = try await rig.desktop.click(applications)
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual([CGPoint(x: 100, y: 110)], rig.pointer.clicks)
        XCTAssertTrue(row.changes.isEmpty)

        rig.ax.hit = outline
        result = try await rig.desktop.click(applications)
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual(1, rig.pointer.clicks.count)
        XCTAssertEqual(["AXSelected=true"], row.changes)
    }

    /// Accessibility's system-wide hit test says where a click lands, as the window server routes clicks: past the
    /// Dock's window that spans the screen (the front-most in the window server's list), never into another app's
    /// element or another window of the app.
    func testAccessibilitySaysWhereAClickLands() async throws {
        let rig = Rig()
        let box = make(kAXCheckBoxRole, "Bold", x: 100, y: 200, width: 40, height: 20)
        let window = try front(rig, [box])
        let found = try await rig.desktop.listClickable(window)
        rig.workspace.run(30, MacDesktop.dockIdentifier, "Dock")
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        rig.workspace.serverWindows[107] = ServerWindow(number: 107, owner: 30, bounds: screen)
        rig.pointer.windowsAtPoint = [107, 420]

        rig.ax.screenHit = box
        var result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual([CGPoint(x: 120, y: 210)], rig.pointer.clicks)

        rig.ax.screenHit = FakeElement(pid: 77, role: kAXButtonRole)
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.fail("I couldn't click that (something else is on top of it)."), result)
        XCTAssertEqual("click point is not in the target window: another app's window there", rig.log.lines.last)

        let other = FakeElement.window(number: 421)
        let inOther = make(kAXButtonRole, "Other")
        other.children = [inOther]
        rig.ax.screenHit = inOther
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual("click point is not in the target window: another window of its app there", rig.log.lines.last)
        XCTAssertEqual(1, rig.pointer.clicks.count)
    }

    /// When Accessibility can't say, the window server's list does: the Dock's window that spans the screen lets a
    /// click through away from the Dock's icons, not on them, nor when the Dock doesn't say where they are.
    func testTheDocksWindowLetsClicksThroughAwayFromItsIcons() async throws {
        let rig = Rig()
        let box = make(kAXCheckBoxRole, "Bold", x: 100, y: 200, width: 40, height: 20)
        let window = try front(rig, [box])
        let found = try await rig.desktop.listClickable(window)
        rig.workspace.run(30, MacDesktop.dockIdentifier, "Dock")
        let icons = FakeElement(pid: 30, role: kAXListRole, frame: CGRect(x: 200, y: 700, width: 600, height: 68))
        let dock = FakeElement.app(pid: 30)
        dock.children = [icons]
        rig.ax.apps[30] = dock
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        rig.workspace.serverWindows[107] = ServerWindow(number: 107, owner: 30, bounds: screen)
        rig.pointer.windowsAtPoint = [107, 420]

        var result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.ok("Clicked."), result)
        XCTAssertEqual([CGPoint(x: 120, y: 210)], rig.pointer.clicks)

        icons.frame = CGRect(x: 0, y: 150, width: 600, height: 100)
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.fail("I couldn't click that (something else is on top of it)."), result)
        icons.frame = nil
        result = try await rig.desktop.click(found[0])
        XCTAssertEqual(.fail("I couldn't click that (something else is on top of it)."), result)
        XCTAssertEqual(1, rig.pointer.clicks.count)
    }

    /// Where a click lands comes from the window server's list: a window whose frame holds the point and that shows,
    /// not a fully transparent one or a passing visual (a dragged image, the pointer).
    func testWhichWindowsTakeAClick() {
        func window(layer: Int = 0, alpha: Double = 1) -> [String: Any] {
            let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
            return [
                kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: frame.dictionaryRepresentation,
            ]
        }

        let inside = CGPoint(x: 150, y: 150)
        XCTAssertTrue(SystemPointer.takesClick(window(), at: inside))
        XCTAssertTrue(SystemPointer.takesClick(window(layer: 25), at: inside))
        XCTAssertFalse(SystemPointer.takesClick(window(), at: CGPoint(x: 50, y: 150)))
        XCTAssertFalse(SystemPointer.takesClick(window(alpha: 0), at: inside))
        XCTAssertFalse(SystemPointer.takesClick(window(layer: SystemPointer.passingLevel), at: inside))
    }

    // MARK: Choosing a text box

    func testFocusesABox() async throws {
        let rig = Rig()
        let box = FakeElement.textField(name: "Message")
        box.holds("Hi")
        let window = try front(rig, [box])
        let boxes = try await rig.desktop.listTextBoxes(window)
        let found = try XCTUnwrap(boxes.first)

        let result = try await rig.desktop.focusTextBox(found)
        XCTAssertEqual(
            TextTargetResult(success: true, message: "", hasTrailingText: true, focusIsEditable: true), result)
        XCTAssertTrue(rig.ax.focused === box)
        XCTAssertTrue(rig.pointer.clicks.isEmpty)
    }

    /// A box that ignores the focus set through Accessibility (some web boxes) is clicked for real, once.
    func testClicksABoxThatIgnoresTheFocus() async throws {
        let rig = Rig()
        let box = FakeElement.textField(name: "Message")
        box.takesFocus = false
        let window = try front(rig, [box])
        let boxes = try await rig.desktop.listTextBoxes(window)
        let found = try XCTUnwrap(boxes.first)
        rig.pointer.windowsAtPoint = [420]

        let missed = "I couldn't put the cursor in that box. Click it once, then say “start typing”."
        var result = try await rig.desktop.focusTextBox(found)
        XCTAssertEqual(TextTargetResult(success: false, message: missed), result)
        XCTAssertEqual([CGPoint(x: 160, y: 22)], rig.pointer.clicks)

        rig.pointer.onClick = { _ in rig.ax.focused = box }
        result = try await rig.desktop.focusTextBox(found)
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(2, rig.pointer.clicks.count)

        // The focus lands in a password box inside it.
        let secret = FakeElement.textField(name: "PIN", frame: CGRect(x: 100, y: 12, width: 40, height: 20))
        secret[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        rig.ax.focused = nil
        rig.pointer.onClick = { _ in rig.ax.focused = secret }
        result = try await rig.desktop.focusTextBox(found)
        XCTAssertEqual("That's a password field — I won't type there.", result.message)
        XCTAssertFalse(result.success)
        XCTAssertEqual(3, rig.pointer.clicks.count)
    }

    func testABoxThatChanged() async throws {
        let rig = Rig()
        let box = FakeElement.textField(name: "Message")
        let window = try front(rig, [box])
        let boxes = try await rig.desktop.listTextBoxes(window)
        let found = try XCTUnwrap(boxes.first)
        var unknown = found
        unknown.id = 999
        let changed = TextTargetResult(success: false, message: "That text box changed. Try again.")
        var result = try await rig.desktop.focusTextBox(unknown)
        XCTAssertEqual(changed, result)

        box.outcome = .gone
        result = try await rig.desktop.focusTextBox(found)
        XCTAssertEqual(changed, result)
    }
}
