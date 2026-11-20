import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

private let screen = ScreenRect(x: 0, y: 0, width: 1920, height: 1040)

/// A rectangle, as BrainTests' `R(x, y, w, h)` (its width defaults to 300).
private func r(_ x: Double, _ y: Double, _ width: Double = 300, _ height: Double = 30) -> ScreenRect {
    ScreenRect(x: x, y: y, width: width, height: height)
}

private let mrBeast = UiElement(
    id: 104, name: "I Survived 50 Hours In Antarctica - MrBeast - 98M views", role: .link, rect: r(200, 200))

private let youTubeHome = [
    UiElement(id: 101, name: "Home", role: .link, rect: r(10, 100, 100)),
    UiElement(id: 102, name: "Shorts", role: .link, rect: r(10, 140, 100)),
    UiElement(id: 103, name: "Search", role: .button, rect: r(700, 20, 40)),
    mrBeast,
    UiElement(id: 105, name: "Why Is This Bridge Twisted? - Veritasium - 4.1M views", role: .link, rect: r(520, 200)),
]

private let youTubeSearchBox = UiElement(id: 110, name: "Search", role: .textBox, rect: r(300, 20, 390))

/// BrainTests.cs's model: it answers with the queued replies, throws, or waits until cancelled, and keeps the
/// conversations it was given.
private final class FakeBrain: BrainModel, @unchecked Sendable {
    private struct NoReply: Error {}

    private let lock = NSLock()
    private var replies: [String] = []
    private var received: [[ChatTurn]] = []
    private var preparedCount = 0
    private var failure: Error?
    private var hangs = false

    var availability = BrainAvailability.ready

    /// What `complete` throws (C#'s `Throw`).
    var error: Error? {
        get { locked { failure } }
        set { locked { failure = newValue } }
    }

    /// `complete` waits until its task is cancelled (C#'s `Hang`).
    var hang: Bool {
        get { locked { hangs } }
        set { locked { hangs = newValue } }
    }

    var calls: [[ChatTurn]] { locked { received } }

    var lastRequest: String { calls.last?.last?.content ?? "" }

    var prepared: Int { locked { preparedCount } }

    func enqueue(_ reply: String) {
        locked { replies.append(reply) }
    }

    func prepare() {
        locked { preparedCount += 1 }
    }

    func complete(_ messages: [ChatTurn]) async throws -> String {
        let (waits, failing) = begin(messages)
        if waits {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }

        if let failing {
            throw failing
        }

        guard let reply = nextReply() else { throw NoReply() }
        return reply
    }

    private func begin(_ messages: [ChatTurn]) -> (Bool, Error?) {
        locked {
            received.append(messages)
            return (hangs, failure)
        }
    }

    private func nextReply() -> String? {
        locked { replies.isEmpty ? nil : replies.removeFirst() }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// BrainTests.cs's desktop: windows, their elements and text boxes, tabs, apps, and what has the focus.
private final class BrainDesktop: JarvisDesktop {
    let brainPlatform: BrainPlatform

    /// The browser that comes to the front when a page opens.
    let browser: WindowInfo
    var windows: [DesktopWindow] = []
    var foreground: WindowInfo?
    var actions: [String] = []
    var clickable: [Int: [UiElement]] = [:]
    var boxes: [Int: [UiElement]] = [:]
    var apps: [String: WindowInfo] = [:]
    var tabs: [BrowserTab] = []
    var focusedName: String?

    /// Overrides whether the focused control takes text (otherwise: a box was focused, or the window has none).
    var focusEditable: Bool?
    var pageComesToFront = true
    var onActivate: (() -> Void)?

    /// Boxes that are the browser's own rather than the page's: its address bar, in any language.
    var browserBars: Set<String> = ["Address and search bar", "Adress- und Suchleiste"]

    init(_ platform: BrainPlatform, browser: WindowInfo) {
        brainPlatform = platform
        self.browser = browser
    }

    func listTabs() async throws -> [BrowserTab] { tabs }

    func selectTab(_ tab: BrowserTab) async throws -> DesktopResult {
        actions.append("tab:\(tab.id)")
        foreground = tab.window
        return .ok("ok", window: tab.window)
    }

    func foregroundWindow() -> WindowInfo? { foreground }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        actions.append("open:\(app.name)")
        foreground = apps[app.name]
        return .ok("ok", window: foreground)
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        let editable = focusEditable ?? (boxes[window.handle] == nil || focusedName != nil)
        return TextTargetResult(success: true, message: "", hasTrailingText: false, focusIsEditable: editable)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "")
    }

    func checkFocusedField() -> AssistantFieldCheck { .safe }

    func focusedTextEndsWithNonWhitespace() -> Bool? { false }

    func typeText(_ text: String) throws { actions.append("type:\(text)") }

    /// Every chord pressed is one the platform's desktop can press (`ShortcutKeys` documents the grammar).
    func pressKeys(_ chord: String) throws {
        XCTAssertTrue(ChordGrammar.parses(chord, mac: brainPlatform.kind == .mac), chord)
        actions.append("keys:\(chord)")
    }

    func backspace(_ count: Int) throws { actions.append("backspace:\(count)") }

    func windowRect(_ window: WindowInfo) -> ScreenRect? { screen }

    func listClickable(_ window: WindowInfo) async throws -> [UiElement] { clickable[window.handle] ?? [] }

    func listTextBoxes(_ window: WindowInfo) async throws -> [UiElement] { boxes[window.handle] ?? [] }

    func click(_ element: UiElement) async throws -> DesktopResult {
        actions.append("click:\(element.id)")
        return .ok("ok")
    }

    func focusTextBox(_ box: UiElement) async throws -> TextTargetResult {
        actions.append("focus:\(box.id)")
        focusedName = box.name
        return TextTargetResult(success: true, message: "", hasTrailingText: false, focusIsEditable: true)
    }

    func listWindows() async throws -> [DesktopWindow] { windows }

    func activateWindow(_ window: WindowInfo) async throws -> DesktopResult {
        actions.append("activate:\(window.processName)")
        onActivate?()
        foreground = window
        if let index = windows.firstIndex(where: { $0.window.sameWindow(window) }) {
            var entry = windows.remove(at: index)
            if entry.show == .minimized {
                entry.show = .normal
            }

            windows.insert(entry, at: 0)
        }

        return .ok("ok", window: window)
    }

    func openURL(_ link: WebLink) async throws -> DesktopResult {
        actions.append("url:\(link.absoluteUri)")
        if !pageComesToFront {
            return .ok("Opened the page in the browser.")
        }

        foreground = browser
        return .ok("ok", window: browser)
    }

