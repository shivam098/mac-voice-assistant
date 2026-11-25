import AppKit
import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore

/// What has the focus, the text before the cursor, the default button, and choosing the text box to type in
/// (windows-voice-assistant `WindowsDesktop`: `CheckFocusedField`, `ReadTextBeforeCaret`, `PrepareTextTarget`,
/// `FocusSearchBox`; `WindowsDesktop.Brain`: `DescribeFocus`). Each runs off the caller's thread, with the C#'s time
/// limits.
extension MacDesktop {
    /// The most text before the cursor that's read, in UTF-16 units (C#'s `MaxChars`).
    static let maxTextBefore = 20_000

    /// The most elements one look for text boxes walks through.
    static let maxWalked = 5_000

    // MARK: What has the focus

    /// Whether the focused control takes text and isn't a password box (C#'s `CheckFocusedField`, 0.8 s at most). The
    /// desktop, the Dock and the menu bar take nothing but a text box there (renaming an icon); elsewhere only
    /// something that positively doesn't take text (`isClearlyNotText`) is `.notText`. It's never `.elevated`: macOS
    /// has no windows that refuse this app's keys, as Windows' administrator windows do. While a password is being
    /// typed somewhere (secure input), `typeText` throws instead, as ThumbFree's typing does.
    public func checkFocusedField() -> AssistantFieldCheck {
        switch Background.wait(0.8, { [self] in fieldCheck() }) {
        case .finished(let check): return check
        case .timedOut: return .unknown
        }
    }

    func fieldCheck() -> AssistantFieldCheck {
        let focused = focus()
        let shell = isShell()
        if shell && !editable(focused) {
            return .notText
        }

        let result = check(focused)
        return result == .safe && !shell && clearlyNotText(focused) ? .notText : result
    }

    /// True if the focused box's text ends in something other than white space; nil when its text can't be read (C#'s
    /// `FocusedTextEndsWithNonWhitespace`, 0.6 s at most).
    public func focusedTextEndsWithNonWhitespace() -> Bool? {
        switch Background.wait(0.6, { [self] in trailingText(focus()) }) {
        case .finished(let ends): return ends
        case .timedOut: return nil
        }
    }

    /// The focused box's text before the cursor (C#'s `ReadTextBeforeCaret`, 1.5 s at most).
    public func readTextBeforeCaret() -> CaretText? {
        switch Background.wait(1.5, { [self] in caretText(focus()) }) {
        case .finished(let text): return text
        case .timedOut: return nil
        }
    }

    /// The focused control's name, whether it takes text and is in a web page, and whether it's Chromium's address bar
    /// (C#'s `DescribeFocus`, 0.6 s at most); nil when it can't be told.
    public func describeFocus() -> FocusInfo? {
        switch Background.wait(0.6, { [self] in focusInfo(focus()) }) {
        case .finished(let info): return info
        case .timedOut: return nil
        }
    }

    /// The default button of the window Return goes to (AXDefaultButton), 0.6 s at most: its name (empty when it can't
    /// be read) when it has one; `.unknown` when that window can't be told or doesn't answer, or when it's a sheet
    /// whose default button can't be read (the save panel's buttons are another process's).
    public func describeDefaultButton() -> DefaultButtonInfo {
        switch Background.wait(0.6, { [self] in defaultButton() }) {
        case .finished(let info): return info
        case .timedOut: return .unknown
        }
    }

    /// The element with the keyboard focus, in whichever app has it; nil when there's none or it can't be told (C#'s
    /// `Focused`).
    func focus() -> AnyObject? {
        try? ax.focusedElement()
    }

    /// C#'s `Check`: unknown without a focused element or an answer.
    func check(_ element: AnyObject?) -> AssistantFieldCheck {
        guard let element, let secure = try? ax.isSecure(element) else { return .unknown }
        return secure ? .password : .safe
    }

    /// C#'s `IsEditable`, false when it can't be told.
    func editable(_ element: AnyObject?) -> Bool {
        element.flatMap { try? ax.isEditable($0) } ?? false
    }

