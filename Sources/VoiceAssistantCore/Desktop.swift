import Foundation
import ThumbFreeCore

/// Jarvis's windows are ThumbFreeCore's `WindowInfo` (C#'s `WindowRef` has the same fields), so the desktop layer the
/// two apps share hands out one kind of window.
extension WindowInfo {
    /// The same window, whatever its title is now. The system can reuse a window handle, so the process ID is compared
    /// too (C#'s `WindowRef.SameWindow`).
    public func sameWindow(_ other: WindowInfo?) -> Bool {
        guard let other else { return false }
        return other.handle == handle && other.processId == processId
    }
}

/// What the desktop did, with a message for the pill.
public struct DesktopResult: Equatable, Sendable {
    public var success: Bool
    public var message: String

    /// The window it acted on, when known.
    public var window: WindowInfo?

    public init(success: Bool, message: String, window: WindowInfo? = nil) {
        self.success = success
        self.message = message
        self.window = window
    }

    public static func ok(_ message: String, window: WindowInfo? = nil) -> DesktopResult {
        DesktopResult(success: true, message: message, window: window)
    }

    public static func fail(_ message: String) -> DesktopResult { DesktopResult(success: false, message: message) }
}

/// Whether a text box is ready for typing: `hasTrailingText` when it already holds text that ends where typing starts,
/// `focusIsEditable` when what has the focus takes text (nil when unknown).
public struct TextTargetResult: Equatable, Sendable {
    public var success: Bool
    public var message: String
    public var hasTrailingText: Bool?
    public var focusIsEditable: Bool?

    public init(success: Bool, message: String, hasTrailingText: Bool? = nil, focusIsEditable: Bool? = nil) {
        self.success = success
        self.message = message
        self.hasTrailingText = hasTrailingText
        self.focusIsEditable = focusIsEditable
    }
}

/// The focused control: its accessible name ("Search", possibly empty), whether it takes text, and whether it is part
/// of a web page (`inPage`: it has a UI Automation Document ancestor on Windows, an `AXWebArea` ancestor on the
/// Mac). In a browser anything outside the page is the browser's own address, search or find bar. `addressBar`: the
/// control itself says it is a browser's address bar, in browsers the app doesn't know too.
public struct FocusInfo: Equatable, Sendable {
    public var name: String
    public var editable: Bool
    public var inPage: Bool
    public var addressBar: Bool

    public init(name: String, editable: Bool, inPage: Bool, addressBar: Bool = false) {
        self.name = name
        self.editable = editable
        self.inPage = inPage
        self.addressBar = addressBar
    }
}

/// The focused field's text before the cursor. `caretKnown` is false when only the whole text could be read (the
/// cursor is then taken to be at the end); `hasSelection` when text is selected (edits are refused, since typing would
/// replace the selection); `editable` false for read-only text (pages, terminal output).
public struct CaretText: Equatable, Sendable {
    public var before: String
    public var caretKnown: Bool
    public var hasSelection: Bool
    public var editable: Bool

    public init(before: String, caretKnown: Bool, hasSelection: Bool = false, editable: Bool = true) {
        self.before = before
        self.caretKnown = caretKnown
        self.hasSelection = hasSelection
        self.editable = editable
    }
}

/// What has the keyboard focus, for typing (C#'s `FieldCheck`). ThumbFreeCore's `FieldCheck` has no `notText`.
public enum AssistantFieldCheck: Sendable {
    /// Positively confirmed not to be a password field.
    case safe

    case password

    /// The front window can't take synthesized input from this app (on Windows: it runs as administrator).
    case elevated

    /// The accessibility query failed or timed out; treated as unsafe.
    case unknown

    /// Nothing that takes text has the focus: the desktop, the Dock or the menu bar, or a list, button or link.
    /// Tap-to-dictate files the dictation on the idea board instead of typing it.
    case notText
}

/// How a window is shown.
public enum WindowShow: Sendable {
    case normal
    case minimized
    case maximized
}

/// The front window's default button (`JarvisDesktop.describeDefaultButton`).
public enum DefaultButtonInfo: Equatable, Sendable {
    /// The window has none.
    case noButton

    /// Its accessible name ("Erase", "Send"). An empty one means its title couldn't be read, and counts as unknown.
    case named(String)

    /// It couldn't be read.
    case unknown
}

