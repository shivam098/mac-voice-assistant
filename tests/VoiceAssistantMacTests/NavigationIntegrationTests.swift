import AppKit
import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// Navigation through the real Accessibility API, CGEvent and AppleScript: the NavigationLab pages (copied from
/// windows-voice-assistant tests/NavigationLab) in Chrome, Edge and Safari, and Finder, TextEdit and System Settings.
/// Scans, clicks, text boxes, tabs, the overlay panel and the core's place, as the core asks for them ("click New on the
/// left" resolved by the core's `TargetResolver`). They run with VOICE_ASSISTANT_NAVIGATION_TESTS=1 (CI's step of their
/// own) or VOICE_ASSISTANT_AX_TESTS=1: Chrome and Edge run with profiles of their own and quit; Safari and System
/// Settings quit only when they weren't running, else only what was opened closes; TextEdit quits, its settings put
/// back. Lines starting "AX test:" say what was found: counts, the lab pages' and Apple's own controls' names, outcomes
/// and timings.
final class NavigationIntegrationTests: XCTestCase {
    private var desktop: MacDesktop!

    override func setUp() async throws {
        try await super.setUp()
        try Integration.skipUnlessNavigationAllowed()
        Integration.report("starting \(name); windows on screen: \(Integration.screenWindows())")
        desktop = MacDesktop(
            scripts: UnaskingScripts(), insertMethod: { "Type" }, log: { Integration.report("desktop: \($0)") })
    }

    // MARK: The lab pages in Chrome

