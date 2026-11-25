import AppKit
import ThumbFreeMac
import VoiceAssistantCore

/// The hotkeys the menu shows by its items, as macOS writes shortcuts ("⌃⇧Space"); empty for one that isn't set.
public struct MenuHotkeys: Equatable, Sendable {
    /// Pauses and resumes listening (the `hotkey` setting).
    public var pause: String
    /// Pastes the last dictation again (`pasteLastHotkey`).
    public var pasteLast: String
    /// Switches the dictation language (`dictationLanguageHotkey`).
    public var language: String

    /// The Mac's defaults: ⌃⇧Space, ⌃⇧Z and ⌃⇧H.
    public init(pause: String = "⌃⇧Space", pasteLast: String = "⌃⇧Z", language: String = "⌃⇧H") {
        self.pause = pause
        self.pasteLast = pasteLast
        self.language = language
    }
}

/// What the menu ticks, read each time it opens (Windows' `menu.Opening`).
public struct MenuState: Equatable, Sendable {
    /// Dictation is in Hindi + English, with the fast model or, when `accurate`, the larger one.
    public var hinglish: Bool
    public var accurate: Bool
    /// The pill is always on screen: it isn't minimized.
    public var pillAlwaysShown: Bool
    /// "Start when I log in" is on.
    public var startsAtLogin: Bool

    public init(hinglish: Bool = false, accurate: Bool = false, pillAlwaysShown: Bool = true, startsAtLogin: Bool = false) {
        self.hinglish = hinglish
        self.accurate = accurate
        self.pillAlwaysShown = pillAlwaysShown
        self.startsAtLogin = startsAtLogin
    }
}

/// What the menu asks of the app: Windows' `TrayIcon` calls on the assistant host, the pill, `StartupRegistration` and
/// the app.
public struct MenuActions {
    /// Opens the window at a page; the idea board opens as the board does (Windows' `OpenPage`).
    public var open: @MainActor (AppPage) -> Void
    /// Pauses listening, or starts it (the host's `ToggleListening`).
    public var toggleListening: @MainActor () -> Void
    public var pasteLast: @MainActor () -> Void
    /// English, or Hindi + English with the fast or the accurate model (the host's `SetDictationLanguage`).
    public var setDictationLanguage: @MainActor (_ hinglish: Bool, _ accurate: Bool) -> Void
    /// Copies the text that wasn't typed, or says there's none (the host's `CopyUntypedText`).
    public var copyUntyped: @MainActor () -> Void
    /// The pill always on screen, or only while it has something to show (the pill's `minimized`).
    public var setPillAlwaysShown: @MainActor (Bool) -> Void
    /// "Start when I log in" on or off.
    public var setStartsAtLogin: @MainActor (Bool) -> Void
    public var quit: @MainActor () -> Void
    /// The ticks, now.
    public var state: @MainActor () -> MenuState

    public init(
        open: @escaping @MainActor (AppPage) -> Void,
        toggleListening: @escaping @MainActor () -> Void,
        pasteLast: @escaping @MainActor () -> Void,
        setDictationLanguage: @escaping @MainActor (_ hinglish: Bool, _ accurate: Bool) -> Void,
        copyUntyped: @escaping @MainActor () -> Void,
        setPillAlwaysShown: @escaping @MainActor (Bool) -> Void,
        setStartsAtLogin: @escaping @MainActor (Bool) -> Void,
        quit: @escaping @MainActor () -> Void,
        state: @escaping @MainActor () -> MenuState
    ) {
        self.open = open
        self.toggleListening = toggleListening
        self.pasteLast = pasteLast
        self.setDictationLanguage = setDictationLanguage
        self.copyUntyped = copyUntyped
        self.setPillAlwaysShown = setPillAlwaysShown
        self.setStartsAtLogin = setStartsAtLogin
        self.quit = quit
        self.state = state
    }
}

/// Voice Assistant's menu bar item (Windows' tray icon, `TrayIcon`): the logo's microphone with a dot for the mode, the
/// mode in its tooltip, and the menu (`StatusMenu`), which opens on a click as menu bar items' menus do. Its balloon
/// says short things by it.
@MainActor
public final class MenuBar {
    public let menu: StatusMenu

    private let item: NSStatusItem
    private let balloon = Balloon()
    private var images: [InteractionMode: NSImage] = [:]

    public init(hotkeys: MenuHotkeys, actions: MenuActions) {
        menu = StatusMenu(hotkeys: hotkeys, actions: actions)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu.menu
        item.button?.image = AppLogo.menuBarImage(dot: Self.dot(nil))
        item.button?.toolTip = "Voice Assistant"
        item.button?.setAccessibilityLabel("Voice Assistant")
    }

