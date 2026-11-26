import AppKit
import VoiceAssistantBoard
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// The app's UI wired to the assistant (windows-voice-assistant App.xaml.cs's OnStartup, with TrayIcon's and
/// MainWindow's subscriptions): a host on fakes whose events come on the main thread, as in the app, a real pill and a
/// real menu, and a menu bar item, window, reminder cards and number badges that record what they're asked.
final class AppUITests: XCTestCase {
    /// Each menu item reaches what it names (Windows' TrayIcon): the host, the window's pages, the pill, the login item
    /// and quitting; the ticks read the host, the pill and the login item each time the menu opens.
    @MainActor
    func testTheMenusItemsReachTheHostTheWindowThePillAndTheLoginItem() async throws {
        let rig = try AppUIRig()
        rig.makeUI()
        let menu = rig.menuBar.menu
        let listening = await rig.startListening()
        XCTAssertTrue(listening)

        for item in [menu.openApp, menu.ideaBoard, menu.whatYouCanSay, menu.settings] {
            menu.click(item)
        }

        XCTAssertEqual(rig.window.opened, [.home, .ideas, .help, .settings])

        menu.click(menu.toggle)
        let paused = await rig.until { rig.window.statuses.contains("Paused. Microphone is off.") }
        XCTAssertTrue(paused)
        XCTAssertEqual(rig.host.mode, .paused)
        XCTAssertFalse(rig.hostRig.microphone.isRunning)
        XCTAssertEqual(rig.ui.pill.model.mode, .paused)
        XCTAssertEqual(rig.menuBar.modes.last, .paused)
        XCTAssertEqual(menu.statusLine.title, "Paused (microphone off)")
        XCTAssertTrue(menu.toggle.title.hasPrefix("Start listening"))

        menu.click(menu.hinglish)
        let hinglish = await rig.until { rig.ui.pill.model.hinglish }
        XCTAssertTrue(hinglish)
        XCTAssertEqual(rig.window.languages, [DictationLanguage(hinglish: true, accurate: false)])
        menu.prepare()
        XCTAssertEqual([menu.english, menu.hinglish, menu.hinglishAccurate].map(\.state), [.off, .on, .off])

        menu.click(menu.pasteLast)
        let pasted = await rig.until { rig.window.statuses.contains("There's no previous dictation yet.") }
        XCTAssertTrue(pasted)
        menu.click(menu.copyUntyped)
        let copied = await rig.until { rig.window.statuses.contains("There's no untyped text.") }
        XCTAssertTrue(copied)

        // The pill only while it has something to show: its flag, and once a word on what that does.
        XCTAssertEqual(menu.showPill.state, .on)
        menu.click(menu.showPill)
        XCTAssertTrue(rig.ui.pill.minimized)
        XCTAssertTrue(StateFlags.isSet(rig.paths.overlayMinimizedFlag))
        XCTAssertEqual(rig.menuBar.balloons, [MenuBarRecorder.Shown(StatusPill.minimizedNote, warning: false)])
        menu.prepare()
        XCTAssertEqual(menu.showPill.state, .off)
        menu.click(menu.showPill)
        XCTAssertFalse(rig.ui.pill.minimized)
        XCTAssertFalse(StateFlags.isSet(rig.paths.overlayMinimizedFlag))
        XCTAssertEqual(rig.menuBar.balloons.count, 1, "said when it's minimized")

        menu.click(menu.startAtLogin)
        XCTAssertEqual(rig.login.asked, [true])
        menu.prepare()
        XCTAssertEqual(menu.startAtLogin.state, .on)
        menu.click(menu.quit)
        XCTAssertEqual(rig.quits, 1)
        await rig.close()
    }

