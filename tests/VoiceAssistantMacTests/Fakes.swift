import AppKit
import AVFoundation
import Carbon.HIToolbox
import ThumbFreeMac
import XCTest
@testable import VoiceAssistantMac

/// An element of a fake app: its attributes (a String, an Int for numbers and true/false, a FakeElement, an array of
/// FakeElements or Strings), its children and parent, and what was done to it.
final class FakeElement {
    let pid: pid_t
    var attributes: [String: Any] = [:]
    var children: [FakeElement] = [] {
        didSet {
            for child in children {
                child.parent = self
            }
        }
    }

    weak var parent: FakeElement?
    var frame: CGRect?

    /// AXUIElementIsAttributeSettable's answers; an attribute not here isn't there.
    var settable: [String: Bool] = [:]

    /// kAXSelectedTextRangeAttribute.
    var selection: CFRange?

    /// Whether it gives text for a range (kAXStringForRangeParameterizedAttribute).
    var givesRanges = true
    var windowNumber: Int?

    /// False: every question about it gets no answer.
    var answers = true

    /// What setting kAXFocusedAttribute to true does: it takes the focus (true), or it's refused.
    var takesFocus = true
    var actions: [String] = []
    var changes: [String] = []

    /// Every attribute set asked of it, whatever it came to.
    var tried: [String] = []

    /// The actions it says it can do (AXUIElementCopyActionNames).
    var actionNames: [String] = []

    /// What performing an action or setting an attribute on it comes to (after its own rules).
    var outcome = AXOutcome.done

    init(pid: pid_t = 42, role: String? = nil, subrole: String? = nil, title: String? = nil, frame: CGRect? = nil) {
        self.pid = pid
        self.frame = frame
        attributes[kAXRoleAttribute] = role
        attributes[kAXSubroleAttribute] = subrole
        attributes[kAXTitleAttribute] = title
    }

    subscript(_ attribute: String) -> Any? {
        get { attributes[attribute] }
        set { attributes[attribute] = newValue }
    }

    /// Text that the box holds, with the cursor at its end unless `cursor` says otherwise.
    func holds(_ text: String, cursor: Int? = nil, selected: Int = 0) {
        attributes[kAXValueAttribute] = text
        attributes[kAXNumberOfCharactersAttribute] = text.utf16.count
        selection = CFRange(location: cursor ?? text.utf16.count, length: selected)
    }

    static func app(pid: pid_t) -> FakeElement { FakeElement(pid: pid, role: kAXApplicationRole) }

    static func window(pid: pid_t = 42, title: String = "", number: Int? = nil, frame: CGRect? = nil) -> FakeElement {
        let window = FakeElement(pid: pid, role: kAXWindowRole, subrole: kAXStandardWindowSubrole, title: title)
        window.windowNumber = number
        window.frame = frame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        return window
    }

    static func textField(
        pid: pid_t = 42, name: String? = nil, frame: CGRect = CGRect(x: 10, y: 10, width: 300, height: 24)
    ) -> FakeElement {
        let field = FakeElement(pid: pid, role: kAXTextFieldRole, frame: frame)
        field[kAXDescriptionAttribute] = name
        field.settable[kAXFocusedAttribute] = true
        field.settable[kAXValueAttribute] = true
        return field
    }

    static func textArea(
        pid: pid_t = 42, name: String? = nil, editable: Bool = true,
        frame: CGRect = CGRect(x: 10, y: 100, width: 600, height: 400)
    ) -> FakeElement {
        let area = FakeElement(pid: pid, role: kAXTextAreaRole, frame: frame)
        area[kAXDescriptionAttribute] = name
        area.settable[kAXFocusedAttribute] = true
        area.settable[kAXValueAttribute] = editable
        return area
    }
}

/// The Accessibility API over FakeElements.
final class FakeAX: AXSystem {
    var focusedApp: FakeElement?
    var focused: FakeElement?
    var apps: [pid_t: FakeElement] = [:]

    /// False: the system-wide element gets no answer.
    var answers = true

    /// False: the system-wide element's focused element gets no answer (its focused application still does).
    var focusAnswers = true

    /// What `set(kAXFocusedAttribute…)` does, besides focusing an element that takes the focus.
    var onSet: ((FakeElement, String, Bool) -> Void)?
    var onPerform: ((FakeElement, String) -> Void)?

