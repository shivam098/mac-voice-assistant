import Foundation
import ThumbFreeCore

/// Navigation: tabs, clicking by name, numbered choices, confirmations, choosing a text box, and the current place
/// (windows-voice-assistant's InteractionController.Navigation.cs; its docs/specs/navigation.md specifies them).
extension InteractionController {
    static let pendingTimeout: TimeInterval = 30
    static let genericBoxNames = ["search", "message", "type a message", "comment", "reply", "ask", "chat", "write"]

    enum ChoiceKind {
        case element
        case tab
        case textBox
    }

    struct Choice {
        var number: Int
        var kind: ChoiceKind
        var window: WindowInfo
        var element: UiElement?
        var tab: BrowserTab?
    }

    /// "go to X" or "open X": a web address, a tab, an app, or (last) something in the front window called X.
    func navigate(_ spokenName: String, newWindow: Bool, _ heard: String) async throws -> Bool {
        if !apps.hasExactName(spokenName), let page = BrainSafety.webAddress(spokenName) {
            // "open instagram.com" opens it; "go to youtube.com" first looks for a tab that shows it already (only a
            // site's front page: any GitHub tab isn't "github.com/shivam098"). Paint.NET and Battle.net are apps.
            if !newWindow && page.absolutePath == "/" && page.query.isEmpty,
               let shown = try await trySelectNamedTab(spokenName, heard) {
                return shown
            }

            return try await openWebPage(page, "Opened \(page.host).", heard)
        }

        // "Open the MrBeast video on YouTube" names a tab only in passing: with the AI brain on, such descriptions
        // need a strong tab match, otherwise the brain gets the whole request (it can switch to the tab and click).
        let described = brainTakes && brainRequest != nil
            && NetText.words(TranscriptText.normalize(spokenName)).count >= 3
        let tabMinimum = described ? NameMatcher.words : NameMatcher.words - 10

        // "Go to YouTube" means the YouTube tab if one is open, unless an app is called exactly that.
        if !newWindow && !apps.hasExactName(spokenName),
           let tabResult = try await trySelectNamedTab(spokenName, heard, minScore: tabMinimum) {
            return tabResult
        }

        if apps.resolve(spokenName) != .notFound {
            return try await open(spokenName, newWindow: newWindow, heard)
        }

        if newWindow, let openTab = try await trySelectNamedTab(spokenName, heard, minScore: tabMinimum) {
            return openTab
        }

        // Not an app or tab: "open Library" or "go to Pull requests" clicks it, but only on a strong name match.
        if desktop.foregroundWindow() != nil {
            let target = CommandParser.parseTarget(spokenName)
            if let clicked = try await click(target, heard, minScore: NameMatcher.words, quietIfMissing: true) {
                return clicked
            }
        }

        if let request = takeBrainRequest() {
            // "Open the MrBeast video on YouTube" isn't an app, tab or button name: the AI brain works it out.
            return try await askBrain(request, heard) ?? false
        }

        report(.warning, "I couldn't find an app, tab or button called “\(spokenName)”.", heard)
        return false
    }

    /// "open Instagram in a new tab": a web address opens directly; anything else goes to the AI brain, which may only
    /// open a page (it knows the site's address); else the app called that opens, else a web search for the name,
    /// never for something on screen ("the first link"). "… in a new window" opens a new window of an app first.
    func openInNewPlace(_ name: String, window: Bool, _ heard: String) async throws -> Bool {
        if name.isEmpty {
            report(.warning, "I didn't catch what to open.", heard)
            return false
        }

        // "Open Paint.NET in a new window" means the app; "open battle.net in a new tab" can only mean the site.
        if !(window && apps.hasExactName(name)), let page = BrainSafety.webAddress(name) {
            return try await openWebPage(page, "Opened \(page.host) in a new tab.", heard)
        }

        // Only an app called that: "YouTube" isn't YouTube Music, "Google" isn't Google Chrome.
        let isApp = apps.resolve(name, fuzzy: false) != .notFound
        if window && isApp {
            return try await open(name, newWindow: true, heard)
        }

        var askedBrain = false
        if let request = takeBrainRequest() {
            askedBrain = true
            if let done = try await askBrain(request, heard, onlyPages: true) {
                return done
            }
        }

        // "Open Notepad in a new tab" (Notepad and File Explorer have tabs): the app, never a web search for its name.
        if isApp {
            return try await open(name, newWindow: false, heard)
        }

        if CommandParser.namesSomethingOnScreen(name) {
            // "Open the first link in a new tab": nothing here opens something on screen in a new tab.
            report(
                .warning,
                "I can open \(window ? "apps and websites" : "websites") in a new \(window ? "window" : "tab"), not "
                    + "“\(Self.short(name, 40))”.",
                heard)
            return false
        }

        let search = BrainSafety.searchUrl(nil, name).url
        let found = "Searched the web for “\(Self.short(name, 40))”."
        let hint = "\(found) Start with “\(options.wakeWordLabel)” and the AI brain opens the site itself."
        return try await openWebPage(search, brainTakes && !askedBrain ? hint : found, heard)
    }

