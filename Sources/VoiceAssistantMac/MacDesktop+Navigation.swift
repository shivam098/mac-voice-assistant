import AppKit
import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore

/// Navigation (windows-voice-assistant `WindowsDesktop.Navigation`): what can be clicked and typed into in a window,
/// clicking, and choosing a text box, through the Accessibility API. A scan walks the window's elements, one call each
/// (`AXSystem.node`), and keeps those that show; the ids it hands out find the elements again for a while
/// (`ElementRegistry`). Each runs off the caller's thread with the C#'s 4-second limit, and work still running when the
/// time is up never acts: the time is checked right before each action and each real click. Chromium browsers and
/// Electron apps describe their pages only once asked: a scan wakes one that this desktop hasn't woken yet (`wake`).
/// Logs hold counts and timings, never names.
extension MacDesktop {
    /// The most elements a scan hands out (C#'s `MaxElements`).
    static let maxElements = 1500

    /// The most elements a scan reads.
    static let maxScanned = 20_000

    /// How long a scan reads before it hands out what it found, inside the 4-second limit: a page too big to read in
    /// time still gives what was read.
    static let scanTime: TimeInterval = 3.5

    /// How long after an app was asked to describe its pages (`wake`) a scan waits for its page.
    static let wakeWait: TimeInterval = 2.5

    static let changedOnScreen = "that changed on screen"
    static let coveredUp = "something else is on top of it"
    static let timedOut = "timed out"

    /// Why an action wasn't followed by a real click: the app didn't answer it, which doesn't mean it isn't doing it.
    static let unanswered = "the app didn't answer"

    // MARK: Scans

    /// The window's frame (C#'s `GetWindowRect`): the window server's, else Accessibility's.
    public func windowRect(_ window: WindowInfo) -> ScreenRect? {
        if window.handle != 0, let server = workspace.serverWindow(window.handle) {
            return ScreenRect(server.bounds)
        }

        return windowElement(window).flatMap { try? ax.screenRect($0) }
    }

    /// Named, enabled elements that show in the window and can be clicked (C#'s `ListClickableAsync`).
    public func listClickable(_ window: WindowInfo) async throws -> [UiElement] {
        try await scanned("clickable scan") { [self] token in scanClickable(window, token) }
    }

    /// Enabled text boxes that show in the window and take typed text, but not password boxes (C#'s
    /// `ListTextBoxesAsync`).
    public func listTextBoxes(_ window: WindowInfo) async throws -> [UiElement] {
        try await scanned("text box scan") { [self] token in scanTextBoxes(window, token) }
    }

    /// Runs a scan with the time limit, as C#'s `RunUia` does with an empty list to fall back on.
    func scanned<Item: Sendable>(_ what: String, _ work: @escaping @Sendable (WorkToken) -> [Item]) async throws
        -> [Item]
    {
        switch try await Background.run(Self.accessibilityTimeout, work) {
        case .finished(let items):
            return items
        case .timedOut:
            log("\(what) timed out")
            return []
        }
    }

    /// C#'s `ScanClickable`: elements that can be clicked (`clickableRole`), enabled, named and showing.
    func scanClickable(_ window: WindowInfo, _ token: WorkToken) -> [UiElement] {
        let start = clock.now()
        guard let root = windowElement(window) else {
            log("clickable scan: no window")
            return []
        }

        wakeForScan(window, root, start, token)
        var found = 0
        var result: [UiElement] = []
        let deadline = start + Self.scanTime
        scan(root, token, deadline: deadline) { element, node, place in
            guard place.shows, let rect = place.rect, node.enabled != false,
                  let role = Self.clickableRole(node, place) else { return true }
            found += 1
            // A name cut short (the time ran out, or the app stopped answering) would be the wrong name: the scan
            // hands out what it has.
            guard let name = clickableName(element, node, inPage: place.inPage, deadline: deadline) else {
                return false
            }

            if !name.isEmpty {
                let id = registry.register(element, inPage: place.inPage)
                result.append(UiElement(id: id, name: name, role: role, rect: rect))
            }

            return result.count < Self.maxElements
        }

        log("clickable scan: \(result.count) of \(found) in \(milliseconds(since: start)) ms")
        return result
    }

