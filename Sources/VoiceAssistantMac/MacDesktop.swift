import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantCore

/// The Mac's side of the core's `JarvisDesktop` (windows-voice-assistant `WindowsDesktop`): apps and windows through
/// NSWorkspace and the Accessibility API (`AXSystem`), keys through CGEvent (`KeyPresser`, on ThumbFreeMac's
/// `PasteTyper.Keys`), and typing through ThumbFreeMac's `PasteTyper`, which pastes and puts the pasteboard back.
/// Navigation scans windows through Accessibility and clicks with its actions or, failing those, the pointer
/// (`PointerSystem`); Safari's tabs come from AppleScript (`ScriptSystem`). Chromium browsers and Electron apps
/// describe their pages only once asked: ThumbFreeMac's `FocusedField.Reader.startWaking()` (the host's) asks each app
/// that comes to the front, and a scan asks an app this desktop hasn't asked yet (`wake`).
///
/// The core calls it from its own task, one call at a time (`InteractionController`'s contract), never on the main
/// thread. Accessibility work runs off the caller's thread with the C#'s time limits; every call to an app waits at
/// most `SystemAX.timeout`, and work that gets no answer stops. Logs (`log`) hold outcomes, counts and timings, never
/// names, titles or text. Messages that said "Windows" say "macOS".
///
/// The window handle is the window server's window number (CGWindowID), so two windows of one app are told apart, as
/// HWNDs are; `WindowInfo.processName` is the bundle identifier of the app taking the keys and `appName` its name as
/// macOS shows it. Rectangles (`ScreenRect`) are in points from the top left of the main display, y down, as
/// Accessibility gives them.
public final class MacDesktop: JarvisDesktop, @unchecked Sendable {
    /// The time limit for Accessibility work that the core awaits (C#'s `UiaTimeout`).
    static let accessibilityTimeout: TimeInterval = 4

    public let brainPlatform = BrainPlatform.mac

    let ax: AXSystem
    let workspace: WorkspaceSystem
    let typer: PasteTyper
    let presser: KeyPresser
    let pointer: PointerSystem
    let scripts: ScriptSystem
    let permissions: Permissions
    let clock: DesktopClock
    let ownProcess: pid_t

    /// The elements and tabs scans handed out (`MacDesktop+Navigation`, `MacDesktop+Tabs`).
    let registry = ElementRegistry()

    /// The apps whose pages this desktop has asked to be described (`MacDesktop.wake`), by process and bundle
    /// identifier.
    let woken = KeySet()

    /// The apps that didn't answer when asked to describe their pages, so the log says it once.
    let unansweredWakes = KeySet()

    /// The browsers whose Automation permission is being asked for (`MacDesktop+Tabs`).
    let automationAsks = KeySet()
    private let insertMethod: @Sendable () -> String
    private let logger: (@Sendable (String) -> Void)?

    /// The Mac itself.
    /// - Parameters:
    ///   - scripts: AppleScript, for Safari's tabs.
    ///   - insertMethod: The insertMethod setting, read before each typing: "Paste", or "Type" for key events (C#'s
    ///     `WindowsDesktop.InsertMethod`).
    ///   - log: Where log lines go.
    public convenience init(
        scripts: ScriptSystem = SystemScripts(), insertMethod: @escaping @Sendable () -> String = { "Paste" },
        log: (@Sendable (String) -> Void)? = nil
    ) {
        let permissions = Permissions()
        let keys = PasteTyper.SystemKeys(permissions: permissions)
        self.init(
            ax: SystemAX(), workspace: SystemWorkspace(), typer: PasteTyper(keys: keys), keys: keys,
            layout: SystemKeyLayout(), scripts: scripts, permissions: permissions, insertMethod: insertMethod, log: log)
    }