/// A top-level app window: where it is and how it's shown, for the AI brain's view of the screen.
public struct DesktopWindow: Equatable, Sendable {
    public var window: WindowInfo
    public var show: WindowShow
    public var rect: ScreenRect?

    /// The usable part of the window's screen (without the menu bar and the Dock).
    public var workArea: ScreenRect?

    public init(window: WindowInfo, show: WindowShow, rect: ScreenRect? = nil, workArea: ScreenRect? = nil) {
        self.window = window
        self.show = show
        self.rect = rect
        self.workArea = workArea
    }
}

/// The assistant's operating-system side effects (C#'s `IDesktop`): Accessibility, NSWorkspace and CGEvent on the Mac
/// (VoiceAssistantMac), faked in tests. Methods that wait can throw `CancellationError` when their task is cancelled,
/// as C#'s take a `CancellationToken`; typing and keys throw what the platform reports, and typing stops there.
public protocol JarvisDesktop: AnyObject {
    /// The window that has the keyboard focus. On the Mac its `processName` is the bundle identifier of the app that
    /// has the keyboard focus (the system-wide Accessibility element's `AXFocusedApplication`), not
    /// `NSWorkspace.frontmostApplication`: Spotlight, Raycast, Alfred and LaunchBar show panels without activating
    /// their app, so the frontmost app would be the one behind the panel. The brain's checks (`brainPlatform`) read it.
    func foregroundWindow() -> WindowInfo?

    /// Opens or activates the app. With `newWindow`, an already-running app with `AppEntry.newWindowKeys` gets a fresh
    /// window. A successful result without a window means the launch was requested but the window couldn't be found.
    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult

    /// Verifies the focused control can take text and, for a profile with an `AppEntry.textArea`, focuses it.
    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult

    /// Finds an edit box named like "search" in the window and focuses it.
    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult

    func checkFocusedField() -> AssistantFieldCheck

    /// True if the focused text field already ends in a non-space character (so dictation needs a leading space); nil
    /// if unknown.
    func focusedTextEndsWithNonWhitespace() -> Bool?

    func typeText(_ text: String) throws

    /// Types `text`, pressing `newLineKeys` for each line break. Every typing with line breaks comes here, and the "new
    /// line" command too, so a desktop can refuse a whole typing, its line breaks included (the Mac's does while secure
    /// input is on); keys asked for by name stay with `pressKeys`. Default: `typeText` for each line's text and
    /// `pressKeys` for each line break, in order, as the C# does.
    func typeText(_ text: String, newLineKeys: String) throws

    /// Presses a chord such as "Shift+Enter" or one from a `ShortcutKeys`.
    func pressKeys(_ chord: String) throws

    func backspace(_ count: Int) throws

    /// The focused text field's text before the cursor (at most the last few thousand characters), so spoken edits can
    /// find words and sentences. Nil if the field's text can't be read. Default: nil.
    func readTextBeforeCaret() -> CaretText?

    /// Presses the chord `count` times (arrow keys for edits). Default: `pressKeys`, `count` times.
    func pressKeysRepeated(_ chord: String, _ count: Int) throws

    // Navigation (tabs, clicking by name, choosing a text box). The defaults say it isn't supported.

    /// The window's bounds in screen pixels, for "on the left / right" hints.
    func windowRect(_ window: WindowInfo) -> ScreenRect?

    /// Named, enabled, visible elements the user could click (buttons, links, tabs, list, tree and menu items).
    func listClickable(_ window: WindowInfo) async throws -> [UiElement]

    /// Visible, enabled text boxes in the window that aren't password fields.
    func listTextBoxes(_ window: WindowInfo) async throws -> [UiElement]

    /// Tabs of every open browser window, the front-most window first, in tab-strip order.
    func listTabs() async throws -> [BrowserTab]

    /// Brings the tab's window to the front, selects the tab, and verifies it is the active tab.
    func selectTab(_ tab: BrowserTab) async throws -> DesktopResult

    /// Activates the element (press, select, toggle, expand), falling back to a real click on its centre.
    func click(_ element: UiElement) async throws -> DesktopResult

    /// Focuses the text box and verifies the focus landed in it.
    func focusTextBox(_ box: UiElement) async throws -> TextTargetResult

    // The AI brain (windows-voice-assistant docs/design/ai-brain.md): the open windows, bringing one to the front or
    // zooming it, opening web pages.