    /// Opens the page in a new tab (of the browser in front, else the default browser).
    func openWebPage(_ link: WebLink, _ message: String, _ heard: String) async throws -> Bool {
        let result = try await desktop.openURL(link)
        trace("page \(result.success ? "opened" : "not opened")")
        if !result.success {
            report(.warning, result.message, heard)
            return false
        }

        if let browser = result.window {
            setPlace(browser, Self.appLabel(browser, apps.findProfileForProcess(browser.processName, browser.title)))
        }

        report(.success, message, heard, place: result.window == nil ? nil : place)
        return true
    }

    /// Nil when no tab matches (so the caller tries apps); otherwise whether the tab was selected.
    func trySelectNamedTab(_ name: String, _ heard: String, minScore: Int = NameMatcher.words - 10) async throws
        -> Bool? {
        let tabs = try await desktop.listTabs()
        switch TargetResolver.resolveTab(tabs, ElementTarget(name: name), minScore: minScore) {
        case .single(let tab):
            return try await activateTab(tab, heard)
        case .ambiguous(let matches):
            offerTabs(matches, heard)
            return false
        case .noMatch:
            return nil
        }
    }

    func selectTab(_ target: ElementTarget, _ heard: String) async throws -> Bool {
        let tabs = try await desktop.listTabs()
        let resolution = TargetResolver.resolveTab(tabs, target)
        if case .noMatch = resolution, !target.name.isEmpty, let request = takeBrainRequest(),
           let done = try await askBrain(request, heard, onlyPages: true) {
            // No tab has that name ("open the Instagram tab" with none open): the AI brain may open the site. A plan
            // that opens no page isn't run, and the tab is reported not found below.
            return done
        }

        guard let first = tabs.first else {
            report(.warning, "I don't see any browser tabs.", heard)
            return false
        }

        switch resolution {
        case .single(let tab):
            return try await activateTab(tab, heard)
        case .ambiguous(let matches):
            offerTabs(matches, heard)
            return false
        case .noMatch:
            let count = tabs.filter { $0.window.sameWindow(first.window) }.count
            report(
                .warning,
                target.name.isEmpty
                    ? "That window has \(count) tab\(count == 1 ? "" : "s")."
                    : "I couldn't find a tab called “\(target.name)”.",
                heard)
            return false
        }
    }

    func activateTab(_ tab: BrowserTab, _ heard: String) async throws -> Bool {
        let result = try await desktop.selectTab(tab)
        trace("tab select \(result.success ? "ok" : "failed")")
        if !result.success {
            report(.warning, result.message, heard)
            return false
        }

        let title = Self.short(NameMatcher.cleanTabTitle(tab.title), 40)
        let app = Self.appLabel(tab.window, apps.findProfileForProcess(tab.window.processName, tab.window.title))
        setPlace(tab.window, "\(app) › \(title)")
        onHighlight?(tab.rect)
        report(.success, "On the “\(title)” tab.", heard, place: place)
        return true
    }

    /// Clicks the element the user named in the front window. Nil (with `quietIfMissing`) means nothing matched and
    /// nothing was reported, so the caller can try something else.
    func click(_ target: ElementTarget, _ heard: String, minScore: Int, quietIfMissing: Bool) async throws -> Bool? {
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window in front.", heard)
            return false
        }