    func describeFocus() -> FocusInfo? {
        guard let name = focusedName else { return nil }
        let bar = browserBars.contains(name)
        return FocusInfo(name: name, editable: focusEditable ?? true, inPage: !bar, addressBar: bar)
    }
}

/// BrainTests.cs's tests of the controller running plans (docs/design/ai-brain.md), with a desktop that names Windows'
/// platform. BrainControllerMacTests runs them all again on the Mac's: its bundle identifiers, its keys (a plan's
/// chords are pressed as their Mac chords) and Finder.
class BrainControllerTests: XCTestCase {
    class var platform: BrainPlatform { .windows }

    var mac: Bool { Self.platform.kind == .mac }

    /// The process a C# test names, on this platform: as named on Windows, its bundle identifier on the Mac.
    func process(_ windowsName: String) -> String {
        guard mac else { return windowsName }
        let bundles = [
            "WindowsTerminal": "com.apple.Terminal", "chrome": "com.google.Chrome", "WhatsApp": "net.whatsapp.WhatsApp",
            "olk": "com.microsoft.Outlook", "Notepad": "com.apple.TextEdit", "explorer": "com.apple.finder",
            "brave": "com.brave.Browser", "Code": "com.microsoft.VSCode",
        ]
        return bundles[windowsName] ?? windowsName
    }

    /// The keys the desktop is asked to press for a plan's chord on this platform.
    func pressed(_ chord: String) -> String { BrainSafety.pressedChord(chord, Self.platform) ?? chord }

    var terminal: WindowInfo { windowRef(1, 11, process("WindowsTerminal"), "Windows PowerShell") }
    var chrome: WindowInfo { windowRef(2, 12, process("chrome"), "Home - YouTube - Google Chrome") }
    var whatsApp: WindowInfo { windowRef(3, 13, process("WhatsApp"), "WhatsApp") }
    var outlook: WindowInfo { windowRef(4, 14, process("olk"), "Weekly newsletter - Outlook") }
    var notepad: WindowInfo { windowRef(5, 15, process("Notepad"), "Untitled - Notepad") }

    var chromeApp: AppEntry {
        AppEntry(
            name: "Google Chrome", aliases: ["chrome"], launch: "chrome.exe", processNames: [process("chrome")],
            searchKeys: mac ? "Cmd+L" : "Ctrl+L", addressBarKeys: mac ? "Cmd+L" : "Ctrl+L")
    }

    var notepadApp: AppEntry {
        AppEntry(name: "Notepad", launch: "notepad.exe", processNames: [process("Notepad")], newLineKeys: "Enter")
    }

    fileprivate var desktop: BrainDesktop!
    fileprivate var brain: FakeBrain!
    var statuses: StatusLog!
    var traces: Recorder<String>!
    var controller: InteractionController!
    var clock: TestClock!

    override func setUp() {
        super.setUp()
        clock = TestClock(utc(2026, 11, 18, 9))
        desktop = BrainDesktop(Self.platform, browser: chrome)

        // The desk from the bug report: PowerShell on the right in front, YouTube in Chrome on the left, WhatsApp
        // minimized.
        desktop.windows = [
            DesktopWindow(window: terminal, show: .normal, rect: r(960, 0, 960, 1040), workArea: screen),
            DesktopWindow(window: chrome, show: .normal, rect: r(0, 0, 960, 1040), workArea: screen),
            DesktopWindow(window: whatsApp, show: .minimized),
        ]
        desktop.foreground = terminal
        desktop.clickable[chrome.handle] = youTubeHome
        desktop.boxes[chrome.handle] = [youTubeSearchBox]
        desktop.boxes[terminal.handle] = [
            UiElement(id: 120, name: "Command line", role: .textBox, rect: r(980, 100, 900)),
        ]
        desktop.apps["Notepad"] = notepad
        brain = FakeBrain()
        statuses = StatusLog()
        traces = Recorder<String>()
        controller = makeController(wakeWord: false)
        controller.onStatus = statuses.add
        controller.onTrace = traces.add
        controller.setListening(true)
    }

    /// A controller on this desktop and brain, as the C# tests make them.
    func makeController(wakeWord: Bool, apps extra: [AppEntry] = []) -> InteractionController {
        let clock: TestClock = self.clock
        let controller = InteractionController(
            desktop, AppCatalog([chromeApp, notepadApp] + extra), CommandParser(keys: mac ? .mac : .windows),
            options: ControllerOptions(wakeWordEnabled: wakeWord, clock: { clock.now }))
        controller.brain = brain
        return controller
    }

    func say(_ text: String) async throws {
        try await controller.handleTranscript(text, 0.9)
    }

    var lastMessage: String { statuses.last?.message ?? "" }

    func frontWindow(_ window: WindowInfo, _ show: WindowShow = .maximized) {
        desktop.windows = [DesktopWindow(window: window, show: show, rect: screen, workArea: screen)]
        desktop.foreground = window
    }

    // MARK: Plans

    private func mrBeastPlan() -> String {
        planReply("Opening the MrBeast video.", [("focus_window", chrome.title, ""), ("click", mrBeast.name, "")])
    }

    func testOpenTheMrBeastVideoSwitchesToYouTubeAndClicksIt() async throws {
        brain.enqueue(mrBeastPlan())
        try await say("Open the MrBeast video on YouTube.")

        XCTAssertEqual(["activate:\(chrome.processName)", "click:104"], desktop.actions)
        XCTAssertEqual(.success, statuses.last?.kind)
        XCTAssertEqual("Opening the MrBeast video.", lastMessage)
        let asked = brain.lastRequest
        XCTAssertTrue(asked.contains("Request: \"Open the MrBeast video on YouTube.\""))
        XCTAssertTrue(asked.contains("Items in \"Home - YouTube - Google Chrome\":"))
        XCTAssertTrue(asked.contains("link \"I Survived 50 Hours In Antarctica - MrBeast - 98M views\""))
    }

    func testADescriptionNamingATabInPassingGoesToTheBrainButATabNameDoesNot() async throws {
        desktop.tabs.append(
            BrowserTab(id: 77, title: "Home - YouTube", index: 1, isSelected: true, window: chrome, rect: r(0, 0, 200)))
        brain.enqueue(mrBeastPlan())
        try await say("Open the MrBeast video on YouTube.")
        XCTAssertEqual(["activate:\(chrome.processName)", "click:104"], desktop.actions)

        desktop.actions.removeAll()
        desktop.foreground = terminal
        try await say("Go to YouTube.")
        XCTAssertEqual(["tab:77"], desktop.actions)
        XCTAssertEqual(1, brain.calls.count)
    }