    func clearlyNotText(_ element: AnyObject?) -> Bool {
        element.flatMap { try? ax.isClearlyNotText($0) } ?? false
    }

    /// The desktop, the Dock or the menu bar takes the keys (C#'s Explorer windows Progman and WorkerW, the desktop,
    /// and Shell_TrayWnd, the taskbar): the Dock, SystemUIServer and Control Center (the menu bar's items), or Finder
    /// showing the desktop, whose "window" is an AXScrollArea, rather than one of its windows.
    func isShell() -> Bool {
        guard let app = try? ax.focusedApplication(), let pid = try? ax.processIdentifier(of: app),
              let bundle = workspace.app(pid)?.bundleIdentifier else { return false }
        if Self.shellApps.contains(bundle) {
            return true
        }

        guard bundle == "com.apple.finder" else { return false }
        do {
            guard let window = try ax.element(kAXFocusedWindowAttribute, of: app) else { return true }
            return try ax.role(of: window) != kAXWindowRole
        } catch {
            return false
        }
    }

    static let shellApps: Set<String> = ["com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter"]

    /// C#'s `HasTrailingText`: whether the box's text ends in something other than white space (half an emoji isn't
    /// white space); nil when it can't be read. Only its end is read (kAXStringForRangeParameterizedAttribute), as a
    /// long document's whole text would be big; a password box is never read.
    func trailingText(_ element: AnyObject?) -> Bool? {
        guard let element else { return nil }
        do {
            if try ax.isSecure(element) {
                return nil
            }

            if let count = try ax.number(kAXNumberOfCharactersAttribute, of: element), count >= 0 {
                if count == 0 {
                    return false
                }

                let range = CFRange(location: max(0, count - 2), length: min(count, 2))
                if let units = try ax.utf16(kAXStringForRangeParameterizedAttribute, for: range, of: element) {
                    return TextUnits.endsWithNonWhiteSpace(units)
                }
            }

            guard let value = try ax.string(kAXValueAttribute, of: element) else { return nil }
            return TextUnits.endsWithNonWhiteSpace(Array(value.utf16))
        } catch {
            return nil
        }
    }

    /// C#'s `ReadTextBeforeCaret`. With a cursor (kAXSelectedTextRangeAttribute, as a TextPattern's selection): the
    /// text from the box's start to it, exact, and whether text is selected. Else the whole value (ValuePattern), the
    /// cursor taken to be at the end. At most the last `maxTextBefore` UTF-16 units, fetched on their own; a password
    /// box is never read.
    func caretText(_ element: AnyObject?) -> CaretText? {
        guard let element else { return nil }
        do {
            if try ax.isSecure(element) {
                return nil
            }

            let takesText = editable(element)
            if let selection = try ax.range(kAXSelectedTextRangeAttribute, of: element), selection.location >= 0,
               let before = try textBefore(element, cursor: selection.location) {
                return CaretText(
                    before: before, caretKnown: true, hasSelection: selection.length > 0, editable: takesText)
            }

            if let value = try ax.string(kAXValueAttribute, of: element) {
                return CaretText(
                    before: TextUnits.last(value, Self.maxTextBefore), caretKnown: false, editable: takesText)
            }
        } catch {
            log("read text before cursor failed: no answer")
        }

        return nil
    }

    /// The last `maxTextBefore` UTF-16 units before `cursor` (kAXStringForRangeParameterizedAttribute), with one unit
    /// more so half an emoji cut at the start goes; else the value's first `cursor` units; nil when neither is there.
    func textBefore(_ element: AnyObject, cursor: Int) throws -> String? {
        if cursor == 0 {
            return ""
        }

        let start = max(0, cursor - Self.maxTextBefore - 1)
        let range = CFRange(location: start, length: cursor - start)
        if let units = try ax.utf16(kAXStringForRangeParameterizedAttribute, for: range, of: element) {
            return TextUnits.last(TextUnits.text(units), Self.maxTextBefore)
        }

        return try ax.string(kAXValueAttribute, of: element).map {
            TextUnits.last(TextUnits.first($0, cursor), Self.maxTextBefore)
        }
    }