    func focusedApplication() throws -> AnyObject? {
        guard answers else { throw AXNoAnswer() }
        return focusedApp
    }

    func focusedElement() throws -> AnyObject? {
        guard answers, focusAnswers else { throw AXNoAnswer() }
        return focused
    }

    func application(_ processIdentifier: pid_t) -> AnyObject {
        if let app = apps[processIdentifier] {
            return app
        }

        let app = FakeElement.app(pid: processIdentifier)
        apps[processIdentifier] = app
        return app
    }

    func processIdentifier(of element: AnyObject) throws -> pid_t {
        try lookup(element).pid
    }

    /// Called with the element and the attribute each `string`, `number` and `elements` asks for, before the element
    /// answers or not: an app that takes its time.
    var onRead: ((FakeElement, String) -> Void)?

    func string(_ attribute: String, of element: AnyObject) throws -> String? {
        try read(element, attribute)[attribute] as? String
    }

    func number(_ attribute: String, of element: AnyObject) throws -> Int? {
        let value = try read(element, attribute)[attribute]
        if let flag = value as? Bool {
            return flag ? 1 : 0
        }

        return value as? Int
    }

    func element(_ attribute: String, of element: AnyObject) throws -> AnyObject? {
        let fake = try lookup(element)
        if attribute == kAXParentAttribute {
            return fake.parent
        }

        if attribute == kAXWindowAttribute, fake[attribute] == nil {
            var node = fake.parent
            while let current = node, current[kAXRoleAttribute] as? String != kAXWindowRole,
                  current[kAXRoleAttribute] as? String != kAXSheetRole {
                node = current.parent
            }

            return node
        }

        return fake[attribute] as? FakeElement
    }

    func elements(_ attribute: String, of element: AnyObject) throws -> [AnyObject] {
        let fake = try read(element, attribute)
        if attribute == kAXChildrenAttribute {
            return fake.children
        }

        return fake[attribute] as? [FakeElement] ?? []
    }

    func strings(_ attribute: String, of element: AnyObject) throws -> [String] {
        try lookup(element)[attribute] as? [String] ?? []
    }