    /// What the host says reaches the pill, the menu bar item and the window, on the main thread (Windows' App and
    /// MainWindow subscriptions): statuses and the mode, a dictation's label, level and words, the language, the AI
    /// brain, "show my reminders", text that couldn't be typed, and the number badges.
    @MainActor
    func testTheHostsEventsReachThePillTheMenuBarAndTheWindow() async throws {
        let brain = FakeBrain()
        let rig = try AppUIRig(brain: brain)
        rig.makeUI()
        XCTAssertEqual(rig.ui.pill.model.display.mode, "Starting…")
        let listening = await rig.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(rig.ui.pill.model.mode, .standby)
        XCTAssertEqual(rig.menuBar.modes.last, .standby)
        XCTAssertEqual(rig.menuBar.menu.statusLine.title, "Waiting for “Hey Jarvis”")

        let host = rig.host
        host.raise(host.activity, AssistantActivity(mode: .standby, label: StatusPill.listening))
        host.raise(host.inputLevel, 0.8)
        host.raise(host.dictationPreview, "hello wor")
        let previewed = await rig.until { rig.ui.pill.model.preview == "hello wor" }
        XCTAssertTrue(previewed)
        XCTAssertEqual(rig.ui.pill.model.activity, StatusPill.listening)
        XCTAssertGreaterThan(rig.ui.pill.model.level, 0)

        host.raise(host.dictationLanguageChanged, DictationLanguage(hinglish: true, accurate: true))
        let accurate = await rig.until { rig.ui.pill.model.accurate }
        XCTAssertTrue(accurate)
        XCTAssertEqual(rig.ui.pill.model.display.badge, "HI + EN · accurate")
        XCTAssertEqual(rig.window.languages, [DictationLanguage(hinglish: true, accurate: true)])

        brain.change(to: .installed)
        let brainSeen = await rig.until { rig.window.brainChanges == 1 }
        XCTAssertTrue(brainSeen)

        host.raise(host.showBoardRequested, BoardList.reminders)
        host.raise(host.showBoardRequested, nil)
        let boards = await rig.until { rig.window.boards.count == 2 }
        XCTAssertTrue(boards)
        XCTAssertEqual(rig.window.boards, [.reminders, nil])

        XCTAssertFalse(rig.ui.menuState.hasUntypedText)
        host.raise(host.untypedTextChanged, true)
        let untyped = await rig.until { rig.ui.hasUntypedText }
        XCTAssertTrue(untyped)
        rig.menuBar.menu.prepare()
        XCTAssertFalse(rig.menuBar.menu.copyUntyped.isHidden, "the menu offers to copy it")

        let rect = ScreenRect(x: 10, y: 20, width: 30, height: 40)
        let badges = [ChoiceBadge(number: 1, rect: rect, label: "Issues")]
        host.raise(host.choicesChanged, badges)
        host.raise(host.highlight, rect)
        host.raise(host.choicesChanged, nil)
        let drawn = await rig.until { rig.badges.shown.count == 2 }
        XCTAssertTrue(drawn)
        XCTAssertEqual(rig.badges.shown, [badges, nil])
        XCTAssertEqual(rig.badges.flashed, [rect])
        await rig.close()
    }

    /// The app's notices show as balloons, the ones in force before the UI listened too; ThumbFree's warning stays
    /// under the menu's status line while it holds; Home hears when permissions change; opening the app again brings
    /// the window; and the window's own notes show with their sign: information, or a warning for what went wrong.
    @MainActor
    func testTheAppsNoticesWarningsAndRequestsReachTheUI() async throws {
        let rig = try AppUIRig()
        let taken = "⌃⇧Space (pause/resume) is used by another app."
        rig.notice.send(taken, topic: AppController.NoticeTopic.hotkey("pause/resume"))
        rig.makeUI(thumbFreeRunsToo: true)
        XCTAssertEqual(rig.menuBar.balloons, [MenuBarRecorder.Shown(taken, warning: true)], "told before the UI was made")
        let note = rig.menuBar.menu.noteLine
        XCTAssertFalse(note.isHidden)
        XCTAssertEqual(note.title, AppController.thumbFreeNote)

        rig.thumbFreeChanged.send(false)
        XCTAssertTrue(note.isHidden, "ThumbFree quit")
        rig.thumbFreeChanged.send(true)
        XCTAssertFalse(note.isHidden)

        let restart = "Couldn't restart. Quit from the menu bar and start Voice Assistant again."
        rig.notice.send(restart)
        XCTAssertEqual(rig.menuBar.balloons.last, MenuBarRecorder.Shown(restart, warning: true))

        rig.permissionsChanged.send(())
        XCTAssertEqual(rig.window.permissionChecks, 1)
        rig.showRequested.send(())
        XCTAssertEqual(rig.window.brought, 1)

        rig.window.notice?(MainWindow.stillRunning, false)
        XCTAssertEqual(rig.menuBar.balloons.last, MenuBarRecorder.Shown(MainWindow.stillRunning, warning: false))
        let problem = "Something went wrong: You don't have permission to save the file “board.json”."
        rig.window.notice?(problem, true)
        XCTAssertEqual(
            rig.menuBar.balloons.last, MenuBarRecorder.Shown(problem, warning: true),
            "what went wrong has the warning sign, as Windows' unhandled-error balloon")
        await rig.close()
    }