    func focusInfo(_ element: AnyObject?) -> FocusInfo? {
        guard let element else { return nil }
        do {
            return try FocusInfo(
                name: ax.name(of: element), editable: editable(element), inPage: ax.isInWebPage(element),
                addressBar: (try? ax.isAddressBar(element)) ?? false)
        } catch {
            return nil
        }
    }

    func defaultButton() -> DefaultButtonInfo {
        do {
            guard let window = try returnWindow() else { return .noButton }
            guard let button = try ax.element(kAXDefaultButtonAttribute, of: window.element) else {
                // A sheet's buttons can be another process's (the save panel's), which it doesn't name: not read.
                return window.isSheet ? .unknown : .noButton
            }

            return .named((try? ax.name(of: button)) ?? "")
        } catch {
            return .unknown
        }
    }

    /// The window Return goes to: the window around the focused element, else the focused window of the app taking the
    /// keys; or the sheet open on it, which takes the keys while it's open. Throws when the app taking the keys can't
    /// be told.
    func returnWindow() throws -> (element: AnyObject, isSheet: Bool)? {
        var found: AnyObject?
        if let focused = try ax.focusedElement() {
            found = try ax.element(kAXWindowAttribute, of: focused)
        }

        if found == nil {
            guard let app = try ax.focusedApplication() else { throw AXNoAnswer() }
            found = try ax.element(kAXFocusedWindowAttribute, of: app)
        }

        guard let window = found else { return nil }
        if try ax.role(of: window) == kAXSheetRole {
            return (element: window, isSheet: true)
        }

        let sheet = try ax.elements(kAXChildrenAttribute, of: window).last { (try? ax.role(of: $0)) == kAXSheetRole }
        return sheet.map { (element: $0, isSheet: true) } ?? (element: window, isSheet: false)
    }

    // MARK: Choosing the text box