    /// The mode in the icon's dot, the tooltip and the menu's status line (Windows' `TrayIcon.Update`).
    public func update(_ mode: InteractionMode) {
        if images[mode] == nil {
            images[mode] = AppLogo.menuBarImage(dot: Self.dot(mode))
        }

        item.button?.image = images[mode]
        item.button?.toolTip = "Voice Assistant — \(StatusMenu.label(mode))"
        menu.showMode(mode)
    }

    /// A short message by the icon for 4 seconds (Windows' `ShowBalloon`), with a warning sign unless `warning` is
    /// false.
    public func showBalloon(_ message: String, warning: Bool = true) {
        balloon.show(message, warning: warning, anchor: item.button?.window?.frame)
    }

    /// Takes the item out of the menu bar: the app is quitting.
    public func remove() {
        balloon.close()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// The icon's dot for `mode`, as on Windows' tray icons: grey while paused (and starting), none while waiting for
    /// "Hey Jarvis", blue while listening for a command, red while typing.
    public static func dot(_ mode: InteractionMode?) -> Colour? {
        guard let mode else { return Colour(0x9AA0A6) }
        switch mode {
        case .paused: return Colour(0x9AA0A6)
        case .standby: return nil
        case .command: return Colour(0x4C8DF6)
        case .dictation: return Colour(0xEA4335)
        }
    }
}

/// The menu (Windows' tray menu, `TrayIcon`): open the window or the idea board; the status and pausing or starting
/// listening; pasting the last dictation; the dictation language; copying the text that wasn't typed; what you can say,
/// Settings, the pill and starting at login; and Quit. The hotkeys show as macOS shows shortcuts; ⌘, and ⌘Q are the
/// Mac's for Settings and Quit. Built apart from the menu bar item, so tests read it and click it.
@MainActor
public final class StatusMenu: NSObject, NSMenuDelegate {
    public let menu = NSMenu()

    let openApp = NSMenuItem()
    let ideaBoard = NSMenuItem()
    let statusLine = NSMenuItem()
    let toggle = NSMenuItem()
    let pasteLast = NSMenuItem()
    let language = NSMenuItem()
    let english = NSMenuItem()
    let hinglish = NSMenuItem()
    let hinglishAccurate = NSMenuItem()
    let copyUntyped = NSMenuItem()
    let whatYouCanSay = NSMenuItem()
    let settings = NSMenuItem()
    let showPill = NSMenuItem()
    let startAtLogin = NSMenuItem()
    let quit = NSMenuItem()

    private let actions: MenuActions
    /// The pause hotkey after the pause item's title, when the menu can't show it as a shortcut.
    private var toggleSuffix = ""

