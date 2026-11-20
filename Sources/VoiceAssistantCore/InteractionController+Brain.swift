import Foundation
import ThumbFreeCore

/// The AI brain (windows-voice-assistant's InteractionController.Brain.cs and docs/design/ai-brain.md): requests the
/// fixed commands don't cover ("open the MrBeast video on YouTube") are planned by an on-device model from a summary of
/// the screen, then run step by step with the assistant's own abilities. The limits are enforced here whatever the
/// model says: no typing or keys in command windows, no Win+R, web links only, a "yes" before anything that sends,
/// deletes, closes or types a lot, at most 8 steps and 30 seconds. Traces name tools, never words or names.
extension InteractionController {
    static let brainPlanLimit: TimeInterval = 60
    static let brainRunLimit: TimeInterval = 30

    /// True while the brain is planning or acting, so Esc can stop it. Safe to read from any thread.
    public var isBrainRunning: Bool { brainActivity.isRunning }

    /// Changes whenever the brain starts or stops work. Read it when speech starts and pass it with the transcript
    /// (`brainChangesWhenSpoken`), so speech that began before the brain's last start or stop is ignored: a "yes" said
    /// before it asked never answers it. Safe to read from any thread.
    public var brainChanges: Int { brainActivity.count }

    var brainTakes: Bool {
        guard let availability = brain?.availability else { return false }
        return availability != .off && availability != .notInstalled
    }

    enum StepResult {
        case done
        case stop

        /// Asked a question or waiting for "yes": the plan stops without failing.
        case waiting
    }

    /// One plan as it runs, shared by its steps and by a step waiting for "yes".
    final class BrainRun {
        var heard: String
        let say: String
        var started: Date

        /// The place shown before the plan ran: the final message shows the place only if a step changed it.
        let placeBefore: String?

        /// Windows (by handle) where this plan typed into a box that isn't a search box: there any send key or click
        /// needs a "yes", so typing into a search box afterwards can't clear it.
        var messageTypedIn = Set<Int>()

        /// Characters (UTF-16 units) typed by this plan so far: more than the limit in all needs a "yes".
        var typedChars = 0

        init(heard: String, say: String, started: Date, placeBefore: String?) {
            self.heard = heard
            self.say = say
            self.started = started
            self.placeBefore = placeBefore
        }
    }

    struct BrainPending {
        var steps: [BrainStep]
        var next: Int
        var run: BrainRun
        var window: WindowInfo
        var at: Date
    }

    /// The brain takes the request in place of a fixed command that found nothing (once per utterance).
    func takeBrainRequest() -> String? {
        let request = brainTakes ? brainRequest : nil
        brainRequest = nil
        return request
    }