    /// Top-level app windows (not the assistant's own), the front-most first.
    func listWindows() async throws -> [DesktopWindow]

    /// Restores the window if minimized, brings it to the front and verifies it is there.
    func activateWindow(_ window: WindowInfo) async throws -> DesktopResult

    /// Makes the window fill the usable part of its screen, as maximizing does. No Mac key does it
    /// (`ShortcutKeys.Maximize.zoomThroughAccessibility`), so where a plan presses Windows' maximize keys the brain
    /// zooms the window in front with this instead (`BrainKeyPress.zooms`). Default: it isn't supported.
    func zoom(_ window: WindowInfo) async throws -> DesktopResult

    /// Opens an http(s) page in a new tab of the browser in front, else the default browser; the result's window is the
    /// browser when it came to the front. It opens `link.url`, never `absoluteUri`, which keeps .NET's Unicode host.
    func openURL(_ link: WebLink) async throws -> DesktopResult

    /// What has the keyboard focus in the front window, for the brain's typing and Enter checks; nil if unknown.
    func describeFocus() -> FocusInfo?

    /// The front window's default button, which Return presses on the Mac whatever has the focus (`AXDefaultButton`:
    /// an alert's "Erase", a sheet's "Send"). On the Mac the brain asks before a key that submits when it sends,
    /// deletes or runs something, and when it can't be read; Windows doesn't read it. Default: `.unknown`, so a Mac
    /// desktop that doesn't read it asks.
    func describeDefaultButton() -> DefaultButtonInfo

    /// The name of the window's app as its user sees it (on the Mac `NSRunningApplication.localizedName`), for labels,
    /// messages and the brain's view of the screen; nil if unknown. Windows names apps from window titles and process
    /// names, as the C# does, and doesn't ask. Default: nil.
    func appName(_ window: WindowInfo) -> String?

    /// The platform's meanings for the brain's limits: where it never types, the browsers and the file manager, the
    /// button words, program files and keys. No default, so a desktop can't get another platform's by leaving it out.
    var brainPlatform: BrainPlatform { get }

    /// A window where text or keys can run a command: the brain never types or presses keys there. Default:
    /// `BrainSafety.isCommandWindow` with `brainPlatform`; a platform adds the windows it recognises.
    func isCommandWindow(_ window: WindowInfo) -> Bool
}

extension JarvisDesktop {
    public func typeText(_ text: String, newLineKeys: String) throws {
        for (i, line) in DotNet.split(text, ["\n"]).enumerated() {
            if i > 0 {
                try pressKeys(newLineKeys)
            }

            if !line.isEmpty {
                try typeText(line)
            }
        }
    }

    public func readTextBeforeCaret() -> CaretText? { nil }

    public func pressKeysRepeated(_ chord: String, _ count: Int) throws {
        for _ in 0..<max(0, count) {
            try pressKeys(chord)
        }
    }

    public func windowRect(_ window: WindowInfo) -> ScreenRect? { nil }

    public func listClickable(_ window: WindowInfo) async throws -> [UiElement] { [] }

    public func listTextBoxes(_ window: WindowInfo) async throws -> [UiElement] { [] }

    public func listTabs() async throws -> [BrowserTab] { [] }

    public func selectTab(_ tab: BrowserTab) async throws -> DesktopResult {
        .fail("Switching tabs isn't supported here.")
    }

    public func click(_ element: UiElement) async throws -> DesktopResult { .fail("Clicking isn't supported here.") }

    public func focusTextBox(_ box: UiElement) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "Choosing a text box isn't supported here.")
    }

    public func listWindows() async throws -> [DesktopWindow] { [] }

    public func activateWindow(_ window: WindowInfo) async throws -> DesktopResult {
        .fail("Switching windows isn't supported here.")
    }

    public func zoom(_ window: WindowInfo) async throws -> DesktopResult {
        .fail("Zooming windows isn't supported here.")
    }

    public func openURL(_ link: WebLink) async throws -> DesktopResult {
        .fail("Opening web pages isn't supported here.")
    }

    public func describeFocus() -> FocusInfo? { nil }

    public func describeDefaultButton() -> DefaultButtonInfo { .unknown }

    public func appName(_ window: WindowInfo) -> String? { nil }

    public func isCommandWindow(_ window: WindowInfo) -> Bool { BrainSafety.isCommandWindow(window, brainPlatform) }
}