    func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
        let fake = try lookup(element)
        return attribute == kAXSelectedTextRangeAttribute ? fake.selection : nil
    }

    /// The ranges asked for, to check what was read.
    var rangesRead: [CFRange] = []

    func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]? {
        let fake = try lookup(element)
        guard attribute == kAXStringForRangeParameterizedAttribute, fake.givesRanges,
              let value = fake[kAXValueAttribute] as? String else { return nil }
        rangesRead.append(range)
        let units = Array(value.utf16)
        let end = min(units.count, range.location + range.length)
        return range.location <= end ? Array(units[range.location..<end]) : []
    }

    func frame(of element: AnyObject) throws -> CGRect? {
        try lookup(element).frame
    }

    func isSettable(_ attribute: String, of element: AnyObject) throws -> Bool? {
        try lookup(element).settable[attribute]
    }

    func set(_ attribute: String, _ value: Bool, of element: AnyObject) -> AXOutcome {
        guard let fake = element as? FakeElement, fake.answers else { return .noAnswer }
        fake.tried.append("\(attribute)=\(value)")
        guard fake.outcome == .done else { return fake.outcome }
        fake.changes.append("\(attribute)=\(value)")
        onSet?(fake, attribute, value)
        if attribute == kAXFocusedAttribute, value {
            guard fake.takesFocus else { return .unsupported }
            focused = fake
        }

        if attribute == kAXMinimizedAttribute || attribute == kAXSelectedAttribute
            || attribute == kAXDisclosingAttribute || attribute == kAXHiddenAttribute {
            fake[attribute] = value
        }

        return .done
    }

    func perform(_ action: String, on element: AnyObject) -> AXOutcome {
        guard let fake = element as? FakeElement, fake.answers else { return .noAnswer }
        guard fake.outcome == .done else { return fake.outcome }
        fake.actions.append(action)
        onPerform?(fake, action)
        return .done
    }

    func setFrame(_ frame: CGRect, of element: AnyObject) -> AXOutcome {
        guard let fake = element as? FakeElement, fake.answers else { return .noAnswer }
        fake.frame = frame
        return .done
    }

    func windowNumber(of window: AnyObject) -> Int? {
        (window as? FakeElement)?.windowNumber
    }

    func isSame(_ element: AnyObject, as other: AnyObject) -> Bool {
        element === other
    }

    /// Called with each element `node` reads, before it's read: a page that's described only after a while.
    var onNode: ((FakeElement) -> Void)?

    func node(_ element: AnyObject) throws -> AXNode {
        let fake = try lookup(element)
        onNode?(fake)
        let enabled = fake[kAXEnabledAttribute]
        return AXNode(
            role: fake[kAXRoleAttribute] as? String, subrole: fake[kAXSubroleAttribute] as? String,
            children: fake.children, title: fake[kAXTitleAttribute] as? String,
            label: fake[kAXDescriptionAttribute] as? String,
            enabled: (enabled as? Bool) ?? (enabled as? Int).map { $0 != 0 }, frame: fake.frame)
    }

    func actions(of element: AnyObject) throws -> [String] {
        try lookup(element).actionNames
    }

    /// What `element(at:of:)` finds; nil: nothing.
    var hit: FakeElement?
    var pointsHit: [CGPoint] = []

    func element(at point: CGPoint, of application: AnyObject) throws -> AnyObject? {
        _ = try lookup(application)
        pointsHit.append(point)
        return hit
    }

    /// What the system-wide `elementAtPoint` finds; nil: nothing.
    var screenHit: FakeElement?

    /// Called at each system-wide hit test, before it's answered.
    var onScreenHit: (() -> Void)?

    func elementAtPoint(_ point: CGPoint) throws -> AnyObject? {
        onScreenHit?()
        guard answers else { throw AXNoAnswer() }
        return screenHit
    }

    /// The app `pid`, taking the keys with `window` (and the focus on `element`, else nothing).
    func focus(_ app: FakeElement, window: FakeElement?, element: FakeElement? = nil) {
        apps[app.pid] = app
        app[kAXFocusedWindowAttribute] = window
        focusedApp = app
        focused = element
    }

    private func read(_ element: AnyObject, _ attribute: String) throws -> FakeElement {
        if let fake = element as? FakeElement {
            onRead?(fake, attribute)
        }

        return try lookup(element)
    }

    private func lookup(_ element: AnyObject) throws -> FakeElement {
        guard let fake = element as? FakeElement, fake.answers else { throw AXNoAnswer() }
        return fake
    }
}

/// NSWorkspace with running apps, installed apps and folders of its own.
final class FakeWorkspace: WorkspaceSystem {
    var running: [RunningApp] = []
    var front: RunningApp?
    var installed: [String: URL] = [:]
    var folders: [URL: [FolderItem]] = [:]
    var bundles: [URL: AppBundle] = [:]
    var windowOrder: [Int] = []
    var screenAreas: [ScreenArea] = []
    var launched: [URL] = []
    var launchError: Error?

    /// What starting an app does (an app that starts adds itself and its windows here).
    var onLaunch: ((URL) -> Void)?
    var opened: [(url: URL, app: URL?)] = []
    var openError: Error?
    var onOpen: ((URL, URL?) -> Void)?
    var activated: [pid_t] = []

    func app(_ processIdentifier: pid_t) -> RunningApp? {
        running.first { $0.processIdentifier == processIdentifier }
    }

    func runningApps() -> [RunningApp] { running }

    func frontmostApp() -> RunningApp? { front }

    func applicationURL(bundleIdentifier: String) -> URL? { installed[bundleIdentifier] }

    func launch(_ url: URL) async throws -> RunningApp? {
        launched.append(url)
        if let launchError {
            throw launchError
        }

        onLaunch?(url)
        return running.first { $0.bundleURL == url }
    }

    func activate(_ processIdentifier: pid_t) -> Bool {
        activated.append(processIdentifier)
        return true
    }

    func open(_ url: URL, withApplicationAt appURL: URL?) async throws {
        opened.append((url, appURL))
        if let openError {
            throw openError
        }

        onOpen?(url, appURL)
    }

    func windowNumbersFrontToBack() -> [Int] { windowOrder }

    /// The window server's windows, by number.
    var serverWindows: [Int: ServerWindow] = [:]