    /// - Parameters:
    ///   - typer: Types text; it should send its keys with `keys`.
    ///   - keys: Where chords go.
    ///   - pointer: Where a click lands, and real clicks.
    ///   - scripts: AppleScript, for Safari's tabs.
    ///   - ownProcess: This app's process, which is never a window to act on.
    public init(
        ax: AXSystem, workspace: WorkspaceSystem, typer: PasteTyper, keys: PasteTyper.Keys, layout: KeyLayout,
        pointer: PointerSystem = SystemPointer(), scripts: ScriptSystem = SystemScripts(),
        permissions: Permissions = Permissions(), clock: DesktopClock = .system,
        ownProcess: pid_t = ProcessInfo.processInfo.processIdentifier,
        insertMethod: @escaping @Sendable () -> String = { "Paste" }, log: (@Sendable (String) -> Void)? = nil
    ) {
        self.ax = ax
        self.workspace = workspace
        self.typer = typer
        presser = KeyPresser(keys: keys, layout: layout)
        self.pointer = pointer
        self.scripts = scripts
        self.permissions = permissions
        self.clock = clock
        self.ownProcess = ownProcess
        self.insertMethod = insertMethod
        logger = log
    }

    /// The permissions the desktop works with that macOS hasn't given this app yet, for the app to explain: reading
    /// and controlling other apps (`.accessibility`) and sending keys (`.postEvents`), both the app's switch in System
    /// Settings › Privacy & Security › Accessibility.
    public var missingPermissions: [Permissions.Kind] {
        [Permissions.Kind.accessibility, .postEvents].filter { permissions.status($0) != .granted }
    }

    /// The installed apps (`InstalledApps`), for the core's `AppCatalog.setDiscoveredApps` (C#'s `StartMenuApps`). It
    /// reads folders: call it off the main thread.
    public func discoverApps() -> [AppEntry] {
        let apps = InstalledApps.discover(workspace)
        log("installed apps discovered: \(apps.count)")
        return apps
    }

    // MARK: The window in front

    /// The app taking the keys (the system-wide AXFocusedApplication, so Spotlight's and Raycast's panels count) and
    /// its focused window: nil when that's this app, or when Accessibility can't tell. When Accessibility answers that
    /// no app has the keys, the app in front, if it's a regular app, and its focused window, else its main one: some
    /// apps answer only for themselves (Chrome just started, on GitHub's runner), as `focus()` finds. An app without a
    /// window comes back with handle 0 and no title.
    public func foregroundWindow() -> WindowInfo? {
        let focused: AnyObject?
        do {
            focused = try ax.focusedApplication()
        } catch {
            return nil
        }

        if let app = focused {
            guard let pid = try? ax.processIdentifier(of: app), pid != ownProcess else { return nil }
            return windowInfo(pid, try? ax.element(kAXFocusedWindowAttribute, of: app))
        }

        guard let front = workspace.frontmostApp(), front.isRegular, front.processIdentifier != ownProcess else {
            return nil
        }

        let app = ax.application(front.processIdentifier)
        var window: AnyObject? = try? ax.element(kAXFocusedWindowAttribute, of: app)
        if window == nil {
            window = try? ax.element(kAXMainWindowAttribute, of: app)
        }

        return windowInfo(front.processIdentifier, window)
    }

    /// The window as the core knows it: its number, its app's process and bundle identifier, its title and its app's
    /// name.
    func windowInfo(_ pid: pid_t, _ window: AnyObject?) -> WindowInfo {
        let app = workspace.app(pid)
        let title = window.flatMap { try? ax.string(kAXTitleAttribute, of: $0) } ?? ""
        let handle = window.flatMap { ax.windowNumber(of: $0) } ?? 0
        return WindowInfo(
            handle: handle, processId: Int(pid), processName: app?.processName ?? "", title: title,
            appName: app?.name)
    }

    /// The window's element: the app's window with its number, or for a window without one (handle 0) the app's
    /// focused window.
    func windowElement(_ window: WindowInfo) -> AnyObject? {
        guard let pid = pid_t(exactly: window.processId) else { return nil }
        let app = ax.application(pid)
        if window.handle == 0 {
            return try? ax.element(kAXFocusedWindowAttribute, of: app)
        }

        let windows = (try? ax.elements(kAXWindowsAttribute, of: app)) ?? []
        if let match = windows.first(where: { ax.windowNumber(of: $0) == window.handle }) {
            return match
        }

        let focused = try? ax.element(kAXFocusedWindowAttribute, of: app)
        return focused.flatMap { ax.windowNumber(of: $0) == window.handle ? $0 : nil }
    }

