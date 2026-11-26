import AppKit
import SwiftUI
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// The idea board's page (see `Renderer`), to compare with Windows' IdeasPage: the window at the board, the board with
/// notes in every list, with the done notes hidden, empty, a note being edited, a note dragged to a place and onto
/// Reminders, "show my reminders", a long list, the narrowest window, the notes' menus and the picture that follows the
/// mouse while a note is dragged. Reduce motion is on, so nothing is caught mid-fade.
extension UIRenderTests {
    @MainActor
    func testTheIdeaBoard() throws {
        try Self.withoutMotion {
            let rig = PageRig()
            defer { rig.folder.remove() }
            let board = try Self.sampleBoard(rig)
            let model = rig.ideas(board)
            let window = WindowModel(
                home: rig.home(board: board), settings: rig.settings(), help: HelpModel(keys: KeyNames()),
                board: model)
            window.show(.ideas)
            Renderer.render(Self.window(window), "window-6-idea-board")
            Renderer.render(Self.page(model), "board-1-page")

            model.showDone = false
            Renderer.render(Self.page(model), "board-2-done-hidden")
            model.showDone = true

            let idea = model.columns[0].notes[1].id
            model.beginEdit(idea)
            model.editText = "A board game about the monsoon that a whole family can play in one evening"
            Renderer.render(Self.page(model), "board-3-editing")
            model.finishEdit(save: false)

            model.dragging = idea
            model.dropTarget = BoardModel.DropTarget(list: .todo, index: 1, line: 1)
            Renderer.render(Self.page(model), "board-4-dragging-to-a-place")
            model.dropTarget = BoardModel.DropTarget(list: .reminders, index: 0, line: nil)
            Renderer.render(Self.page(model), "board-5-dragging-onto-reminders")
            model.dragEnded()

            model.highlight(.reminders)
            Renderer.render(Self.page(model), "board-6-show-my-reminders")
            rig.runLater()

            Renderer.render(Self.page(rig.ideas(try rig.board())), "board-7-empty")
            let long = try rig.board()
            for number in 1...16 {
                try long.add(.brainstorm, "Brainstorm note number \(number), long enough to wrap onto a second line")
            }

            Renderer.render(Self.page(rig.ideas(long)), "board-8-long-list")
            Renderer.render(Self.page(model, width: MainWindow.minimumSize.width - 230), "board-9-narrowest-window")
            Renderer.render(Self.menus(model), "board-10-menus")
            try Self.renderGhost(model)
        }
    }

    /// A board as it might be after a few days: ideas, a brainstorm, to-dos and reminders, some done, one due.
    @MainActor
    private static func sampleBoard(_ rig: PageRig) throws -> BoardStore {
        let board = try rig.board()
        let now = rig.now.value
        let mug = try board.add(.ideas, "Mug with a Hindi pun")
        try board.setDone(mug.id, true)
        try board.add(.ideas, "Sticker pack of Indian street food")
        try board.add(.ideas, "A podcast about chai and startups")
        try board.add(.ideas, "A voice game for kids")
        try board.add(.brainstorm, "Offline mode for the whole family")
        try board.add(.brainstorm, "Names for the app: Jarvis, Saathi, Dost")
        let plumber = try board.add(.todo, "Call the plumber")
        try board.setDone(plumber.id, true)
        try board.add(.todo, "Book the car service")
        try board.add(.todo, "Pay the electricity bill")
        try board.add(.todo, "Renew passport")
        try board.add(.reminders, "Water the plants", due: nil)
        try board.add(.reminders, "Book the dentist for Thursday morning", due: PageRig.date("2026-11-27 09:00"))
        try board.add(.reminders, "Stretch", due: PageRig.date("2026-11-26 18:00"))
        try board.add(.reminders, "Call mom", due: now.addingTimeInterval(25 * 60))
        try board.add(.reminders, "Pay the rent", due: now.addingTimeInterval(-10 * 60))
        return board
    }

    /// The page as the window shows it beside the sidebar, or `width` wide.
    @MainActor
    private static func page(_ model: BoardModel, width: CGFloat? = nil) -> some View {
        let shown: CGFloat = width ?? MainWindow.size.width - 230
        return IdeasPage(model: model)
            .frame(width: shown, height: MainWindow.size.height)
            .background(Color(Theme.background))
    }

    /// The menus of a note in the middle of a list, its Move to, the top note's (it can't move up) and a reminder's.
    @MainActor
    private static func menus(_ model: BoardModel) -> some View {
        let ideas = model.columns[0].notes
        let reminder = model.columns[3].notes[1]
        let middle = NoteMenu.make(model.menu(for: ideas[1].id)) { _ in }
        let top = NoteMenu.make(model.menu(for: ideas[0].id)) { _ in }
        let snooze = NoteMenu.make(model.menu(for: reminder.id)) { _ in }
        let moveTo: NSMenu = middle.items[1].submenu ?? NSMenu()
        return HStack(alignment: .top, spacing: 0) {
            MenuPicture(middle)
            MenuPicture(moveTo)
            MenuPicture(top)
            MenuPicture(snooze)
        }
        .background(Color(white: 0.82))
    }

    /// The picture that follows the mouse while the first idea is dragged, grabbed near its left end.
    @MainActor
    private static func renderGhost(_ model: BoardModel) throws {
        let note = model.columns[0].notes[0]
        let hosted = Hosted(NoteCard(model: model, note: note).frame(width: 205), size: CGSize(width: 205, height: 60))
        defer { hosted.close() }
        let mouse = try XCTUnwrap(hosted.views(NoteInteractionView.self).first)
        let grab = NSPoint(x: 40, y: mouse.bounds.midY)
        let ghost = try XCTUnwrap(NoteGhost.make(from: mouse, grab: grab))
        Renderer.render(
            Image(nsImage: ghost.image).padding(24).background(Color(Theme.card)), "board-11-drag-ghost")
    }
}