    /// Reminders that are due pop up as cards, with a sound, once the UI is made (Windows' ShowDueReminders at startup);
    /// a card's Open board opens the window at the reminders.
    @MainActor
    func testDueRemindersPopUpAndOpenBoardOpensTheWindowAtTheReminders() async throws {
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let board = try BoardStore(path: nil, clock: { now.value })
        try board.add(.reminders, "Call mom", due: now.value.addingTimeInterval(-60))
        try board.add(.reminders, "Water the plants", due: now.value.addingTimeInterval(3_600))
        let rig = try AppUIRig(board: board)
        rig.makeUI()
        let shown = await rig.until { rig.cards.count == 1 }
        XCTAssertTrue(shown)
        XCTAssertEqual(rig.cards.map(\.text), ["Call mom"])
        XCTAssertTrue(rig.cards[0].shown)
        XCTAssertEqual(rig.sounds, 1)

        rig.cards[0].answer(.openBoard)
        XCTAssertEqual(rig.window.boards, [.reminders])
        XCTAssertTrue(rig.cards[0].closed)
        await rig.close()
    }

    /// At launch the window opens at Home, unless the app started in the background with nothing to ask: Windows shows
    /// it unless started in the background, and a Mac also opens it while a permission is missing, for Home to ask.
    @MainActor
    func testTheWindowOpensAtLaunchUnlessInTheBackgroundWithNothingToAsk() async throws {
        let rig = try AppUIRig()
        rig.makeUI()
        rig.ui.showAtLaunch(background: true)
        XCTAssertEqual(rig.window.opened, [])

        rig.window.permissionsNeeded = true
        rig.ui.showAtLaunch(background: true)
        XCTAssertEqual(rig.window.opened, [.home])

        rig.window.permissionsNeeded = false
        rig.ui.showAtLaunch(background: false)
        XCTAssertEqual(rig.window.opened, [.home, .home])
        await rig.close()
    }

    /// Quitting takes the menu bar item and the pill away, and the UI stops hearing the host and the app.
    @MainActor
    func testClosingTakesTheUIAwayAndStopsListening() async throws {
        let rig = try AppUIRig()
        rig.makeUI()
        XCTAssertTrue(rig.ui.pill.isOnScreen)
        rig.ui.close()
        XCTAssertEqual(rig.window.finishedEditing, 1, "a note being edited is saved first")
        XCTAssertTrue(rig.menuBar.removed)
        XCTAssertFalse(rig.ui.pill.isOnScreen)

        rig.notice.send("Couldn't restart. Quit from the menu bar and start Voice Assistant again.")
        rig.showRequested.send(())
        let host = rig.host
        host.raise(host.status, AssistantStatus(mode: .command, kind: .info, message: "Yes? Say a command."))
        host.raise(host.showBoardRequested, nil)
        await rig.drainMain()
        XCTAssertEqual(rig.menuBar.balloons, [])
        XCTAssertEqual(rig.window.brought, 0)
        XCTAssertEqual(rig.window.statuses, [])
        XCTAssertEqual(rig.window.boards, [])
        XCTAssertEqual(rig.menuBar.modes, [])
        await rig.close()
    }

    /// The app's window is made on the assistant host and its AI brain as they are: the host is the window's
    /// `AssistantControls`, and its brain the Settings card's `BrainControls`.
    @MainActor
    func testTheAppsWindowIsMadeOnTheHostAndItsBrain() async throws {
        let rig = try AppUIRig(brain: FakeBrain())
        let parts = AppUI.Parts.standard(
            settings: AppSettings(), paths: rig.paths, board: rig.board, host: rig.host, restart: { _ in })
        let window = try XCTUnwrap(parts.window({ _, _ in }) as? MainWindow)
        XCTAssertFalse(window.isVisible)
        window.brainChanged()
        XCTAssertEqual(window.model.settings.brainCard.text, "Ready: Qwen3 4B, running on this Mac.")

        let listening = await rig.hostRig.startListening()
        XCTAssertTrue(listening)
        window.model.home.toggleListening()
        let paused = await rig.until { rig.host.mode == .paused }
        XCTAssertTrue(paused)
        await rig.close()
    }