    /// Checks that the focused control can take text and, for a profile with a text area, focuses it (C#'s
    /// `PrepareTextTargetAsync`, 4 s at most). Windows first refuses administrator windows; macOS has none.
    public func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        let outcome = try await Background.run(Self.accessibilityTimeout) { [self] token in
            prepare(window, profile, token)
        }

        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            log("ax prepare timed out")
            let name = profile?.name ?? label(window)
            return Self.fail("\(name) isn't responding, so I can't check where I'd be typing. Try again in a moment.")
        }
    }

    /// Finds an edit box named like "search" in the window and focuses it (C#'s `FocusSearchBoxAsync`, 4 s at most).
    public func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        switch try await Background.run(Self.accessibilityTimeout, { [self] token in focusSearch(window, token) }) {
        case .finished(let result):
            return result
        case .timedOut:
            log("ax search box timed out")
            return Self.fail("That app isn't responding. Try again in a moment.")
        }
    }

    /// C#'s `PrepareTextTarget`: with a profile's text area ("Bottom" or "Largest", and its name), when the focus isn't
    /// in a text box, or not in the one named, that box is found and focused; then the focused control is checked.
    func prepare(_ window: WindowInfo, _ profile: AppEntry?, _ token: WorkToken) -> TextTargetResult {
        var focused = focus()
        let wrongBox = profile?.textAreaName.map { !matchesName(focused, $0) } ?? false
        if let profile, let strategy = profile.textArea, !editable(focused) || wrongBox {
            var area = findTextArea(window, strategy, profile.textAreaName, token)
            if area == nil {
                // Chromium and Electron describe their pages once asked: give them a moment.
                clock.sleep(0.4)
                area = findTextArea(window, strategy, profile.textAreaName, token)
            }

            guard let area else {
                return Self.fail(
                    "I couldn't find where to type in \(profile.name). Click it once, then say “start typing”.")
            }

            if token.isCancelled {
                return Self.fail("")
            }

            if ax.set(kAXFocusedAttribute, true, of: area) != .done {
                log("text area focus failed")
            }

            clock.sleep(0.15)
            focused = focus()
            if !editable(focused) || (profile.textAreaName.map { !matchesName(focused, $0) } ?? false) {
                return Self.fail(
                    "I couldn't focus the text area in \(profile.name). Click it once, then say “start typing”.")
            }
        }

        switch check(focused) {
        case .password:
            return Self.fail("That's a password field — I won't type there.")
        case .unknown:
            return Self.fail("I couldn't check the focused field. Click into the text box, then say “start typing”.")
        default:
            return TextTargetResult(
                success: true, message: "", hasTrailingText: trailingText(focused), focusIsEditable: editable(focused))
        }
    }

    /// C#'s `FocusSearchBox`.
    func focusSearch(_ window: WindowInfo, _ token: WorkToken) -> TextTargetResult {
        var box = findSearchBox(window, token)
        if box == nil {
            clock.sleep(0.4)
            box = findSearchBox(window, token)
        }

        let name = label(window)
        guard let box else { return Self.fail("I couldn't find a search box in \(name).") }
        if token.isCancelled {
            return Self.fail("")
        }

        if ax.set(kAXFocusedAttribute, true, of: box) != .done {
            log("search focus failed")
        }

        clock.sleep(0.15)
        return editable(focus())
            ? TextTargetResult(success: true, message: "")
            : Self.fail("I couldn't focus the search box in \(name). Click it once, then say “start typing”.")
    }

    /// C#'s `FindSearchBox`: a text box or combo box whose name, identifier or help text says "search", or a search
    /// field (AXSearchField, which says it in any language); the top-most one wins.
    func findSearchBox(_ window: WindowInfo, _ token: WorkToken) -> AnyObject? {
        guard let root = windowElement(window) else { return nil }
        let boxes = editableCandidates(root, includeCombo: true, token).filter { box in
            if box.subrole == kAXSearchFieldSubrole {
                return true
            }

            let words = [
                (try? ax.name(of: box.element)) ?? "", (try? ax.identifier(of: box.element)) ?? "",
                (try? ax.helpText(of: box.element)) ?? "",
            ]
            return TextUnits.contains(words.joined(separator: " "), "search")
        }

        return DotNet.orderBy(boxes) { $0.rect.y }.first?.element
    }

    /// C#'s `FindTextArea`: "Bottom" (a chat's message box at the bottom of the window) is the lowest box, "Largest" (a
    /// document editor) the biggest, of those at least 120 points wide and, with `name`, named so.
    func findTextArea(_ window: WindowInfo, _ strategy: String, _ name: String?, _ token: WorkToken) -> AnyObject? {
        guard let root = windowElement(window) else { return nil }
        var boxes = editableCandidates(root, includeCombo: false, token).filter { $0.rect.width >= 120 }
        if let name {
            boxes = boxes.filter { matchesName($0.element, name) }
        }

        let ordered = DotNet.equalsOrdinalIgnoreCase(strategy, "Largest")
            ? DotNet.orderByDescending(boxes) { $0.rect.width * $0.rect.height }
            : DotNet.orderByDescending(boxes) { $0.rect.bottom }
        return ordered.first?.element
    }

    /// C#'s `MatchesName`: the element's name is `name`, or its help text contains it, ignoring case.
    func matchesName(_ element: AnyObject?, _ name: String) -> Bool {
        guard let element else { return false }
        let own = (try? ax.name(of: element)) ?? ""
        let help = (try? ax.helpText(of: element)) ?? ""
        return DotNet.equalsOrdinalIgnoreCase(own, name) || TextUnits.contains(help, name)
    }

    /// A text box found in a window.
    struct TextBox {
        let element: AnyObject
        let subrole: String?
        let rect: ScreenRect
    }

    /// C#'s `EditableCandidates`: the window's enabled text boxes that take text, can have the focus, show inside the
    /// window and aren't password boxes: text fields and text areas, and combo boxes with `includeCombo`.
    func editableCandidates(_ root: AnyObject, includeCombo: Bool, _ token: WorkToken) -> [TextBox] {
        let bounds = try? ax.screenRect(root)
        let roles = [kAXTextFieldRole, kAXTextAreaRole] + (includeCombo ? [kAXComboBoxRole] : [])
        var found: [TextBox] = []
        walk(root, token) { element, node in
            guard let role = node.role, roles.contains(role), node.subrole != kAXSecureTextFieldSubrole,
                  let rect = try? ax.screenRect(element), !rect.isEmpty, bounds.map({ rect.intersects($0) }) ?? true,
                  (try? ax.number(kAXEnabledAttribute, of: element)) != 0,
                  (try? ax.isSettable(kAXFocusedAttribute, of: element)) != false,
                  editable(element) else { return }
            found.append(TextBox(element: element, subrole: node.subrole, rect: rect))
        }

        return found
    }

    /// Walks the elements in `root`, breadth first and at most `maxWalked`, calling `visit` with each: not into text,
    /// images or text boxes, which hold no boxes. It stops when an app doesn't answer or `token` is cancelled.
    func walk(_ root: AnyObject, _ token: WorkToken, _ visit: (AnyObject, AXNode) -> Void) {
        var queue: [AnyObject] = [root]
        var next = 0
        while next < queue.count, next < Self.maxWalked, !token.isCancelled {
            let element = queue[next]
            next += 1
            guard let node = try? ax.node(element) else { return }
            visit(element, node)
            if !Self.leafRoles.contains(node.role ?? "") {
                queue += node.children
            }
        }
    }

    static let leafRoles: Set<String> = [kAXStaticTextRole, kAXImageRole, kAXTextFieldRole, kAXTextAreaRole]

    static func fail(_ message: String) -> TextTargetResult {
        TextTargetResult(success: false, message: message)
    }
}

