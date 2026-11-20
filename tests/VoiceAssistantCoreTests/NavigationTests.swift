import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

private let chrome = WindowInfo(
    handle: 10, processId: 1, processName: "chrome", title: "Lofi beats - YouTube - Google Chrome")
private let edge = WindowInfo(
    handle: 20, processId: 2, processName: "msedge", title: "Work items - Boards - Microsoft\u{200B} Edge")
private let copilot = WindowInfo(handle: 30, processId: 3, processName: "github", title: "GitHub Copilot")

/// NavigationTests.cs's desktop: tabs, and clickable elements and text boxes by window handle.
private final class NavDesktop: JarvisDesktop {
    var foreground: WindowInfo?
    var actions: [String] = []
    var tabs: [BrowserTab] = []
    var clickable: [Int: [UiElement]] = [:]
    var boxes: [Int: [UiElement]] = [:]
    var apps: [String: WindowInfo] = [:]
    var brainPlatform: BrainPlatform { .windows }

    /// Scans that return nothing before the page's elements appear (a just-activated browser tab).
    var emptyScansBeforePage = 0
    private(set) var clickableScans = 0

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        actions.append("open:\(app.name)")
        foreground = apps[app.name]
        return .ok("ok", window: foreground)
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        actions.append("prepare:\(window.processName)")
        return TextTargetResult(success: true, message: "", hasTrailingText: false, focusIsEditable: false)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "")
    }

    func checkFocusedField() -> AssistantFieldCheck { .safe }

    func focusedTextEndsWithNonWhitespace() -> Bool? { false }

    func typeText(_ text: String) throws { actions.append("type:\(text)") }

    func pressKeys(_ chord: String) throws { actions.append("keys:\(chord)") }

    func backspace(_ count: Int) throws { actions.append("backspace:\(count)") }

    func windowRect(_ window: WindowInfo) -> ScreenRect? { ScreenRect(x: 0, y: 0, width: 1800, height: 1200) }

    func listClickable(_ window: WindowInfo) async throws -> [UiElement] {
        clickableScans += 1
        return clickableScans <= emptyScansBeforePage ? [] : clickable[window.handle] ?? []
    }

    func listTextBoxes(_ window: WindowInfo) async throws -> [UiElement] { boxes[window.handle] ?? [] }

    func listTabs() async throws -> [BrowserTab] { tabs }

    func selectTab(_ tab: BrowserTab) async throws -> DesktopResult {
        actions.append("tab:\(tab.id)")
        var shown = tab.window
        shown.title = NameMatcher.cleanTabTitle(tab.title) + " - Google Chrome"
        foreground = shown
        return .ok("ok", window: shown)
    }

    func click(_ element: UiElement) async throws -> DesktopResult {
        actions.append("click:\(element.id)")
        return .ok("ok")
    }

    func focusTextBox(_ box: UiElement) async throws -> TextTargetResult {
        actions.append("focus:\(box.id)")
        return TextTargetResult(success: true, message: "", hasTrailingText: false, focusIsEditable: true)
    }
}

/// The id of a single match, nil otherwise.
private func singleId(_ resolution: Resolution<UiElement>) -> Int? {
    guard case .single(let element) = resolution else { return nil }
    return element.id
}

private func singleId(_ resolution: Resolution<BrowserTab>) -> Int? {
    guard case .single(let tab) = resolution else { return nil }
    return tab.id
}

private func isAmbiguous<T>(_ resolution: Resolution<T>) -> Bool {
    guard case .ambiguous = resolution else { return false }
    return true
}

private func isNoMatch<T>(_ resolution: Resolution<T>) -> Bool {
    guard case .noMatch = resolution else { return false }
    return true
}

/// windows-voice-assistant tests/VoiceAssistant.Core.Tests/NavigationTests.cs: name cleaning, matching, resolving
/// and the grammar, then the controller's flows: tabs, clicking by name, numbers, confirmations and text boxes.
final class NavigationTests: XCTestCase {
    // MARK: Name cleaning (inputs are real accessibility names seen on the development laptop)