    /// The tab strip, switching tabs, "click" by name and side, a chat row that opens only on a real click (with the
    /// badges over it), and text boxes, in the lab pages in Chrome, started by Launch Services with a profile of its
    /// own. Nothing else wakes Chrome here: the desktop asks it to describe its pages itself (AXEnhancedUserInterface)
    /// at its first scan, and Chrome does 2 s later.
    func testNavigatesTheLabPagesInChrome() async throws {
        let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: chromeApp.path), "Chrome isn't installed.")
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-assistant-chrome-\(UUID().uuidString)")
        let pages: [String] = ["videos", "lab", "mail", "chats"].map { Integration.page($0).absoluteString }
        let arguments: [String] = [
            "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
            "--hide-crash-restore-bubble", "--use-mock-keychain", "--new-window",
        ]
        Integration.report("starting Chrome")
        let launched = try await Integration.launch(chromeApp, arguments: arguments + pages, newInstance: true)
        let chrome = try XCTUnwrap(launched, "Chrome didn't start")
        defer {
            Integration.stop(chrome)
            try? FileManager.default.removeItem(at: profile)
        }

        Integration.report("Chrome started")
        let running = try XCTUnwrap(SystemWorkspace().app(chrome.processIdentifier))
        let appeared = try await Integration.waitUntil(30) {
            desktop.windows(of: running).contains { $0.info.title.contains("Lab") }
        }
        Integration.report("Chrome's windows: \(desktop.windows(of: running).map { $0.info.title })")
        XCTAssertTrue(appeared, "Chrome's window")
        // While Chrome starts it answers Accessibility slowly, and no app seems to have the keys until it does.
        let settled = try await Integration.waitUntil(20) {
            desktop.foregroundWindow()?.processName == "com.google.Chrome"
        }
        Integration.report("Chrome has the keys: \(settled) (\(Integration.keys(desktop)))")
        let entry = AppEntry(name: "Google Chrome", launch: "com.google.Chrome", processNames: ["com.google.Chrome"])
        let window = try await open(entry)
        let element = try XCTUnwrap(desktop.windowElement(window))
        let strip = desktop.tabItems(element, WorkToken()).count
        let described = desktop.hasPage(element, WorkToken())
        Integration.report("Chrome before waking: \(strip) tabs in its strip, page described: \(described)")

        var tabs: [BrowserTab] = []
        let started = Date()
        try await Integration.waitUntil(10) {
            tabs = try await desktop.listTabs()
            return tabs.count == 4
        }
        let waited = Integration.seconds(since: started)
        Integration.report("Chrome's tabs after \(waited) s: \(Integration.describe(tabs))")
        if tabs.count != 4 {
            Integration.dump(desktop, element)
        }

        XCTAssertEqual(
            ["Lab Videos - YouTube", "Nav Lab", "Lab Inbox - Mail", "Lab Chats"],
            tabs.map { NameMatcher.cleanTabTitle($0.title) })
        XCTAssertEqual(1, tabs.filter(\.isSelected).count)
        XCTAssertEqual("Google Chrome", desktop.appName(window))

        try await check(lab: show(tabs, "Nav Lab"), browser: "Chrome")
        try await check(chats: show(tabs, "Lab Chats"), browser: "Chrome", withBadges: true)
        try await check(mail: show(tabs, "Lab Inbox"), browser: "Chrome")

        // A tab of a browser behind another app: the browser comes to the front first.
        _ = try await Integration.launch(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        let behind = try await Integration.waitUntil(5) {
            desktop.foregroundWindow()?.processName == "com.apple.finder"
        }
        Integration.report("Finder in front before going back to Chrome: \(behind)")
        let back = try await show(tabs, "Lab Videos")
        XCTAssertTrue(back.sameWindow(desktop.foregroundWindow()), "Chrome in front: \(Integration.keys(desktop))")

        try await checkPlace()
    }

    /// The core's place, the pill's "📍" breadcrumb, from the Mac's app names and window titles: the real controller
    /// over this desktop switches to the lab page's tab, clicks in it, and starts typing in its Message box.
    private func checkPlace() async throws {
        let chrome = AppEntry(
            name: "Google Chrome", launch: "com.google.Chrome", processNames: ["com.google.Chrome"],
            searchKeys: "Cmd+L", addressBarKeys: "Cmd+L")
        let options = ControllerOptions(wakeWordEnabled: false)
        let controller = InteractionController(desktop, AppCatalog([chrome]), CommandParser(keys: .mac), options: options)
        var places: [String] = []
        controller.onStatus = { status in
            if let place = status.place {
                places.append(place)
            }
        }

        controller.setListening(true)
        try await controller.handleTranscript("go to the second tab", 0.9)
        let tab = controller.place ?? ""
        XCTAssertTrue(tab.hasPrefix("Google Chrome › Nav Lab"), tab)
        try await controller.handleTranscript("click pull requests", 0.9)
        XCTAssertEqual("Google Chrome", controller.place)
        try await controller.handleTranscript("start typing in the message box", 0.9)
        let typing = controller.place ?? ""
        XCTAssertTrue(typing.hasPrefix("Google Chrome › Nav Lab"), typing)
        XCTAssertTrue(typing.hasSuffix(" › Message"), typing)
        Integration.report("the places the pill showed: \(places)")
    }

    // MARK: The lab pages in Edge

    /// Edge, another Chromium browser: its tab strip, a tab switch, and a click in a page the desktop woke.
    func testNavigatesTheLabPagesInEdge() async throws {
        let edgeApp = URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: edgeApp.path), "Edge isn't installed.")
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-assistant-edge-\(UUID().uuidString)")
        let pages: [String] = ["videos", "lab"].map { Integration.page($0).absoluteString }
        let arguments: [String] = [
            "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check", "--use-mock-keychain",
            "--new-window",
        ]
        Integration.report("starting Edge")
        let launched = try await Integration.launch(edgeApp, arguments: arguments + pages, newInstance: true)
        let edge = try XCTUnwrap(launched, "Edge didn't start")
        defer {
            Integration.stop(edge)
            try? FileManager.default.removeItem(at: profile)
            // Edge's first start can open Microsoft AutoUpdate, whose window would stay over the next tests' apps.
            for updater in ["com.microsoft.autoupdate2", "com.microsoft.autoupdate.fba"] {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: updater) {
                    app.forceTerminate()
                }
            }
        }

        Integration.report("Edge started")
        var tabs: [BrowserTab] = []
        let listed = try await Integration.waitUntil(30) {
            tabs = try await desktop.listTabs().filter { $0.window.processName == "com.microsoft.edgemac" }
            return tabs.contains { NameMatcher.cleanTabTitle($0.title).hasPrefix("Nav Lab") }
        }
        Integration.report("Edge's tabs: \(Integration.describe(tabs))")
        XCTAssertTrue(listed, "Edge's tabs")

        let window = try await show(tabs, "Nav Lab")
        let inFront = try await Integration.waitUntil(5) {
            desktop.foregroundWindow()?.processName == "com.microsoft.edgemac"
        }
        XCTAssertTrue(inFront, "Edge has the keys: \(Integration.keys(desktop))")
        let bounds = desktop.windowRect(window)
        var elements: [UiElement] = []
        let started = Date()
        let described = try await Integration.waitUntil(15) {
            elements = try await desktop.listClickable(window)
            return Integration.resolve(elements, "Pull requests", in: bounds) != nil
        }
        let waited = Integration.seconds(since: started)
        Integration.report("Edge's lab page after \(waited) s: \(Integration.roles(elements))")
        XCTAssertTrue(described, "Edge described the lab page")
        let pull = try XCTUnwrap(Integration.resolve(elements, "Pull requests", in: bounds), "Pull requests")
        let clicked = try await desktop.click(pull)
        XCTAssertTrue(clicked.success, clicked.message)
        let changed = try await Integration.waitUntil(3) {
            desktop.windowTitle(window).contains("clicked Pull requests left")
        }
        XCTAssertTrue(changed, "Edge: clicked Pull requests (title \(desktop.windowTitle(window)))")
    }

    // MARK: The lab pages in Safari

    /// The same in Safari, whose tabs come from AppleScript. A test can't answer macOS's Automation prompt, so the
    /// AppleScript part runs only where this process may control Safari already; elsewhere each lab page is opened by
    /// Launch Services and checked in Safari's front window, and Safari's tab bar is reported. The pages come over
    /// HTTP from the test itself (`LabServer`): Safari asks before it loads a file that AppleScript opens.
    func testNavigatesTheLabPagesInSafari() async throws {
        let bundle = "com.apple.Safari"
        let safariApp = URL(fileURLWithPath: "/Applications/Safari.app")
        let wasRunning = Integration.isRunning(bundle)
        Integration.report("starting Safari")
        let launched = try await Integration.launch(safariApp)
        XCTAssertNotNil(launched, "Safari didn't start")
        let permission: AutomationPermission
        switch Background.wait(5, { SystemScripts().automation(bundle, ask: false) }) {
        case .finished(let answer):
            permission = answer
        case .timedOut:
            permission = .unknown
        }

        Integration.report("Automation of Safari: \(permission); \(Integration.integrityProtection())")
        defer {
            if !wasRunning {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                    app.forceTerminate()
                }
            }
        }

        guard permission == .granted else {
            try await checkSafariWithoutAppleScript(safariApp, closing: wasRunning)
            return
        }

        let server = LabServer()
        defer { server?.stop() }
        Integration.report("the lab pages served on port \(server?.port ?? 0) (0: Safari gets files)")
        let pages: [String] = ["videos", "lab", "mail", "chats"].map { name in
            (server?.url(name) ?? Integration.page(name)).absoluteString
        }
        let opened = Integration.script("""
            tell application id "com.apple.Safari"
                make new document with properties {URL:"\(pages[0])"}
                tell front window
                    make new tab at end of tabs with properties {URL:"\(pages[1])"}
                    make new tab at end of tabs with properties {URL:"\(pages[2])"}
                    make new tab at end of tabs with properties {URL:"\(pages[3])"}
                    set current tab to tab 1
                end tell
                return id of front window
            end tell
            """)
        Integration.report("Safari opened the lab pages: \(opened)")
        guard case .output(let id) = opened else {
            XCTFail("Safari didn't open the pages: \(opened)")
            return
        }

        defer {
            if wasRunning {
                _ = Integration.script("tell application id \"com.apple.Safari\" to close window id \(id)")
            }
        }

        var shown = try await Integration.waitUntil(10) {
            guard let front = desktop.foregroundWindow(), front.processName == bundle else { return false }
            return NameMatcher.cleanTabTitle(front.title).hasPrefix("Lab Videos")
        }
        Integration.report("Safari shows the lab pages' window: \(shown) (\(Integration.keys(desktop)))")
        if !shown && answerSheet() {
            shown = try await Integration.waitUntil(10) {
                NameMatcher.cleanTabTitle(desktop.foregroundWindow()?.title).hasPrefix("Lab Videos")
            }
            Integration.report("Safari shows the lab pages' window now: \(shown) (\(Integration.keys(desktop)))")
        }

        let entry = AppEntry(name: "Safari", launch: bundle, processNames: [bundle])
        let window = try await open(entry)
        Integration.report("Safari's window number \(window.handle), AppleScript's window id \(id)")

        var tabs: [BrowserTab] = []
        try await Integration.waitUntil(15) {
            tabs = try await desktop.listTabs().filter { $0.window.sameWindow(window) }
            return tabs.map { NameMatcher.cleanTabTitle($0.title) }.contains("Lab Chats")
        }
        Integration.report("Safari's tabs: \(Integration.describe(tabs))")
        reportTabBar(window, expecting: tabs.count)

        XCTAssertEqual(
            ["Lab Videos - YouTube", "Nav Lab", "Lab Inbox - Mail", "Lab Chats"],
            tabs.map { NameMatcher.cleanTabTitle($0.title) })

        try await check(lab: show(tabs, "Nav Lab"), browser: "Safari")
        try await check(chats: show(tabs, "Lab Chats"), browser: "Safari", withBadges: false)
        try await check(mail: show(tabs, "Lab Inbox"), browser: "Safari")
    }

    /// Without the Automation permission: each lab page opened by Launch Services and checked in Safari's front window
    /// (closed afterwards with `closing`, else Safari quits); the tab bar as Accessibility shows it.
    private func checkSafariWithoutAppleScript(_ safariApp: URL, closing: Bool) async throws {
        let server = LabServer()
        defer { server?.stop() }
        let lab = try await openInSafari(safariApp, "lab", "Nav Lab", server)
        reportTabBar(lab, expecting: nil)
        try await check(lab: lab, browser: "Safari")
        let chats = try await openInSafari(safariApp, "chats", "Lab Chats", server)
        try await check(chats: chats, browser: "Safari", withBadges: false)
        let mail = try await openInSafari(safariApp, "mail", "Lab Inbox", server)
        try await check(mail: mail, browser: "Safari")
        if closing {
            for window in [lab, chats, mail] {
                close(window)
            }
        }
    }

    /// Opens a lab page in Safari through Launch Services (served by `server`, else the file), and waits for it in
    /// Safari's window in front.
    private func openInSafari(
        _ safariApp: URL, _ page: String, _ title: String, _ server: LabServer?
    ) async throws -> WindowInfo {
        Integration.report("opening the lab's \(page) page in Safari")
        let address: String = server?.url(page).absoluteString ?? Integration.page(page).path
        let opened = Integration.run(["/usr/bin/open", "-a", safariApp.path, address], timeout: 15)
        XCTAssertTrue(opened, "Safari didn't take the \(page) page")
        var front: WindowInfo?
        let shown = try await Integration.waitUntil(15) {
            front = desktop.foregroundWindow()
            guard let window = front, window.processName == "com.apple.Safari" else { return false }
            return NameMatcher.cleanTabTitle(window.title).hasPrefix(title)
        }
        XCTAssertTrue(shown, "Safari shows \(title) (in front: \(Integration.keys(desktop)))")
        return try XCTUnwrap(front)
    }

    /// Safari's tab bar as Accessibility shows it: its tab buttons' names, against the tabs AppleScript lists.
    private func reportTabBar(_ window: WindowInfo, expecting count: Int?) {
        guard let element = desktop.windowElement(window) else { return }
        let buttons = desktop.tabItems(element, WorkToken())
        let names: [String] = buttons.map { $0.name + ($0.selected ? " (shown)" : "") }
        Integration.report("Safari's tab bar in Accessibility: \(buttons.count) tabs \(names)")
        if let count, buttons.count != count {
            Integration.dump(desktop, element)
        }
    }

    /// A sheet that keeps the keys in the window in front (Safari's, on GitHub's runner): what it says and its buttons
    /// are reported, then its Allow, Open, OK or Continue button is pressed, else Esc cancels it. True when there was
    /// one.
    private func answerSheet() -> Bool {
        let ax = desktop.ax
        guard let app = try? ax.focusedApplication(), let sheet = try? ax.element(kAXFocusedWindowAttribute, of: app),
              (try? ax.role(of: sheet)) == kAXSheetRole else { return false }
        var texts: [String] = []
        var buttons: [(name: String, element: AnyObject)] = []
        desktop.scan(sheet, WorkToken()) { element, node, _ in
            if node.role == kAXStaticTextRole, let text = try? ax.string(kAXValueAttribute, of: element) {
                texts.append(text)
            } else if node.role == kAXButtonRole {
                buttons.append((name: node.title ?? node.label ?? "", element: element))
            }

            return texts.count + buttons.count < 40
        }

        let names: [String] = buttons.map { $0.name }
        Integration.report("a sheet keeps the keys: it says \(texts); its buttons \(names)")
        let yes: Set<String> = ["Allow", "Open", "OK", "Continue"]
        if let button = buttons.first(where: { yes.contains($0.name) }) {
            ax.perform(kAXPressAction, on: button.element)
        } else {
            try? desktop.pressKeys("Esc")
        }

        return true
    }

    // MARK: Finder, TextEdit and System Settings

    /// A Finder window in list view: its files are rows named by their name, selected by a click; a click on its
    /// sidebar's Applications goes there.
    func testScansAndClicksInFinder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-assistant-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Gamma"), withIntermediateDirectories: true)
        for file in ["Alpha.txt", "Beta.txt"] {
            try Data("lab".utf8).write(to: folder.appendingPathComponent(file))
        }

        defer { try? FileManager.default.removeItem(at: folder) }
        let opened = Integration.script("""
            tell application "Finder"
                set lab to make new Finder window to (POSIX file "\(folder.path)" as alias)
                set current view of lab to list view
                return id of lab
            end tell
            """)
        Integration.report("Finder opened the folder: \(opened)")
        guard case .output = opened else {
            XCTFail("Finder didn't open the folder: \(opened)")
            return
        }

        let entry = AppEntry(name: "Finder", launch: "com.apple.finder", processNames: ["com.apple.finder"])
        let window = try await open(entry)
        defer { close(window) }

        var elements: [UiElement] = []
        try await Integration.waitUntil(10) {
            elements = try await desktop.listClickable(window)
            return elements.contains { $0.name.hasPrefix("Alpha.txt") }
        }
        let rows = elements.filter { $0.role == .treeItem || $0.role == .listItem }.map(\.name)
        Integration.report("Finder: \(Integration.roles(elements)); rows \(rows)")
        let alpha = try XCTUnwrap(elements.first { $0.name.hasPrefix("Alpha.txt") }, "the Alpha.txt row")
        let clicked = try await desktop.click(alpha)
        XCTAssertTrue(clicked.success, clicked.message)
        let row = try XCTUnwrap(desktop.registry.lookup(alpha.id)?.element)
        let selected = try await Integration.waitUntil(3) {
            (try? desktop.ax.number(kAXSelectedAttribute, of: row)) == 1
        }
        XCTAssertTrue(selected, "Alpha.txt selected")

        if let applications = Integration.resolve(elements, "Applications", in: desktop.windowRect(window)) {
            let point = CGPoint(x: applications.rect.centerX, y: applications.rect.centerY)
            let there = Integration.describeServerWindow(SystemPointer().windowNumber(at: point, below: 0))
            let hit = Integration.describeHit(desktop, at: point)
            Integration.report(
                "at Finder's Applications: the window server's window \(there), Accessibility's \(hit); Finder's: "
                    + "\(window.handle)")
            let result = try await desktop.click(applications)
            XCTAssertTrue(result.success, result.message)
            let moved = try await Integration.waitUntil(3) { desktop.windowTitle(window) == "Applications" }
            Integration.report("Finder's sidebar: \(applications.role) clicked, window moved: \(moved)")
            XCTAssertTrue(moved, "Finder went to Applications (title now \(desktop.windowTitle(window)))")
        } else {
            XCTFail("Finder's sidebar has no single Applications")
        }
    }

    /// TextEdit: its document is a text box that takes the focus; its find bar's Done button closes the find bar.
    func testScansAndClicksInTextEdit() async throws {
        let previous = Integration.setTextEditSettings()
        await Integration.quit("com.apple.TextEdit")
        defer { Integration.restoreTextEditSettings(previous) }
        let entry = AppEntry(
            name: "TextEdit", launch: "com.apple.TextEdit", processNames: ["com.apple.TextEdit"], textArea: "Largest")
        let window = try await open(entry)

        let elements = try await desktop.listClickable(window)
        Integration.report("TextEdit: \(Integration.roles(elements)); \(elements.map(\.name))")
        let boxes = try await desktop.listTextBoxes(window)
        Integration.report("TextEdit's text boxes: \(boxes.count)")
        func area(_ box: UiElement) -> Double { box.rect.width * box.rect.height }
        let document = try XCTUnwrap(boxes.max { area($0) < area($1) })
        let focused = try await desktop.focusTextBox(document)
        XCTAssertTrue(focused.success, focused.message)
        XCTAssertEqual(true, focused.focusIsEditable)

        try desktop.pressKeys("Cmd+F")
        var withFindBar: [UiElement] = []
        try await Integration.waitUntil(5) {
            withFindBar = try await desktop.listClickable(window)
            return Integration.resolve(withFindBar, "Done", in: desktop.windowRect(window)) != nil
        }
        let done = try XCTUnwrap(Integration.resolve(withFindBar, "Done", in: desktop.windowRect(window)), "Done")
        let clicked = try await desktop.click(done)
        XCTAssertTrue(clicked.success, clicked.message)
        let closed = try await Integration.waitUntil(3) { desktop.findSearchBox(window, WorkToken()) == nil }
        XCTAssertTrue(closed, "the find bar closed")
        await Integration.quit("com.apple.TextEdit")
    }

    /// System Settings' sidebar: "Appearance" is there, and clicking it shows that pane.
    func testScansAndClicksInSystemSettings() async throws {
        let bundle = "com.apple.systempreferences"
        let wasRunning = Integration.isRunning(bundle)
        defer {
            if !wasRunning {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                    app.forceTerminate()
                }
            }
        }

        let entry = AppEntry(name: "System Settings", launch: bundle, processNames: [bundle])
        let window = try await open(entry)

        var elements: [UiElement] = []
        try await Integration.waitUntil(10) {
            elements = try await desktop.listClickable(window)
            return Integration.resolve(elements, "Appearance", in: desktop.windowRect(window)) != nil
        }
        Integration.report("System Settings: \(Integration.roles(elements)); \(elements.prefix(40).map(\.name))")
        if Integration.resolve(elements, "Appearance", in: desktop.windowRect(window)) == nil,
           let element = desktop.windowElement(window) {
            Integration.dump(desktop, element, pages: true, limit: 250)
        }

        let appearance = try XCTUnwrap(
            Integration.resolve(elements, "Appearance", in: desktop.windowRect(window)), "Appearance")
        Integration.report("System Settings' Appearance is a \(appearance.role)")
        let clicked = try await desktop.click(appearance)
        XCTAssertTrue(clicked.success, clicked.message)
        let shown = try await Integration.waitUntil(5) { desktop.windowTitle(window) == "Appearance" }
        XCTAssertTrue(shown, "the Appearance pane (title now \(desktop.windowTitle(window)))")
    }

    // MARK: The overlay

    /// The panel shows the badges where they go and the outline for under a second; the window server lists it,
    /// front-most at its badge, and the window under it after it, while Accessibility's hit test there finds what a
    /// click reaches, not the panel (that real clicks go through it is checked in Chrome's chat list, with the badges
    /// over the rows).
    @MainActor
    func testTheOverlayShowsBadgesAndClicksGoThrough() async throws {
        let overlay = MarkerOverlay()
        let rect = ScreenRect(x: 300, y: 300, width: 120, height: 30)
        overlay.showBadges([ChoiceBadge(number: 7, rect: rect, label: "Seven")])
        let number = try XCTUnwrap(overlay.windowNumber)
        XCTAssertEqual([OverlayLayout.Badge(number: 7, origin: CGPoint(x: 34, y: 34))], overlay.layout?.badges)
        try await Task.sleep(nanoseconds: 300_000_000)
        let workspace = SystemWorkspace()
        let server = workspace.serverWindow(number)
        let onScreen = workspace.windowNumbersFrontToBack().contains(number)
        let listed: String = server.map { "\($0.bounds)" } ?? "not listed"
        Integration.report("the overlay's window: \(listed), on screen \(onScreen)")
        if let server {
            XCTAssertEqual(getpid(), server.owner)
            XCTAssertEqual(CGRect(x: 260, y: 260, width: 200, height: 110), server.bounds)
        }

        let point = CGPoint(x: 360, y: 315)
        let under = SystemPointer().windowNumber(at: point, below: 0)
        let below = SystemPointer().windowNumber(at: point, below: number)
        let first = Integration.describeServerWindow(under)
        let next = Integration.describeServerWindow(below)
        Integration.report("the window server's windows at the badge: \(first), then \(next)")
        let current: MacDesktop = desktop
        let hit = await Task.detached { Integration.describeHit(current, at: point) }.value
        let owner: pid_t? = await Task.detached { () -> pid_t? in
            guard let element = try? current.ax.elementAtPoint(point) else { return nil }
            return try? current.ax.processIdentifier(of: element)
        }.value
        Integration.report("Accessibility's element at the badge: \(hit)")
        XCTAssertEqual(number, under, "the overlay is the front-most window at its badge")
        XCTAssertNotEqual(number, below)
        XCTAssertNotEqual(getpid(), owner, "Accessibility finds what's under the badge, as a click there reaches it")

        overlay.flash(rect)
        XCTAssertNotNil(overlay.layout?.outline)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(overlay.layout?.outline)
        XCTAssertNotNil(overlay.windowNumber)
        overlay.showBadges(nil)
        XCTAssertNil(overlay.windowNumber)
    }

    // MARK: The lab pages

    /// Opens or brings forward the app, as "open …" does, and gives its window; when that fails, who has the keys is
    /// reported.
    private func open(_ entry: AppEntry) async throws -> WindowInfo {
        let result = try await desktop.openOrActivate(entry, newWindow: false)
        if !result.success {
            let windows: [String] = desktop.appWindows(entry).map { "\($0.info.handle) \"\($0.info.title)\"" }
            Integration.report("\(entry.name) isn't in front: \(Integration.keys(desktop)); its windows \(windows)")
        }

        return try XCTUnwrap(result.window, result.message)
    }

    /// Shows the tab whose title starts with `title`, and gives its window, whose title follows the tab (C#'s
    /// `tab.Window with { Title = title }`).
    private func show(_ tabs: [BrowserTab], _ title: String) async throws -> WindowInfo {
        let tab = try XCTUnwrap(tabs.first { NameMatcher.cleanTabTitle($0.title).hasPrefix(title) }, title)
        let selected = try await desktop.selectTab(tab)
        XCTAssertTrue(selected.success, selected.message)
        if !selected.success {
            Integration.report("the \(title) tab isn't shown: \(Integration.keys(desktop))")
        }

        let window = try XCTUnwrap(selected.window, selected.message)
        XCTAssertTrue(NameMatcher.cleanTabTitle(window.title).hasPrefix(title), "the window's title: \(window.title)")
        return window
    }

    /// lab.html in `window`: "click New on the left" and on the right, "click Pull requests", and typing into its
    /// Message box.
    private func check(lab window: WindowInfo, browser: String) async throws {
        let bounds = desktop.windowRect(window)
        var elements: [UiElement] = []
        let started = Date()
        let described = try await Integration.waitUntil(15) {
            elements = try await desktop.listClickable(window)
            return Integration.resolve(elements, "Pull requests", in: bounds) != nil
        }
        Integration.report(
            "\(browser) lab page after \(Integration.seconds(since: started)) s: \(Integration.roles(elements))")
        Integration.report("\(browser) lab page's names: \(elements.map(\.name))")
        if !described, let element = desktop.windowElement(window) {
            Integration.dump(desktop, element, pages: true, limit: 250)
        }

        XCTAssertTrue(described, "\(browser) described the lab page")

        let clicks: [(name: String, region: ScreenRegion?, title: String)] = [
            ("Pull requests", nil, "clicked Pull requests left"), ("New", .left, "clicked New left"),
            ("New", .right, "clicked New right"), ("Library", nil, "clicked Library left"),
        ]
        for click in clicks {
            let element = try XCTUnwrap(Integration.resolve(elements, click.name, click.region, in: bounds), click.name)
            let clicked = try await desktop.click(element)
            XCTAssertTrue(clicked.success, clicked.message)
            let changed = try await Integration.waitUntil(3) { desktop.windowTitle(window).contains(click.title) }
            XCTAssertTrue(changed, "\(browser): \(click.title) (title \(desktop.windowTitle(window)))")
        }

        let boxes = try await desktop.listTextBoxes(window)
        Integration.report("\(browser) lab page's text boxes: \(boxes.map(\.name))")
        let message = try XCTUnwrap(Integration.resolve(boxes, "Message", in: bounds), "the Message box")
        let focused = try await desktop.focusTextBox(message)
        XCTAssertTrue(focused.success, focused.message)
        XCTAssertEqual(true, desktop.describeFocus()?.inPage)
        try desktop.typeText("hello from voice")
        let typed = try await Integration.waitUntil(3) { desktop.readTextBeforeCaret()?.before == "hello from voice" }
        XCTAssertTrue(typed, "\(browser): typed into Message (\(desktop.readTextBeforeCaret()?.before ?? "nothing"))")
    }

    /// chats.html in `window`: chat rows that open only on a real click, by name and by a sound-alike name.
    private func check(chats window: WindowInfo, browser: String, withBadges: Bool) async throws {
        let bounds = desktop.windowRect(window)
        var elements: [UiElement] = []
        try await Integration.waitUntil(10) {
            elements = try await desktop.listClickable(window)
            return Integration.resolve(elements, "family", in: bounds) != nil
        }
        Integration.report("\(browser) chats page: \(Integration.roles(elements)); \(elements.map(\.name))")

        var overlay: MarkerOverlay?
        let chats: [(name: String, title: String)] = [
            ("family", "opened Family"), ("vivash morang", "opened Bibhash Morang"),
        ]
        for chat in chats {
            let element = try XCTUnwrap(Integration.resolve(elements, chat.name, in: bounds), chat.name)
            if withBadges {
                // The badges over the chat row, as "show numbers" leaves them: the click goes through them.
                let badges = [ChoiceBadge(number: 1, rect: element.rect, label: element.name)]
                let shown = overlay
                overlay = await MainActor.run {
                    let panel = shown ?? MarkerOverlay()
                    panel.showBadges(badges)
                    return panel
                }
            }

            let clicked = try await desktop.click(element)
            XCTAssertTrue(clicked.success, clicked.message)
            let opened = try await Integration.waitUntil(3) { desktop.windowTitle(window).contains(chat.title) }
            XCTAssertTrue(opened, "\(browser): \(chat.title) (title \(desktop.windowTitle(window)))")
        }

        if let overlay {
            await MainActor.run { overlay.showBadges(nil) }
        }
    }

    /// mail.html in `window`: its two boxes, To and Subject, besides the browser's own address bar.
    private func check(mail window: WindowInfo, browser: String) async throws {
        var boxes: [UiElement] = []
        try await Integration.waitUntil(10) {
            boxes = try await desktop.listTextBoxes(window)
            return boxes.contains { $0.name == "Subject" }
        }
        Integration.report("\(browser) mail page's text boxes: \(boxes.map(\.name))")
        XCTAssertTrue(boxes.contains { $0.name == "To" })
        XCTAssertTrue(boxes.contains { $0.name == "Subject" })
    }

    /// Closes the window with its close button.
    private func close(_ window: WindowInfo) {
        guard let element = desktop.windowElement(window),
              let button = try? desktop.ax.element(kAXCloseButtonAttribute, of: element) else { return }
        desktop.ax.perform(kAXPressAction, on: button)
    }
}
