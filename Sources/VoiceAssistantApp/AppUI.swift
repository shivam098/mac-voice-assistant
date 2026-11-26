import AppKit
import VoiceAssistantBoard
import VoiceAssistantCore

/// The menu bar item as the app's UI uses it: `MenuBar` in the app, a fake in tests.
@MainActor
protocol MenuBarItem: AnyObject {
    /// Its menu, which tests click.
    var menu: StatusMenu { get }

    /// The mode in the icon's dot, its tooltip and the menu's status line.
    func update(_ mode: InteractionMode)

    /// A short message by the icon, with a warning sign or an information sign.
    func showBalloon(_ message: String, warning: Bool)

    /// Takes the item out of the menu bar.
    func remove()
}

extension MenuBar: MenuBarItem {}

/// The window as the app's UI uses it: `MainWindow` in the app, a fake in tests.
@MainActor
protocol AppWindow: AnyObject {
    var isVisible: Bool { get }

    /// macOS hasn't given a permission the assistant needs: Home lists it.
    var permissionsNeeded: Bool { get }

    func bring()
    func open(_ page: AppPage)
    func showBoard(_ list: BoardList?)
    func showStatus(_ update: AssistantStatus)
    func setDictationLanguage(hinglish: Bool, accurate: Bool)
    func brainChanged()

    /// What macOS allows changed: Home's "Permissions needed" follows.
    func refreshPermissions()
}

extension MainWindow: AppWindow {
    func refreshPermissions() {
        model.home.refreshPermissions()
    }
}

/// The desktop's number badges and click outline over other apps (Windows' `MarkerOverlay`): the members of
/// VoiceAssistantMac's `MarkerOverlay`, which the desktop layer's part 2 brings. Until it's in, the app has none, and
/// the host's `choicesChanged` and `highlight` aren't drawn; then `extension MarkerOverlay: NumberBadges {}` and
/// `badges: { MarkerOverlay() }` in `AppUI.Parts.standard` draw them.
@MainActor
protocol NumberBadges: AnyObject {
    /// Numbers on the candidates; nil, or none, hides them.
    func showBadges(_ badges: [ChoiceBadge]?)

    /// Outlines what was just clicked, selected or focused, for under a second.
    func flash(_ rect: ScreenRect)
}

/// The window's members of the same names as the assistant host's (`AssistantControls`).
extension AssistantHost: AssistantControls {}

/// The app's UI wired to the assistant (windows-voice-assistant App.xaml.cs's `OnStartup`, its windows' part, with the
/// subscriptions of `TrayIcon` and `MainWindow`): the menu bar item and its balloons, the status pill, the window and
/// the reminder cards, kept up to date by the assistant host's events and the app's, and driving the host. The host's
/// events come on the main thread (its `post`); the UI reads only the host's own state (its mode and dictation
/// language) and what the events said, never the controller's. Main thread only.
@MainActor
final class AppUI {
    /// What the UI is made of besides the pill: the app's own (`standard`), fakes in tests.
    struct Parts {
        /// The menu bar item, with the hotkeys its menu shows and what its items do.
        var menuBar: @MainActor (MenuHotkeys, MenuActions) -> MenuBarItem

        /// The window, given how it says something by the menu bar icon: the message, and whether it's a warning.
        var window: @MainActor (_ notice: @escaping @MainActor (String, Bool) -> Void) -> AppWindow

        /// A reminder's card.
        var card: ReminderCards.MakeCard

        /// The sound reminder cards come with.
        var sound: @MainActor () -> Void

        /// "Start when I log in".
        var startAtLogin: StartAtLogin

        /// Quits the app: the menu's Quit Voice Assistant.
        var quit: @MainActor () -> Void

        /// The desktop's number badges; nil until the desktop's navigation part brings them.
        var badges: (@MainActor () -> NumberBadges)?
    }

    /// What the app (`AppController`) tells its UI.
    struct AppEvents {
        /// Notices for balloons, the ones still in force replayed when the UI subscribes.
        var notice: NoticeEvent

        /// ThumbFree started or quit while both use the same key.
        var thumbFreeChanged: HostEvent<Bool>

        /// What macOS allows changed.
        var permissionsChanged: HostEvent<Void>

        /// Voice Assistant was opened again while it runs.
        var showRequested: HostEvent<Void>

        /// ThumbFree runs too with the same key, as the UI starts.
        var thumbFreeRunsToo: Bool
    }

    let pill: StatusPill.Panel
    private(set) var menuBar: MenuBarItem!
    private(set) var window: AppWindow!
    private(set) var reminders: ReminderCards!

    /// There's dictated text that couldn't be typed, as the host last said (`untypedTextChanged`): the menu offers to
    /// copy it. The UI never holds the text.
    private(set) var hasUntypedText = false