    public init(hotkeys: MenuHotkeys, actions: MenuActions) {
        self.actions = actions
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        set(openApp, "Open Voice Assistant") { [weak self] in self?.actions.open(.home) }
        openApp.attributedTitle = NSAttributedString(
            string: openApp.title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
        set(ideaBoard, "Idea board") { [weak self] in self?.actions.open(.ideas) }
        set(statusLine, "Starting…")
        set(toggle, "Start listening") { [weak self] in self?.actions.toggleListening() }
        toggleSuffix = Self.show(hotkeys.pause, on: toggle)
        toggle.title += toggleSuffix
        set(pasteLast, "Paste last dictation") { [weak self] in self?.actions.pasteLast() }
        pasteLast.title += Self.show(hotkeys.pasteLast, on: pasteLast)
        // The hotkey switches between English and whichever Hindi + English mode was chosen last.
        set(language, hotkeys.language.isEmpty ? "Dictation language" : "Dictation language (\(hotkeys.language))")
        set(english, "English") { [weak self] in self?.actions.setDictationLanguage(false, false) }
        set(hinglish, "Hindi + English — fast (typed in Roman letters)") { [weak self] in
            self?.actions.setDictationLanguage(true, false)
        }

        set(hinglishAccurate, "Hindi + English — accurate (slower; 830 MB download)") { [weak self] in
            self?.actions.setDictationLanguage(true, true)
        }

        let languages = NSMenu()
        languages.autoenablesItems = false
        for choice in [english, hinglish, hinglishAccurate] {
            languages.addItem(choice)
        }

        language.submenu = languages
        language.isEnabled = true
        set(copyUntyped, "Copy text that wasn't typed") { [weak self] in self?.actions.copyUntyped() }
        set(whatYouCanSay, "What you can say") { [weak self] in self?.actions.open(.help) }
        set(settings, "Settings…") { [weak self] in self?.actions.open(.settings) }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        set(showPill, "Always show status pill") { [weak self] in
            guard let self else { return }
            self.actions.setPillAlwaysShown(!self.actions.state().pillAlwaysShown)
        }

        set(startAtLogin, "Start when I log in") { [weak self] in
            guard let self else { return }
            self.actions.setStartsAtLogin(!self.actions.state().startsAtLogin)
        }

        set(quit, "Quit Voice Assistant") { [weak self] in self?.actions.quit() }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        for item in [
            openApp, ideaBoard, NSMenuItem.separator(), statusLine, toggle, pasteLast, language, copyUntyped,
            NSMenuItem.separator(), whatYouCanSay, settings, showPill, startAtLogin, NSMenuItem.separator(), quit,
        ] {
            menu.addItem(item)
        }

        prepare()
    }

    /// The mode in the status line, and whether the pause item pauses or starts listening (Windows' `TrayIcon.Update`).
    public func showMode(_ mode: InteractionMode) {
        statusLine.title = Self.label(mode)
        toggle.title = (mode == .paused ? "Start listening" : "Pause listening") + toggleSuffix
    }

    /// Brings the ticks up to date before the menu opens (Windows' `menu.Opening`).
    public func prepare() {
        let state = actions.state()
        showPill.state = state.pillAlwaysShown ? .on : .off
        startAtLogin.state = state.startsAtLogin ? .on : .off
        english.state = state.hinglish ? .off : .on
        hinglish.state = state.hinglish && !state.accurate ? .on : .off
        hinglishAccurate.state = state.hinglish && state.accurate ? .on : .off
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        prepare()
    }

    /// What the status line says for `mode`.
    static func label(_ mode: InteractionMode) -> String {
        switch mode {
        case .dictation: return "Typing"
        case .command: return "Listening for commands"
        case .standby: return "Waiting for “Hey Jarvis”"
        case .paused: return "Paused (microphone off)"
        }
    }

    /// A shortcut as macOS writes it ("⌃⇧Space", "⌃⇧Z", "⌥⌘F5") as a menu item's key equivalent; nil for one without a
    /// modifier, or with a key that a menu can't show.
    static func keyEquivalent(_ shortcut: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        var key = Substring(shortcut)
        while let glyph = key.first, let modifier = modifierGlyphs[glyph] {
            modifiers.insert(modifier)
            key = key.dropFirst()
        }

        guard !modifiers.isEmpty, !key.isEmpty else { return nil }
        if let named = namedKeys[String(key)] {
            return (named, modifiers)
        }

        if key.count == 1 {
            return (key.lowercased(), modifiers)
        }

        if key.first == "F", let number = Int(key.dropFirst()), (1...20).contains(number) {
            return (functionKey(NSF1FunctionKey + number - 1), modifiers)
        }

        return nil
    }

    /// Tests: what clicking `item` does.
    func click(_ item: NSMenuItem) {
        (item.representedObject as? MenuItemAction)?.run()
    }

    private static let modifierGlyphs: [Character: NSEvent.ModifierFlags] = [
        "⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command,
    ]

    private static let namedKeys: [String: String] = [
        "Space": " ", "Return": "\r", "Tab": "\t", "Esc": "\u{1B}", "Delete": "\u{8}",
        "←": functionKey(NSLeftArrowFunctionKey), "→": functionKey(NSRightArrowFunctionKey),
        "↑": functionKey(NSUpArrowFunctionKey), "↓": functionKey(NSDownArrowFunctionKey),
    ]

    /// The character AppKit stands for a function or arrow key with.
    private static func functionKey(_ code: Int) -> String {
        Unicode.Scalar(UInt32(code)).map { String(Character($0)) } ?? ""
    }

    /// Shows `shortcut` by `item` as macOS shows shortcuts. One a menu can't show is returned to go after the title.
    private static func show(_ shortcut: String, on item: NSMenuItem) -> String {
        guard !shortcut.isEmpty else { return "" }
        guard let equivalent = keyEquivalent(shortcut) else { return " (\(shortcut))" }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.modifiers
        return ""
    }

    /// A title, and what clicking does; without an action the item is a line of text.
    private func set(_ item: NSMenuItem, _ title: String, _ action: (@MainActor () -> Void)? = nil) {
        item.title = title
        guard let action else {
            item.isEnabled = false
            return
        }

        item.target = self
        item.action = #selector(clicked(_:))
        item.representedObject = MenuItemAction(action)
        item.isEnabled = true
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        click(sender)
    }
}

/// What a menu item does when it's clicked.
private final class MenuItemAction {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}