    /// The windows in `windowOrder` that `serverWindows` has.
    func serverWindowsFrontToBack() -> [ServerWindow] { windowOrder.compactMap { serverWindows[$0] } }

    func serverWindow(_ number: Int) -> ServerWindow? { serverWindows[number] }

    /// The processes of apps built with Electron.
    var electronApps: Set<pid_t> = []

    func isElectron(_ app: RunningApp) -> Bool { electronApps.contains(app.processIdentifier) }

    func screens() async -> [ScreenArea] { screenAreas }

    func folderItems(_ folder: URL) -> [FolderItem] { folders[folder] ?? [] }

    func appBundle(at url: URL) -> AppBundle? { bundles[url] }

    /// A running app with a bundle in /Applications.
    @discardableResult
    func run(_ pid: pid_t, _ bundleIdentifier: String, _ name: String) -> RunningApp {
        let app = RunningApp(
            processIdentifier: pid, bundleIdentifier: bundleIdentifier, name: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), executableName: name)
        running.append(app)
        return app
    }
}

/// The keyboard: what was pressed and typed.
final class FakeKeys: PasteTyper.Keys {
    var posted: [PasteTyper.Chord] = []
    var typed: [String] = []
    var held: [PasteTyper.Modifiers] = []
    var secureInput = FocusedField.SecureInput.off
    var pasteChord = PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_V), modifiers: .command)
    var failure: Error?
    var onPost: ((PasteTyper.Chord) -> Void)?

    /// The modifiers held, one reading at a time from `held`, then none.
    var heldModifiers: PasteTyper.Modifiers {
        held.isEmpty ? [] : held.removeFirst()
    }

    func post(_ chord: PasteTyper.Chord) throws {
        if let failure {
            throw failure
        }

        posted.append(chord)
        onPost?(chord)
    }

    func type(_ characters: String) throws {
        if let failure {
            throw failure
        }

        typed.append(characters)
    }
}

/// A pasteboard holding text.
final class FakePasteboard: PasteTyper.Pasteboard {
    var changeCount = 0
    var access = PasteTyper.PasteboardAccess.unrestricted
    var text: String?
    var writes: [String] = []

    func save() -> PasteTyper.Saved {
        guard let text else { return .empty }
        let item = PasteTyper.Contents.Representation(type: "public.utf8-plain-text", data: Data(text.utf8))
        return .items(PasteTyper.Contents(items: [[item]]))
    }

    func write(_ text: String) throws -> Int {
        writes.append(text)
        self.text = text
        changeCount += 1
        return changeCount
    }

    func restore(_ saved: PasteTyper.Saved) {
        changeCount += 1
        if case .items(let contents) = saved, let data = contents.items.first?.first?.data {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = nil
        }
    }
}

/// The keyboard layout: the keys that type each character, with ⌘ and without.
final class FakeLayout: KeyLayout {
    var plain: [Character: CGKeyCode] = [:]
    var command: [Character: CGKeyCode] = [:]

    func keyCode(typing character: Character, command: Bool) -> CGKeyCode? {
        command ? self.command[character] : plain[character]
    }
}

/// Permissions macOS has given, all of them unless taken away.
final class FakePermissions: Permissions.System {
    var trusted = true
    var mayPost = true

    func microphoneStatus() -> AVAuthorizationStatus { .authorized }

    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) { completion(true) }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { trusted }

    func canPostEvents() -> Bool { mayPost }

    func requestPostEvents() -> Bool { mayPost }

    func canListenToEvents() -> Bool { true }

    func requestListenToEvents() -> Bool { true }

    func open(_ url: URL) -> Bool { true }
}

/// A clock that moves only when the desktop waits.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { time } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { time += seconds }
    }

    var clock: DesktopClock {
        DesktopClock(
            now: { [self] in now },
            pause: { [self] seconds in
                try Task.checkCancellation()
                advance(seconds)
            },
            sleep: { [self] seconds in advance(seconds) })
    }
}

/// Log lines.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []

    var lines: [String] { lock.withLock { written } }

    func add(_ line: String) {
        lock.withLock { written.append(line) }
    }

    func clear() {
        lock.withLock { written.removeAll() }
    }
}

