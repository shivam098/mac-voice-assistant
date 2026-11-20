/// A shortcut command ("copy", "new tab", "go back"): what it does, whatever keys the platform uses for it.
public enum Shortcut: CaseIterable, Sendable {
    case selectAll
    case copy
    case paste
    case cut
    case undo
    case redo
    case save
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case back
    case forward

    /// The folder that contains this one (File Explorer, Finder).
    case parentFolder
    case refresh
    case scrollDown
    case scrollUp
}

/// The keys the core presses for its shortcuts, so the same commands press the Mac's shortcuts on the Mac. The C# core
/// spells out Windows chords (Ctrl+C, Alt+Left, F5, Ctrl+Backspace, Win+Up); `windows` has them, and the ported tests
/// use it unchanged. `mac` follows docs/design.md, "Mac shortcuts". (Carbon has a `KeyMap`, hence the name.)
///
/// A chord names its modifiers first, in the order Ctrl, Alt, Shift, then Win or Cmd, joined by "+": "Ctrl+Shift+Tab",
/// "Shift+Cmd+Z". On the Mac, Cmd is ⌘, Ctrl ⌃, Alt is Option (⌥) and Shift ⇧. Keys the platforms share keep their
/// names: Enter, Tab, Esc, Backspace, the arrows, PageUp and PageDown.
public struct ShortcutKeys: Equatable, Sendable {
    /// How the front window is maximized.
    public enum Maximize: Equatable, Sendable {
        /// Press these keys (Windows: Win+Up).
        case keys(String)

        /// Zoom the window to fill the screen through Accessibility: no Mac shortcut does it.
        case zoomThroughAccessibility
    }

    public var selectAll: String
    public var copy: String
    public var paste: String
    public var cut: String
    public var undo: String
    public var redo: String
    public var save: String
    public var newTab: String
    public var closeTab: String
    public var nextTab: String
    public var previousTab: String
    public var back: String
    public var forward: String
    public var parentFolder: String
    public var refresh: String
    public var scrollDown: String
    public var scrollUp: String

    /// Deletes the word before the cursor, where the text can't be read to edit it exactly.
    public var deleteWordBefore: String

    public var maximize: Maximize

    public init(
        selectAll: String,
        copy: String,
        paste: String,
        cut: String,
        undo: String,
        redo: String,
        save: String,
        newTab: String,
        closeTab: String,
        nextTab: String,
        previousTab: String,
        back: String,
        forward: String,
        parentFolder: String,
        refresh: String,
        scrollDown: String,
        scrollUp: String,
        deleteWordBefore: String,
        maximize: Maximize
    ) {
        self.selectAll = selectAll
        self.copy = copy
        self.paste = paste
        self.cut = cut
        self.undo = undo
        self.redo = redo
        self.save = save
        self.newTab = newTab
        self.closeTab = closeTab
        self.nextTab = nextTab
        self.previousTab = previousTab
        self.back = back
        self.forward = forward
        self.parentFolder = parentFolder
        self.refresh = refresh
        self.scrollDown = scrollDown
        self.scrollUp = scrollUp
        self.deleteWordBefore = deleteWordBefore
        self.maximize = maximize
    }

    /// The keys for `shortcut`.
    public func keys(for shortcut: Shortcut) -> String {
        switch shortcut {
        case .selectAll: return selectAll
        case .copy: return copy
        case .paste: return paste
        case .cut: return cut
        case .undo: return undo
        case .redo: return redo
        case .save: return save
        case .newTab: return newTab
        case .closeTab: return closeTab
        case .nextTab: return nextTab
        case .previousTab: return previousTab
        case .back: return back
        case .forward: return forward
        case .parentFolder: return parentFolder
        case .refresh: return refresh
        case .scrollDown: return scrollDown
        case .scrollUp: return scrollUp
        }
    }

    /// The chords the C# core presses on Windows.
    public static let windows = ShortcutKeys(
        selectAll: "Ctrl+A", copy: "Ctrl+C", paste: "Ctrl+V", cut: "Ctrl+X", undo: "Ctrl+Z", redo: "Ctrl+Y",
        save: "Ctrl+S", newTab: "Ctrl+T", closeTab: "Ctrl+W", nextTab: "Ctrl+Tab", previousTab: "Ctrl+Shift+Tab",
        back: "Alt+Left", forward: "Alt+Right", parentFolder: "Alt+Up", refresh: "F5", scrollDown: "PageDown",
        scrollUp: "PageUp", deleteWordBefore: "Ctrl+Backspace", maximize: .keys("Win+Up"))

    /// The Mac's shortcuts: ⌘ where Windows uses Ctrl, ⇧⌘Z to redo, ⌘[ and ⌘] for back and forward, ⌘↑ for the
    /// enclosing folder in Finder, ⌘R to reload, ⌥⌫ to delete a word. Browsers and Finder switch tabs with ⌃Tab and
    /// ⌃⇧Tab, as on Windows.
    public static let mac = ShortcutKeys(
        selectAll: "Cmd+A", copy: "Cmd+C", paste: "Cmd+V", cut: "Cmd+X", undo: "Cmd+Z", redo: "Shift+Cmd+Z",
        save: "Cmd+S", newTab: "Cmd+T", closeTab: "Cmd+W", nextTab: "Ctrl+Tab", previousTab: "Ctrl+Shift+Tab",
        back: "Cmd+[", forward: "Cmd+]", parentFolder: "Cmd+Up", refresh: "Cmd+R", scrollDown: "PageDown",
        scrollUp: "PageUp", deleteWordBefore: "Alt+Backspace", maximize: .zoomThroughAccessibility)
}