    func testTabTitlesLoseCountsStatusAndBrowserNames() {
        check([
            ("(53) WhatsApp - Pinned - Memory usage - 120 MB", "WhatsApp"),
            ("Model Chat - Memory usage - 54.3 MB", "Model Chat"),
            ("what is fleurs in ai - Google Search - Memory usage - 80 MB", "what is fleurs in ai - Google Search"),
            ("Lofi beats - YouTube - Google Chrome", "Lofi beats - YouTube"),
            ("Work items - Boards - Microsoft\u{200B} Edge", "Work items - Boards"),
            ("Speech To Text Arena - a Hugging Face Space", "Speech To Text Arena - a Hugging Face Space"),
        ]) { NameMatcher.cleanTabTitle($0) }
    }

    func testElementNamesLoseShortcutsAndStates() {
        check([
            ("New project, Ctrl + Alt + Shift + N", "New project"),
            ("Resolving an Unspecified Issue, unread", "Resolving an Unspecified Issue"),
            ("Session review request. Status: Done.", "Session review request"),
            ("Pull requests", "Pull requests"),
        ]) { NameMatcher.cleanElementName($0) }
    }

    func testSiteProfilesMatchThePageNotTheBrowser() {
        let cases: [(String, String?)] = [
            ("(3) WhatsApp - Google Chrome", "WhatsApp"),
            ("ChatGPT - Google Chrome", "ChatGPT"),
            ("Amazon.in: Shoes - Google Chrome", "Amazon"),
            ("Inbox (3) - me@example.com - Gmail - Google Chrome", "Gmail"),
            ("weather - Google Search - Google Chrome", "Google"),
            ("Google - Google Chrome", "Google"),
            ("Lofi beats - YouTube - Personal - Microsoft\u{200B} Edge", "YouTube"),
            ("Microsoft Copilot: Your AI companion - Google Chrome", "Copilot"),
            ("Some article - Google Chrome", nil),
            ("Budget - Google Docs - Google Chrome", nil),
        ]
        check(cases) { SiteProfile.forTitle($0)?.name }
    }

    func testScores() {
        let cases: [((String, String), Int)] = [
            (("library", "Library"), NameMatcher.exact),
            (("pull request", "Pull requests"), NameMatcher.exact - 5),
            (("git hub", "GitHub"), NameMatcher.exact - 5),
            (("new", "New project"), NameMatcher.strong - 1),
            (("libary", "Library"), NameMatcher.fuzzy),
            (("issues", "Pull requests"), 0),
            (("vivash morang", "Bibhash Morang aise bante hai richest"), NameMatcher.fuzzy),
            (("bibhash morang", "Bibhash Morang"), NameMatcher.exact),
            (("shivam", "Sivam"), NameMatcher.fuzzy),
            (("send", "Sent items"), 0),
            (("settings", "Getting started"), 0),
            (("delete", "Deleted Items"), 0),
            (("new", "Now playing"), 0),
            (("vivash", "Prabhatee"), 0),
        ]
        check(cases) { NameMatcher.score($0.0, $0.1) }
    }

    func testSoundKeysMergeCommonRecognitionSwaps() {
        check([("vivash", "bibas"), ("bibhash", "bibas"), ("phool", "ful"), ("shivam", "sibam")]) {
            NameMatcher.soundKey($0)
        }
    }

    // Real WhatsApp Web chat-list names (each row is reported as a row and a name cell).
    func testChatRowsLoseUnreadCountsAndTimes() {
        XCTAssertEqual(
            "Bibhash Morang aise bante hai richest",
            NameMatcher.cleanElementName("1 unread message Bibhash Morang 11:27 am aise bante hai richest"))
        XCTAssertEqual("Family", NameMatcher.cleanElementName("10 unread messages Family 11:25 am"))
        XCTAssertEqual("Standup at 10 am", NameMatcher.cleanElementName("Standup at 10 am"))
        XCTAssertEqual("9:30 AM", NameMatcher.cleanElementName("9:30 AM"))
        XCTAssertEqual("7:00 AM, Good morning", NameMatcher.cleanElementName("7:00 AM, Good morning"))
    }