/// The pointer: the windows a click would land in, and the clicks.
final class FakePointer: PointerSystem {
    /// The windows at every point, front-most first, as `windowNumber(at:below:)` goes down them.
    var windowsAtPoint: [Int] = []
    var clicks: [CGPoint] = []
    var onClick: ((CGPoint) -> Void)?
    var clickWorks = true

    func windowNumber(at point: CGPoint, below: Int) -> Int? {
        let next = below == 0 ? 0 : (windowsAtPoint.firstIndex(of: below) ?? windowsAtPoint.count) + 1
        return next < windowsAtPoint.count ? windowsAtPoint[next] : nil
    }

    func click(at point: CGPoint) -> Bool {
        clicks.append(point)
        onClick?(point)
        return clickWorks
    }
}

/// AppleScript: what each script prints, and the Automation permission.
final class FakeScripts: ScriptSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var permission = AutomationPermission.granted
    private var asks: [Bool] = []

    /// The scripts run, with their arguments.
    var ran: [(source: String, arguments: [String])] = []

    /// What a script comes to; failing by default.
    var onRun: ((String, [String]) -> ScriptResult)?

    /// What asking for the permission comes to.
    var answer = AutomationPermission.granted

    var automationPermission: AutomationPermission {
        get { lock.withLock { permission } }
        set { lock.withLock { permission = newValue } }
    }

    /// Whether each look at the permission asked the user.
    var asked: [Bool] { lock.withLock { asks } }

    func run(_ source: String, arguments: [String], timeout: TimeInterval) -> ScriptResult {
        ran.append((source, arguments))
        return onRun?(source, arguments) ?? .failed(nil)
    }

    func automation(_ bundleIdentifier: String, ask: Bool) -> AutomationPermission {
        lock.withLock {
            asks.append(ask)
            if ask {
                permission = answer
            }

            return permission
        }
    }
}

/// A desktop on fakes.
final class Rig {
    let ax = FakeAX()
    let workspace = FakeWorkspace()
    let keys = FakeKeys()
    let pasteboard = FakePasteboard()
    let layout = FakeLayout()
    let pointer = FakePointer()
    let scripts = FakeScripts()
    let permissions = FakePermissions()
    let time = FakeClock()
    let log = LogLines()
    let clickThrough = ClickThroughWindows()
    var insertMethod = "Paste"

    /// This app's process.
    static let own: pid_t = 1

    lazy var desktop: MacDesktop = {
        let method = insertMethod
        let lines = self.log
        let typer = PasteTyper(pasteboard: pasteboard, keys: keys, sleep: { _ in }, now: { 0 })
        return MacDesktop(
            ax: ax, workspace: workspace, typer: typer, keys: keys, layout: layout, pointer: pointer,
            scripts: scripts, permissions: Permissions(system: permissions), clock: time.clock,
            clickThrough: clickThrough, ownProcess: Self.own, insertMethod: { method }, log: { lines.add($0) })
    }()

    /// A running app with a window taking the keys (and `element` the focus).
    @discardableResult
    func front(
        _ pid: pid_t = 42, _ bundleIdentifier: String = "com.apple.TextEdit", _ name: String = "TextEdit",
        window: FakeElement? = nil, focus element: FakeElement? = nil
    ) -> FakeElement {
        if workspace.app(pid) == nil {
            workspace.run(pid, bundleIdentifier, name)
        }

        let app = ax.apps[pid] ?? FakeElement.app(pid: pid)
        let window = window ?? FakeElement.window(pid: pid, title: "Untitled", number: Int(pid) * 10)
        if let element {
            window.children.append(element)
        }

        var windows = app[kAXWindowsAttribute] as? [FakeElement] ?? []
        if !windows.contains(where: { $0 === window }) {
            windows.insert(window, at: 0)
        }

        app[kAXWindowsAttribute] = windows
        ax.focus(app, window: window, element: element)
        return window
    }

    /// Setting AXMain on a window makes it its app's focused window, and AXFrontmost on an app makes it take the keys,
    /// as macOS does.
    func activates() {
        ax.onSet = { [unowned self] element, attribute, value in
            guard value else { return }
            if attribute == kAXMainAttribute {
                self.ax.apps[element.pid]?[kAXFocusedWindowAttribute] = element
            } else if attribute == kAXFrontmostAttribute {
                self.ax.focusedApp = element
                self.ax.focused = nil
            }
        }
    }
}