    private let host: AssistantHost
    private let paths: AppPaths
    private let parts: Parts
    private var badges: NumberBadges?
    private var subscriptions: [HostSubscription] = []
    private var closed = false

    /// Makes the UI and wires it: the pill (minimized as its state flag says), the menu bar item, the window (closed:
    /// `showAtLaunch` opens it) and the reminder cards, which start checking the board.
    init(
        host: AssistantHost, app: AppEvents, settings: AppSettings, paths: AppPaths, board: BoardStore, parts: Parts
    ) {
        self.host = host
        self.paths = paths
        self.parts = parts
        let keys = Self.keyNames(settings)
        pill = StatusPill.Panel(
            commandModeIsIdle: !settings.wakeWordEnabled, keyName: keys.dictation, languageKeys: keys.hotkeys.language,
            minimized: StateFlags.isSet(paths.overlayMinimizedFlag))
        menuBar = parts.menuBar(keys.hotkeys, menuActions())
        window = parts.window({ [weak self] (message: String, warning: Bool) in
            self?.menuBar.showBalloon(message, warning: warning)
        })
        reminders = ReminderCards(
            board: board,
            openBoard: { [weak self] in self?.window.showBoard(.reminders) },
            report: { [weak self] message in self?.menuBar.showBalloon(message, warning: true) },
            sound: parts.sound,
            makeCard: parts.card)
        badges = parts.badges?()
        pill.onMinimizedChanged = { [weak self] minimized in
            MainActor.assumeIsolated { self?.pillMinimizedChanged(minimized) }
        }

        pill.setDictationLanguage(hinglish: host.hinglishDictation, accurate: host.hinglishAccurate)
        showThumbFreeWarning(app.thumbFreeRunsToo)
        subscribeToHost()
        subscribeToApp(app)
        reminders.start()
    }

    /// The keys the UI names, as macOS writes them: the dictation key, and the hotkeys as the Mac registers them.
    nonisolated static func keyNames(_ settings: AppSettings) -> KeyNames {
        let hotkeys = MenuHotkeys(
            pause: AppSettings.hotkeyLabel(settings.macHotkey),
            pasteLast: AppSettings.hotkeyLabel(settings.macPasteLastHotkey),
            language: AppSettings.hotkeyLabel(settings.macDictationLanguageHotkey))
        return KeyNames(dictation: settings.dictationKeyLabel, hotkeys: hotkeys)
    }

    /// At launch the window opens at Home, unless the app started in the background (at login, or restarted with the
    /// window closed); then too while macOS hasn't given a permission the assistant needs, so Home can ask for it.
    func showAtLaunch(background: Bool) {
        guard !background || window.permissionsNeeded else {
            Log.info("ui: the window stays closed (started in the background)")
            return
        }

        Log.info(background ? "ui: window opened at Home for a missing permission" : "ui: window opened at Home")
        window.open(.home)
    }

    /// Takes the UI off the screen and stops listening to the host: the app is quitting. Once is enough.
    func close() {
        guard !closed else { return }
        closed = true
        reminders.stop()
        for subscription in subscriptions {
            subscription.cancel()
        }

        subscriptions = []
        pill.close()
        menuBar.remove()
    }

    /// What the menu's ticks say now: the host's dictation language, the pill, the login item and the untyped text.
    var menuState: MenuState {
        MenuState(
            hinglish: host.hinglishDictation, accurate: host.hinglishAccurate, pillAlwaysShown: !pill.minimized,
            startsAtLogin: parts.startAtLogin.isEnabled(), hasUntypedText: hasUntypedText)
    }

    // MARK: Wiring

    /// What the menu's items do (Windows' `TrayIcon`): the host's actions, the window's pages, the pill, the login item
    /// and quitting.
    private func menuActions() -> MenuActions {
        let host = self.host
        return MenuActions(
            open: { [weak self] page in self?.window.open(page) },
            toggleListening: { host.toggleListening() },
            pasteLast: { host.pasteLastTranscript() },
            setDictationLanguage: { hinglish, accurate in
                host.setDictationLanguage(hinglish: hinglish, accurate: accurate)
            },
            copyUntyped: { host.copyUntypedText() },
            setPillAlwaysShown: { [weak self] shown in self?.pill.minimized = !shown },
            setStartsAtLogin: parts.startAtLogin.set,
            quit: parts.quit,
            state: { [weak self] in self?.menuState ?? MenuState() })
    }