    /// C#'s `ScanTextBoxes`: text fields, text areas and combo boxes that show, are enabled and at least 40 points
    /// wide, can take the focus and take typed text (`takesTypedText`), but not password boxes.
    func scanTextBoxes(_ window: WindowInfo, _ token: WorkToken) -> [UiElement] {
        let start = clock.now()
        guard let root = windowElement(window) else {
            log("text box scan: no window")
            return []
        }

        wakeForScan(window, root, start, token)
        var found = 0
        var result: [UiElement] = []
        scan(root, token, deadline: start + Self.scanTime) { element, node, place in
            guard let role = node.role, Self.textBoxRoles.contains(role), node.subrole != kAXSecureTextFieldSubrole,
                  node.enabled != false, place.shows, let rect = place.rect else { return true }
            found += 1
            guard rect.width >= 40, (try? ax.isSettable(kAXFocusedAttribute, of: element)) != false,
                  takesTypedText(element, role) else { return true }
            let name = DotNet.trim((try? ax.name(of: element)) ?? "")
            let id = registry.register(element, inPage: place.inPage)
            result.append(UiElement(id: id, name: name, role: .textBox, rect: rect))
            return true
        }

        log("text box scan: \(result.count) of \(found) in \(milliseconds(since: start)) ms")
        return result
    }

    static let textBoxRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// Whether a box takes typed text (the C#'s read-only test): a text field unless its value can't be set, as an Edit
    /// counts unless its ValuePattern is read-only; a text area or a combo box only when it's editable (`isEditable`),
    /// as a Document or ComboBox counts only with a ValuePattern that isn't read-only (not a web page's root document).
    func takesTypedText(_ element: AnyObject, _ role: String) -> Bool {
        if role == kAXTextFieldRole {
            return (try? ax.isSettable(kAXValueAttribute, of: element)) != false
        }

        return editable(element)
    }

    /// Where a scanned element is: its frame; whether it shows, inside the window and inside every scroll area, web
    /// area, table, outline and list around it (UI Automation's IsOffscreen false); whether it's part of a web page;
    /// and its parent's role.
    struct Place {
        var rect: ScreenRect?
        var shows: Bool
        var inPage: Bool
        var parentRole: String?
    }

    /// Walks the elements in `root` (a window) breadth first, reading at most `limit` of them until `deadline` (on the
    /// desktop's clock; `scanTime` from now when not given), checked before each one, and calls `visit` with each and
    /// where it is until `visit` says it has enough (false). Not into text, images and text boxes, which hold no
    /// controls, nor into a scroll area, web area, table, outline, list, row or cell that doesn't show; with `pages`
    /// false, not into web pages. A table or outline is walked by the rows that show (AXVisibleRows) when it says.
    /// What's in a sheet, a drawer, a popover or a menu shows where they are, inside the window or not. It stops when
    /// an app doesn't answer or `token` is cancelled.
    func scan(
        _ root: AnyObject, _ token: WorkToken, pages: Bool = true, limit: Int = MacDesktop.maxScanned,
        deadline: TimeInterval? = nil, _ visit: (AnyObject, AXNode, Place) -> Bool
    ) {
        struct Pending {
            let element: AnyObject
            let clip: ScreenRect?
            let inPage: Bool
            let parentRole: String?
        }

        let deadline = deadline ?? clock.now() + Self.scanTime
        var queue = [Pending(element: root, clip: nil, inPage: false, parentRole: nil)]
        var next = 0
        while next < queue.count, next < limit, !token.isCancelled {
            if clock.now() > deadline {
                log("scan stopped after \(next) elements")
                break
            }

            let item = queue[next]
            next += 1
            guard let node = try? ax.node(item.element) else { break }
            let rect = node.frame.map { ScreenRect($0) }
            var shows = false
            if let rect, !rect.isEmpty {
                shows = item.clip.map { rect.intersects($0) } ?? true
            }

            let place = Place(rect: rect, shows: shows, inPage: item.inPage, parentRole: item.parentRole)
            if !visit(item.element, node, place) {
                break
            }

            let role = node.role ?? ""
            if Self.scanLeaves.contains(role) || (!pages && role == AXName.webArea) {
                continue
            }

            var clip = item.clip
            if let rect, !rect.isEmpty {
                if Self.ownAreaRoles.contains(role) {
                    clip = rect
                } else if Self.clippingRoles.contains(role) {
                    guard shows else { continue }
                    clip = clip.map { $0.intersection(rect) } ?? rect
                } else if (role == kAXRowRole || role == kAXCellRole) && !shows {
                    continue
                }
            }

            var children = node.children
            if role == kAXTableRole || role == kAXOutlineRole,
               let rows = try? ax.elements(kAXVisibleRowsAttribute, of: item.element), !rows.isEmpty {
                children = rows
            }

            let inPage = item.inPage || role == AXName.webArea
            queue += children.map { Pending(element: $0, clip: clip, inPage: inPage, parentRole: node.role) }
        }
    }