    /// Plans the request and runs the plan. Nil when there was no plan: the model failed or answered nonsense (already
    /// reported), or, with `onlyPages`, the plan opened no page (not reported: the caller carries on). Otherwise
    /// whether the plan ran to the end (or stopped to ask something). `onlyPages`: the request asked for a page ("open
    /// X in a new tab"), so only the steps that open one run.
    func askBrain(_ request: String, _ heard: String, onlyPages: Bool = false) async throws -> Bool? {
        guard let brain else { return nil }
        brainRequest = nil
        brainActivity.set(running: true)
        defer { brainActivity.set(running: false) }
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Int { Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
        do {
            report(
                .info,
                brain.availability == .ready ? "Thinking…" : "Waking up the AI brain (a few seconds the first time)…",
                heard)
            let screen = try await describeScreen(request)
            trace(
                "brain: screen of \(screen.scanned) windows, \(screen.items) items, \(screen.text.utf16.count) chars "
                    + "in \(elapsed()) ms")

            let reply: String
            do {
                reply = try await complete(brain, BrainPrompt.messages(screen.text, request))
            } catch {
                if error is CancellationError && Task.isCancelled {
                    throw error
                }

                if error is CancellationError || error is BrainPlanTimeout {
                    trace("brain: no answer in time")
                    report(.warning, "The AI brain took too long. Try again, or say it another way.", heard)
                    return nil
                }

                // The model is another process: any failure there means "no plan", never a crash here.
                trace("brain: failed (\(type(of: error)))")
                report(.warning, "The AI brain isn't working right now. Try again in a moment.", heard)
                return nil
            }

            let plan: BrainPlan
            switch BrainPlan.parse(reply) {
            case .success(let parsed):
                plan = parsed
            case .failure(let unusable):
                trace("brain: unusable reply (\(unusable.reason))")
                report(.warning, "I couldn't work out how to do that. Try saying it another way.", heard)
                return nil
            }

            var steps = BrainPlan.tidy(plan.steps)
            var say = plan.say
            let tools = steps.map { BrainPlan.nameOf($0.tool) }.joined(separator: ", ")
            let dropped = steps.count < plan.steps.count
                ? " (\(plan.steps.count - steps.count) new-tab step dropped)"
                : ""
            trace("brain: plan [\(tools)] in \(elapsed()) ms\(dropped)")
            if onlyPages {
                guard let pages = BrainPlan.onlyPages(steps) else {
                    // "A new GitHub tab" planned as switching to the GitHub app and clicking there: never what was
                    // asked.
                    trace("brain: the plan opens no page; not run")
                    return nil
                }

                if pages.count < steps.count {
                    // The model's sentence may describe the dropped steps ("Switched to WhatsApp and opened GitHub").
                    trace("brain: \(steps.count - pages.count) step(s) besides opening the page dropped")
                    say = ""
                }

                steps = pages
            }

            if !steps.isEmpty {
                // Windows and pages are about to change: "send" must not press Enter in a typing target left behind.
                clearPending()
                unbind()
            }

            let run = BrainRun(heard: heard, say: say, started: options.clock(), placeBefore: place)
            return try await runPlan(run, steps, 0, confirmedFirst: false)
        } catch is CancellationError where Task.isCancelled {
            trace("brain: stopped")
            report(.info, "Stopped.", heard)
            return false
        }
    }

    /// The model's reply, or `BrainPlanTimeout` after `brainPlanLimit` (C#'s linked token that cancels after 60 s).
    private func complete(_ brain: BrainModel, _ messages: [ChatTurn]) async throws -> String {
        let limit = Self.brainPlanLimit
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await brain.complete(messages) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }

            defer { group.cancelAll() }
            guard let first = try await group.next(), let reply = first else { throw BrainPlanTimeout() }
            return reply
        }
    }

    /// "yes" after the brain asked: runs the waiting step and the rest of the plan. Nil if nothing was waiting.
    func resumeBrain(_ heard: String) async throws -> Bool? {
        guard let pending = brainPending else { return nil }
        brainPending = nil
        if options.clock().timeIntervalSince(pending.at) > Self.pendingTimeout {
            report(.info, "That waited too long, so I didn't do it. Ask again.", heard)
            return false
        }

        if !pending.window.sameWindow(desktop.foregroundWindow()) {
            report(.warning, "Focus moved to another window, so I didn't do that.", heard)
            return false
        }

        pending.run.heard = heard
        pending.run.started = options.clock()
        brainActivity.set(running: true)
        defer { brainActivity.set(running: false) }
        do {
            return try await runPlan(pending.run, pending.steps, pending.next, confirmedFirst: true)
        } catch is CancellationError where Task.isCancelled {
            trace("brain: stopped")
            report(.info, "Stopped.", heard)
            return false
        }
    }

    func runPlan(_ run: BrainRun, _ steps: [BrainStep], _ start: Int, confirmedFirst: Bool) async throws -> Bool {
        if steps.isEmpty {
            // Chat or a question about something: the answer is the whole reply.
            report(
                .success,
                run.say.isEmpty ? "I'm not sure what to do there. Try saying it another way." : run.say,
                run.heard)
            return !run.say.isEmpty
        }

        for i in stride(from: start, to: steps.count, by: 1) {
            try Task.checkCancellation()
            if options.clock().timeIntervalSince(run.started) > Self.brainRunLimit {
                trace("brain: time limit")
                report(.warning, "That was taking too long, so I stopped.", run.heard)
                return false
            }

            let result = try await runStep(run, steps, i, confirmed: confirmedFirst && i == start)
            trace("brain: \(BrainPlan.nameOf(steps[i].tool)) \(result)")
            if result == .stop {
                return false
            }

            if result == .waiting {
                return true
            }
        }

        let moved = Self.differs(place, run.placeBefore)
        report(.success, run.say.isEmpty ? "Done." : run.say, run.heard, place: moved ? place : nil)
        return true
    }

    func runStep(_ run: BrainRun, _ steps: [BrainStep], _ index: Int, confirmed: Bool) async throws -> StepResult {
        let step = steps[index]
        let heard = run.heard
        switch step.tool {
        case .focusWindow:
            return try await brainFocus(Self.first(step.target, step.text), heard) ? .done : .stop
        case .openApp:
            return try await brainOpenApp(Self.first(step.target, step.text), heard) ? .done : .stop
        case .openUrl:
            guard let url = BrainSafety.normalizeUrl(Self.first(step.target, step.text)) else {
                report(.warning, "I only open web links (http or https).", heard)
                return .stop
            }

            return try await openPage(url, "Opening \(url.host)…", heard, last: index == steps.count - 1)
        case .webSearch:
            let (site, query) = step.text.isEmpty ? ("google", step.target) : (step.target, step.text)
            if query.isEmpty {
                report(.warning, "I didn't catch what to search for.", heard)
                return .stop
            }

            let search = BrainSafety.searchUrl(site, query)
            return try await openPage(
                search.url, "Searching \(search.site) for “\(Self.short(query, 40))”…", heard,
                last: index == steps.count - 1)
        case .click:
            return try await brainClick(run, steps, index, confirmed: confirmed)
        case .typeText:
            return try await brainType(run, steps, index, confirmed: confirmed)
        case .press:
            return try brainPress(run, steps, index, confirmed: confirmed)
        case .scroll:
            guard let scrolled = desktop.foregroundWindow() else {
                report(.warning, "There's no window in front.", heard)
                return .stop
            }

            if desktop.isCommandWindow(scrolled) {
                // Page Up in a console brings back an earlier command.
                refuseCommandWindow(scrolled, typing: false, heard)
                return .stop
            }

            if !checkField(heard, nil, allowUnknown: true) {
                return .stop
            }

            let up = NetText.containsOrdinalIgnoreCase(Self.first(step.target, step.text), "up")
            try desktop.pressKeys(up ? keys.scrollUp : keys.scrollDown)
            report(.success, up ? "Scrolled up." : "Scrolled down.", heard)
            return .done
        case .ask:
            let question = Self.first(step.text, step.target, run.say)
            report(.info, question.isEmpty ? "Can you say that another way?" : question, heard)
            return .waiting
        }
    }

    /// A window from the screen by title or app name; else a tab with that name, or the app if it isn't open.
    func brainFocus(_ target: String, _ heard: String) async throws -> Bool {
        if target.isEmpty {
            report(.warning, "I didn't catch which window.", heard)
            return false
        }

        // The best score, the front-most window of those with it (C#'s OrderByDescending, then ThenBy the index).
        let scored = try await desktop.listWindows()
            .map { (window: $0.window, score: windowScore(target, $0.window)) }
            .filter { $0.score >= NameMatcher.partial }
        let found = scored.map(\.score).max().flatMap { best in scored.first { $0.score == best }?.window }
        guard let match = found else {
            if let tab = try await trySelectNamedTab(target, heard) {
                return tab
            }

            if case .found = apps.resolve(target) {
                return try await open(target, newWindow: false, heard)
            }

            report(.warning, "I couldn't find a window called “\(Self.short(target, 40))”.", heard)
            return false
        }

        if !match.sameWindow(desktop.foregroundWindow()) {
            let result = try await desktop.activateWindow(match)
            trace("brain: window \(result.success ? "activated" : "not activated")")
            if !result.success {
                report(.warning, result.message, heard)
                return false
            }
        }

        setPlace(match, placeOf(match, apps.findProfileForProcess(match.processName, match.title)))
        return true
    }

    private func windowScore(_ target: String, _ window: WindowInfo) -> Int {
        max(
            max(NameMatcher.score(target, window.title), TargetResolver.tabScore(target, window.title)),
            NameMatcher.score(target, brainAppName(window)))
    }

    func brainOpenApp(_ name: String, _ heard: String) async throws -> Bool {
        if name.isEmpty {
            report(.warning, "I didn't catch which app.", heard)
            return false
        }

        if apps.resolve(name) == .notFound, let tab = try await trySelectNamedTab(name, heard) {
            // "open YouTube" when YouTube is a tab, not an app.
            return tab
        }

        return try await open(name, newWindow: true, heard)
    }

    /// Opens the page. Steps after it act on the browser, so if the browser didn't come to the front the plan stops
    /// there rather than clicking or typing in the window that's still in front.
    func openPage(_ url: WebLink, _ message: String, _ heard: String, last: Bool) async throws -> StepResult {
        let result = try await desktop.openURL(url)
        trace("brain: page \(result.success ? "opened" : "not opened")")
        if !result.success {
            report(.warning, result.message, heard)
            return .stop
        }

        guard let browser = result.window else {
            report(
                .info,
                last ? message : "Opened the page, but the browser didn't come to the front, so I stopped there.",
                heard)
            return last ? .done : .waiting
        }

        setPlace(browser, Self.appLabel(browser, apps.findProfileForProcess(browser.processName, browser.title)))
        report(.info, message, heard)
        return .done
    }

    func brainClick(_ run: BrainRun, _ steps: [BrainStep], _ index: Int, confirmed: Bool) async throws -> StepResult {
        let name = Self.first(steps[index].target, steps[index].text)
        let heard = run.heard
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window in front.", heard)
            return .stop
        }

        if name.isEmpty {
            report(.warning, "I didn't catch what to click.", heard)
            return .stop
        }

        let target = ElementTarget(name: name)
        switch try await resolveClickable(window, target, minScore: NameMatcher.partial) {
        case .single(let element):
            let label = Self.short(NameMatcher.cleanElementName(element.name), 40)

            // After typing a message here, any click could send it. The file manager hides known extensions, so any
            // file there could be a program.
            let platform = desktop.brainPlatform
            if !confirmed
                && (TargetResolver.isDestructive(element.name) || BrainSafety.isSendLike(element.name, platform)
                    || BrainSafety.runsProgram(element.name, platform)
                    || BrainSafety.isShellItem(window, element.role, platform)
                    || run.messageTypedIn.contains(window.handle)) {
                onHighlight?(element.rect)
                return askFirst(run, steps, index, window, "Click “\(label)”?")
            }

            return try await clickVerified(element, window, label, heard) ? .done : .stop
        case .ambiguous(let elements):
            // The user picks with a number; the rest of the plan is dropped.
            let numbered = elements.enumerated().map {
                Choice(number: $0.offset + 1, kind: .element, window: window, element: $0.element)
            }
            offer(numbered, "Which “\(Self.short(name, 30))”? Say the number.", heard)
            return .waiting
        case .noMatch:
            break
        }

        // Clicking a text box means putting the cursor in it.
        let boxes = try await desktop.listTextBoxes(window)
        if case .single(let box) = TargetResolver.resolveElement(
            boxes, target, desktop.windowRect(window), minScore: NameMatcher.partial) {
            let focused = try await desktop.focusTextBox(box)
            if !focused.success {
                report(.warning, focused.message, heard)
                return .stop
            }

            onHighlight?(box.rect)
            return .done
        }

        let app = Self.appLabel(window, apps.findProfileForProcess(window.processName, window.title))
        report(.warning, "I couldn't find “\(Self.short(name, 40))” in \(app).", heard)
        return .stop
    }

    func brainType(_ run: BrainRun, _ steps: [BrainStep], _ index: Int, confirmed: Bool) async throws -> StepResult {
        let step = steps[index]
        let heard = run.heard

        // type_text(text); some models also name the box in "target", or put the text there.
        let (boxName, text) = step.text.isEmpty ? ("", step.target) : (step.target, step.text)
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window to type into.", heard)
            return .stop
        }

        if text.isEmpty {
            report(.warning, "I didn't catch what to type.", heard)
            return .stop
        }

        if desktop.isCommandWindow(window) {
            refuseCommandWindow(window, typing: true, heard)
            return .stop
        }

        let length = text.utf16.count
        if !confirmed && run.typedChars + length > BrainSafety.maxTypedWithoutAsking {
            let app = Self.appLabel(window, apps.findProfileForProcess(window.processName, window.title))
            return askFirst(run, steps, index, window, "Type \(length) characters into \(app)?")
        }

        let profile = apps.findProfileForProcess(window.processName, window.title)
        let chosen = try await findTypingBox(window, profile, boxName, heard)
        if !chosen.found {
            return .stop
        }

        let browser = isBrowser(window, profile)
        let focus = desktop.describeFocus()
        let boxLabel = chosen.label ?? focus?.name
        if refuseTypingAt(browser, focus, boxLabel, heard) {
            return .stop
        }

        let search = BrainSafety.isSearchBox(boxLabel)
        if search && BrainSafety.isRefusedAddress(text) {
            // Search boxes that take addresses open them: a browser's new-tab page, the address bar of a browser no
            // list knows ("Search or enter address").
            trace("brain: refused an address in a search box")
            report(.warning, "I don't type web addresses into search boxes. Ask me to open the page instead.", heard)
            return .stop
        }

        if !checkField(heard, text, allowUnknown: false) {
            return .stop
        }

        segments.removeAll()
        segments.append(try typeWithNewLines(text, profile?.newLineKeys ?? "Shift+Enter"))

        // Bound like "start typing" (without switching to typing), so "send", "scratch that" and "new line" act on it.
        target = window
        targetProfile = profile
        typedTail = Self.tail(text)
        boxHadText = false
        needsLeadingSpace = !Self.endsWithWhiteSpace(text)
        endsSentence = Self.endsWithAny(text, ".!?")
        searchField = search
        run.typedChars += length
        if !search {
            run.messageTypedIn.insert(window.handle)
        }

        let box = boxLabel.map { $0.isEmpty ? "Text box" : Self.short(NameMatcher.cleanElementName($0), 30) }
            ?? "Text box"
        setPlace(window, "\(placeOf(window, profile)) › \(box)")
        report(.success, "Typed “\(Self.short(text, 40))”.", heard, place: place)
        return .done
    }

    /// Puts the cursor where the plan types: the box it named, else whatever already takes text, else the page's main
    /// box (a known site's, the only one, or the one named like a message or search box). Returns the name of the box
    /// it chose, or nil when the cursor was already in one (the caller asks the desktop what has the focus).
    func findTypingBox(_ window: WindowInfo, _ profile: AppEntry?, _ boxName: String, _ heard: String) async throws
        -> (found: Bool, label: String?) {
        var listed: [UiElement]?
        if !boxName.isEmpty {
            let named = try await desktop.listTextBoxes(window)
            listed = named
            let resolution = TargetResolver.resolveElement(
                named, ElementTarget(name: boxName), desktop.windowRect(window), minScore: NameMatcher.partial)
            switch resolution {
            case .single(let box):
                return try await focusBox(box, heard)
            case .ambiguous(let boxes):
                return try await focusBox(boxes[0], heard)
            case .noMatch:
                break
            }
        }

        let prepared = try await desktop.prepareTextTarget(window, profile: profile)
        if !prepared.success {
            report(.warning, prepared.message, heard)
            return (false, nil)
        }

        if prepared.focusIsEditable != false {
            // The caller reads the focused box's name.
            return (true, nil)
        }

        let boxes: [UiElement]
        if let listed {
            boxes = listed
        } else {
            boxes = try await desktop.listTextBoxes(window)
        }

        let browser = isBrowser(window, profile)
        let candidates = boxes.filter { !browser || !Self.isAddressBar($0) }
        var pick: UiElement?
        if let site = SiteProfile.forTitle(window.title) {
            for name in site.textBoxNames where pick == nil {
                pick = TargetResolver.sortReadingOrder(candidates.filter {
                    NameMatcher.score(name, NameMatcher.cleanElementName($0.name)) >= NameMatcher.words
                }).first
            }
        }

        if pick == nil && candidates.count == 1 {
            pick = candidates[0]
        }

        if pick == nil {
            let generic = candidates.filter { box in
                Self.genericBoxNames.contains {
                    NameMatcher.score($0, NameMatcher.cleanElementName(box.name)) >= NameMatcher.words
                }
            }
            pick = generic.count == 1 ? generic[0] : nil
        }

        guard let box = pick else {
            report(.warning, "I couldn't tell where to type. Say “start typing in the … box” first.", heard)
            return (false, nil)
        }

        return try await focusBox(box, heard)
    }

    func focusBox(_ box: UiElement, _ heard: String) async throws -> (found: Bool, label: String?) {
        let focused = try await desktop.focusTextBox(box)
        if !focused.success {
            report(.warning, focused.message, heard)
            return (false, nil)
        }

        onHighlight?(box.rect)
        return (true, box.name)
    }

    /// A key the model asked for. Plans name keys the Windows way (`BrainSafety` says why). On the Mac each is pressed
    /// as its Mac chord, which the messages name, and judged by the Mac's rules too; back and forward work only in a
    /// browser there, as for the voice commands. The chords that change the tab or page are known by their Windows
    /// names, as in the C#.
    func brainPress(_ run: BrainRun, _ steps: [BrainStep], _ index: Int, confirmed: Bool) throws -> StepResult {
        let heard = run.heard
        let platform = desktop.brainPlatform
        let named = Self.first(steps[index].target, steps[index].text)
        guard let chord = BrainSafety.normalizeChord(named) else {
            report(.warning, "I can't press “\(Self.short(named, 20))”.", heard)
            return .stop
        }

        // The keys as pressed and as the messages name them: the chord itself on Windows, its Mac chord on the Mac.
        let pressed = BrainSafety.pressedChord(chord, platform)
        let shown = pressed ?? chord
        if let reason = BrainSafety.refusalReason(chord, platform) {
            trace("brain: refused keys")
            report(.warning, "I won't press \(shown): \(reason).", heard)
            return .stop
        }

        // Every chord without keys on this platform was refused above.
        guard let toPress = pressed else { return .stop }
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window in front.", heard)
            return .stop
        }

        if desktop.isCommandWindow(window) {
            refuseCommandWindow(window, typing: false, heard)
            return .stop
        }

        if let refusal = backForwardRefusal(toPress, platform.kind == .mac ? .mac : .windows) {
            trace("brain: back or forward refused outside a browser")
            report(.warning, refusal, heard)
            return .stop
        }

        // What Enter, Space or a letter does depends on what has the focus: a letter in a box types it.
        let submit = BrainSafety.isSubmitChord(chord)
        let character = BrainSafety.isCharacterKey(chord)
        let browser = isBrowser(window, apps.findProfileForProcess(window.processName, window.title))
        let focus = submit || character ? desktop.describeFocus() : nil
        if let focus, focus.editable, refuseTypingAt(browser, focus, focus.name, heard) {
            return .stop
        }

        if character && focus == nil && browser {
            // It could land in the address bar.
            trace("brain: refused keys, focus unknown")
            report(.warning, "I couldn't tell where \(shown) would go, so I didn't press it.", heard)
            return .stop
        }

        if !confirmed && submit, let question = submitQuestion(run, window, shown, focus) {
            return askFirst(run, steps, index, window, question)
        }

        // On the Mac, Backspace asks unless the focus is a text box.
        let deciding = BrainSafety.focusDecides(chord, platform) ? (focus ?? desktop.describeFocus()) : focus
        if !confirmed && BrainSafety.needsConfirmation(chord, platform, focus: deciding) {
            return askFirst(run, steps, index, window, "Press \(shown)?")
        }

        if !checkField(heard, nil, allowUnknown: true) {
            return .stop
        }

        if character, let focus, focus.editable {
            // Counted like type_text, so Enter in that box later asks first.
            run.typedChars += 1
            if !BrainSafety.isSearchBox(focus.name) {
                run.messageTypedIn.insert(window.handle)
            }
        }

        try desktop.pressKeys(toPress)
        segments.removeAll()
        typedTail = nil
        if Self.tabChangingChords(.windows).contains(chord) {
            unbind()
        }

        report(.success, "Pressed \(shown).", heard)
        return .done
    }

    /// Whether Enter, Space or Alt+S needs a "yes" first: after the plan typed a message in this window ("Send it?"),
    /// in any text box that isn't a search box (it may hold a draft), on a button that sends, deletes or runs
    /// something, and when what has the focus is unknown. Nil when it may go ahead. `chord` is as the messages name it.
    func submitQuestion(_ run: BrainRun, _ window: WindowInfo, _ chord: String, _ focus: FocusInfo?) -> String? {
        if run.messageTypedIn.contains(window.handle) {
            return "Send it?"
        }

        guard let focus else { return "Press \(chord)?" }
        let name = Self.short(NameMatcher.cleanElementName(focus.name), 30)
        if focus.editable {
            if BrainSafety.isSearchBox(focus.name) {
                return nil
            }

            return name.isEmpty ? "Press \(chord)?" : "Press \(chord) in “\(name)”?"
        }

        let platform = desktop.brainPlatform
        let risky = TargetResolver.isDestructive(focus.name) || BrainSafety.isSendLike(focus.name, platform)
            || BrainSafety.runsProgram(focus.name, platform)
        return risky ? "Press \(chord) on “\(name)”?" : nil
    }

    /// Typing (type_text, or a letter key into a box) goes only into the page in a browser, never into the browser's
    /// own address, search or find bar (they open file:, local and script addresses), nor into a terminal inside an
    /// app. The platform's browsers are `JarvisDesktop.brainPlatform`'s.
    func refuseTypingAt(_ browser: Bool, _ focus: FocusInfo?, _ boxLabel: String?, _ heard: String) -> Bool {
        if focus?.addressBar == true || (browser && focus?.inPage != true) {
            trace("brain: refused typing outside the page")
            report(
                .warning,
                "I only type into the page, never the browser's address bar. Ask me to open the page or search "
                    + "instead.",
                heard)
            return true
        }

        if BrainSafety.isCommandBox(boxLabel) || BrainSafety.isCommandBox(focus?.name) {
            trace("brain: refused typing in a command box")
            report(
                .warning,
                "I don't type where text runs as a command. Say “start typing” to dictate there yourself.",
                heard)
            return true
        }

        return false
    }

    /// A web browser, whether or not the app list has it (Brave, Opera, Vivaldi…), by the platform's list.
    func isBrowser(_ window: WindowInfo, _ profile: AppEntry?) -> Bool {
        profile?.addressBarKeys != nil || BrainSafety.isBrowser(window, desktop.brainPlatform)
    }

    /// Says why the brain doesn't type or press keys in this window. The C# names File Explorer; the platform's file
    /// manager is `BrainPlatform.fileManagerName` (Finder on the Mac).
    func refuseCommandWindow(_ window: WindowInfo, typing: Bool, _ heard: String) {
        trace(typing ? "brain: refused typing in a command window" : "brain: refused keys in a command window")
        let places = desktop.brainPlatform
        let fileManager = places.isFileManager(window.processName)
        let message: String
        switch (fileManager, typing) {
        case (true, true):
            message = "I don't type in \(places.fileManagerName): it can start programs. Say “start typing” to dictate "
                + "there yourself."
        case (true, false):
            message = "I don't press keys in \(places.fileManagerName): they can start programs or delete files."
        case (false, true):
            message = "I don't type into command windows. Say “start typing” to dictate there yourself."
        case (false, false):
            message = "I don't press keys in command windows."
        }

        report(.warning, message, heard)
    }

    func askFirst(_ run: BrainRun, _ steps: [BrainStep], _ index: Int, _ window: WindowInfo, _ question: String)
        -> StepResult {
        brainPending = BrainPending(steps: steps, next: index, run: run, window: window, at: options.clock())
        if mode == .command {
            // The whole wait is available for the answer.
            awakeSince = options.clock()
        }

        trace("brain: \(BrainPlan.nameOf(steps[index].tool)) waits for yes")
        report(.warning, "\(question) Say “yes” to go ahead, or “no”.", run.heard)
        return .waiting
    }

    /// The windows (front first) and, for a few of them, what can be clicked or typed into: the screen text the model
    /// plans from. Never logged. The C# reads the chosen windows at once; here they're read one after the other, in
    /// the same order.
    func describeScreen(_ request: String) async throws -> (text: String, scanned: Int, items: Int) {
        let listed = try await desktop.listWindows()
        var windows = Array(listed.prefix(ScreenSummary.maxWindows))
        if windows.isEmpty, let front = desktop.foregroundWindow() {
            // Platforms without a window list: at least the window in front.
            windows.append(DesktopWindow(window: front, show: .normal, rect: desktop.windowRect(front)))
        }

        let toScan = ScreenSummary.chooseWindowsToScan(windows, request) { brainAppName($0) }
        var items: [Int: [UiElement]] = [:]
        for scanned in toScan {
            let clickable = try await desktop.listClickable(scanned.window)
            let boxes = try await desktop.listTextBoxes(scanned.window)
            items[scanned.window.handle] = clickable + boxes
        }

        let text = ScreenSummary.format(windows, items, request) { brainAppName($0) }
        return (text, toScan.count, items.values.reduce(0) { $0 + $1.count })
    }

    func brainAppName(_ window: WindowInfo) -> String {
        Self.appLabel(window, apps.findProfileForProcess(window.processName, window.title))
    }

    static func first(_ values: String...) -> String { values.first { !$0.isEmpty } ?? "" }

    /// `a != b` for C#'s strings: ordinal, nil only equal to nil.
    private static func differs(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (x?, y?): return !DotNet.ordinalEquals(x, y)
        default: return true
        }
    }
}

/// The model gave no answer within `InteractionController.brainPlanLimit`.
private struct BrainPlanTimeout: Error {}
