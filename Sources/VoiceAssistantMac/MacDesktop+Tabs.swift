import AppKit
import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore

/// Browser tabs (windows-voice-assistant `WindowsDesktop.Navigation`: `ListTabsAsync`, `SelectTabAsync`). Chrome, Edge,
/// Brave and the other Chromium browsers, and Firefox, describe their tab strips to Accessibility; a Chromium browser
/// is woken first (`wake`, AXEnhancedUserInterface). Safari's tabs come from AppleScript (docs/design.md), which needs
/// the Automation permission for Safari: it's asked for the first time Safari's tabs are wanted, and they're listed
/// from then on.
extension MacDesktop {
    /// The browsers whose tabs come from AppleScript.
    static let scriptedBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// The longest one AppleScript may take, inside the 4-second limit.
    static let scriptTime: TimeInterval = 3

    /// A tab of a tab strip, as Accessibility describes it.
    struct TabItem {
        let element: AnyObject
        let name: String
        let rect: ScreenRect
        let selected: Bool
    }

    /// A Safari window as AppleScript lists it: its id, its title, which tab shows (from 1) and its tabs.
    struct ScriptedWindow: Equatable {
        var id: Int
        var title: String
        var current: Int
        var tabs: [ScriptedPage]
    }

    /// A Safari tab's title and address, as AppleScript lists them.
    struct ScriptedPage: Equatable {
        var title: String
        var url: String
    }

    /// A Safari tab handed out by a tab scan, for `selectTab`.
    final class ScriptedTab {
        let bundleIdentifier: String
        let windowID: Int
        let index: Int
        let url: String
        let title: String

        init(bundleIdentifier: String, windowID: Int, index: Int, url: String, title: String) {
            self.bundleIdentifier = bundleIdentifier
            self.windowID = windowID
            self.index = index
            self.url = url
            self.title = title
        }
    }

    // MARK: Listing

    /// The tabs of every browser window that shows, the front-most window first, each in tab-strip order (C#'s
    /// `ListTabsAsync`, 4 s at most).
    public func listTabs() async throws -> [BrowserTab] {
        try await scanned("tab scan") { [self] token in scanTabs(token) }
    }

    /// C#'s `ScanTabs`: the tabs of each browser window on screen (not minimized, hidden or on another Space), numbered
    /// from 1 in reading order, across a tab strip or down a vertical one.
    func scanTabs(_ token: WorkToken) -> [BrowserTab] {
        let start = clock.now()
        let onScreen = Set(workspace.windowNumbersFrontToBack())
        var scripted: [pid_t: [ScriptedWindow]] = [:]
        var tabs: [BrowserTab] = []
        for window in browserWindows() where window.info.handle == 0 || onScreen.contains(window.info.handle) {
            if token.isCancelled || clock.now() > start + Self.scanTime {
                break
            }

            if Self.scriptedBrowsers.contains(window.info.processName) {
                tabs += scriptedTabs(window, &scripted, start, token)
            } else {
                tabs += accessibilityTabs(window, start, token)
            }
        }

        let windows = Set(tabs.map { $0.window.handle }).count
        log("tab scan: \(tabs.count) tabs in \(windows) windows, \(milliseconds(since: start)) ms")
        return tabs
    }

    /// A window's tabs through Accessibility, as C#'s `ScanTabs` reads TabItems. A Chromium browser this desktop
    /// hasn't woken yet is woken first (`wake`), and given until `wakeWait` after `start` to describe its tab strip.
    func accessibilityTabs(_ window: AppWindow, _ start: TimeInterval, _ token: WorkToken) -> [BrowserTab] {
        let woke = wake(window.info)
        var items = tabItems(window.element, token, deadline: start + Self.scanTime)
        while woke, items.isEmpty, !token.isCancelled, clock.now() + 0.25 <= start + Self.wakeWait {
            clock.sleep(0.25)
            items = tabItems(window.element, token, deadline: start + Self.scanTime)
        }

        return items.enumerated().map { index, item in
            BrowserTab(
                id: registry.register(item.element), title: item.name, index: index + 1, isSelected: item.selected,
                window: window.info, rect: item.rect)
        }
    }