    func testTheLogNeverContainsWordsTitlesOrNames() async throws {
        brain.enqueue(mrBeastPlan())
        try await say("Open the MrBeast video on YouTube.")

        let log = traces.all.joined(separator: "\n")
        XCTAssertTrue(log.contains("brain: plan [focus_window, click]"))
        for secret in ["MrBeast", "YouTube", "Antarctica", "PowerShell", "Opening"] {
            XCTAssertFalse(NetText.containsOrdinalIgnoreCase(log, secret), secret)
        }
    }

    func testRequestsThatAreNotCommandsGoToTheBrain() async throws {
        brain.enqueue(
            planReply("Searching Google for the weather.", [("web_search", "google", "weather in Bangalore")]))
        try await say("What's the weather in Bangalore?")
        XCTAssertEqual(["url:https://www.google.com/search?q=weather%20in%20Bangalore"], desktop.actions)
        XCTAssertEqual("Searching Google for the weather.", lastMessage)
    }

    func testChatIsAnsweredWithoutSteps() async throws {
        brain.enqueue(planReply("All good, ready when you are.", []))
        try await say("How are you doing?")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("All good, ready when you are.", lastMessage)
    }

    func testAQuestionFromTheBrainIsShownAndNothingRuns() async throws {
        brain.enqueue(planReply("Which one?", [("ask", "", "Which video do you mean?")]))
        try await say("Do the thing.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("Which video do you mean?", lastMessage)
    }

    func testWithoutTheBrainUnknownPhrasesAreLearnedAsBefore() async throws {
        brain.availability = .off
        try await say("What's the weather in Bangalore?")
        XCTAssertEqual(0, brain.calls.count)
        XCTAssertEqual("Not a command I know. Say it another way and I'll remember.", lastMessage)

        brain.availability = .notInstalled
        try await say("What's the weather in Bangalore?")
        XCTAssertEqual(0, brain.calls.count)
        XCTAssertTrue(lastMessage.contains("AI brain in Settings"))
    }

    func testAFailingOrConfusedModelIsReportedNotRun() async throws {
        brain.error = URLError(.cannotConnectToHost)
        try await say("What's the weather in Bangalore?")
        XCTAssertTrue(lastMessage.contains("isn't working"))

        brain.error = nil
        brain.enqueue("I am not sure what you mean.")
        try await say("What's the weather in Bangalore?")
        XCTAssertTrue(lastMessage.contains("couldn't work out"))
        XCTAssertEqual([], desktop.actions)
    }

    func testDeletingWaitsForYesAndThenContinues() async throws {
        frontWindow(outlook)
        desktop.clickable[outlook.handle] = [
            UiElement(id: 301, name: "Reply", role: .button, rect: r(10, 10, 60)),
            UiElement(id: 302, name: "Delete", role: .button, rect: r(80, 10, 60)),
        ]
        brain.enqueue(planReply("Deleted it.", [("click", "Delete", ""), ("scroll", "down", "")]))
        try await say("Get rid of this email.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("Click “Delete”? Say “yes” to go ahead, or “no”.", lastMessage)

        try await say("Yes.")
        XCTAssertEqual(["click:302", "keys:PageDown"], desktop.actions)
        XCTAssertEqual("Deleted it.", lastMessage)
    }

    func testNoCancelsAWaitingStepAndAnotherRequestDropsIt() async throws {
        frontWindow(outlook)
        desktop.clickable[outlook.handle] = [UiElement(id: 302, name: "Delete", role: .button, rect: r(80, 10, 60))]
        brain.enqueue(planReply("Deleted it.", [("click", "Delete", "")]))
        try await say("Get rid of this email.")
        try await say("No.")
        XCTAssertEqual("Cancelled.", lastMessage)
        try await say("Yes.")
        XCTAssertEqual([], desktop.actions)

        brain.enqueue(planReply("Deleted it.", [("click", "Delete", "")]))
        try await say("Get rid of this email.")
        try await say("Scroll down.")
        try await say("Yes.")
        XCTAssertEqual(["keys:PageDown"], desktop.actions)
    }

    func testAYesAfterFocusMovedDoesNothing() async throws {
        frontWindow(outlook)
        desktop.clickable[outlook.handle] = [UiElement(id: 302, name: "Delete", role: .button, rect: r(80, 10, 60))]
        brain.enqueue(planReply("Deleted it.", [("click", "Delete", "")]))
        try await say("Get rid of this email.")
        desktop.foreground = chrome
        try await say("Yes.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("Focus moved"))
    }

    func testTypedMessagesAreSentOnlyAfterYes() async throws {
        frontWindow(whatsApp)
        let rahul = "Rahul Sharma, Are we still on for tomorrow?, 10:42"
        desktop.clickable[whatsApp.handle] = [
            UiElement(id: 201, name: rahul, role: .listItem, rect: r(10, 100, 400, 60)),
        ]
        desktop.boxes[whatsApp.handle] = [
            UiElement(id: 203, name: "Type a message", role: .textBox, rect: r(500, 1000, 1200, 40)),
        ]
        brain.enqueue(planReply(
            "Replied to Rahul.",
            [("click", rahul, ""), ("type_text", "Type a message", "Thanks!"), ("press", "enter", "")]))
        try await say("Reply thanks to Rahul on WhatsApp.")
        XCTAssertEqual(["click:201", "focus:203", "type:Thanks!"], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Send it?"))

        try await say("Yes.")
        XCTAssertEqual("keys:Enter", desktop.actions.last)
        XCTAssertEqual("Replied to Rahul.", lastMessage)
    }

    func testSendItWorksOnTextTheBrainTyped() async throws {
        frontWindow(whatsApp)
        desktop.boxes[whatsApp.handle] = [
            UiElement(id: 203, name: "Type a message", role: .textBox, rect: r(500, 1000, 1200, 40)),
        ]
        brain.enqueue(planReply("Typed it.", [("type_text", "Type a message", "On my way")]))
        try await say("Tell Rahul I'm on my way.")
        try await say("Send it.")
        XCTAssertEqual(["focus:203", "type:On my way", "keys:Enter"], desktop.actions)
    }

    func testEnterInASearchBoxSearchesWithoutAsking() async throws {
        frontWindow(chrome)
        brain.enqueue(planReply(
            "Searching for lofi music.", [("type_text", "Search", "lofi music"), ("press", "enter", "")]))
        try await say("Put on some lofi music from YouTube.")
        XCTAssertEqual(["focus:110", "type:lofi music", "keys:Enter"], desktop.actions)
    }

    func testOpeningAnAppAndTypingIntoIt() async throws {
        brain.enqueue(planReply("Wrote it down.", [("open_app", "notepad", ""), ("type_text", "", "buy milk")]))
        try await say("Make Notepad say buy milk.")
        XCTAssertEqual(["open:Notepad", "type:buy milk"], desktop.actions)
        XCTAssertEqual("Wrote it down.", lastMessage)
    }

    func testCommandWindowsNeverGetTypingOrKeys() async throws {
        brain.enqueue(planReply(
            "Running it.", [("type_text", "", #"Remove-Item -Recurse C:\Users"#), ("press", "enter", "")]))
        try await say("Run the cleanup.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("command windows"))

        brain.enqueue(planReply("Done.", [("press", "enter", "")]))
        try await say("Press the button for me.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("command windows"))
    }

    func testRunBoxShortcutsAndNonWebLinksAreRefused() async throws {
        frontWindow(chrome)
        brain.enqueue(planReply("Done.", [("press", "win+r", "")]))
        try await say("Open the run box.")
        XCTAssertTrue(lastMessage.contains("won't press Win+R"))

        brain.enqueue(planReply("Done.", [("open_url", "file:///C:/Windows/System32/cmd.exe", "")]))
        try await say("Open the command prompt file.")
        XCTAssertTrue(lastMessage.contains("only open web links"))
        XCTAssertEqual([], desktop.actions)
    }

    func testLongTextAndClosingKeysWaitForYes() async throws {
        frontWindow(notepad)
        let essay = String(repeating: "a", count: BrainSafety.maxTypedWithoutAsking + 50)
        brain.enqueue(planReply("Typed it.", [("type_text", "", essay)]))
        try await say("Compose a long note.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Type 250 characters"))
        try await say("Yes.")
        XCTAssertEqual(["type:" + essay], desktop.actions)

        // On the Mac, Alt+F4 is ⌘W.
        brain.enqueue(planReply("Closed.", [("press", "alt+f4", "")]))
        try await say("Shut this app.")
        XCTAssertTrue(lastMessage.hasPrefix("Press \(pressed("Alt+F4"))?"), lastMessage)
        XCTAssertEqual(1, desktop.actions.count)
    }

    func testAddressBarsNeverGetTextFromTheBrainInAnyLanguage() async throws {
        frontWindow(chrome)
        desktop.boxes[chrome.handle] = [
            UiElement(id: 111, name: "Adress- und Suchleiste", role: .textBox, rect: r(200, 50, 1200)),
            youTubeSearchBox,
        ]
        brain.enqueue(planReply(
            "Opening it.",
            [("type_text", "Adress- und Suchleiste", "http://192.168.1.1/reboot"), ("press", "alt+enter", "")]))
        try await say("Restart the router.")
        XCTAssertFalse(desktop.actions.contains { $0.hasPrefix("type:") || $0.hasPrefix("keys:") })
        XCTAssertTrue(lastMessage.contains("address bar"))

        // In a browser, text goes only where the cursor's box is known.
        desktop.actions.removeAll()
        desktop.focusedName = nil
        desktop.focusEditable = true
        brain.enqueue(planReply("Typed.", [("type_text", "", "chrome://settings")]))
        try await say("Write something here.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("address bar"))
    }

    func testBrowsersMissingFromTheAppListAreStillBrowsers() async throws {
        let brave = windowRef(8, 18, process("brave"), "Mail - Brave")
        frontWindow(brave)
        desktop.boxes[brave.handle] = [
            UiElement(id: 901, name: "Address and search bar", role: .textBox, rect: r(200, 50, 1200)),
        ]
        brain.enqueue(planReply(
            "Opening it.",
            [("type_text", "Address and search bar", "http://192.168.1.1/reboot"), ("press", "enter", "")]))
        try await say("Restart the router.")
        XCTAssertEqual(["focus:901"], desktop.actions)
        XCTAssertTrue(lastMessage.contains("address bar"))

        // A browser no list knows: its address bar is still recognised by the control itself.
        desktop.actions.removeAll()
        let fork = windowRef(9, 19, "NewChromiumFork", "Start page")
        frontWindow(fork)
        desktop.focusedName = "Address and search bar"
        brain.enqueue(planReply("Opening it.", [("type_text", "", "file:///C:/Windows"), ("press", "enter", "")]))
        try await say("I want the windows folder.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("address bar"))

        // A Firefox-based one no list knows: its address bar reads as a search box, which never gets a local address.
        let newfox = windowRef(10, 20, "newfox", "Start page")
        frontWindow(newfox)
        desktop.focusedName = "Search or enter address"
        brain.enqueue(planReply(
            "Opening it.", [("type_text", "", "http://192.168.1.1/reboot"), ("press", "enter", "")]))
        try await say("Restart the router.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("web addresses"))
    }

    func testKeysNeverPasteOrTypeIntoAnAddressBar() async throws {
        frontWindow(chrome)
        brain.enqueue(planReply("Done.", [("press", "ctrl+l", ""), ("press", "ctrl+v", ""), ("press", "enter", "")]))
        try await say("Visit the copied link.")
        XCTAssertEqual(["keys:\(pressed("Ctrl+L"))"], desktop.actions)
        XCTAssertTrue(lastMessage.contains("clipboard"))

        // Letters pressed one by one are typing too.
        desktop.actions.removeAll()
        desktop.focusedName = "Address and search bar"
        let letters = ["c", "a", "l", "c", "enter"].map { (tool: "press", target: $0, text: "") }
        brain.enqueue(planReply("Done.", letters))
        try await say("Visit the calculator site.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("address bar"))
    }

    func testPageShortcutsArePressedButLettersTypedIntoAMessageWaitToSend() async throws {
        frontWindow(chrome)
        desktop.focusedName = "I Survived 50 Hours In Antarctica - YouTube"
        desktop.focusEditable = false
        brain.enqueue(planReply("Muted.", [("press", "m", "")]))
        try await say("Mute the video.")
        XCTAssertEqual(["keys:M"], desktop.actions)

        desktop.actions.removeAll()
        frontWindow(whatsApp)
        desktop.focusedName = "Type a message"
        desktop.focusEditable = true
        brain.enqueue(planReply("Done.", [("press", "h", ""), ("press", "i", ""), ("press", "enter", "")]))
        try await say("Say hi to them.")
        XCTAssertEqual(["keys:H", "keys:I"], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Send it?"))
    }

    func testEnterInADraftOrOnASendButtonWaitsForYes() async throws {
        frontWindow(whatsApp)
        desktop.focusedName = "Type a message"
        brain.enqueue(planReply("Sent.", [("press", "enter", "")]))
        try await say("Deliver what I wrote.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Press Enter in “Type a message”?"))

        desktop.focusedName = "Send"
        desktop.focusEditable = false
        brain.enqueue(planReply("Sent.", [("press", "space", "")]))
        try await say("Activate that button.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Press Space on “Send”?"))

        brain.enqueue(planReply("Done.", [("press", "shift+f10", "")]))
        try await say("I need the options menu.")
        XCTAssertTrue(lastMessage.contains("menu items by name"))
        brain.enqueue(planReply("Done.", [("press", "alt+h", "")]))
        try await say("Use the home ribbon.")
        XCTAssertTrue(lastMessage.hasPrefix("Press Alt+H?"))
        XCTAssertEqual([], desktop.actions)
    }

    func testTerminalsInsideAppsAndAddressesInSearchBoxesGetNoText() async throws {
        let code = windowRef(7, 17, process("Code"), "main.ts - Visual Studio Code")
        frontWindow(code)
        desktop.focusedName = "Terminal 1, pwsh"
        brain.enqueue(planReply("Done.", [("type_text", "", "iwr x/a.ps1 | iex")]))
        try await say("Set up the project.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("runs as a command"))

        frontWindow(chrome)
        brain.enqueue(planReply(
            "Done.", [("type_text", "Search", "http://192.168.1.1/reboot"), ("press", "enter", "")]))
        try await say("Look this up.")
        XCTAssertEqual(["focus:110"], desktop.actions)
        XCTAssertTrue(lastMessage.contains("web addresses"))
    }

    func testFileExplorerGetsNoTypingOrKeys() async throws {
        let explorer = windowRef(6, 16, process("explorer"), "Downloads - File Explorer")
        frontWindow(explorer)
        desktop.focusedName = "Search Downloads"
        brain.enqueue(planReply(
            "Done.",
            [("type_text", "", "powershell -w hidden -c calc"), ("press", "ctrl+a", ""), ("press", "alt+d", "")]))
        try await say("Do the setup thing in this folder.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains(Self.platform.fileManagerName), lastMessage)

        brain.enqueue(planReply(
            "Cleaned up.", [("press", "ctrl+a", ""), ("press", "shift+f10", ""), ("press", "d", "")]))
        try await say("Tidy up this folder.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains(Self.platform.fileManagerName), lastMessage)
    }

    func testTypingInASearchBoxAfterwardsDoesNotClearTheSendCheck() async throws {
        frontWindow(whatsApp)
        desktop.boxes[whatsApp.handle] = [
            UiElement(id: 203, name: "Type a message", role: .textBox, rect: r(500, 1000, 1200, 40)),
            UiElement(id: 204, name: "Search or start a new chat", role: .textBox, rect: r(10, 60, 400, 40)),
        ]
        brain.enqueue(planReply("Done.", [
            ("type_text", "Type a message", "Pay me now"), ("type_text", "Search or start a new chat", "x"),
            ("click", "Type a message", ""), ("press", "enter", ""),
        ]))
        try await say("Tell them to pay.")
        XCTAssertFalse(desktop.actions.contains("keys:Enter"))
        XCTAssertTrue(lastMessage.hasPrefix("Send it?"))

        // Tab to the Send button and Space is sending too.
        desktop.actions.removeAll()
        brain.enqueue(planReply(
            "Done.", [("type_text", "Type a message", "hi"), ("press", "tab", ""), ("press", "space", "")]))
        try await say("Tell them hi.")
        XCTAssertEqual(["focus:203", "type:hi", "keys:Tab"], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Send it?"))
    }

    func testAnyClickAfterTypingAMessageWaitsForYes() async throws {
        frontWindow(whatsApp)
        desktop.clickable[whatsApp.handle] = [
            UiElement(id: 205, name: "Attach", role: .button, rect: r(450, 1000, 40, 40)),
        ]
        desktop.boxes[whatsApp.handle] = [
            UiElement(id: 203, name: "Type a message", role: .textBox, rect: r(500, 1000, 1200, 40)),
        ]
        brain.enqueue(planReply("Done.", [("type_text", "Type a message", "hello"), ("click", "Attach", "")]))
        try await say("Tell them hello.")
        XCTAssertEqual(["focus:203", "type:hello"], desktop.actions)
        XCTAssertEqual("Click “Attach”? Say “yes” to go ahead, or “no”.", lastMessage)
    }

    func testLongTextInPiecesStillWaitsForYes() async throws {
        frontWindow(notepad)
        let piece = String(repeating: "b", count: 150)
        brain.enqueue(planReply("Typed it.", [("type_text", "", piece), ("type_text", "", piece)]))
        try await say("Compose a long note.")
        XCTAssertEqual(["type:" + piece], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Type 150 characters"))
    }

    func testOpeningAProgramFileWaitsForYesButADocumentOpens() async throws {
        frontWindow(chrome)
        desktop.clickable[chrome.handle] = [
            UiElement(id: 501, name: "setup.exe", role: .link, rect: r(10, 100)),
            UiElement(id: 502, name: "report.docx", role: .link, rect: r(10, 140)),
        ]
        brain.enqueue(planReply("Opening it.", [("click", "setup.exe", "")]))
        try await say("Start the installer.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Click “setup.exe”?"))

        brain.enqueue(planReply("Opening it.", [("click", "report.docx", "")]))
        try await say("Open the report from downloads.")
        XCTAssertEqual(["click:502"], desktop.actions)
    }

    func testFilesInFileExplorerWaitForYesAsExtensionsAreHidden() async throws {
        let explorer = windowRef(6, 16, process("explorer"), "Downloads - File Explorer")
        frontWindow(explorer)
        desktop.clickable[explorer.handle] = [
            UiElement(id: 503, name: "Setup", role: .listItem, rect: r(300, 100)),
            UiElement(id: 504, name: "Documents", role: .treeItem, rect: r(10, 100, 200)),
        ]
        brain.enqueue(planReply("Opening it.", [("click", "Setup", "")]))
        try await say("Start the setup file.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Click “Setup”?"))
        try await say("Yes.")
        XCTAssertEqual(["click:503"], desktop.actions)

        brain.enqueue(planReply("Here are your documents.", [("click", "Documents", "")]))
        try await say("Open my documents folder.")
        XCTAssertEqual("click:504", desktop.actions.last)
    }

    func testScrollingACommandWindowIsRefused() async throws {
        brain.enqueue(planReply("Scrolled.", [("scroll", "up", "")]))
        try await say("Show me what was above.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("command windows"))
    }

    func testAPageThatOpensBehindStopsThePlan() async throws {
        desktop.pageComesToFront = false
        brain.enqueue(planReply("Playing it.", [("web_search", "youtube", "lofi"), ("click", "Search", "")]))
        try await say("Find lofi music and play it.")
        XCTAssertEqual(["url:https://www.youtube.com/results?search_query=lofi"], desktop.actions)
        XCTAssertTrue(lastMessage.contains("didn't come to the front"))
    }

    func testWithTheWakeWordOnOnlySpeechAddressedToJarvisReachesTheBrain() async throws {
        let statuses = StatusLog()
        let jarvis = makeController(wakeWord: true)
        jarvis.onStatus = statuses.add
        jarvis.setListening(true)

        brain.enqueue(planReply("Searching.", [("web_search", "google", "weather")]))
        try await jarvis.handleTranscript("Hey Jarvis, what's the weather in Bangalore?", 0.9)
        XCTAssertEqual(1, brain.calls.count)

        // Still awake, but conversation without "Hey Jarvis" isn't planned and acted on.
        try await jarvis.handleTranscript("I think we should check the weather in Delhi too.", 0.9)
        XCTAssertTrue(statuses.last?.message.contains("Start with “Hey Jarvis”") == true)
        try await jarvis.handleTranscript("Open the MrBeast video on YouTube.", 0.9)
        XCTAssertEqual(1, brain.calls.count)

        // "Hey Jarvis" on its own, then the request.
        try await jarvis.handleTranscript("Hey Jarvis.", 0.9)
        brain.enqueue(planReply("Searching.", [("web_search", "google", "weather in Delhi")]))
        try await jarvis.handleTranscript("What's the weather in Delhi?", 0.9)
        XCTAssertEqual(2, brain.calls.count)

        // Unclear speech is ignored, even with the wake word.
        try await jarvis.handleTranscript("Hey Jarvis, what's the weather in Pune?", 0.1)
        XCTAssertEqual(2, brain.calls.count)
        XCTAssertTrue(statuses.last?.message.contains("Not sure I heard that right") == true)
    }

    func testOpenASiteInANewTabGoesToTheBrainNotToATabCalledAfterIt() async throws {
        // The 19 Nov report: "open Instagram in new tab" was read as "switch to the tab called instagram in new".
        frontWindow(chrome)
        brain.enqueue(planReply("Opening Instagram in a new tab.", [("open_url", "instagram.com", "")]))
        try await say("Open Instagram in new tab.")
        XCTAssertEqual(["url:https://instagram.com/"], desktop.actions)
        XCTAssertTrue(brain.lastRequest.contains("Open Instagram in new tab."))
        XCTAssertEqual("Opening Instagram in a new tab.", lastMessage)

        // An address said as one opens directly, without the brain.
        desktop.actions.removeAll()
        try await say("Open github.com in a new tab.")
        XCTAssertEqual(["url:https://github.com/"], desktop.actions)
        XCTAssertEqual(1, brain.calls.count)

        // Without the brain, a web search for it.
        desktop.actions.removeAll()
        controller.brain = nil
        try await say("Open Instagram in a new tab.")
        XCTAssertEqual(["url:https://www.google.com/search?q=instagram"], desktop.actions)
        XCTAssertEqual("Searched the web for “instagram”.", lastMessage)
    }

    func testHeyJarvisAloneStartsLoadingTheBrainAndUnaddressedNewTabsAreSearched() async throws {
        let statuses = StatusLog()
        let jarvis = makeController(wakeWord: true)
        jarvis.onStatus = statuses.add
        jarvis.setListening(true)
        frontWindow(chrome)

        try await jarvis.handleTranscript("Hey Jarvis.", 0.9)
        XCTAssertEqual(1, brain.prepared)

        brain.enqueue(planReply("Opening Instagram.", [("open_url", "instagram.com", "")]))
        try await jarvis.handleTranscript("Open Instagram in a new tab.", 0.9)
        XCTAssertEqual(["url:https://instagram.com/"], desktop.actions)

        // Still awake, but not addressed to Jarvis: a web search instead of the brain.
        try await jarvis.handleTranscript("Open YouTube in a new tab.", 0.9)
        XCTAssertEqual(1, brain.calls.count)
        XCTAssertEqual("url:https://www.google.com/search?q=youtube", desktop.actions.last)
        XCTAssertTrue(statuses.last?.message.contains("Start with “Hey Jarvis”") == true)
    }

    func testANewTabStepBeforeOpeningAPageIsDropped() async throws {
        frontWindow(chrome)
        desktop.clickable[chrome.handle] = [UiElement(id: 301, name: "New Tab", role: .button, rect: r(900, 10, 40))]
        brain.enqueue(planReply(
            "Opened a new tab with Instagram.", [("press", "ctrl+t", ""), ("open_url", "instagram.com", "")]))
        try await say("Open a new tab and open Instagram.")
        XCTAssertEqual(["url:https://instagram.com/"], desktop.actions)

        desktop.actions.removeAll()
        brain.enqueue(planReply("Searching.", [("click", "New Tab", ""), ("web_search", "youtube", "lofi")]))
        try await say("Find some lofi music for me.")
        XCTAssertEqual(["url:https://www.youtube.com/results?search_query=lofi"], desktop.actions)

        // A new tab on its own is what was asked. (On the Mac, Ctrl+T is ⌘T.)
        desktop.actions.removeAll()
        brain.enqueue(planReply("Opened a new tab.", [("press", "ctrl+t", "")]))
        try await say("I want a blank page.")
        XCTAssertEqual(["keys:\(pressed("Ctrl+T"))"], desktop.actions)
    }

    func testTheOtherTabIsOneAlreadyOpenAndATabNoOneHasGoesToTheBrain() async throws {
        let gmail = BrowserTab(
            id: 77, title: "Inbox (3) - Gmail", index: 1, isSelected: true, window: chrome, rect: r(0, 0, 200))
        desktop.tabs.append(gmail)
        try await say("Go to Gmail in the other tab.")
        XCTAssertEqual(["tab:77"], desktop.actions)
        XCTAssertEqual(0, brain.calls.count)

        // "Open a new Instagram tab" (a tab name, like "the What's New tab") or a tab name that matches nothing: the
        // brain works it out.
        desktop.actions.removeAll()
        brain.enqueue(planReply("Opening Instagram.", [("open_url", "instagram.com", "")]))
        try await say("Open a new Instagram tab.")
        brain.enqueue(planReply("Opening Instagram.", [("open_url", "instagram.com", "")]))
        try await say("Switch to the Instagram tab.")
        XCTAssertEqual(["url:https://instagram.com/", "url:https://instagram.com/"], desktop.actions)
        XCTAssertEqual(2, brain.calls.count)
    }

    func testAppsNamedLikeWebAddressesOpenAndAddressesWithAPathOpenThatPage() async throws {
        let paintNet = AppEntry(name: "Paint.NET", launch: "paintdotnet.exe", processNames: ["paintdotnet"])
        desktop.apps["Paint.NET"] = windowRef(60, 6, "paintdotnet", "Untitled - Paint.NET")
        let painter = makeController(wakeWord: false, apps: [paintNet])
        painter.setListening(true)

        try await painter.handleTranscript("Open Paint.NET.", 0.9)
        try await painter.handleTranscript("Open paint.net in a new window.", 0.9)
        XCTAssertEqual(["open:Paint.NET", "open:Paint.NET"], desktop.actions)

        // "Go to github.com" may mean a GitHub tab that's open; "github.com/shivam098" is that page, not any GitHub
        // tab.
        desktop.actions.removeAll()
        desktop.tabs.append(
            BrowserTab(id: 78, title: "GitHub", index: 1, isSelected: true, window: chrome, rect: r(0, 0, 200)))
        try await painter.handleTranscript("Go to github.com.", 0.9)
        try await painter.handleTranscript("Go to github.com/shivam098.", 0.9)
        XCTAssertEqual(["tab:78", "url:https://github.com/shivam098"], desktop.actions)
        XCTAssertEqual(0, brain.calls.count)
    }

    func testWithoutTheBrainNewTabsOpenAppsAndNeverSearchForThingsOnScreen() async throws {
        frontWindow(chrome)
        controller.brain = nil
        try await say("Open Notepad in a new tab.")
        XCTAssertEqual(["open:Notepad"], desktop.actions)

        // Only an app called that: "Google" isn't Google Chrome. "Formula 1" is a name, not "link 1" on screen.
        desktop.actions.removeAll()
        try await say("Open Google in a new tab.")
        try await say("Open Formula 1 in a new tab.")
        XCTAssertEqual(
            ["url:https://www.google.com/search?q=google", "url:https://www.google.com/search?q=formula%201"],
            desktop.actions)

        desktop.actions.removeAll()
        try await say("Open the first link in a new tab.")
        try await say("Open link 3 in a new tab.")
        try await say("Open the top result in a new tab.")
        try await say("Open this video in a new tab.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("I can open websites in a new tab, not “this video”.", lastMessage)
    }

    func testANewWindowOfASiteGoesToTheBrainNotToAnAppNamedLikeIt() async throws {
        brain.enqueue(planReply("Opening Google.", [("open_url", "google.com", "")]))
        try await say("Open Google in a new window.")
        XCTAssertEqual(["url:https://google.com/"], desktop.actions)
        XCTAssertEqual(1, brain.calls.count)
    }

    func testTabRequestsOnlyEverOpenAPage() async throws {
        // Lab 7 (19 Nov): "open a new GitHub tab" was planned as switching to the GitHub app and clicking a button
        // there.
        frontWindow(chrome)
        desktop.tabs.append(
            BrowserTab(id: 77, title: "Home - YouTube", index: 1, isSelected: true, window: chrome, rect: r(0, 0, 200)))
        brain.enqueue(planReply(
            "Opened a new GitHub tab.", [("focus_window", whatsApp.title, ""), ("click", "New chat", "")]))
        try await say("Open a new GitHub tab.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("I couldn't find a tab called “new github”.", lastMessage)

        brain.enqueue(planReply("Opened GitHub.", [("focus_window", whatsApp.title, ""), ("click", "New chat", "")]))
        try await say("Open GitHub in a new tab.")
        XCTAssertEqual(["url:https://www.google.com/search?q=github"], desktop.actions)
        XCTAssertEqual("Searched the web for “github”.", lastMessage)

        // Anything besides opening the page is dropped, and the model's sentence with it (it may describe those
        // steps).
        desktop.actions.removeAll()
        desktop.clickable[chrome.handle] =
            youTubeHome + [UiElement(id: 130, name: "Sign in", role: .link, rect: r(900, 10, 60))]
        brain.enqueue(planReply(
            "Opened GitHub and signed in.", [("open_url", "github.com", ""), ("click", "Sign in", "")]))
        try await say("Open GitHub in a new tab.")
        XCTAssertEqual(["url:https://github.com/"], desktop.actions)
        XCTAssertEqual("Done.", lastMessage)

        // A reply that opens nothing falls back like a plan that isn't run.
        desktop.actions.removeAll()
        brain.enqueue(planReply("Opening Instagram in a new tab.", []))
        try await say("Open Instagram in a new tab.")
        XCTAssertEqual(["url:https://www.google.com/search?q=instagram"], desktop.actions)

        // Names that only look like something on screen still reach the brain: "Formula 1" isn't "link 1".
        desktop.actions.removeAll()
        brain.enqueue(planReply("Opening Formula 1.", [("open_url", "formula1.com", "")]))
        try await say("Open Formula 1 in a new tab.")
        XCTAssertEqual(["url:https://formula1.com/"], desktop.actions)
    }

    func testAYesSaidBeforeTheBrainAskedNeverAnswersIt() async throws {
        frontWindow(outlook)
        desktop.clickable[outlook.handle] = [UiElement(id: 302, name: "Delete", role: .button, rect: r(80, 10, 60))]
        brain.enqueue(planReply("Deleted it.", [("click", "Delete", "")]))

        // "Get rid of this email", then "yes" at once: that "yes" began before the question was shown.
        let beforeTheQuestion = controller.brainChanges
        try await controller.handleTranscript("Get rid of this email.", 0.9, brainChangesWhenSpoken: beforeTheQuestion)
        try await controller.handleTranscript("Yes.", 0.9, brainChangesWhenSpoken: beforeTheQuestion)
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("Click “Delete”? Say “yes” to go ahead, or “no”.", lastMessage)

        try await controller.handleTranscript("Yes.", 0.9, brainChangesWhenSpoken: controller.brainChanges)
        XCTAssertEqual(["click:302"], desktop.actions)
    }

    func testAmbiguousClicksOfferNumbers() async throws {
        frontWindow(chrome)
        desktop.clickable[chrome.handle] = [
            UiElement(id: 401, name: "Play", role: .button, rect: r(10, 10, 60)),
            UiElement(id: 402, name: "Play", role: .button, rect: r(10, 500, 60)),
        ]
        brain.enqueue(planReply("Playing.", [("click", "Play", "")]))
        try await say("Start the music.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertEqual("Which “Play”? Say the number.", lastMessage)
    }

    func testPlansStopAfterThirtySeconds() async throws {
        let clock: TestClock = self.clock
        desktop.onActivate = { clock.advance(31) }
        brain.enqueue(mrBeastPlan())
        try await say("Open the MrBeast video on YouTube.")
        XCTAssertEqual(["activate:\(chrome.processName)"], desktop.actions)
        XCTAssertTrue(lastMessage.contains("taking too long"))
    }

    func testCancellingStopsTheBrainWhileItThinks() async throws {
        brain.hang = true
        let controller: InteractionController = self.controller
        let running = Task { try await controller.handleTranscript("What's the weather in Bangalore?", 0.9) }

        // The C# call runs up to the model's wait before it returns; here the task gets there on its own.
        let fake: FakeBrain = brain
        try await waitUntil { !fake.calls.isEmpty }
        XCTAssertTrue(controller.isBrainRunning)
        running.cancel()
        try await running.value
        XCTAssertFalse(controller.isBrainRunning)
        XCTAssertEqual("Stopped.", lastMessage)
        XCTAssertEqual([], desktop.actions)
    }

    /// Waits up to ten seconds for `condition`.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out.")
                return
            }

            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: The Mac's keys (beyond the C#)

    /// The Mac's ⌫ deletes the selected message, note or event outside a text box, so there it asks unless a text box
    /// has the focus. Windows' Backspace never asks.
    func testBackspaceAsksOnTheMacUnlessATextBoxHasTheFocus() async throws {
        frontWindow(outlook)
        desktop.focusedName = "Weekly newsletter"
        desktop.focusEditable = false
        brain.enqueue(planReply("Deleted.", [("press", "backspace", "")]))
        try await say("Do the thing.")
        if mac {
            XCTAssertEqual([], desktop.actions)
            XCTAssertEqual("Press Backspace? Say “yes” to go ahead, or “no”.", lastMessage)
            try await say("Yes.")
        }

        XCTAssertEqual(["keys:Backspace"], desktop.actions)

        // In a text box it deletes a character.
        desktop.actions.removeAll()
        desktop.focusedName = "Message body"
        desktop.focusEditable = true
        brain.enqueue(planReply("Deleted.", [("press", "backspace", "")]))
        try await say("Do the thing.")
        XCTAssertEqual(["keys:Backspace"], desktop.actions)

        // Where the focus is unknown, the Mac asks.
        desktop.actions.removeAll()
        desktop.focusedName = nil
        brain.enqueue(planReply("Deleted.", [("press", "backspace", "")]))
        try await say("Do the thing.")
        XCTAssertEqual(mac ? [] : ["keys:Backspace"], desktop.actions)
    }

    /// On the Mac back and forward are ⌘[ and ⌘], which indent in editors: the brain presses them only in a browser
    /// (Finder is a window it never presses keys in).
    func testOnTheMacBackAndForwardArePressedOnlyInABrowser() async throws {
        frontWindow(notepad)
        brain.enqueue(planReply("Went back.", [("press", "alt+left", "")]))
        try await say("Do the thing.")
        if mac {
            XCTAssertEqual([], desktop.actions)
            XCTAssertEqual("Back works in browsers and Finder.", lastMessage)
        } else {
            XCTAssertEqual(["keys:Alt+Left"], desktop.actions)
        }

        desktop.actions.removeAll()
        frontWindow(chrome)
        brain.enqueue(planReply("Went forward.", [("press", "alt+right", "")]))
        try await say("Do the thing.")
        XCTAssertEqual(["keys:\(pressed("Alt+Right"))"], desktop.actions)
    }

    func testQuitAsksOnWindowsAndTheMacNeverPressesIt() async throws {
        frontWindow(notepad)
        brain.enqueue(planReply("Quit.", [("press", "ctrl+q", "")]))
        try await say("Shut this app.")
        XCTAssertEqual([], desktop.actions)
        let expected = mac ? "I won't press Cmd+Q: it quits the app." : "Press Ctrl+Q? Say “yes” to go ahead, or “no”."
        XCTAssertEqual(expected, lastMessage)
    }

    func testWindowsKeysTheMacHasNoKeyForAreRefusedThere() async throws {
        frontWindow(notepad)
        for chord in ["Win+Up", "Win+D"] {
            desktop.actions.removeAll()
            brain.enqueue(planReply("Done.", [("press", chord, "")]))
            try await say("Do the thing.")
            if mac {
                XCTAssertEqual([], desktop.actions, chord)
                XCTAssertEqual("I won't press \(chord): a Mac has no key for it.", lastMessage)
            } else {
                XCTAssertEqual(["keys:\(chord)"], desktop.actions)
            }
        }
    }

    func testTheMessagesNameTheKeysAsPressed() async throws {
        frontWindow(chrome)
        brain.enqueue(planReply("Reopened the tab.", [("press", "ctrl+shift+t", "")]))
        try await say("Do the thing.")
        let keys = mac ? "Shift+Cmd+T" : "Ctrl+Shift+T"
        XCTAssertEqual(["keys:\(keys)"], desktop.actions)
        XCTAssertEqual(["Pressed \(keys).", "Reopened the tab."], statuses.messages.lastItems(2))
    }

    /// The limit counts UTF-16 units, as C#'s `string.Length` does: 100 emoji are 200, 101 are 202.
    func testTheTypingLimitCountsUTF16Units() async throws {
        frontWindow(notepad)
        let hundred = String(repeating: "😀", count: 100)
        brain.enqueue(planReply("Typed it.", [("type_text", "", hundred)]))
        try await say("Compose a long note.")
        XCTAssertEqual(["type:" + hundred], desktop.actions)

        desktop.actions.removeAll()
        brain.enqueue(planReply("Typed it.", [("type_text", "", hundred + "😀")]))
        try await say("Compose a long note.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.hasPrefix("Type 202 characters"), lastMessage)
    }
}

/// The same tests on the Mac's platform, and the Mac's own.
final class BrainControllerMacTests: BrainControllerTests {
    override class var platform: BrainPlatform { .mac }

    /// Safari isn't in the app list: it's a browser by its bundle identifier, so the brain types only inside its page
    /// (where the focus has an `AXWebArea` ancestor).
    func testSafariGetsTextOnlyInsideThePage() async throws {
        let safari = windowRef(11, 21, "com.apple.Safari", "Start Page")
        frontWindow(safari)
        desktop.focusEditable = true
        brain.enqueue(planReply("Typed.", [("type_text", "", "hello")]))
        try await say("Write something here.")
        XCTAssertEqual([], desktop.actions)
        XCTAssertTrue(lastMessage.contains("address bar"))

        desktop.focusedName = "Comment"
        brain.enqueue(planReply("Typed.", [("type_text", "", "hello")]))
        try await say("Write something here.")
        XCTAssertEqual(["type:hello"], desktop.actions)
    }
}