    /// Roles whose elements show where they are, inside the window or not: the window, a sheet, a drawer, a popover, a
    /// menu.
    static let ownAreaRoles: Set<String> = [kAXWindowRole, kAXSheetRole, kAXDrawerRole, AXName.popover, kAXMenuRole]

    /// Roles that show only what's inside their own frame of what they hold.
    static let clippingRoles: Set<String> = [
        kAXScrollAreaRole, AXName.webArea, kAXTableRole, kAXOutlineRole, kAXListRole, kAXGridRole, kAXBrowserRole,
    ]

    /// Roles that hold no controls.
    static let scanLeaves: Set<String> = [kAXStaticTextRole, kAXImageRole, kAXTextFieldRole, kAXTextAreaRole]

    /// The core's role for an element that can be clicked, as UI Automation's control types map on Windows (C#'s
    /// `ClickableTypes`): buttons (and menu buttons and disclosure triangles), links, tabs (a radio button in a tab
    /// strip), menu items, tree items (an outline's rows), list items (other rows, and a web page's cells: a grid's,
    /// such as WhatsApp's chat list), checkboxes, radio buttons, and combo and pop-up buttons. Nil for anything else; a
    /// Mac app's table cells are their rows'.
    static func clickableRole(_ node: AXNode, _ place: Place) -> ElementRole? {
        switch node.role ?? "" {
        case kAXButtonRole, kAXMenuButtonRole, kAXDisclosureTriangleRole:
            return .button
        case AXName.link:
            return .link
        case kAXRadioButtonRole:
            return isTab(node, place) ? .tab : .radioButton
        case kAXMenuItemRole, kAXMenuBarItemRole:
            return .menuItem
        case kAXRowRole:
            return node.subrole == kAXOutlineRowSubrole ? .treeItem : .listItem
        case kAXCellRole:
            return place.inPage ? .listItem : nil
        case kAXCheckBoxRole:
            return .checkBox
        case kAXComboBoxRole, kAXPopUpButtonRole:
            return .comboBox
        default:
            return nil
        }
    }

    /// A tab: a radio button that says it's one (AXTabButton) or sits in a tab strip (AXTabGroup).
    static func isTab(_ node: AXNode, _ place: Place) -> Bool {
        node.subrole == AXName.tabButton || place.parentRole == kAXTabGroupRole
    }

    /// What a clickable is called (C#'s Name, trimmed): its title, else its description, else its label's text or its
    /// placeholder (`labelName`), else the text inside it, as Chromium names a row or a link by its contents: all of
    /// it in a web page (a WhatsApp chat row is "1 unread message Bibhash Morang 11:27 am…"), the first cell's for a
    /// row of a Mac app's table or outline (Finder's file name, as Explorer names a row). Empty when it has none; nil
    /// when it couldn't be read in full: a read got no answer (which isn't the same as no value), or `deadline` (on the
    /// desktop's clock) passed.
    func clickableName(_ element: AnyObject, _ node: AXNode, inPage: Bool, deadline: TimeInterval? = nil) -> String? {
        for text in [node.title, node.label] {
            if let text, !DotNet.isNullOrWhiteSpace(text) {
                return DotNet.trim(text)
            }
        }

        let labelled: String
        do {
            labelled = try ax.labelName(of: element)
        } catch {
            return nil
        }

        if !DotNet.isNullOrWhiteSpace(labelled) {
            return DotNet.trim(labelled)
        }

        return contentsText(node.children, firstOnly: node.role == kAXRowRole && !inPage, deadline: deadline)
    }