    /// The tab strip's tabs (`isTab`), named and with a frame, in reading order; selected when their value or
    /// AXSelected says so. Tab controls inside the window's pages (and an installed web app's whole page) aren't
    /// browser tabs, so pages aren't walked.
    func tabItems(_ root: AnyObject, _ token: WorkToken, deadline: TimeInterval? = nil) -> [TabItem] {
        var items: [TabItem] = []
        scan(root, token, pages: false, deadline: deadline) { element, node, place in
            guard node.role == kAXRadioButtonRole, Self.isTab(node, place), let rect = place.rect, !rect.isEmpty
            else { return true }
            guard let name = clickableName(element, node, inPage: false), !name.isEmpty else { return true }
            items.append(TabItem(element: element, name: name, rect: rect, selected: isShownTab(element)))
            return true
        }

        return TargetResolver.sortReadingOrder(items) { $0.rect }
    }

    /// Whether a tab of a tab strip shows: its value (Chromium's) or AXSelected says so.
    func isShownTab(_ element: AnyObject) -> Bool {
        if (try? ax.number(kAXValueAttribute, of: element)) == 1 {
            return true
        }

        return (try? ax.number(kAXSelectedAttribute, of: element)) == 1
    }

    /// A Safari window's tabs, from AppleScript: all of Safari's windows are read once a scan, then each is matched to
    /// its window by number, else by title, front-most first. A tab's frame is its tab-strip button's when
    /// Accessibility shows as many buttons, else empty, and no badge goes on it.
    func scriptedTabs(
        _ window: AppWindow, _ read: inout [pid_t: [ScriptedWindow]], _ start: TimeInterval, _ token: WorkToken
    ) -> [BrowserTab] {
        guard let pid = pid_t(exactly: window.info.processId) else { return [] }
        if read[pid] == nil {
            read[pid] = scriptedWindows(window.info.processName)
        }

        guard var windows = read[pid], let found = Self.matchingWindow(window.info, windows) else { return [] }
        let scripted = windows.remove(at: found)
        read[pid] = windows
        let buttons = tabItems(window.element, token, deadline: start + Self.scanTime)
        let noPlace = ScreenRect(x: 0, y: 0, width: 0, height: 0)
        var places: [ScreenRect] = Array(repeating: noPlace, count: scripted.tabs.count)
        if buttons.count == scripted.tabs.count {
            places = buttons.map { $0.rect }
        }

        var tabs: [BrowserTab] = []
        for (index, page) in scripted.tabs.enumerated() {
            let handle = ScriptedTab(
                bundleIdentifier: window.info.processName, windowID: scripted.id, index: index + 1, url: page.url,
                title: page.title)
            let shown: Bool = index + 1 == scripted.current
            tabs.append(
                BrowserTab(
                    id: registry.register(handle), title: page.title, index: index + 1, isSelected: shown,
                    window: window.info, rect: places[index]))
        }

        return tabs
    }

    /// Which of AppleScript's windows `window` is: the one with its number, else the first with its title.
    static func matchingWindow(_ window: WindowInfo, _ windows: [ScriptedWindow]) -> Int? {
        if let byNumber = windows.firstIndex(where: { $0.id == window.handle }) {
            return byNumber
        }

        return windows.firstIndex(where: { $0.title == window.title })
    }

    /// All of the browser's windows and their tabs, through AppleScript. Without the Automation permission there are
    /// none: it's asked for when it hasn't been (macOS shows its prompt), and the tabs come from the next time.
    func scriptedWindows(_ bundleIdentifier: String) -> [ScriptedWindow] {
        guard Self.isBundleIdentifier(bundleIdentifier) else { return [] }
        switch scripts.automation(bundleIdentifier, ask: false) {
        case .denied:
            log("tab scan: not allowed to control the browser (Automation)")
            return []
        case .notAsked:
            askAutomation(bundleIdentifier)
            return []
        case .granted, .unknown:
            break
        }

        switch scripts.run(Self.listScript(bundleIdentifier), arguments: [], timeout: Self.scriptTime) {
        case .output(let text):
            return Self.parseWindows(text)
        case .failed(let code):
            log("tab scan script failed: \(code.map { String($0) } ?? "no error number")")
            return []
        case .timedOut:
            log("tab scan script timed out")
            return []
        }
    }