    /// The app's name as macOS shows it (NSRunningApplication.localizedName).
    public func appName(_ window: WindowInfo) -> String? {
        guard let pid = pid_t(exactly: window.processId) else { return nil }
        return workspace.app(pid)?.name
    }

    /// What messages call a window: its app's name, else its title, else its bundle identifier. (Windows names it by
    /// its title, which names the app there.)
    func label(_ window: WindowInfo) -> String {
        if let name = appName(window), !DotNet.isNullOrWhiteSpace(name) {
            return name
        }

        return DotNet.isNullOrWhiteSpace(window.title) ? window.processName : window.title
    }

    /// The core's places by bundle identifier (`BrainSafety.isCommandWindow` with `BrainPlatform.mac`), checked for the
    /// app the window's process is too, should the window name it otherwise.
    public func isCommandWindow(_ window: WindowInfo) -> Bool {
        if BrainSafety.isCommandWindow(window, brainPlatform) {
            return true
        }

        guard let pid = pid_t(exactly: window.processId), let running = workspace.app(pid)?.processName,
              !running.isEmpty, !DotNet.equalsOrdinalIgnoreCase(running, window.processName) else { return false }
        var actual = window
        actual.processName = running
        return BrainSafety.isCommandWindow(actual, brainPlatform)
    }

    // MARK: Typing and keys

    /// Pastes (or, with insertMethod "Type", types with key events) `text`, its line breaks as spaces, once held
    /// modifier keys are let go (`PasteTyper.paste`). Nothing is typed while a password is being typed somewhere
    /// (secure input): PasteTyper throws then, as for ThumbFree.
    public func typeText(_ text: String) throws {
        useInsertMethod()
        try typer.paste(text)
    }

    /// Types `text` with each line break as `newLineKeys`, a chord of the Mac's grammar (⇧↩ in chat apps, where ↩
    /// sends), as ThumbFreeMac's `PasteTyper.type` types a dictation: each line pasted (or typed with keys) and the
    /// new-line keys pressed between lines, each once held modifier keys are let go and secure input is checked. The
    /// core sends every typing with line breaks here, and the "new line" and "new paragraph" commands. While a
    /// password is being typed somewhere, or Terminal's Secure Keyboard Entry is on, nothing goes out, not even the
    /// new-line keys of a text that starts with a line break, and PasteTyper's `Failure.secureInput` comes through as
    /// it is. Keys asked for by name (`pressKeys`) still go out then, as on Windows.
    public func typeText(_ text: String, newLineKeys: String) throws {
        let newLine = try presser.resolve(newLineKeys)
        useInsertMethod()
        try typer.type(text, newLine: newLine)
    }

    /// The insertMethod setting, read before each typing: "Paste", or "Type" for key events.
    private func useInsertMethod() {
        typer.insertMethod = DotNet.equalsOrdinalIgnoreCase(insertMethod(), "Paste") ? .paste : .typeWithKeys
    }

    /// Presses a chord in the Mac's grammar (`MacChord`) once held modifier keys are let go; `UnknownKeys` for any
    /// other.
    public func pressKeys(_ chord: String) throws {
        let keys = try presser.resolve(chord)
        typer.waitForModifiersReleased()
        try presser.press(keys)
    }

    public func backspace(_ count: Int) throws {
        guard count > 0 else { return }
        typer.waitForModifiersReleased()
        try presser.press(PasteTyper.Chord(key: CGKeyCode(kVK_Delete)), times: count)
    }

    public func pressKeysRepeated(_ chord: String, _ count: Int) throws {
        let keys = try presser.resolve(chord)
        typer.waitForModifiersReleased()
        try presser.press(keys, times: count)
    }

    func log(_ line: String) {
        logger?(line)
    }
}