    func testAChatRowAndItsNameCellResolveToOneTarget() {
        let rows = [
            UiElement(
                id: 1, name: "1 unread message Bibhash Morang 11:27 am aise bante hai richest", role: .listItem,
                rect: rect(80, 540, 570, 90)),
            UiElement(
                id: 2, name: "1 unread message Bibhash Morang 11:27 am aise bante hai richest", role: .listItem,
                rect: rect(80, 540, 570, 90)),
            UiElement(
                id: 3, name: "1 unread message Bibhash Morang 11:27 am", role: .listItem,
                rect: rect(160, 550, 480, 30)),
            UiElement(
                id: 4, name: "10 unread messages Family 11:25 am Papa: https://www.facebook.com/share", role: .listItem,
                rect: rect(80, 632, 570, 90)),
            UiElement(id: 5, name: "Prabhatee 11:19 am Sticker", role: .listItem, rect: rect(80, 816, 570, 90)),
        ]
        for spoken in ["vivash morang", "bibhash morang", "bibhash"] {
            let result = TargetResolver.resolveElement(rows, ElementTarget(name: spoken), rect(0, 0, 2000, 1180))
            XCTAssertEqual(3, singleId(result), spoken)
        }
    }

    // MARK: Resolving elements

    private let copilotSidebar = [
        UiElement(id: 1, name: "New", role: .listItem, rect: rect(15, 101, 300)),
        UiElement(id: 2, name: "New", role: .button, rect: rect(15, 101, 300)),
        UiElement(id: 3, name: "Pull requests", role: .listItem, rect: rect(15, 161, 300)),
        UiElement(id: 4, name: "Pull requests", role: .button, rect: rect(15, 161, 300)),
        UiElement(id: 5, name: "Issues", role: .button, rect: rect(15, 221, 300)),
        UiElement(id: 6, name: "New project, Ctrl + Alt + Shift + N", role: .button, rect: rect(336, 491, 30)),
        UiElement(id: 7, name: "New chat", role: .button, rect: rect(1500, 693, 80)),
        UiElement(id: 8, name: "New", role: .button, rect: rect(1500, 120, 60)),
    ]

    private let copilotWindow = rect(0, 0, 1800, 1200)

    func testDuplicateListItemAndButtonCollapseToTheButton() {
        let kept = TargetResolver.deduplicate(copilotSidebar).filter { $0.name == "Pull requests" }
        XCTAssertEqual(1, kept.count)
        XCTAssertEqual(.button, kept.first?.role)
    }

    func testTwoNewsAreAmbiguousUntilLeftNarrowsIt() {
        let both = TargetResolver.resolveElement(copilotSidebar, ElementTarget(name: "new"), copilotWindow)
        XCTAssertTrue(isAmbiguous(both))
        let left =
            TargetResolver.resolveElement(copilotSidebar, ElementTarget(name: "new", region: .left), copilotWindow)
        XCTAssertEqual(2, singleId(left))
    }

    func testExactNameBeatsPrefixMatches() {
        let result = TargetResolver.resolveElement(copilotSidebar, ElementTarget(name: "issues"), copilotWindow)
        XCTAssertEqual(5, singleId(result))
    }

    func testOrdinalPicksInReadingOrder() {
        let second =
            TargetResolver.resolveElement(copilotSidebar, ElementTarget(name: "new", ordinal: 2), copilotWindow)
        XCTAssertEqual(8, singleId(second))
    }

    func testUnknownNameResolvesToNone() {
        let result = TargetResolver.resolveElement(copilotSidebar, ElementTarget(name: "settings"), copilotWindow)
        XCTAssertTrue(isNoMatch(result))
    }

    func testDestructiveNamesNeedConfirmation() {
        check([
            ("Delete repository", true), ("Merge pull request", true), ("Sign out", true), ("Discard changes", true),
            ("Pull requests", false), ("Display settings", false), ("Library", false),
        ]) { TargetResolver.isDestructive($0) }
    }

    // MARK: Resolving tabs

    private let tabs = [
        BrowserTab(
            id: 101, title: "(53) WhatsApp - Pinned - Memory usage - 120 MB", index: 1, isSelected: false,
            window: chrome, rect: rect(0, 0)),
        BrowserTab(
            id: 102, title: "Lofi beats - YouTube", index: 2, isSelected: true, window: chrome, rect: rect(100, 0)),
        BrowserTab(
            id: 103, title: "Inbox (3) - Gmail", index: 3, isSelected: false, window: chrome, rect: rect(200, 0)),
        BrowserTab(id: 201, title: "Work items - Boards", index: 1, isSelected: true, window: edge, rect: rect(0, 0)),
        BrowserTab(id: 202, title: "YouTube Music", index: 2, isSelected: false, window: edge, rect: rect(100, 0)),
    ]