    /// Asks for the Automation permission off the caller's thread, since macOS's prompt waits for an answer; once at a
    /// time.
    func askAutomation(_ bundleIdentifier: String) {
        guard automationAsks.insert(bundleIdentifier) else { return }
        log("tab scan: asking for permission to control the browser (Automation)")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let answer = scripts.automation(bundleIdentifier, ask: true)
            automationAsks.remove(bundleIdentifier)
            log("Automation permission \(answer == .granted ? "given" : "not given")")
        }
    }

    /// The windows and tabs `listScript` printed.
    static func parseWindows(_ text: String) -> [ScriptedWindow] {
        var windows: [ScriptedWindow] = []
        for line in text.split(separator: "\u{1E}") {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map { String($0) }
            if fields.count >= 4, fields[0] == "W", let id = Int(fields[1]), let current = Int(fields[2]) {
                let title = fields[3...].joined(separator: "\u{1F}")
                windows.append(ScriptedWindow(id: id, title: title, current: current, tabs: []))
            } else if fields.count >= 3, fields[0] == "T", !windows.isEmpty {
                let page = ScriptedPage(title: fields[1], url: fields[2...].joined(separator: "\u{1F}"))
                windows[windows.count - 1].tabs.append(page)
            }
        }

        return windows
    }

    /// A bundle identifier that can go into a script as it is: letters, digits, dots and hyphens.
    static func isBundleIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
        }
    }

    /// The AppleScript that lists the browser's windows that show, and their tabs: a line per window ("W", its id, its
    /// current tab's number and its title) and per tab ("T", its title and address), fields and lines parted by
    /// control characters 31 and 30, which titles and addresses don't hold.
    static func listScript(_ bundleIdentifier: String) -> String {
        """
        set fieldBreak to character id 31
        set lineBreak to character id 30
        set listing to ""
        tell application id "\(bundleIdentifier)"
            repeat with w in windows
                try
                    if visible of w and not miniaturized of w then
                        set windowName to ""
                        try
                            set windowName to name of w
                        end try
                        if windowName is missing value then set windowName to ""
                        set entry to "W" & fieldBreak & (id of w) & fieldBreak & (index of current tab of w)
                        set entry to entry & fieldBreak & windowName & lineBreak
                        repeat with t in tabs of w
                            set tabName to ""
                            set tabAddress to ""
                            try
                                set tabName to name of t
                            end try
                            try
                                set tabAddress to URL of t
                            end try
                            if tabName is missing value then set tabName to ""
                            if tabAddress is missing value then set tabAddress to ""
                            set entry to entry & "T" & fieldBreak & tabName & fieldBreak & tabAddress & lineBreak
                        end repeat
                        set listing to listing & entry
                    end if
                end try
            end repeat
        end tell
        return listing
        """
    }

    /// The AppleScript that makes a tab its window's current tab: window id, tab number, address and title as
    /// arguments. The tab is found again by its address (by its title when it has none), at its number first, should
    /// tabs have moved since the scan; "changed" when it's gone.
    static func selectScript(_ bundleIdentifier: String) -> String {
        """
        on run argv
            set wantedWindow to (item 1 of argv) as integer
            set wantedIndex to (item 2 of argv) as integer
            set wantedAddress to item 3 of argv
            set wantedName to item 4 of argv
            tell application id "\(bundleIdentifier)"
                try
                    set w to window id wantedWindow
                    set total to count of tabs of w
                on error
                    return "changed"
                end try
                set chosen to 0
                repeat with k from 0 to total
                    if k is 0 then
                        set i to wantedIndex
                    else
                        set i to k
                    end if
                    if i >= 1 and i <= total then
                        set candidate to ""
                        try
                            if wantedAddress is "" then
                                set candidate to (name of tab i of w) as text
                            else
                                set candidate to (URL of tab i of w) as text
                            end if
                        end try
                        if wantedAddress is "" and candidate is wantedName then
                            set chosen to i
                        else if wantedAddress is not "" and candidate is wantedAddress then
                            set chosen to i
                        end if
                        if chosen is not 0 then exit repeat
                    end if
                end repeat
                if chosen is 0 then return "changed"
                set current tab of w to tab chosen of w
            end tell
            return "ok"
        end run
        """
    }

    // MARK: Selecting

    /// Brings the tab's window to the front, shows the tab, and checks the window's title follows it (C#'s
    /// `SelectTabAsync`): selected or pressed through Accessibility (`activateElement`), or in Safari made the current
    /// tab through AppleScript. Windows first refuses a browser that runs as administrator; macOS has none.
    public func selectTab(_ tab: BrowserTab) async throws -> DesktopResult {
        if !tab.window.sameWindow(foregroundWindow()) {
            guard let element = windowElement(tab.window) else { return .fail("That tab changed. Try again.") }
            let activated = try await activate(AppWindow(info: tab.window, element: element), "the browser")
            if !activated.success {
                return activated
            }
        }

        guard let entry = registry.lookup(tab.id) else { return .fail("That tab changed. Try again.") }
        let outcome = try await Background.run(Self.accessibilityTimeout) { [self] token -> String? in
            if let scripted = entry.element as? ScriptedTab {
                return selectScripted(scripted)
            }

            return activateElement(entry.element, tab.rect, preferSelect: true, inPage: false, tab.window, token)
        }

        let acted: String?
        switch outcome {
        case .finished(let error):
            acted = error
        case .timedOut:
            log("tab select timed out")
            acted = Self.timedOut
        }

        // A browser that didn't answer may have switched all the same: the title says.
        if let acted, acted != Self.unanswered {
            return .fail("I couldn't switch to that tab (\(acted)).")
        }

        // Verify: the browser window's title follows the active tab.
        let prefix = DotNet.ordinalIgnoreCase(TextUnits.first(NameMatcher.cleanTabTitle(tab.title), 16))
        for attempt in 0..<15 {
            let title = windowTitle(tab.window)
            if prefix.isEmpty || DotNet.ordinalIgnoreCase(NameMatcher.cleanTabTitle(title)).starts(with: prefix) {
                log("tab select ok after \(attempt * 100) ms")
                var shown = tab.window
                shown.title = title
                return .ok("Switched tab.", window: shown)
            }

            try await clock.pause(0.1)
        }

        log("tab select not verified")
        return .fail("The tab didn't change. Click it once, or try “next tab”.")
    }

    /// Makes the tab Safari's current tab through AppleScript. Nil when it did, else why not.
    func selectScripted(_ tab: ScriptedTab) -> String? {
        guard Self.isBundleIdentifier(tab.bundleIdentifier) else { return Self.changedOnScreen }
        let arguments = [String(tab.windowID), String(tab.index), tab.url, tab.title]
        switch scripts.run(Self.selectScript(tab.bundleIdentifier), arguments: arguments, timeout: Self.scriptTime) {
        case .output(let answer):
            return answer == "ok" ? nil : Self.changedOnScreen
        case .failed(let code):
            log("tab select script failed: \(code.map { String($0) } ?? "no error number")")
            return code == -1743 ? "it needs the Automation permission" : "the browser didn't answer"
        case .timedOut:
            return "timed out"
        }
    }

    /// The window's title now (C#'s `GetWindowTitle`); empty when it can't be read.
    func windowTitle(_ window: WindowInfo) -> String {
        windowElement(window).flatMap { try? ax.string(kAXTitleAttribute, of: $0) } ?? ""
    }
}
