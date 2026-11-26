import AppKit
import SwiftUI
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// The window (windows-voice-assistant MainWindow.cs): closing hides it and says once that the app still runs, the
/// sidebar's pages and the board, what the assistant tells it, the pages read again as it shows, and the Mac's keys
/// while it's in front.
final class MainWindowTests: XCTestCase {
    @MainActor
    func testClosingHidesTheWindowAndSaysOnceThatTheAppIsStillRunning() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        var notices: [String] = []
        var signs: [Bool] = []
        var restarts: [Bool] = []
        let window = try Self.window(
            rig, notice: { notices.append($0); signs.append($1) }, restart: { restarts.append($0) })
        XCTAssertFalse(window.isVisible, "the app brings it when it should show")

        XCTAssertFalse(window.windowShouldClose(NSWindow()), "closing hides it")
        XCTAssertEqual(notices, [MainWindow.stillRunning])
        XCTAssertEqual(signs, [false], "as information")
        XCTAssertEqual(
            MainWindow.stillRunning,
            "Voice Assistant is still running in the menu bar. Click its icon › Quit Voice Assistant to quit.")
        XCTAssertFalse(window.windowShouldClose(NSWindow()))
        XCTAssertEqual(notices.count, 1, "said the first time only")

        window.model.settings.saveAndRestart()
        XCTAssertEqual(restarts, [false], "closed: the new copy starts with its window closed, as Windows' Restart")

        // Closing hides the app too (the keyboard goes back to the app before); the floating panels stay.
        let pill = FloatingPanel.make(FirstClickHostingView(rootView: Text(verbatim: "Listening for a command")))
        XCTAssertFalse(pill.canHide, "the pill, the cards and the balloon stay on the screen")
    }

    @MainActor
    func testANoteBeingEditedIsSavedWhenTheWindowClosesOrAnotherAppComesInFront() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let note = try board.add(.ideas, "a voice game")
        let window = try Self.window(rig, board: board)
        let ideas = window.model.board
        ideas.beginEdit(note.id)
        ideas.editText = "a voice game for kids"
        XCTAssertFalse(window.windowShouldClose(NSWindow()))
        XCTAssertNil(ideas.editing)
        XCTAssertEqual(board.items.first?.text, "A voice game for kids", "closing the window saves it")

        ideas.beginEdit(note.id)
        ideas.editText = "a voice game for grown-ups"
        window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertNil(ideas.editing)
        XCTAssertEqual(
            board.items.first?.text, "A voice game for grown-ups",
            "another app in front saves it, as Windows' editor saves when its window loses the keyboard")
    }

    @MainActor
    func testTheSidebarOpensPagesAndTheBoardOpensAtAList() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = try Self.window(rig).model
        XCTAssertEqual(model.page, .home)
        model.show(.settings)
        XCTAssertEqual(model.page, .settings)
        model.showBoard(.reminders)
        XCTAssertEqual(model.page, .ideas)
        XCTAssertEqual(model.boardList, .reminders, "“show my reminders”")
        model.show(.help)
        model.show(.ideas)
        XCTAssertEqual(model.page, .ideas)
        XCTAssertNil(model.boardList, "the sidebar opens the whole board")
    }

    @MainActor
    func testThePagesAreReadAgainWhenTheWindowShows() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        try board.add(.reminders, "Call mom", due: rig.now.value.addingTimeInterval(10 * 60))
        rig.system.microphone = .notDetermined
        let model = WindowModel(
            home: rig.home(board: board), settings: rig.settings(), help: HelpModel(keys: KeyNames()),
            board: rig.ideas(board))
        XCTAssertEqual(model.home.permissions.map(\.kind), [.microphone])
        XCTAssertEqual(model.home.upcoming.map(\.colour), [Theme.text])
        XCTAssertFalse(model.settings.startsAtLogin)

        // Away for 20 minutes, while the microphone and the login item were switched on in System Settings.
        rig.now.update { $0 = $0.addingTimeInterval(20 * 60) }
        rig.system.microphone = .authorized
        rig.login.enabled = true
        model.refresh()
        XCTAssertEqual(model.home.permissions, [])
        XCTAssertEqual(model.home.upcoming.map(\.colour), [Theme.danger], "due now")
        XCTAssertEqual(model.board.columns[3].notes.map(\.overdue), [true], "on the board too")
        XCTAssertTrue(model.settings.startsAtLogin)
    }

    @MainActor
    func testWhatTheAssistantSaysReachesThePages() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let window = try Self.window(rig)
        window.showStatus(AssistantStatus(mode: .command, kind: .success, message: "Opened TextEdit."))
        XCTAssertEqual(window.model.home.mode, .command)
        XCTAssertEqual(window.model.home.activity.count, 1)
        XCTAssertTrue(window.model.home.activity[0].text.hasSuffix("   Opened TextEdit."))

        window.setDictationLanguage(hinglish: true, accurate: true)
        XCTAssertEqual(window.model.home.languageIndex, 2)

        rig.brain.status = .ready
        rig.brain.canDownload = false
        window.brainChanged()
        XCTAssertEqual(window.model.settings.brainCard.text, "Ready: Qwen3 4B, running on this Mac.")
        XCTAssertEqual(rig.assistant.calls, [], "nothing goes back to the assistant")
    }

    @MainActor
    func testTheAppsMenuGivesTheWindowTheMacsKeys() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        _ = try Self.window(rig)
        let menu = try XCTUnwrap(NSApplication.shared.mainMenu)
        var items: [NSMenuItem] = []
        for top in menu.items {
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                items.append(item)
            }
        }

        XCTAssertEqual(
            items.map(\.title),
            [
                "Settings…", "Hide Voice Assistant", "Quit Voice Assistant", "Undo", "Redo", "Cut", "Copy", "Paste",
                "Select All", "Close", "Minimize",
            ])
        XCTAssertEqual(items.map(\.keyEquivalent), [",", "h", "q", "z", "Z", "x", "c", "v", "a", "w", "m"])
        let command: NSEvent.ModifierFlags = [.command]
        XCTAssertTrue(items.allSatisfy { (item: NSMenuItem) -> Bool in item.keyEquivalentModifierMask == command })
        XCTAssertEqual(items.last?.action, #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertEqual(items[2].action, #selector(NSApplication.terminate(_:)), "quitting is the app's, as ⌘Q")
    }

    @MainActor
    private static func window(
        _ rig: PageRig, board: BoardStore? = nil, notice: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
        restart: @escaping @MainActor (Bool) -> Void = { _ in }
    ) throws -> MainWindow {
        _ = NSApplication.shared
        let window = MainWindow(
            settings: AppSettings(), paths: rig.paths, board: try board ?? rig.board(), assistant: rig.assistant,
            brain: rig.brain, keys: KeyNames(), startAtLogin: rig.login.item, restart: restart, notice: notice,
            permissions: Permissions(system: rig.system), opener: rig.opener)
        return window
    }
}