    /// The host's events (Windows' App, TrayIcon and MainWindow subscriptions), on the main thread.
    private func subscribeToHost() {
        let host = self.host
        keep(host.status.subscribe { [weak self] update in
            MainActor.assumeIsolated { self?.showStatus(update) }
        })
        keep(host.activity.subscribe { [weak self] activity in
            MainActor.assumeIsolated { self?.pill.showMode(activity.mode, activity: activity.label) }
        })
        keep(host.dictationPreview.subscribe { [weak self] text in
            MainActor.assumeIsolated { self?.pill.showPreview(text) }
        })
        keep(host.inputLevel.subscribe { [weak self] level in
            MainActor.assumeIsolated { self?.pill.showInputLevel(level) }
        })
        keep(host.dictationLanguageChanged.subscribe { [weak self] language in
            MainActor.assumeIsolated { self?.languageChanged(language) }
        })
        keep(host.brainChanged.subscribe { [weak self] _ in
            MainActor.assumeIsolated { self?.window.brainChanged() }
        })
        keep(host.showBoardRequested.subscribe { [weak self] list in
            MainActor.assumeIsolated { self?.window.showBoard(list) }
        })
        keep(host.untypedTextChanged.subscribe { [weak self] has in
            MainActor.assumeIsolated { self?.hasUntypedText = has }
        })
        keep(host.choicesChanged.subscribe { [weak self] badges in
            MainActor.assumeIsolated { self?.badges?.showBadges(badges) }
        })
        keep(host.highlight.subscribe { [weak self] rect in
            MainActor.assumeIsolated { self?.badges?.flash(rect) }
        })
    }

    /// The app's events: notices as balloons, ThumbFree's warning in the menu while it holds, permissions for Home, and
    /// a second launch bringing the window.
    private func subscribeToApp(_ app: AppEvents) {
        keep(app.notice.subscribe { [weak self] message in
            MainActor.assumeIsolated { self?.menuBar.showBalloon(message, warning: true) }
        })
        keep(app.thumbFreeChanged.subscribe { [weak self] clash in
            MainActor.assumeIsolated { self?.showThumbFreeWarning(clash) }
        })
        keep(app.permissionsChanged.subscribe { [weak self] _ in
            MainActor.assumeIsolated { self?.window.refreshPermissions() }
        })
        keep(app.showRequested.subscribe { [weak self] _ in
            MainActor.assumeIsolated { self?.window.bring() }
        })
    }

    private func keep(_ subscription: HostSubscription) {
        subscriptions.append(subscription)
    }

    /// A status line: the pill shows it, the menu bar item and Home follow the mode (Windows' `Status` handlers).
    private func showStatus(_ update: AssistantStatus) {
        pill.showStatus(update)
        menuBar.update(update.mode)
        window.showStatus(update)
    }

    /// The hotkey or the menu changed the dictation language: the pill's badge and Home's choice follow.
    private func languageChanged(_ language: DictationLanguage) {
        pill.setDictationLanguage(hinglish: language.hinglish, accurate: language.accurate)
        window.setDictationLanguage(hinglish: language.hinglish, accurate: language.accurate)
    }

    /// The pill was minimized or brought back: its state flag, and the first word on what minimizing does.
    private func pillMinimizedChanged(_ minimized: Bool) {
        StateFlags.set(paths.overlayMinimizedFlag, minimized)
        if minimized {
            menuBar.showBalloon(StatusPill.minimizedNote, warning: false)
        }
    }

    /// ThumbFree's warning under the menu's status line while both apps use the same key, as ThumbFree's menu warns
    /// about Voice Assistant; it goes once ThumbFree quits.
    private func showThumbFreeWarning(_ clash: Bool) {
        let note: String? = clash ? AppController.thumbFreeNote : nil
        menuBar.menu.showNote(note)
    }
}

extension AppUI.Parts {
    /// The app's: the menu bar item, the window on the assistant host and its AI brain, reminder cards with the Mac's
    /// alert sound, the login item, and quitting. No number badges yet.
    static func standard(
        settings: AppSettings, paths: AppPaths, board: BoardStore, host: AssistantHost,
        restart: @escaping @MainActor (_ windowVisible: Bool) -> Void
    ) -> AppUI.Parts {
        let startAtLogin = StartAtLogin(isEnabled: { LoginItem.isEnabled }, set: { LoginItem.set($0) })
        let keys = AppUI.keyNames(settings)
        let brain: BrainControls? = host.brain
        return AppUI.Parts(
            menuBar: { hotkeys, actions in MenuBar(hotkeys: hotkeys, actions: actions) },
            window: { notice in
                MainWindow(
                    settings: settings, paths: paths, board: board, assistant: host, brain: brain, keys: keys,
                    startAtLogin: startAtLogin, restart: restart, notice: notice)
            },
            card: { item, answer in ReminderCardPanel(item, answer: answer) },
            sound: { NSSound.beep() },
            startAtLogin: startAtLogin,
            quit: { NSApp.terminate(nil) },
            badges: nil)
    }
}