    /// The text inside an element (its name from contents): the values of its texts and text fields, in order, joined
    /// by spaces; read from at most 40 elements 4 levels down, at most 400 UTF-16 units. With `firstOnly`, only the
    /// first child that has some. Nil when a read there got no answer or `deadline` passed: what was read would be only
    /// part of it.
    func contentsText(_ children: [AnyObject], firstOnly: Bool, deadline: TimeInterval? = nil) -> String? {
        var parts: [String] = []
        var read = 0
        var cutShort = false
        func collect(_ element: AnyObject, _ depth: Int) {
            guard !cutShort, read < 40 else { return }
            if let deadline, clock.now() > deadline {
                cutShort = true
                return
            }

            guard let node = try? ax.node(element) else {
                cutShort = true
                return
            }

            read += 1
            switch node.role ?? "" {
            case kAXStaticTextRole, kAXTextFieldRole:
                let value: String?
                do {
                    value = try ax.string(kAXValueAttribute, of: element)
                } catch {
                    cutShort = true
                    return
                }

                let text = value ?? node.title ?? ""
                if !DotNet.isNullOrWhiteSpace(text) {
                    parts.append(DotNet.trim(text))
                }
            case kAXImageRole:
                return
            default:
                guard depth < 4 else { return }
                for child in node.children {
                    collect(child, depth + 1)
                }
            }
        }

        for child in children {
            collect(child, 1)
            if cutShort {
                return nil
            }

            if firstOnly && !parts.isEmpty {
                break
            }
        }

        return TextUnits.first(parts.joined(separator: " "), 400)
    }

    /// Milliseconds since `start` on the desktop's clock, for the logs.
    func milliseconds(since start: TimeInterval) -> Int {
        Int(((clock.now() - start) * 1000).rounded())
    }

    // MARK: Waking pages