    func testFirstAndLastTabMeanTheFrontBrowserWindow() {
        XCTAssertEqual(101, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "", ordinal: 1))))
        XCTAssertEqual(103, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "", ordinal: -1))))
        XCTAssertTrue(isNoMatch(TargetResolver.resolveTab(tabs, ElementTarget(name: "", ordinal: 7))))
    }

    func testNamedTabMatchesATitleSegmentAcrossWindows() {
        XCTAssertEqual(103, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "gmail"))))
        XCTAssertEqual(101, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "whatsapp"))))
        XCTAssertEqual(201, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "boards"))))
    }

    func testTwoYouTubeTabsPreferTheExactSegment() {
        // "Lofi beats - YouTube" has a segment exactly "YouTube"; "YouTube Music" only starts with it.
        XCTAssertEqual(102, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "youtube"))))
    }

    func testSameSiteInTwoWindowsPrefersTheFrontWindow() {
        let tabs = [
            BrowserTab(id: 1, title: "Song A - YouTube", index: 1, isSelected: true, window: chrome, rect: rect(0, 0)),
            BrowserTab(id: 2, title: "Song B - YouTube", index: 1, isSelected: true, window: edge, rect: rect(0, 0)),
        ]
        XCTAssertEqual(1, singleId(TargetResolver.resolveTab(tabs, ElementTarget(name: "youtube"))))
        var moved = tabs[1]
        moved.window = chrome
        moved.index = 2
        XCTAssertTrue(isAmbiguous(TargetResolver.resolveTab([tabs[0], moved], ElementTarget(name: "youtube"))))
    }

    // MARK: Grammar

    private func one(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> VoiceCommand? {
        let commands = CommandParser().parse(phrase, .command).commands
        XCTAssertEqual(1, commands.count, phrase, file: file, line: line)
        return commands.count == 1 ? commands[0] : nil
    }

    func testTabPhrases() {
        let cases: [(String, String, Int?)] = [
            ("Go to the first tab.", "", 1),
            ("first tab", "", 1),
            ("Switch to the second tab", "", 2),
            ("go to tab 3", "", 3),
            ("tab number four", "", 4),
            ("go to the last tab", "", -1),
            ("Go to the YouTube tab", "youtube", nil),
            ("go to the tab where YouTube is open", "youtube", nil),
            ("switch to the tab with Gmail", "gmail", nil),
            ("open the WhatsApp tab", "whatsapp", nil),
            ("Open the What's New tab.", "whats new", nil),
            ("open New York Times tab", "new york times", nil),
        ]
        for (phrase, name, ordinal) in cases {
            let command = one(phrase)
            XCTAssertEqual(.selectTab, command?.kind, phrase)
            XCTAssertEqual(name, command?.target?.name, phrase)
            XCTAssertEqual(ordinal, command?.target?.ordinal, phrase)
        }
    }

    func testOpeningPagesNeverSelectsATabNamedAfterTheRequest() {
        let cases: [(String, CommandKind, String)] = [
            ("Open Instagram in new tab.", .openInNewTab, "instagram"),
            ("Can you open Instagram in a new tab, please?", .openInNewTab, "instagram"),
            ("Open Instagram in a new tap.", .openInNewTab, "instagram"),
            ("Open the Instagram website in another tab", .openInNewTab, "instagram"),
            ("Open a new tab and then open Instagram", .openInNewTab, "instagram"),
            ("Open instagram.com in a new tab.", .openInNewTab, "instagram.com"),
            ("Open a new tab with github.com/shivam098.", .openInNewTab, "github.com/shivam098"),
            ("Open Notepad in a new window.", .openInNewWindow, "notepad"),
            ("Open instagram.com.", .openApp, "instagram.com"),
            ("Go to instagram dot com.", .switchToApp, "instagram.com"),
            ("Open Instagram in a second tab.", .openInNewTab, "instagram"),
        ]
        for (phrase, kind, name) in cases {
            let command = one(phrase)
            XCTAssertEqual(kind, command?.kind, phrase)
            XCTAssertEqual(name, command?.argument, phrase)
        }
    }

    func testTypingInTheSecondTabSelectsTheTabThatIsOpen() {
        let phrases =
            ["Start typing in the second tab.", "Open the second tab and start typing.", "Open the second tab to type."]
        for phrase in phrases {
            let commands = CommandParser().parse(phrase, .command).commands
            XCTAssertEqual([.selectTab, .startTyping], commands.map { $0.kind }, phrase)
            XCTAssertEqual(2, commands.first?.target?.ordinal, phrase)
        }
    }

    func testTabsAlreadyOpenTypingAndKindsOfTabAreNotPagesToOpen() {
        let phrases = [
            "Go to the WhatsApp tab in the other window.", "Go to the WhatsApp tab in a different window.",
            "Start typing in a new tab.", "Open a new tab and start dictating.", "Open a blank page in a new tab.",
            "Open incognito in a new window.",
        ]
        for phrase in phrases {
            let commands = CommandParser().parse(phrase, .command).commands
            XCTAssertFalse(commands.contains { $0.kind == .openInNewTab || $0.kind == .openInNewWindow }, phrase)
        }
    }

    func testTabShortcutsStillPressKeys() {
        for (phrase, chord) in [("new tab", "Ctrl+T"), ("next tab", "Ctrl+Tab"), ("close tab", "Ctrl+W")] {
            let command = one(phrase)
            XCTAssertEqual(.pressKeys, command?.kind, phrase)
            XCTAssertEqual(chord, command?.argument, phrase)
        }
    }

    func testClickPhrases() {
        let cases: [(String, String, ScreenRegion?, Int?)] = [
            ("Click on New on the left side.", "new", .left, nil),
            ("click Library", "library", nil, nil),
            ("Select Library", "library", nil, nil),
            ("press the Issues button", "issues", nil, nil),
            ("click the second session", "session", nil, 2),
            ("tap pull requests in the sidebar", "pull requests", .left, nil),
            ("expand sessions", "sessions", nil, nil),
        ]
        for (phrase, name, region, ordinal) in cases {
            let command = one(phrase)
            XCTAssertEqual(.click, command?.kind, phrase)
            XCTAssertEqual(name, command?.target?.name, phrase)
            XCTAssertEqual(region, command?.target?.region, phrase)
            XCTAssertEqual(ordinal, command?.target?.ordinal, phrase)
        }
    }

    func testExistingAndUtilityPhrases() {
        let cases: [(String, CommandKind)] = [
            ("select all", .pressKeys), ("click the search box", .focusSearch), ("press enter", .pressKeys),
            ("show numbers", .showNumbers), ("hide numbers", .hideNumbers), ("yes", .confirm), ("cancel", .cancel),
        ]
        for (phrase, kind) in cases {
            XCTAssertEqual(kind, one(phrase)?.kind, phrase)
        }
    }

    func testNumberChoices() {
        let cases = [
            ("3", 3), ("Seven.", 7), ("click 12", 12), ("number two", 2), ("choose four", 4), ("the second one", 2),
        ]
        for (phrase, number) in cases {
            let command = one(phrase)
            XCTAssertEqual(.choose, command?.kind, phrase)
            XCTAssertEqual(String(number), command?.argument, phrase)
        }
    }

    func testStartTypingInAnAppOrSiteSwitchesThenTypes() {
        let parsed = CommandParser().parse("Start typing in YouTube", .command)
        XCTAssertEqual([.switchToApp, .startTyping], parsed.commands.map { $0.kind })
        XCTAssertEqual("youtube", parsed.commands.first?.argument)
    }

    func testStartTypingInATabSelectsItFirst() {
        let parsed = CommandParser().parse("start typing in the first tab", .command)
        XCTAssertEqual([.selectTab, .startTyping], parsed.commands.map { $0.kind })
    }

    func testStartTypingInAField() {
        let cases: [(String, CommandKind, String?)] = [
            ("start typing in the message box", .focusField, "message"),
            ("type in the comment box", .focusField, "comment"),
            ("start typing in the search box", .focusSearch, nil),
            ("start typing in the address bar", .focusAddressBar, nil),
            ("start typing in the text box", .startTyping, nil),
        ]
        for (phrase, kind, field) in cases {
            let command = one(phrase)
            XCTAssertEqual(kind, command?.kind, phrase)
            XCTAssertEqual(field, command?.target?.name, phrase)
        }
    }

    func testTabOrClickCanChainStartTyping() {
        let parsed = CommandParser().parse("go to the YouTube tab and start typing", .command)
        XCTAssertEqual([.selectTab, .startTyping], parsed.commands.map { $0.kind })
    }

    func testOpenAppAndStartTypingIsUnchanged() {
        let parsed = CommandParser().parse("open notepad and start typing", .command)
        XCTAssertEqual([.openApp, .startTyping], parsed.commands.map { $0.kind })
    }

    func testWhileTypingNavigationNeedsTheWakeWord() {
        let parser = CommandParser()
        XCTAssertNotNil(parser.parse("go to the first tab", .dictation).dictationText)
        let woken = parser.parse("Hey Jarvis, go to the first tab", .dictation).commands
        XCTAssertEqual([.selectTab], woken.map { $0.kind })
        XCTAssertNotNil(parser.parse("click New", .dictation).dictationText)
        XCTAssertNotNil(parser.parse("two", .dictation).dictationText)
    }

    // MARK: Controller flows

    private static let chromeApp = AppEntry(
        name: "Google Chrome", aliases: ["chrome"], launch: "chrome.exe", processNames: ["chrome"],
        searchKeys: "Ctrl+L", addressBarKeys: "Ctrl+L")
    private static let copilotApp = AppEntry(
        name: "GitHub Copilot", launch: "copilot", processNames: ["github"], windowTitleContains: "GitHub Copilot")

    private var desktop: NavDesktop!
    private var controller: InteractionController!
    private var statuses: StatusLog!
    private var badges: Recorder<[ChoiceBadge]?>!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        let fixture = makeFixture()
        desktop = fixture.desktop
        controller = fixture.controller
        statuses = fixture.statuses
        badges = fixture.badges
        clock = fixture.clock
    }

    /// The C# test class's constructor, also for each case of a theory.
    private func makeFixture() -> (
        desktop: NavDesktop, controller: InteractionController, statuses: StatusLog, badges: Recorder<[ChoiceBadge]?>,
        clock: TestClock
    ) {
        let desktop = NavDesktop()
        desktop.apps["Google Chrome"] = chrome
        desktop.apps["GitHub Copilot"] = copilot
        desktop.tabs = tabs
        desktop.clickable[copilot.handle] = copilotSidebar
        desktop.boxes[copilot.handle] = [
            UiElement(id: 900, name: "Message", role: .textBox, rect: rect(400, 1100, 1000, 60)),
        ]
        desktop.boxes[chrome.handle] = [
            UiElement(id: 910, name: "Address and search bar", role: .textBox, rect: rect(200, 50, 1200, 30)),
            UiElement(id: 911, name: "Search", role: .textBox, rect: rect(500, 120, 600, 40)),
        ]
        let clock = TestClock(utc(2026, 11, 5, 12))
        let controller = InteractionController(
            desktop, AppCatalog([Self.chromeApp, Self.copilotApp]), CommandParser(),
            options: ControllerOptions(wakeWordEnabled: false, clock: { clock.now }))
        let statuses = StatusLog()
        let badges = Recorder<[ChoiceBadge]?>()
        controller.onStatus = statuses.add
        controller.onChoicesChanged = badges.add
        controller.setListening(true)
        desktop.foreground = copilot
        return (desktop, controller, statuses, badges, clock)
    }

    private func say(_ text: String) async throws {
        try await controller.handleTranscript(text, 0.9)
    }

    /// The numbers shown last (C#'s `_badges[^1]`, which must be a list).
    private func shownBadges(file: StaticString = #filePath, line: UInt = #line) throws -> [ChoiceBadge] {
        try XCTUnwrap(try XCTUnwrap(badges.all.last, file: file, line: line), file: file, line: line)
    }

    private func addDeleteSession() {
        desktop.clickable[copilot.handle]?.append(
            UiElement(id: 50, name: "Delete session", role: .button, rect: rect(900, 400)))
    }

    func testClickInAJustActivatedBrowserTabWaitsForThePage() async throws {
        desktop.foreground = chrome
        desktop.clickable[chrome.handle] = [UiElement(id: 500, name: "Library", role: .button, rect: rect(20, 300))]
        desktop.emptyScansBeforePage = 2
        try await say("Click Library.")
        XCTAssertEqual(["click:500"], desktop.actions)
        XCTAssertEqual(3, desktop.clickableScans)
    }

    func testClickOutsideBrowsersDoesNotRescan() async throws {
        try await say("Click Settings.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual(1, desktop.clickableScans)
    }

    func testOpenChromeFirstTabThenStartTyping() async throws {
        try await say("Open Chrome.")
        try await say("Go to the first tab.")
        XCTAssertEqual(["open:Google Chrome", "tab:101"], desktop.actions)
        XCTAssertEqual("Google Chrome › WhatsApp", controller.place)
        XCTAssertEqual("Google Chrome › WhatsApp", statuses.last?.place)
    }

    func testYouTubeTabThenItsSearchBox() async throws {
        try await say("Go to the tab where YouTube is open.")
        try await say("Start typing.")
        XCTAssertEqual(["tab:102", "prepare:chrome", "focus:911"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
        XCTAssertEqual("Google Chrome › Lofi beats - YouTube › Search", controller.place)
        try await say("lofi music")
        XCTAssertTrue(desktop.actions.contains("type:Lofi music"))
    }

    func testStartTypingInYouTubeDoesBoth() async throws {
        try await say("Start typing in YouTube.")
        XCTAssertEqual(["tab:102", "prepare:chrome", "focus:911"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testCopilotSwitchClickNewOnTheLeftThenType() async throws {
        desktop.foreground = chrome
        try await say("Switch to GitHub Copilot.")
        try await say("Click on New on the left.")
        try await say("Start typing.")
        XCTAssertEqual(["open:GitHub Copilot", "click:2", "prepare:github", "focus:900"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
        XCTAssertEqual(copilot, controller.target)
    }

    func testBrowserPageWithTwoUnnamedBoxesAsksWhich() async throws {
        var mail = chrome
        mail.handle = 11
        mail.title = "Lab Inbox - Mail - Google Chrome"
        desktop.foreground = mail
        desktop.boxes[mail.handle] = [
            UiElement(id: 920, name: "Address and search bar", role: .textBox, rect: rect(200, 50, 1200, 30)),
            UiElement(id: 921, name: "To", role: .textBox, rect: rect(100, 200, 400, 30)),
            UiElement(id: 922, name: "Subject", role: .textBox, rect: rect(100, 250, 400, 30)),
        ]
        try await say("Start typing.")
        XCTAssertEqual(2, try shownBadges().count)
        XCTAssertEqual(.command, controller.mode)
        try await say("Two.")
        XCTAssertEqual(["prepare:chrome", "focus:922"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testBrowserPageWithoutBoxesUsesTheAddressBar() async throws {
        var article = chrome
        article.handle = 12
        article.title = "Some article - Google Chrome"
        desktop.foreground = article
        desktop.boxes[article.handle] = [
            UiElement(id: 930, name: "Address and search bar", role: .textBox, rect: rect(200, 50, 1200, 30)),
        ]
        try await say("Start typing.")
        XCTAssertEqual(["prepare:chrome", "keys:Ctrl+L"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testAmbiguousClickShowsNumbersAndANumberClicks() async throws {
        try await say("Click New.")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("click:") })
        XCTAssertEqual(2, try shownBadges().count)
        try await say("Two.")
        XCTAssertEqual(["click:8"], desktop.actions)
        XCTAssertNil(try XCTUnwrap(badges.all.last))
    }

    func testShowNumbersThenPickATextBoxStartsTyping() async throws {
        try await say("Show numbers.")
        let messages = try shownBadges().filter { $0.label == "Message" }
        XCTAssertEqual(1, messages.count)
        let message = try XCTUnwrap(messages.first)
        try await say(String(message.number))
        XCTAssertEqual(["focus:900"], desktop.actions)
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testChoicesExpireAndOtherCommandsClearThem() async throws {
        try await say("Click New.")
        clock.advance(31)
        controller.tick()
        XCTAssertNil(try XCTUnwrap(badges.all.last))
        try await say("Two.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(NetText.containsOrdinalIgnoreCase(statuses.last?.message ?? "", "nothing to choose"))
    }

    func testDestructiveClickWaitsForYes() async throws {
        addDeleteSession()
        try await say("Click delete session.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(NetText.containsOrdinalIgnoreCase(statuses.last?.message ?? "", "say “yes”"))
        try await say("Yes.")
        XCTAssertEqual(["click:50"], desktop.actions)
    }

    func testDestructiveClickIsDroppedOnNoOrAnotherCommand() async throws {
        addDeleteSession()
        try await say("Click delete session.")
        try await say("No.")
        try await say("Yes.")
        XCTAssertEqual([], desktop.actions)
    }

    func testClickRefusesWhenFocusMovedBeforeConfirmation() async throws {
        addDeleteSession()
        try await say("Click delete session.")
        desktop.foreground = chrome
        try await say("Yes.")
        XCTAssertEqual([], desktop.actions)
    }

    func testGoToAButtonNameClicksItWhenNoAppOrTabMatches() async throws {
        try await say("Go to pull requests.")
        XCTAssertEqual(["click:4"], desktop.actions)
    }

    func testUnknownGoToReportsWhatWasTried() async throws {
        try await say("Go to settings.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(statuses.last?.message.contains("app, tab or button") == true)
    }

    func testWakeWordNavigationWhileTypingStopsTypingFirst() async throws {
        try await say("Start typing.")
        XCTAssertEqual(.dictation, controller.mode)
        desktop.actions.removeAll()
        try await controller.handleTranscript("Hey Jarvis, go to the first tab", 0.9)
        XCTAssertEqual(["tab:101"], desktop.actions)
        XCTAssertEqual(.command, controller.mode)
        try await say("this should not be typed")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
    }

    func testWakeWordShortcutsWhileTypingStopTyping() async throws {
        let cases = [
            ("Hey Jarvis, next tab", "keys:Ctrl+Tab"), ("Hey Jarvis, go back", "keys:Alt+Left"),
            ("Hey Jarvis, close tab", "keys:Ctrl+W"),
        ]
        for (phrase, action) in cases {
            let fixture = makeFixture()
            try await fixture.controller.handleTranscript("Start typing.", 0.9)
            fixture.desktop.actions.removeAll()
            try await fixture.controller.handleTranscript(phrase, 0.9)
            XCTAssertEqual([action], fixture.desktop.actions, phrase)
            XCTAssertEqual(.command, fixture.controller.mode, phrase)
            try await fixture.controller.handleTranscript("send", 0.9)
            XCTAssertFalse(fixture.desktop.actions.contains("keys:Enter"), phrase)
        }
    }

    func testPressKeyWhileTypingKeepsTyping() async throws {
        try await say("Start typing.")
        try await say("press tab")
        XCTAssertEqual(.dictation, controller.mode)
    }

    func testChoicesOfferedWhileTypingLeaveTypingSoNumbersAreNotTyped() async throws {
        desktop.boxes[copilot.handle]?.append(
            UiElement(id: 901, name: "Message", role: .textBox, rect: rect(400, 100, 600, 40)))
        try await say("Start typing.")
        desktop.actions.removeAll()
        try await controller.handleTranscript("Hey Jarvis, start typing in the message box", 0.9)
        XCTAssertEqual(.command, controller.mode)
        try await say("Two.")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") })
        XCTAssertEqual(1, desktop.actions.filter { $0.hasPrefix("focus:") }.count)
    }

    func testUnrelatedSpeechDropsAPendingConfirmation() async throws {
        addDeleteSession()
        try await say("Click delete session.")
        try await say("What a nice day it is outside.")
        try await say("Yeah.")
        XCTAssertEqual([], desktop.actions)
    }

    func testEverydayWordsInStandbyStaySilent() async throws {
        let controller = InteractionController(
            desktop, AppCatalog([Self.chromeApp, Self.copilotApp]), CommandParser())
        let statuses = StatusLog()
        controller.setListening(true)
        controller.onStatus = statuses.add
        for word in ["Yes.", "No.", "Two.", "Yeah."] {
            try await controller.handleTranscript(word, 0.9)
        }

        XCTAssertEqual([], statuses.messages)
        try await controller.handleTranscript("Go to the first tab.", 0.9)
        XCTAssertEqual(1, statuses.all.count)
        XCTAssertTrue(statuses.last?.message.contains("first") == true)
    }
}