        switch try await resolveClickable(window, target, minScore: minScore) {
        case .single(let element):
            return try await actOnElement(element, window, heard)
        case .ambiguous(let elements):
            let numbered = elements.enumerated().map {
                Choice(number: $0.offset + 1, kind: .element, window: window, element: $0.element)
            }
            offer(numbered, "Which “\(target.name)”? Say the number.", heard)
            return false
        case .noMatch:
            if quietIfMissing {
                return nil
            }

            if let request = takeBrainRequest() {
                // "Click the MrBeast video" while it's in a window behind: the AI brain can switch there first.
                return try await askBrain(request, heard) ?? false
            }

            report(
                .warning,
                "I couldn't find “\(Self.describe(target))” here. Say “show numbers” to see what I can click.",
                heard)
            return false
        }
    }

    func click(_ target: ElementTarget, _ heard: String, minScore: Int) async throws -> Bool {
        try await click(target, heard, minScore: minScore, quietIfMissing: false) ?? false
    }

    /// The element named in the window; browsers are read again briefly while a just-shown page builds.
    func resolveClickable(_ window: WindowInfo, _ target: ElementTarget, minScore: Int) async throws
        -> Resolution<UiElement> {
        var elements = try await desktop.listClickable(window)
        var resolution = TargetResolver.resolveElement(elements, target, desktop.windowRect(window), minScore: minScore)

        // Browsers build a tab's page only after the tab is shown, so right after "go to the second tab" the page can
        // still be missing for a moment: look again before saying it isn't there.
        if case .noMatch = resolution,
           apps.findProfileForProcess(window.processName, window.title)?.addressBarKeys != nil {
            for _ in 0..<3 {
                guard case .noMatch = resolution else { break }
                try await Task.sleep(nanoseconds: 400_000_000)
                if !window.sameWindow(desktop.foregroundWindow()) {
                    break
                }

                elements = try await desktop.listClickable(window)
                resolution = TargetResolver.resolveElement(
                    elements, target, desktop.windowRect(window), minScore: minScore)
            }
        }

        return resolution
    }

    func actOnElement(_ element: UiElement, _ window: WindowInfo, _ heard: String) async throws -> Bool {
        let label = Self.short(NameMatcher.cleanElementName(element.name), 40)
        if TargetResolver.isDestructive(element.name) {
            pendingClick = (element, window, options.clock())
            onHighlight?(element.rect)
            trace("click needs confirmation")
            report(.warning, "“\(label)” can't be undone. Say “yes” to click it, or “no”.", heard)
            return false
        }

        return try await clickVerified(element, window, label, heard)
    }

    func clickVerified(_ element: UiElement, _ window: WindowInfo, _ label: String, _ heard: String) async throws
        -> Bool {
        if !window.sameWindow(desktop.foregroundWindow()) {
            report(.warning, "Focus moved to another window, so I didn't click.", heard)
            return false
        }

        let result = try await desktop.click(element)
        trace("click \(DotNet.upperFirst("\(element.role)")) \(result.success ? "ok" : "failed")")
        if !result.success {
            report(.warning, result.message, heard)
            return false
        }

        onHighlight?(element.rect)
        setPlace(window, Self.appLabel(window, apps.findProfileForProcess(window.processName, window.title)))
        report(.success, "Clicked “\(label)”.", heard, place: place)
        return true
    }

    func confirmPending(_ heard: String) async throws -> Bool {
        if let resumed = try await resumeBrain(heard) {
            return resumed
        }

        guard let pending = pendingClick, options.clock().timeIntervalSince(pending.at) <= Self.pendingTimeout else {
            pendingClick = nil
            report(.info, "There's nothing waiting for a yes.", heard)
            return false
        }

        pendingClick = nil
        let label = Self.short(NameMatcher.cleanElementName(pending.element.name), 40)
        return try await clickVerified(pending.element, pending.window, label, heard)
    }

    func showNumbers(_ heard: String) async throws -> Bool {
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window in front.", heard)
            return false
        }

        let clickable = TargetResolver.deduplicate(try await desktop.listClickable(window))
        let boxes = try await desktop.listTextBoxes(window)
        let items = clickable.map { (element: $0, kind: ChoiceKind.element) }
            + boxes.map { (element: $0, kind: ChoiceKind.textBox) }
        let numbered = TargetResolver.sortReadingOrder(items) { $0.element.rect }.prefix(99).enumerated().map {
            Choice(number: $0.offset + 1, kind: $0.element.kind, window: window, element: $0.element.element)
        }
        if numbered.isEmpty {
            report(.warning, "I can't see anything to click in this window.", heard)
            return false
        }

        offer(numbered, "Say a number to click it, or “hide numbers”.", heard)
        return true
    }

    func choose(_ number: Int, _ heard: String) async throws -> Bool {
        expirePending()
        guard let choice = choices.first(where: { $0.number == number }) else {
            let message = choices.isEmpty
                ? "There's nothing to choose. Say “show numbers” first."
                : "There's no number \(number)."
            report(.warning, message, heard)
            return false
        }

        clearPending()
        switch choice.kind {
        case .tab:
            return try await activateTab(choice.tab!, heard)
        case .textBox:
            return try await focusBoxAndBind(choice.element!, choice.window, heard)
        case .element:
            return try await actOnElement(choice.element!, choice.window, heard)
        }
    }

    /// "start typing in the message box": the text box with that name in the front window.
    func focusField(_ target: ElementTarget, _ heard: String) async throws -> Bool {
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window to type into.", heard)
            return false
        }

        let boxes = try await desktop.listTextBoxes(window)
        switch TargetResolver.resolveElement(boxes, target, desktop.windowRect(window)) {
        case .single(let box):
            return try await focusBoxAndBind(box, window, heard)
        case .ambiguous(let matches):
            let numbered = matches.enumerated().map {
                Choice(number: $0.offset + 1, kind: .textBox, window: window, element: $0.element)
            }
            offer(numbered, "Which box? Say the number.", heard)
            return false
        case .noMatch:
            report(.warning, "I couldn't find a “\(target.name)” box here.", heard)
            return false
        }
    }

    /// For "start typing" when nothing editable has the focus: the only text box, else the one named like a message or
    /// search box, else numbers to choose from. Nil means there are no text boxes (the caller keeps its old
    /// behaviour). In browsers the address bar doesn't count: it's the fallback when the page has no boxes.
    func pickTextBox(_ window: WindowInfo, _ heard: String, browser: Bool = false) async throws -> Bool? {
        let boxes = try await desktop.listTextBoxes(window).filter { !browser || !Self.isAddressBar($0) }
        if boxes.isEmpty {
            return nil
        }

        if boxes.count == 1 {
            return try await focusBoxAndBind(boxes[0], window, heard)
        }

        let named = boxes.filter { box in
            Self.genericBoxNames.contains {
                NameMatcher.score($0, NameMatcher.cleanElementName(box.name)) >= NameMatcher.words
            }
        }
        if named.count == 1 {
            return try await focusBoxAndBind(named[0], window, heard)
        }

        let numbered = TargetResolver.sortReadingOrder(named.count > 1 ? named : boxes).prefix(20).enumerated().map {
            Choice(number: $0.offset + 1, kind: .textBox, window: window, element: $0.element)
        }
        offer(numbered, "Which box? Say the number.", heard)
        return false
    }

    /// A known website's main box (YouTube's search, WhatsApp's message box). False if it isn't there.
    func focusSiteBox(_ window: WindowInfo, _ site: SiteProfile, _ heard: String) async throws -> Bool {
        let boxes = try await desktop.listTextBoxes(window)
        for name in site.textBoxNames {
            let matching = boxes.filter {
                NameMatcher.score(name, NameMatcher.cleanElementName($0.name)) >= NameMatcher.words
            }
            if let match = TargetResolver.sortReadingOrder(matching).first {
                return try await focusBoxAndBind(match, window, heard)
            }
        }

        return false
    }

    func focusBoxAndBind(_ box: UiElement, _ window: WindowInfo, _ heard: String) async throws -> Bool {
        if !window.sameWindow(desktop.foregroundWindow()) {
            report(.warning, "Focus moved to another window, so I didn't start typing.", heard)
            return false
        }

        let focused = try await desktop.focusTextBox(box)
        trace("text box focus \(focused.success ? "ok" : "failed")")
        if !focused.success {
            report(.warning, focused.message, heard)
            return false
        }

        let profile = apps.findProfileForProcess(window.processName, window.title)
        let label = Self.short(NameMatcher.cleanElementName(box.name), 30)
        let search = NetText.containsOrdinalIgnoreCase(label, "search")
        bindTarget(window, profile, boxHadText: focused.hasTrailingText == true, searchField: search)
        onHighlight?(box.rect)
        setPlace(window, "\(placeOf(window, profile)) › \(label.isEmpty ? "Text box" : label)")
        report(
            .success,
            search
                ? "In the search box. Say what to search for, then “search”."
                : "Typing into “\(label.isEmpty ? "the text box" : label)”. Say “stop typing” when done.",
            heard,
            place: place)
        return true
    }

    static func isAddressBar(_ box: UiElement) -> Bool {
        NetText.containsOrdinalIgnoreCase(box.name, "address") || DotNet.contains(box.name, "URL")
    }

    /// The keys that show another tab or page (C#'s `TabChangingChords`, with the platform's keys): new and close tab,
    /// next and previous tab, back, forward, the parent folder and reload.
    static func tabChangingChords(_ keys: ShortcutKeys) -> IgnoreCaseSet {
        IgnoreCaseSet([
            keys.newTab, keys.closeTab, keys.nextTab, keys.previousTab, keys.back, keys.forward, keys.parentFolder,
            keys.refresh,
        ])
    }

    /// Commands after which the old typing target may show different content (another tab, page or app). A back or
    /// forward that `backForwardRefusal` stops changes nothing.
    func movesAway(_ command: VoiceCommand) -> Bool {
        switch command.kind {
        case .openApp, .switchToApp, .selectTab, .click, .choose, .openInNewTab, .openInNewWindow:
            return true
        case .pressKeys:
            let chord = command.argument ?? ""
            return Self.tabChangingChords(keys).contains(chord) && backForwardRefusal(chord) == nil
        default:
            return false
        }
    }

    func unbind() {
        target = nil
        targetProfile = nil
        segments.removeAll()
        if mode == .dictation {
            awake()
        }
    }

    func offerTabs(_ tabs: [BrowserTab], _ heard: String) {
        let numbered = tabs.prefix(9).enumerated().map {
            Choice(number: $0.offset + 1, kind: .tab, window: $0.element.window, tab: $0.element)
        }
        let list = numbered.map { "\($0.number) “\(Self.short(NameMatcher.cleanTabTitle($0.tab?.title), 24))”" }
        offer(numbered, "Which tab? \(list.joined(separator: " · "))", heard)
    }

    func offer(_ offered: [Choice], _ message: String, _ heard: String) {
        choices = offered
        choicesAt = options.clock()
        if mode == .dictation {
            // Numbers are answered by voice: while typing, "two" would be typed instead.
            awake()
        }

        if mode == .command {
            // The whole window to answer with a number.
            awakeSince = options.clock()
        }

        trace("choices offered: \(offered.count)")
        onChoicesChanged?(offered.map { choice in
            let label = choice.tab.map { NameMatcher.cleanTabTitle($0.title) }
                ?? NameMatcher.cleanElementName(choice.element?.name)
            return ChoiceBadge(number: choice.number, rect: choice.tab?.rect ?? choice.element!.rect, label: label)
        })
        report(.info, message, heard)
    }

    func clearPending() {
        pendingClick = nil
        brainPending = nil
        if !choices.isEmpty {
            choices.removeAll()
            onChoicesChanged?(nil)
        }
    }

    func expirePending() {
        let now = options.clock()
        if let pending = pendingClick, now.timeIntervalSince(pending.at) > Self.pendingTimeout {
            pendingClick = nil
        }

        if let waiting = brainPending, now.timeIntervalSince(waiting.at) > Self.pendingTimeout {
            brainPending = nil
        }

        if !choices.isEmpty && now.timeIntervalSince(choicesAt) > Self.pendingTimeout {
            choices.removeAll()
            onChoicesChanged?(nil)
        }
    }

    func setPlace(_ window: WindowInfo, _ path: String) {
        place = path.isEmpty ? Self.displayName(window) : path
    }

    /// The place's first part: the app, and for browsers the tab (from the window title).
    func placeOf(_ window: WindowInfo, _ profile: AppEntry?) -> String {
        let app = Self.appLabel(window, profile)
        if profile?.searchKeys == nil {
            return app
        }

        let tab = Self.short(NameMatcher.cleanTabTitle(window.title), 40)
        return tab.isEmpty ? app : "\(app) › \(tab)"
    }

    static func appLabel(_ window: WindowInfo, _ profile: AppEntry?) -> String {
        if let profile {
            return profile.name
        }

        // Apps usually end their title with their name ("Report.docx - Word"); short titles are the name ("Copilot").
        let title = DotNet.trim(DotNet.replace(window.title, "\u{200B}", " "))
        let last = DotNet.trim(NetText.split(title, " - ").last ?? "")
        if (1...30).contains(last.utf16.count) {
            return last
        }

        return DotNet.isNullOrWhiteSpace(window.processName)
            ? displayName(window)
            : NetText.toTitleCase(window.processName)
    }

    static func describe(_ target: ElementTarget) -> String {
        var name = target.name
        if let n = target.ordinal {
            name = DotNet.trim("\(n == -1 ? "last" : String(n) + ordinalSuffix(n)) \(name)")
        }

        return target.region.map { "\(name) on the \($0)" } ?? name
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        switch n {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