    /// Chromium browsers by bundle identifier (betas and other channels add to it after a dot), as ThumbFreeMac's
    /// `FocusedField.Reader` knows them.
    static let chromiumBrowsers = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser",
    ]

    /// What turns on an app's descriptions of its pages, as VoiceOver turns them on: AXEnhancedUserInterface for a
    /// Chromium browser, AXManualAccessibility for an Electron app; nil for an app that describes them anyway (Safari,
    /// AppKit apps).
    func wakeAttribute(_ app: RunningApp) -> String? {
        if let id = app.bundleIdentifier,
           Self.chromiumBrowsers.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) {
            return "AXEnhancedUserInterface"
        }

        return workspace.isElectron(app) ? "AXManualAccessibility" : nil
    }

    /// An app that needs asking to describe its pages (`wakeAttribute`): its process, the key `woken` knows it by,
    /// and what it's asked with.
    struct Wakeable {
        let pid: pid_t
        let key: String
        let attribute: String
    }

    /// The window's app when it needs asking to describe its pages; nil for one that doesn't, or this app.
    func wakeable(_ window: WindowInfo) -> Wakeable? {
        guard let pid = pid_t(exactly: window.processId), pid != ownProcess, let app = workspace.app(pid),
              let attribute = wakeAttribute(app) else { return nil }
        return Wakeable(pid: pid, key: "\(pid) \(app.processName)", attribute: attribute)
    }

    /// Wakes the window's app when it needs it (`wakeAttribute`) and this desktop hasn't woken it yet, as
    /// ThumbFreeMac's reader wakes each app that comes to the front (the app's host runs one too); true when it woke
    /// it now. When it was asked is kept (`woken`). Chromium acts on the flag but hands it on to AppKit, which answers
    /// that the app has no such attribute: that counts as woken, and it isn't asked again, since each ask restarts the
    /// 2 s Chromium waits before it turns descriptions on. An app that didn't answer (one still starting) is asked
    /// again next time; the log says so once.
    func wake(_ window: WindowInfo) -> Bool {
        guard let app = wakeable(window) else { return false }
        return wake(app)
    }

    func wake(_ app: Wakeable) -> Bool {
        guard woken.claim(app.key, at: clock.now()) else { return false }
        let outcome = ax.set(app.attribute, true, of: ax.application(app.pid))
        switch outcome {
        case .done:
            log("page descriptions asked for")
            return true
        case .unsupported:
            log("page descriptions asked for (the app says it has no such setting)")
            return true
        case .gone, .noAnswer:
            woken.remove(app.key)
            if unansweredWakes.insert(app.key) {
                log("page descriptions not asked for: the app didn't answer (\(outcome))")
            }

            return false
        }
    }

    /// For a scan that started at `start`: wakes the window's app if it needs it (`wake`), then, while it's less than
    /// `wakeWait` since the app was asked (by this scan or an earlier one, such as a tab scan's), waits for its page to
    /// be described, which Chromium does about 2 s after it's asked.
    func wakeForScan(_ window: WindowInfo, _ root: AnyObject, _ start: TimeInterval, _ token: WorkToken) {
        guard let app = wakeable(window) else { return }
        let askedNow = wake(app)
        guard let asked = woken.time(app.key), start < asked + Self.wakeWait else { return }
        var waited = false
        while !token.isCancelled {
            if hasPage(root, token) {
                if askedNow || waited {
                    log("page described \(milliseconds(since: asked)) ms after waking")
                }

                return
            }

            if clock.now() + 0.25 > asked + Self.wakeWait {
                break
            }

            clock.sleep(0.25)
            waited = true
        }

        log("page not described \(milliseconds(since: asked)) ms after waking")
    }

    /// Whether the window holds a page with something in it (a web area with children), among its first 500 elements.
    func hasPage(_ root: AnyObject, _ token: WorkToken) -> Bool {
        var found = false
        scan(root, token, limit: 500) { _, node, _ in
            found = node.role == AXName.webArea && !node.children.isEmpty
            return !found
        }

        return found
    }

    // MARK: Clicking

    /// Clicks the element if it still has the name it was found with (C#'s `ClickAsync`, 4 s at most), through
    /// Accessibility or for real on its centre (`activateElement`). Windows first refuses windows that run as
    /// administrator; macOS has none.
    public func click(_ element: UiElement) async throws -> DesktopResult {
        guard let live = registry.lookup(element.id), let front = foregroundWindow() else {
            return .fail("That changed on screen. Try again.")
        }

        let outcome = try await Background.run(Self.accessibilityTimeout) { [self] token -> String? in
            // The confirmed name must still be the element's name: a page drawn again must not turn "click 7" or a
            // confirmed "yes" into a click on something else.
            guard let node = try? ax.node(live.element),
                  clickableName(live.element, node, inPage: live.inPage) == element.name else {
                return Self.changedOnScreen
            }

            return activateElement(
                live.element, element.rect, preferSelect: element.role == .tab, inPage: live.inPage, front, token)
        }

        let error: String?
        switch outcome {
        case .finished(let result):
            error = result
        case .timedOut:
            log("click timed out")
            error = Self.timedOut
        }

        if error == Self.unanswered {
            return .fail("\(label(front)) didn't answer, so I didn't click again.")
        }

        return error.map { DesktopResult.fail("I couldn't click that (\($0)).") } ?? .ok("Clicked.")
    }

    /// C#'s `Activate`. A web grid's row or cell is clicked for real (`clickGridItem`), and so is an app's table or
    /// outline row when the click lands on the row itself; anything else the first way it takes, in the C#'s order:
    /// selected, for a tab (AXSelected, as SelectionItem's Select); pressed (AXPress, as Invoke and Toggle); selected;
    /// opened or closed (AXDisclosing, as ExpandCollapse). When the app refuses that, or it takes none, a real click on
    /// its centre, only if that lands in `window`. When the app doesn't answer the action, no click: it may be doing
    /// it all the same (`unanswered`). The time is checked right before each action. Nil when it was done, else why
    /// not.
    func activateElement(
        _ element: AnyObject, _ rect: ScreenRect, preferSelect: Bool, inPage: Bool, _ window: WindowInfo,
        _ token: WorkToken
    ) -> String? {
        let role: String?
        do {
            role = try ax.role(of: element)
        } catch {
            // Gone from the screen, or no answer: never click where it used to be.
            return Self.changedOnScreen
        }

        let isRow: Bool = role == kAXRowRole || role == kAXCellRole
        if isRow && inPage && !preferSelect {
            // Web grid rows (chat lists) only highlight when selected through Accessibility; they open on a real click.
            return token.isCancelled ? Self.timedOut : clickGridItem(element, rect, window, token, native: false)
        }

        if isRow && !preferSelect && !token.isCancelled {
            // An app's rows take AXSelected, but some act only on a real click (Finder's sidebar goes to the folder):
            // clicked for real when the click lands on the row itself, else selected below.
            let clicked = clickGridItem(element, rect, window, token, native: true)
            if clicked == nil || clicked == Self.timedOut {
                return clicked
            }
        }

        enum Way {
            case select
            case press
            case disclose(Bool)
        }

        let selectable = (try? ax.isSettable(kAXSelectedAttribute, of: element)) == true
        let actions = (try? ax.actions(of: element)) ?? []
        var way: Way?
        if preferSelect && selectable {
            way = .select
        } else if actions.contains(kAXPressAction) {
            way = .press
        } else if selectable {
            way = .select
        } else if (try? ax.isSettable(kAXDisclosingAttribute, of: element)) == true {
            way = .disclose((try? ax.number(kAXDisclosingAttribute, of: element)) != 1)
        }

        if let way {
            if token.isCancelled {
                return Self.timedOut
            }

            let outcome: AXOutcome
            switch way {
            case .select:
                outcome = ax.set(kAXSelectedAttribute, true, of: element)
            case .press:
                outcome = ax.perform(kAXPressAction, on: element)
            case .disclose(let open):
                outcome = ax.set(kAXDisclosingAttribute, open, of: element)
            }

            switch outcome {
            case .done:
                return nil
            case .gone:
                return Self.changedOnScreen
            case .noAnswer:
                // kAXErrorCannotComplete doesn't mean it wasn't done: the app may be doing it still (AppKit runs a
                // pop-up button's menu inside the press), and a real click now could do it twice or close the menu.
                if case .press = way, menuShows(under: element, role: role) {
                    log("accessibility action got no answer, but its menu shows")
                    return nil
                }

                log("accessibility action got no answer, not clicking again")
                return Self.unanswered
            case .unsupported:
                log("accessibility action refused, clicking instead")
            }
        }

        if token.isCancelled {
            return Self.timedOut
        }

        return clickAt(CGPoint(x: rect.centerX, y: rect.centerY), window, token)
    }

    /// C#'s `ClickGridItem`: scrolls a web grid's row or cell into view (AXScrollToVisible), then clicks its centre for
    /// real, only if the element there is the target, or inside it or a row or cell around it up to 4 levels (WhatsApp
    /// draws the time over the name cell's centre); not when it's something else (a half-hidden row's centre can sit
    /// under the search box above the list). For an app's own (`native`) row, only the row itself, its cells, or text
    /// and images in them count, never a control in the row (a checkbox, a switch, Finder's eject button). The element
    /// there is asked of the window's app, where the C# asks the whole screen: `clickAt` checks no other window covers
    /// the point. Nil when it clicked, else why not.
    func clickGridItem(
        _ element: AnyObject, _ rect: ScreenRect, _ window: WindowInfo, _ token: WorkToken, native: Bool
    ) -> String? {
        if ((try? ax.actions(of: element)) ?? []).contains(AXName.scrollToVisible) {
            if token.isCancelled {
                return Self.timedOut
            }

            if ax.perform(AXName.scrollToVisible, on: element) == .done {
                clock.sleep(0.15)
            } else {
                log("scroll into view failed")
            }
        }

        var target = rect
        if let now = try? ax.screenRect(element), !now.isEmpty {
            target = now
        }

        let point = CGPoint(x: target.centerX, y: target.centerY)
        var accepted = [element]
        var parent = try? ax.element(kAXParentAttribute, of: element)
        for _ in 0..<4 {
            guard let current = parent else { break }
            let role = try? ax.role(of: current)
            if role == kAXRowRole || role == kAXCellRole {
                accepted.append(current)
            }

            parent = try? ax.element(kAXParentAttribute, of: current)
        }

        var onTarget = false
        if let pid = pid_t(exactly: window.processId) {
            var node = try? ax.element(at: point, of: ax.application(pid))
            var depth = 0
            while let current = node, depth < 25 {
                if accepted.contains(where: { ax.isSame(current, as: $0) }) {
                    onTarget = true
                    break
                }

                if native, !Self.rowParts.contains((try? ax.role(of: current)) ?? "") {
                    break
                }

                node = try? ax.element(kAXParentAttribute, of: current)
                depth += 1
            }
        }

        if !onTarget {
            log("grid item centre is covered by something else")
            return Self.coveredUp
        }

        return token.isCancelled ? Self.timedOut : clickAt(point, window, token)
    }

    /// What a click on an app's row may land on besides the row itself: its cells, and text and images in them.
    static let rowParts: Set<String> = [kAXCellRole, kAXStaticTextRole, kAXImageRole]

    /// Whether a pop-up or menu button's menu shows: AppKit lists it among the button's children, with a frame, while
    /// it's open. A press that got no answer then worked: AppKit may answer it only once the menu closes.
    func menuShows(under element: AnyObject, role: String?) -> Bool {
        guard role == kAXPopUpButtonRole || role == kAXMenuButtonRole,
              let children = try? ax.elements(kAXChildrenAttribute, of: element) else { return false }
        return children.contains { child in
            guard (try? ax.role(of: child)) == kAXMenuRole, let frame = try? ax.frame(of: child) else { return false }
            return !frame.isEmpty
        }
    }

    /// C#'s `ClickAt`: a real left click at a point of the screen, only if a click there lands in `window`, once held
    /// modifier keys are let go, and only if the time isn't up then; then the pointer goes back where it was. Nil when
    /// it clicked, else why not.
    func clickAt(_ point: CGPoint, _ window: WindowInfo, _ token: WorkToken) -> String? {
        let point = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        let landed = landing(window, at: point)
        guard landed == .target else {
            log("click point is not in the target window: \(landed.rawValue) there")
            return Self.coveredUp
        }

        guard permissions.status(.postEvents) == .granted else {
            log("click not allowed: no permission to post events")
            return "it needs the Accessibility permission"
        }

        typer.waitForModifiersReleased()
        guard !token.isCancelled else {
            log("click not sent: the time ran out")
            return Self.timedOut
        }

        return pointer.click(at: point) ? nil : Self.coveredUp
    }

    /// Where a click at a point lands (`landing`).
    enum Landing: String {
        case target = "the target window"
        case nothing = "no window"
        case otherApp = "another app's window"
        case otherWindow = "another window of its app"
        case ownApp = "a window of this app's"
    }

    /// Where a click at `point` lands (C#: whether `WindowFromPoint`'s root window is `window`): the target when it's
    /// `window` or a sheet open on it, or, for a window without a number, any of its app's. Accessibility's
    /// system-wide hit test finds the element a click there reaches, as the window server routes clicks: past windows
    /// that let them through (the Dock's, which spans the screen; this app's number badges). When it can't tell, the
    /// window server's list says (`serverLanding`). This app's other windows (the pill, a reminder card, a balloon)
    /// cover the point, as the C#'s `WindowFromPoint` finds its pill and reminder popup.
    func landing(_ window: WindowInfo, at point: CGPoint) -> Landing {
        accessibilityLanding(window, at: point) ?? serverLanding(window, at: point)
    }

    /// Where Accessibility's system-wide hit test says a click at `point` lands; nil when it can't tell: no answer, an
    /// element in a window that lets clicks through, or one whose window has no number.
    func accessibilityLanding(_ window: WindowInfo, at point: CGPoint) -> Landing? {
        guard let element = try? ax.elementAtPoint(point), let pid = try? ax.processIdentifier(of: element) else {
            return nil
        }

        if pid == ownProcess {
            // Should Accessibility ever find the badges' panel, which clicks go through, the window server's list goes
            // past it.
            guard let number = windowNumber(around: element), clickThrough.contains(number) else { return .ownApp }
            return nil
        }

        guard Int(pid) == window.processId else { return .otherApp }
        if window.handle == 0 {
            return .target
        }

        guard let number = windowNumber(around: element) else { return nil }
        if number == window.handle || isSheet(number, of: window) {
            return .target
        }

        return .otherWindow
    }

    /// The number of the window or sheet an element is in; nil when it can't be told.
    func windowNumber(around element: AnyObject) -> Int? {
        let role = try? ax.role(of: element)
        var around: AnyObject? = element
        if role != kAXWindowRole && role != kAXSheetRole {
            around = try? ax.element(kAXWindowAttribute, of: element)
        }

        return around.flatMap { ax.windowNumber(of: $0) }
    }

    /// Where the window server's list says a click at `point` lands: in the front-most window there that shows, past
    /// this app's windows that clicks go through (`clickThrough`: the badges) and the Dock's away from its icons
    /// (`isDockSeeThrough`).
    func serverLanding(_ window: WindowInfo, at point: CGPoint) -> Landing {
        var below = 0
        for _ in 0..<8 {
            guard let hit = pointer.windowNumber(at: point, below: below) else { return .nothing }
            let server = workspace.serverWindow(hit)
            let dock: Bool = server.map { isDockSeeThrough($0, at: point) } ?? false
            if clickThrough.contains(hit) || dock {
                below = hit
                continue
            }

            if server?.owner == ownProcess {
                return .ownApp
            }

            let sameApp: Bool = server.map { Int($0.owner) == window.processId } ?? false
            if window.handle == 0 {
                return sameApp ? .target : .otherApp
            }

            if hit == window.handle || isSheet(hit, of: window) {
                return .target
            }

            return sameApp ? .otherWindow : .otherApp
        }

        return .nothing
    }

    static let dockIdentifier = "com.apple.dock"

    /// Whether a click at `point` goes through this window of the Dock's: the Dock draws its icons in a window that
    /// spans the screen and lets clicks through everywhere else. True when the Dock says where its lists of icons are
    /// and none holds the point.
    func isDockSeeThrough(_ server: ServerWindow, at point: CGPoint) -> Bool {
        guard workspace.app(server.owner)?.bundleIdentifier == Self.dockIdentifier,
              let parts = try? ax.elements(kAXChildrenAttribute, of: ax.application(server.owner)) else { return false }
        var lists = 0
        for part in parts where (try? ax.role(of: part)) == kAXListRole {
            guard let frame = try? ax.frame(of: part), !frame.contains(point) else { return false }
            lists += 1
        }

        return lists > 0
    }

    /// Whether the window numbered `number` is a sheet open on `window`.
    func isSheet(_ number: Int, of window: WindowInfo) -> Bool {
        guard let element = windowElement(window) else { return false }
        let children = (try? ax.elements(kAXChildrenAttribute, of: element)) ?? []
        return children.contains { child in
            (try? ax.role(of: child)) == kAXSheetRole && ax.windowNumber(of: child) == number
        }
    }

    // MARK: Choosing a text box

    /// Focuses the text box and checks the focus landed in it (C#'s `FocusTextBoxAsync`, 4 s at most).
    public func focusTextBox(_ box: UiElement) async throws -> TextTargetResult {
        guard let live = registry.lookup(box.id), let front = foregroundWindow() else {
            return Self.fail("That text box changed. Try again.")
        }

        let outcome = try await Background.run(Self.accessibilityTimeout) { [self] token in
            focusBox(live.element, box.rect, front, token)
        }

        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            log("text box focus timed out")
            return Self.fail("That app isn't responding. Try again in a moment.")
        }
    }

    /// C#'s `FocusBox`: focused through Accessibility; when the focus isn't in it 0.15 s later (some web boxes ignore
    /// that), clicked for real once, only inside the window. Then it must have the focus, take text and not be a
    /// password box.
    func focusBox(_ element: AnyObject, _ rect: ScreenRect, _ window: WindowInfo, _ token: WorkToken)
        -> TextTargetResult
    {
        switch ax.set(kAXFocusedAttribute, true, of: element) {
        case .gone:
            return Self.fail("That text box changed. Try again.")
        case .unsupported, .noAnswer:
            log("text box focus through Accessibility failed")
        case .done:
            break
        }

        clock.sleep(0.15)
        var focused = focus()
        if !isInside(focused, element, rect) && !token.isCancelled {
            _ = clickAt(CGPoint(x: rect.centerX, y: rect.centerY), window, token)
            clock.sleep(0.2)
            focused = focus()
        }

        guard isInside(focused, element, rect), editable(focused) else {
            return Self.fail("I couldn't put the cursor in that box. Click it once, then say “start typing”.")
        }

        if check(focused) == .password {
            return Self.fail("That's a password field — I won't type there.")
        }

        return TextTargetResult(
            success: true, message: "", hasTrailingText: trailingText(focused), focusIsEditable: true)
    }

    /// C#'s `IsInside`: the focused element is the box, or inside it (rich editors focus an element within).
    func isInside(_ focused: AnyObject?, _ box: AnyObject, _ rect: ScreenRect) -> Bool {
        guard let focused else { return false }
        if ax.isSame(focused, as: box) {
            return true
        }

        guard let frame = try? ax.screenRect(focused), !frame.isEmpty else { return false }
        return rect.contains(frame.centerX, frame.centerY)
    }
}