/// Text in UTF-16 units, as .NET counts it, without ever keeping half of a character made of two (a surrogate pair, as
/// in most emoji), which a Swift string can't hold and a C# one can.
enum TextUnits {
    /// Text from UTF-16 units that a range may have cut: half an emoji at either end goes.
    static func text(_ units: [UInt16]) -> String {
        var whole = units[...]
        if let first = whole.first, UTF16.isTrailSurrogate(first) {
            whole = whole.dropFirst()
        }

        if let last = whole.last, UTF16.isLeadSurrogate(last) {
            whole = whole.dropLast()
        }

        return String(decoding: whole, as: UTF16.self)
    }

    /// The first `count` UTF-16 units of `text`; a count inside a pair stops before it.
    static func first(_ text: String, _ count: Int) -> String {
        let units = text.utf16
        var end = units.index(units.startIndex, offsetBy: min(max(count, 0), units.count))
        while end > units.startIndex, end.samePosition(in: text.unicodeScalars) == nil {
            end = units.index(before: end)
        }

        return String(String.UnicodeScalarView(text.unicodeScalars[..<end]))
    }

    /// The last `count` UTF-16 units of `text` (C#'s `value[^count..]`); a count inside a pair starts after it.
    static func last(_ text: String, _ count: Int) -> String {
        let units = text.utf16
        guard units.count > count else { return text }
        var start = units.index(units.endIndex, offsetBy: -count)
        while start < units.endIndex, start.samePosition(in: text.unicodeScalars) == nil {
            start = units.index(after: start)
        }

        return String(String.UnicodeScalarView(text.unicodeScalars[start...]))
    }

    /// `value.Length > 0 && !char.IsWhiteSpace(value[^1])`: half of an emoji isn't white space.
    static func endsWithNonWhiteSpace(_ units: [UInt16]) -> Bool {
        guard let last = units.last else { return false }
        guard let scalar = Unicode.Scalar(last) else { return true }
        return !DotNet.isWhiteSpace(scalar)
    }

    /// `text.Contains(part, StringComparison.OrdinalIgnoreCase)`.
    static func contains(_ text: String, _ part: String) -> Bool {
        let whole = DotNet.ordinalIgnoreCase(text)
        let wanted = DotNet.ordinalIgnoreCase(part)
        guard !wanted.isEmpty else { return true }
        guard wanted.count <= whole.count else { return false }
        return (0...(whole.count - wanted.count)).contains { start in
            whole[start..<(start + wanted.count)].elementsEqual(wanted)
        }
    }
}