    /// The app's window shows the app's board, the page "show my reminders" opens lit at the reminders, and a change
    /// the board can't save is said by the menu bar icon with the warning sign (Windows' "Something went wrong").
    @MainActor
    func testTheAppsBoardPageSaysWhenTheBoardCantSaveAChange() async throws {
        // board.json's folder can't be made: a file has its name.
        let folder = TempFolder()
        defer { folder.remove() }
        let file = folder.file("not-a-folder")
        TestFiles.write(file, "")
        let board = try BoardStore(path: (file as NSString).appendingPathComponent("board.json"))
        let rig = try AppUIRig(board: board)
        let parts = AppUI.Parts.standard(
            settings: AppSettings(), paths: rig.paths, board: rig.board, host: rig.host, restart: { _ in })
        rig.makeUI(window: parts.window)
        let window = try XCTUnwrap(rig.ui.window as? MainWindow)
        let ideas = window.model.board
        ideas.adding[.ideas] = "a voice game for kids"
        ideas.add(to: .ideas)
        let balloon = try XCTUnwrap(rig.menuBar.balloons.last)
        XCTAssertTrue(balloon.message.hasPrefix("Something went wrong: "), balloon.message)
        XCTAssertTrue(balloon.warning)
        XCTAssertEqual(ideas.columns[0].notes.map(\.text), ["A voice game for kids"], "the board keeps it in memory")

        window.model.showBoard(.reminders)
        XCTAssertEqual(window.model.page, .ideas)
        XCTAssertEqual(ideas.glowing, .reminders, "“show my reminders” lights the list up")
        await rig.close()
    }

    /// Quitting saves a note being edited on the board before the UI goes, as Windows' editor saves when its window
    /// loses the keyboard.
    @MainActor
    func testQuittingSavesANoteBeingEdited() async throws {
        let rig = try AppUIRig()
        let note = try rig.board.add(.ideas, "a voice game")
        let parts = AppUI.Parts.standard(
            settings: AppSettings(), paths: rig.paths, board: rig.board, host: rig.host, restart: { _ in })
        rig.makeUI(window: parts.window)
        let window = try XCTUnwrap(rig.ui.window as? MainWindow)
        window.model.board.beginEdit(note.id)
        window.model.board.editText = "a voice game for kids"
        rig.ui.close()
        XCTAssertNil(window.model.board.editing)
        XCTAssertEqual(rig.board.items.first?.text, "A voice game for kids")
        await rig.close()
    }
}

/// The app's UI on a host on fakes whose events come on the main thread, as in the app: `makeUI` makes it with a real
/// pill and a real menu, and a menu bar item, window, reminder cards and number badges that record what they're asked.
@MainActor
final class AppUIRig {
    let hostRig: HostRig
    let board: BoardStore
    let login = PageLogin()
    let window = WindowRecorder()
    let badges = BadgeRecorder()
    let notice = NoticeEvent()
    let thumbFreeChanged = HostEvent<Bool>()
    let permissionsChanged = HostEvent<Void>()
    let showRequested = HostEvent<Void>()
    private(set) var ui: AppUI!
    private(set) var menuBar: MenuBarRecorder!
    private(set) var cards: [CardRecorder] = []
    private(set) var sounds = 0
    private(set) var quits = 0

    /// - Parameter board: The idea board; an empty one in memory by default.
    init(brain: FakeBrain? = nil, board: BoardStore? = nil) throws {
        _ = NSApplication.shared
        let made: BoardStore
        if let board {
            made = board
        } else {
            made = try BoardStore(path: nil)
        }

        self.board = made
        hostRig = HostRig(brain: brain, board: made, post: AssistantHost.postToMain)
    }

    var host: AssistantHost { hostRig.host }

    var paths: AppPaths { hostRig.paths }

    /// Makes the UI, as the app does once the host is made and before it's told anything; with the window `window`
    /// makes, rather than the recorder, when it's given.
    func makeUI(
        thumbFreeRunsToo: Bool = false,
        window: (@MainActor (_ notice: @escaping @MainActor (String, Bool) -> Void) -> AppWindow)? = nil
    ) {
        let events = AppUI.AppEvents(
            notice: notice, thumbFreeChanged: thumbFreeChanged, permissionsChanged: permissionsChanged,
            showRequested: showRequested, thumbFreeRunsToo: thumbFreeRunsToo)
        var parts = self.parts()
        if let window {
            parts.window = window
        }

        ui = AppUI(host: host, app: events, settings: AppSettings(), paths: paths, board: board, parts: parts)
    }

    /// Starts the host, and waits until it listens for the wake word: the window has its status.
    func startListening() async -> Bool {
        host.start()
        return await until { window.statuses.contains(HostRig.listening) }
    }

    /// Waits until `condition` holds, checking every 20 ms for 10 s at most; meanwhile the main thread runs what the
    /// host posted. False if it never did.
    func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return condition()
    }

    /// Waits until what was posted to the main thread so far has run.
    func drainMain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                done.resume()
            }
        }
    }

    func close() async {
        ui?.close()
        await hostRig.close()
    }

    private func parts() -> AppUI.Parts {
        let window = self.window
        let badges = self.badges
        return AppUI.Parts(
            menuBar: { [weak self] hotkeys, actions in
                let menuBar = MenuBarRecorder(hotkeys: hotkeys, actions: actions)
                self?.menuBar = menuBar
                return menuBar
            },
            window: { (notice: @escaping @MainActor (String, Bool) -> Void) in
                window.notice = notice
                return window
            },
            card: { [weak self] item, answer in
                let card = CardRecorder(text: item.text, answer: answer)
                self?.cards.append(card)
                return card
            },
            sound: { [weak self] in
                self?.sounds += 1
            },
            startAtLogin: login.item,
            quit: { [weak self] in
                self?.quits += 1
            },
            badges: { badges })
    }
}

/// The menu bar item: a real menu, and what the icon and its balloons were asked to show.
@MainActor
final class MenuBarRecorder: MenuBarItem {
    /// A balloon by the icon.
    struct Shown: Equatable {
        let message: String
        let warning: Bool

        init(_ message: String, warning: Bool) {
            self.message = message
            self.warning = warning
        }
    }

    let menu: StatusMenu
    private(set) var modes: [InteractionMode] = []
    private(set) var balloons: [Shown] = []
    private(set) var removed = false

    init(hotkeys: MenuHotkeys, actions: MenuActions) {
        menu = StatusMenu(hotkeys: hotkeys, actions: actions)
    }

    func update(_ mode: InteractionMode) {
        modes.append(mode)
        menu.showMode(mode)
    }

    func showBalloon(_ message: String, warning: Bool) {
        balloons.append(Shown(message, warning: warning))
    }

    func remove() {
        removed = true
    }
}

/// The window: what it was asked to show, and the notice it was given for the menu bar icon.
@MainActor
final class WindowRecorder: AppWindow {
    var isVisible = false
    var permissionsNeeded = false
    var notice: (@MainActor (String, Bool) -> Void)?
    private(set) var brought = 0
    private(set) var opened: [AppPage] = []
    private(set) var boards: [BoardList?] = []
    private(set) var statuses: [String] = []
    private(set) var languages: [DictationLanguage] = []
    private(set) var brainChanges = 0
    private(set) var permissionChecks = 0
    private(set) var finishedEditing = 0

    func bring() {
        brought += 1
    }

    func open(_ page: AppPage) {
        opened.append(page)
    }

    func showBoard(_ list: BoardList?) {
        boards.append(list)
    }

    func showStatus(_ update: AssistantStatus) {
        statuses.append(update.message)
    }

    func setDictationLanguage(hinglish: Bool, accurate: Bool) {
        languages.append(DictationLanguage(hinglish: hinglish, accurate: accurate))
    }

    func brainChanged() {
        brainChanges += 1
    }

    func refreshPermissions() {
        permissionChecks += 1
    }

    func finishEditing() {
        finishedEditing += 1
    }
}

/// A reminder's card: its text, whether it showed or closed, and its buttons.
@MainActor
final class CardRecorder: ReminderCardWindow {
    let text: String
    let answer: @MainActor (ReminderAnswer) -> Void
    let size = CGSize(width: 354, height: 128)
    private(set) var shown = false
    private(set) var closed = false

    init(text: String, answer: @escaping @MainActor (ReminderAnswer) -> Void) {
        self.text = text
        self.answer = answer
    }

    func place(_ frame: CGRect) {}

    func show() {
        shown = true
    }

    func close() {
        closed = true
    }
}

/// The desktop's number badges: what they were asked to draw.
@MainActor
final class BadgeRecorder: NumberBadges {
    private(set) var shown: [[ChoiceBadge]?] = []
    private(set) var flashed: [ScreenRect] = []

    func showBadges(_ badges: [ChoiceBadge]?) {
        shown.append(badges)
    }

    func flash(_ rect: ScreenRect) {
        flashed.append(rect)
    }
}
