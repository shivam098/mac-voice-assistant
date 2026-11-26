import AppKit
import SwiftUI
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// The idea board (windows-voice-assistant IdeasPage.cs): a column of sticky notes per list, the add boxes, ticking,
/// editing, the notes' menus, dragging with the drop line, "show my reminders", and the notes that fade in; and the
/// AppKit parts on a real view: the mouse on a note, its editor, and what catches a dragged note over the board.
final class IdeasPageTests: XCTestCase {
    @MainActor
    func testEachListIsAColumnOfItsOpenNotesInOrderThenTheDoneOnes() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        try board.add(.ideas, "a voice game for kids")
        rig.now.update { $0 = PageRig.date("2026-11-26 16:01") }
        try board.add(.ideas, "a podcast about chai")
        try board.add(.todo, "renew passport")
        let rent = try board.add(.todo, "pay the rent")
        try board.setDone(rent.id, true)
        try board.add(.reminders, "water the plants", due: nil)
        try board.add(.reminders, "call mom", due: PageRig.date("2026-11-26 16:26"))
        try board.add(.reminders, "stretch", due: PageRig.date("2026-11-26 15:51"))
        let model = rig.ideas(board)

        XCTAssertEqual(model.columns.map(\.name), ["Ideas", "Brainstorm", "To-do", "Reminders"])
        XCTAssertEqual(model.columns.map(\.count), ["2", "", "1", "3"], "the open notes")
        XCTAssertEqual(
            model.columns[0].notes.map(\.text), ["A podcast about chai", "A voice game for kids"],
            "a new note goes on top")
        XCTAssertEqual(model.columns[1].notes, [])
        XCTAssertEqual(model.columns.map(\.empty), [
            "Nothing here yet.", "Nothing here yet.", "Nothing here yet.", "No reminders yet.",
        ])
        let todo = model.columns[2].notes
        XCTAssertEqual(todo.map(\.text), ["Renew passport", "Pay the rent"], "done, below the open ones")
        XCTAssertEqual(todo.map(\.done), [false, true])
        XCTAssertEqual(todo.map(\.colour), [Colour(0xDDF5E3), Theme.background], "the list's colour; grey once done")
        let reminders = model.columns[3].notes
        XCTAssertEqual(
            reminders.map(\.text), ["Stretch", "Call mom", "Water the plants"], "by time, those without one last")
        XCTAssertEqual(reminders.map(\.due), ["⏰ today 3:51 PM (due)", "⏰ in 25 min", nil])
        XCTAssertEqual(reminders.map(\.overdue), [true, false, false], "red once due")
        XCTAssertEqual(reminders.map(\.position), [0, 1, 2])
        XCTAssertTrue(reminders[0].help.hasPrefix("Added "), reminders[0].help)
        XCTAssertTrue(
            reminders[0].help.hasSuffix(". Drag to move, double-click to edit, right-click for more."),
            reminders[0].help)
        XCTAssertEqual(
            model.columns.map(\.placeholder),
            ["Add a note…", "Add a note…", "Add a note…", "Add a reminder… (with a time)"])
        XCTAssertEqual(model.columns[0].addHelp, "Type a note and press Return")
        XCTAssertEqual(
            model.columns[3].addHelp, "Type a reminder with a time (“call mom tomorrow 5 pm”) and press Return")
        XCTAssertEqual(
            rig.ideas(board, keys: KeyNames(dictation: "Right Option")).tip,
            "Tap Right Option and say “Add to my ideas, …” or “Add … to my to-do list”, then tap Right Option again. "
                + "After “Hey Jarvis”: “remind me to call mom tomorrow at 5 pm”. Everything stays on this Mac.")

        model.showDone = false
        XCTAssertEqual(model.columns[2].notes.map(\.text), ["Renew passport"], "Show done off")
        XCTAssertEqual(model.columns[2].count, "1")
    }

    @MainActor
    func testTheAddBoxPutsANoteOnTopAndReadsAReminderTime() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        try board.add(.ideas, "first")
        let model = rig.ideas(board)

        model.adding[.ideas] = "  a voice game for kids. "
        model.add(to: .ideas)
        XCTAssertEqual(model.columns[0].notes.map(\.text), ["A voice game for kids", "First"], "tidied, on top")
        XCTAssertEqual(model.adding[.ideas], "", "the box empties")

        model.adding[.reminders] = "call mom tomorrow 5 pm"
        model.add(to: .reminders)
        let reminder = try XCTUnwrap(board.items.first { $0.list == .reminders })
        XCTAssertEqual(reminder.text, "Call mom")
        XCTAssertEqual(reminder.due, PageRig.date("2026-11-27 17:00"))
        XCTAssertEqual(model.columns[3].notes.first?.due, "⏰ tomorrow 5:00 PM")

        model.adding[.todo] = "   "
        model.add(to: .todo)
        XCTAssertEqual(model.adding[.todo], "   ", "a blank box does nothing")
        XCTAssertEqual(board.items.count, 3)
    }

    @MainActor
    func testATickAndAnEditGoToTheBoard() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let passport = try board.add(.todo, "renew passport")
        let rent = try board.add(.todo, "pay the rent")
        let model = rig.ideas(board)
        let text = { (id: String) -> String? in board.items.first { $0.id == id }?.text }

        model.setDone(passport.id, true)
        XCTAssertEqual(board.items.first { $0.id == passport.id }?.done, true)
        XCTAssertEqual(model.columns[2].notes.map(\.text), ["Pay the rent", "Renew passport"])

        model.beginEdit(rent.id)
        XCTAssertEqual(model.editing, rent.id)
        XCTAssertEqual(model.editText, "Pay the rent")
        model.editText = "pay the rent and the bills. "
        model.finishEdit(save: true)
        XCTAssertNil(model.editing)
        XCTAssertEqual(text(rent.id), "Pay the rent and the bills", "saved, tidied")

        model.beginEdit(rent.id)
        model.editText = "something else"
        model.finishEdit(save: false)
        XCTAssertEqual(text(rent.id), "Pay the rent and the bills", "Esc keeps the note as it was")

        model.beginEdit(rent.id)
        model.editText = "   "
        model.finishEdit(save: true)
        XCTAssertEqual(text(rent.id), "Pay the rent and the bills", "a blank text isn't saved")

        model.beginEdit(rent.id)
        model.editText = "changed"
        model.beginEdit(passport.id)
        XCTAssertEqual(text(rent.id), "Changed", "opening another editor saves the first")
        XCTAssertEqual(model.editing, passport.id)
        try board.remove(passport.id)
        PageRig.waitForMain { model.editing == nil }
        XCTAssertNil(model.editing, "its note was deleted (by voice, say)")
    }

    @MainActor
    func testANotesMenuHasWhatSuitsIt() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let three = try board.add(.ideas, "three")
        let two = try board.add(.ideas, "two")
        let one = try board.add(.ideas, "one")
        let call = try board.add(.reminders, "call mom", due: rig.now.value.addingTimeInterval(3600))
        let water = try board.add(.reminders, "water the plants", due: nil)
        let model = rig.ideas(board)
        let titles = { (id: String) -> [String] in
            model.menu(for: id).map { (item: BoardModel.MenuItem) -> String in item.isSeparator ? "—" : item.title }
        }

        XCTAssertEqual(titles(two.id), ["Edit", "Move to", "Move up", "Move down", "—", "Delete"])
        XCTAssertEqual(model.menu(for: two.id)[1].submenu.map(\.title), ["Brainstorm", "To-do", "Reminders"])
        XCTAssertEqual(model.menu(for: two.id).map(\.enabled), [true, true, true, true, true, true])
        XCTAssertFalse(model.menu(for: one.id)[2].enabled, "the top note can't move up")
        XCTAssertFalse(model.menu(for: three.id)[3].enabled, "nor the last one down")
        XCTAssertEqual(
            titles(call.id), ["Edit", "Move to", "Snooze 10 minutes", "—", "Delete"], "reminders keep their time order")
        XCTAssertEqual(titles(water.id), ["Edit", "Move to", "—", "Delete"], "no time, nothing to snooze")

        model.perform(.moveDown, on: one.id)
        XCTAssertEqual(model.columns[0].notes.map(\.text), ["Two", "One", "Three"])
        model.perform(.moveUp, on: three.id)
        XCTAssertEqual(model.columns[0].notes.map(\.text), ["Two", "Three", "One"])
        model.perform(.move(.brainstorm), on: one.id)
        XCTAssertEqual(model.columns[1].notes.map(\.text), ["One"])
        model.perform(.snooze, on: call.id)
        XCTAssertEqual(board.items.first { $0.id == call.id }?.due, rig.now.value.addingTimeInterval(10 * 60))
        model.perform(.delete, on: water.id)
        XCTAssertEqual(model.columns[3].notes.map(\.text), ["Call mom"])
        model.perform(.edit, on: two.id)
        XCTAssertEqual(model.editing, two.id)
        model.finishEdit(save: false)

        model.setDone(two.id, true)
        XCTAssertEqual(titles(two.id), ["Edit", "Move to", "—", "Delete"], "a done note isn't reordered")
        XCTAssertEqual(
            NoteCard.spoken(model.menu(for: three.id)).map(\.title),
            ["Edit", "Move to Brainstorm", "Move to To-do", "Move to Reminders", "Delete"],
            "VoiceOver's actions: what can be chosen (it's the only open idea now)")
    }

    @MainActor
    func testADraggedNoteLandsBeforeTheFirstNoteWhoseMiddleIsBelowThePointer() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let c = try board.add(.ideas, "three")
        let b = try board.add(.ideas, "two")
        let a = try board.add(.ideas, "one")
        let done = try board.add(.ideas, "done")
        try board.setDone(done.id, true)
        let columns = rig.ideas(board).columns
        // Ideas from x 0 to 200 and its notes' visible part from y 100 to 400, with three open notes 40 high and 8
        // apart, then the done one; Brainstorm and Reminders beside it.
        var layout = BoardModel.Layout()
        layout.columns[.ideas] = CGRect(x: 0, y: 0, width: 200, height: 500)
        layout.columns[.brainstorm] = CGRect(x: 200, y: 0, width: 200, height: 500)
        layout.columns[.reminders] = CGRect(x: 600, y: 0, width: 200, height: 500)
        layout.viewports[.ideas] = CGRect(x: 0, y: 100, width: 200, height: 300)
        layout.notes[a.id] = CGRect(x: 0, y: 100, width: 200, height: 40)
        layout.notes[b.id] = CGRect(x: 0, y: 148, width: 200, height: 40)
        layout.notes[c.id] = CGRect(x: 0, y: 196, width: 200, height: 40)
        layout.notes[done.id] = CGRect(x: 0, y: 244, width: 200, height: 40)
        let target = { (x: CGFloat, y: CGFloat, dragged: String, current: BoardModel.DropTarget?) in
            BoardModel.dropTarget(
                at: CGPoint(x: x, y: y), dragged: dragged, columns: columns, layout: layout, current: current)
        }
        let ideas = { (index: Int, line: Int) in BoardModel.DropTarget(list: .ideas, index: index, line: line) }

        XCTAssertEqual(target(50, 110, "x", nil), ideas(0, 0), "above the first note's middle")
        XCTAssertEqual(target(50, 150, "x", nil), ideas(1, 1))
        XCTAssertEqual(target(50, 230, "x", nil), ideas(3, 3), "below the last open one; the done note doesn't count")
        XCTAssertEqual(target(50, 40, "x", nil), ideas(0, 0), "over the title or the add box: the top")
        XCTAssertEqual(target(50, 450, "x", nil), ideas(3, 3), "below the notes you can see: after the last one seen")
        XCTAssertEqual(target(50, 150, a.id, nil), ideas(0, 1), "the dragged note doesn't count: it stays where it is")
        XCTAssertEqual(target(50, 300, a.id, nil), ideas(2, 3))
        // The line drawn above "two" pushes "two" and "three" down 11: measured as they'd be without it.
        layout.notes[b.id] = CGRect(x: 0, y: 159, width: 200, height: 40)
        layout.notes[c.id] = CGRect(x: 0, y: 207, width: 200, height: 40)
        XCTAssertEqual(target(50, 172, "x", ideas(1, 1)), ideas(2, 2), "below two's middle (168) without the line")
        XCTAssertEqual(target(50, 165, "x", ideas(1, 1)), ideas(1, 1))
        XCTAssertEqual(
            target(650, 300, a.id, nil), BoardModel.DropTarget(list: .reminders, index: 0, line: nil),
            "reminders keep their time order: anywhere is the list")
        XCTAssertEqual(
            target(250, 300, a.id, nil), BoardModel.DropTarget(list: .brainstorm, index: 0, line: 0), "an empty list")
        XCTAssertNil(target(450, 300, a.id, nil), "not over a column")

        XCTAssertEqual(BoardModel.autoscroll(at: CGPoint(x: 50, y: 390), layout: layout)?.by, 16, "near the bottom")
        XCTAssertEqual(BoardModel.autoscroll(at: CGPoint(x: 50, y: 110), layout: layout)?.by, -16, "near the top")
        XCTAssertEqual(BoardModel.autoscroll(at: CGPoint(x: 50, y: 40), layout: layout)?.by, -16, "over the add box")
        XCTAssertNil(BoardModel.autoscroll(at: CGPoint(x: 50, y: 250), layout: layout))
        XCTAssertNil(BoardModel.autoscroll(at: CGPoint(x: 50, y: 450), layout: layout), "below the notes")
    }

    @MainActor
    func testADropPutsTheNoteWhereTheLineShowed() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let b = try board.add(.ideas, "two")
        let a = try board.add(.ideas, "one")
        let model = rig.ideas(board)
        model.layoutChanged([
            .column(.ideas): CGRect(x: 0, y: 0, width: 200, height: 500),
            .column(.todo): CGRect(x: 400, y: 0, width: 200, height: 500),
            .note(a.id): CGRect(x: 0, y: 100, width: 200, height: 40),
            .note(b.id): CGRect(x: 0, y: 148, width: 200, height: 40),
        ])
        XCTAssertFalse(model.dragMoved(to: CGPoint(x: 50, y: 300)), "no drag")

        model.dragBegan(a.id)
        XCTAssertEqual(model.dragging, a.id)
        XCTAssertTrue(model.dragMoved(to: CGPoint(x: 50, y: 300)))
        XCTAssertEqual(model.dropTarget, BoardModel.DropTarget(list: .ideas, index: 1, line: 2))
        XCTAssertFalse(model.dragMoved(to: CGPoint(x: 300, y: 300)), "between the columns")
        XCTAssertNil(model.dropTarget)
        XCTAssertTrue(model.dragMoved(to: CGPoint(x: 50, y: 300)))
        model.dragExited()
        XCTAssertNil(model.dropTarget)
        XCTAssertTrue(model.drop(at: CGPoint(x: 50, y: 300)))
        model.dragEnded()
        XCTAssertNil(model.dragging)
        XCTAssertEqual(model.columns[0].notes.map(\.text), ["Two", "One"])

        model.dragBegan(b.id)
        XCTAssertTrue(model.drop(at: CGPoint(x: 450, y: 300)))
        model.dragEnded()
        XCTAssertEqual(model.columns[2].notes.map(\.text), ["Two"], "to another list")
        XCTAssertTrue(model.columns[2].notes[0].fresh, "a note that moved fades in where it lands")
    }

    @MainActor
    func testShowMyRemindersLightsTheListForAMoment() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.ideas(try rig.board())
        model.highlight(.reminders)
        XCTAssertEqual(model.glowing, .reminders)
        XCTAssertEqual(rig.later.map { $0.seconds }, [1.8])
        model.highlight(.ideas)
        XCTAssertEqual(model.glowing, .ideas)
        rig.runLater()
        XCTAssertNil(model.glowing, "the first glow's end doesn't cut the second short; the second's ends it")

        let window = WindowModel(
            home: rig.home(board: nil), settings: rig.settings(), help: HelpModel(keys: KeyNames()), board: model)
        window.showBoard(.todo)
        XCTAssertEqual(window.page, .ideas)
        XCTAssertEqual(model.glowing, .todo, "“show my to-do list”")
        window.showBoard(nil)
        rig.runLater()
        XCTAssertNil(model.glowing)
    }

    @MainActor
    func testANoteFadesInWhenItsNewWhereItIs() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let old = try board.add(.ideas, "already there")
        let model = rig.ideas(board)
        XCTAssertEqual(model.columns[0].notes.map(\.fresh), [false], "the first time the board is drawn")

        model.adding[.ideas] = "new"
        model.add(to: .ideas)
        // The board tells of the change too, which draws the board again before SwiftUI draws it.
        PageRig.waitForMain(until: { true })
        XCTAssertEqual(model.columns[0].notes.map(\.fresh), [true, false], "still new when it's drawn")
        rig.runLater()
        XCTAssertEqual(model.columns[0].notes.map(\.fresh), [false, false], "drawn as they are from then on")

        model.setDone(old.id, true)
        PageRig.waitForMain(until: { true })
        XCTAssertEqual(model.columns[0].notes.last?.fresh, true, "ticked")
        XCTAssertNotEqual(
            model.columns[0].notes.last?.key, old.id, "a note ticked is drawn afresh (and fades in) as on Windows")
    }

    @MainActor
    func testAChangeTheBoardCantSaveIsReported() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        // board.json's folder can't be made: a file has its name.
        let file = rig.folder.file("not-a-folder")
        TestFiles.write(file, "")
        let now = rig.now
        let board = try BoardStore(
            path: (file as NSString).appendingPathComponent("board.json"), clock: { now.value },
            timeZone: rig.timeZone)
        let model = rig.ideas(board)
        model.adding[.ideas] = "a voice game"
        model.add(to: .ideas)
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertTrue(rig.reports.first?.hasPrefix("Something went wrong: ") == true, rig.reports.first ?? "")
        XCTAssertEqual(model.columns[0].notes.map(\.text), ["A voice game"], "the board keeps it in memory")
    }

    // MARK: AppKit

    @MainActor
    func testANoteTakesTheMouseButItsTickBoxKeepsItsClicks() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let note = try board.add(.ideas, "a voice game for kids")
        let other = try board.add(.ideas, "a podcast about chai")
        let model = rig.ideas(board)
        let shown = try XCTUnwrap(model.columns[0].notes.last)
        let hosted = Hosted(NoteCard(model: model, note: shown).frame(width: 240), size: CGSize(width: 240, height: 60))
        defer { hosted.close() }
        let mouse = try XCTUnwrap(hosted.views(NoteInteractionView.self).first)
        XCTAssertEqual(mouse.toolTip, shown.help)

        let card = mouse.convert(mouse.bounds, to: hosted.view)
        let onText = Self.hit(hosted, CGPoint(x: card.minX + 120, y: card.midY))
        XCTAssertTrue(onText === mouse, "the text lets the mouse through to the note: \(String(describing: onText))")
        let onTick = Self.hit(hosted, CGPoint(x: card.minX + 17, y: card.minY + 17))
        XCTAssertFalse(onTick === mouse, "the tick box keeps its clicks: \(String(describing: onTick))")

        let menu = try XCTUnwrap(mouse.menu(for: try Self.click(.zero, type: .rightMouseDown, in: hosted.window)))
        XCTAssertEqual(
            menu.items.map { (item: NSMenuItem) -> String in item.isSeparatorItem ? "—" : item.title },
            ["Edit", "Move to", "Move up", "Move down", "—", "Delete"])
        XCTAssertTrue(menu.items[2].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled, "the last note can't move down")
        XCTAssertEqual(menu.items[1].submenu?.items.map(\.title), ["Brainstorm", "To-do", "Reminders"])
        menu.items[1].submenu?.performActionForItem(at: 1)
        XCTAssertEqual(board.items.first { $0.id == note.id }?.list, .todo, "Move to › To-do")

        // A double-click edits; a click on another note closes the editor, saving it.
        let middle = mouse.convert(NSPoint(x: mouse.bounds.midX, y: mouse.bounds.midY), to: nil)
        mouse.mouseDown(with: try Self.click(middle, count: 2, in: hosted.window))
        XCTAssertEqual(model.editing, note.id)
        model.editText = "a voice game for grown-ups"
        let otherShown = try XCTUnwrap(model.columns[0].notes.first { $0.id == other.id })
        let otherMouse = NoteInteractionView()
        otherMouse.update(model: model, note: otherShown)
        otherMouse.mouseDown(with: try Self.click(middle, in: hosted.window))
        XCTAssertNil(model.editing)
        XCTAssertEqual(board.items.first { $0.id == note.id }?.text, "A voice game for grown-ups")
    }

    @MainActor
    func testTheEditorTakesTheKeyboardSavesOnReturnAndNotOnEsc() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let note = try board.add(.ideas, "a voice game for kids")
        let model = rig.ideas(board)
        model.beginEdit(note.id)
        let shown = try XCTUnwrap(model.columns[0].notes.first)
        let hosted = Hosted(NoteCard(model: model, note: shown).frame(width: 240), size: CGSize(width: 240, height: 90))
        defer { hosted.close() }
        let field = try XCTUnwrap(hosted.views(NoteEditorField.self).first)
        XCTAssertEqual(field.stringValue, "A voice game for kids")
        PageRig.waitForMain { field.currentEditor() != nil }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "it takes the keyboard")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 21), "its text selected, to type over")

        editor.insertText("a voice game for grown-ups", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.editText, "a voice game for grown-ups")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNil(model.editing, "Return saves")
        XCTAssertEqual(board.items.first?.text, "A voice game for grown-ups")

        model.beginEdit(note.id)
        let coordinator = NoteEditor.Coordinator(model: model)
        model.editText = "never mind"
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(model.editing, "Esc")
        XCTAssertEqual(board.items.first?.text, "A voice game for grown-ups", "not saved")
        model.beginEdit(note.id)
        model.editText = "for everyone"
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertEqual(board.items.first?.text, "For everyone", "leaving it saves")
    }

    @MainActor
    func testTheEditorGrowsWithItsText() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let note = try board.add(.ideas, "a voice game for kids")
        let model = rig.ideas(board)
        model.beginEdit(note.id)
        model.editText = "A board game about the monsoon that a whole family can play in one evening"
        let shown = try XCTUnwrap(model.columns[0].notes.first)
        let card = NoteCard(model: model, note: shown).frame(width: 240)
        let hosted = Hosted(card, size: CGSize(width: 240, height: 160))
        defer { hosted.close() }
        let field = try XCTUnwrap(hosted.views(NoteEditorField.self).first)
        PageRig.waitForMain { field.currentEditor() != nil }
        hosted.view.layoutSubtreeIfNeeded()
        let line = NoteEditor.height(of: "A", width: field.frame.width)
        XCTAssertGreaterThan(field.frame.height, line * 2, "it wraps, as tall as its text, with the keyboard too")
    }

    @MainActor
    func testADraggedNoteIsCaughtOverTheBoardAndLandsWhereTheLineShows() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let three = try board.add(.ideas, "three")
        let two = try board.add(.ideas, "two")
        let one = try board.add(.ideas, "one")
        let model = rig.ideas(board)
        let hosted = Hosted(IdeasPage(model: model), size: CGSize(width: 1000, height: 600))
        defer { hosted.close() }
        PageRig.waitForMain { model.layout.notes.count == 3 && model.layout.columns.count == 4 }
        XCTAssertEqual(model.layout.notes.count, 3, "the page tells the board where its notes are")
        XCTAssertTrue(hosted.views(DropCatcherView.self).isEmpty, "nothing over the board but during a drag")

        model.dragBegan(one.id)
        PageRig.waitForMain { !hosted.views(DropCatcherView.self).isEmpty }
        let catcher = try XCTUnwrap(hosted.views(DropCatcherView.self).first)
        // The catcher's coordinates are the board's: a note measured in them is where the note is drawn.
        let mouse = try XCTUnwrap(hosted.views(NoteInteractionView.self).first { $0.note?.id == two.id })
        let drawn = mouse.convert(mouse.bounds, to: hosted.view)
        let measured = catcher.convert(try XCTUnwrap(model.layout.notes[two.id]), to: hosted.view)
        XCTAssertEqual(measured.minX, drawn.minX, accuracy: 1, "\(measured) is drawn at \(drawn)")
        XCTAssertEqual(measured.minY, drawn.minY, accuracy: 1, "\(measured) is drawn at \(drawn)")
        XCTAssertEqual(measured.height, drawn.height, accuracy: 1)
        let last = try XCTUnwrap(model.layout.notes[three.id])
        let below = catcher.convert(CGPoint(x: last.midX, y: last.maxY + 4), to: nil)
        XCTAssertEqual(catcher.moved(to: below), .move)
        XCTAssertEqual(model.dropTarget, BoardModel.DropTarget(list: .ideas, index: 2, line: 3))
        XCTAssertTrue(catcher.dropped(at: below))
        model.dragEnded()
        XCTAssertEqual(model.columns[0].notes.map(\.text), ["Two", "Three", "One"])

        model.dragBegan(two.id)
        PageRig.waitForMain { !hosted.views(DropCatcherView.self).isEmpty }
        let again = try XCTUnwrap(hosted.views(DropCatcherView.self).first)
        let todo = try XCTUnwrap(model.layout.columns[.todo])
        let addBox = again.convert(CGPoint(x: todo.midX, y: todo.minY + 45), to: nil)
        XCTAssertEqual(again.moved(to: addBox), .move, "over To-do's add box")
        XCTAssertEqual(model.dropTarget, BoardModel.DropTarget(list: .todo, index: 0, line: 0))
        let above = again.convert(CGPoint(x: todo.midX, y: todo.minY - 20), to: nil)
        XCTAssertEqual(again.moved(to: above), [], "not over a column")
        XCTAssertNil(model.dropTarget)
        model.dragEnded()
        PageRig.waitForMain { hosted.views(DropCatcherView.self).isEmpty }
        XCTAssertTrue(hosted.views(DropCatcherView.self).isEmpty, "gone with the drag")
    }

    @MainActor
    func testAColumnScrollsWhileANoteIsDraggedNearItsBottom() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        for number in 1...20 {
            try board.add(.ideas, "note \(number)")
        }

        let model = rig.ideas(board)
        let hosted = Hosted(IdeasPage(model: model), size: CGSize(width: 1000, height: 420))
        defer { hosted.close() }
        PageRig.waitForMain { model.layout.viewports[.ideas] != nil && model.layout.notes.count == 20 }
        let viewport = try XCTUnwrap(model.layout.viewports[.ideas])
        model.dragBegan(model.columns[0].notes[0].id)
        PageRig.waitForMain { !hosted.views(DropCatcherView.self).isEmpty }
        let catcher = try XCTUnwrap(hosted.views(DropCatcherView.self).first)
        let first = model.columns[0].notes[1].id
        let before = try XCTUnwrap(model.layout.notes[first])
        _ = catcher.moved(to: catcher.convert(CGPoint(x: viewport.midX, y: viewport.maxY - 5), to: nil))
        PageRig.waitForMain { model.layout.notes[first] != before }
        let after = try XCTUnwrap(model.layout.notes[first])
        XCTAssertEqual(after.minY, before.minY - 16, accuracy: 0.5, "16 points at a time, as on Windows")
        model.dragEnded()
    }

    @MainActor
    func testTheDraggedPictureIsTheNoteTilted() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        try board.add(.ideas, "a voice game for kids")
        let model = rig.ideas(board)
        let shown = try XCTUnwrap(model.columns[0].notes.first)
        let hosted = Hosted(NoteCard(model: model, note: shown).frame(width: 240), size: CGSize(width: 240, height: 60))
        defer { hosted.close() }
        let mouse = try XCTUnwrap(hosted.views(NoteInteractionView.self).first)
        let ghost = try XCTUnwrap(NoteGhost.make(from: mouse, grab: NSPoint(x: 30, y: 10)))
        XCTAssertEqual(ghost.frame, mouse.bounds.insetBy(dx: -12, dy: -12), "with room for its tilt and shadow")
        XCTAssertEqual(ghost.image.size, ghost.frame.size)
        let picture = try XCTUnwrap(ghost.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: picture)
        XCTAssertFalse(Renderer.isBlank(bitmap), "the note is in it")
        let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01, "clear round it")
    }

    /// The view `point` (in the hosting view, from the top left) is in.
    @MainActor
    private static func hit<Content: View>(_ hosted: Hosted<Content>, _ point: CGPoint) -> NSView? {
        let host = hosted.view
        guard let frame = host.superview else { return host.hitTest(point) }
        return host.hitTest(host.convert(point, to: frame))
    }

    /// A click at `point` in `window`'s coordinates.
    @MainActor
    private static func click(
        _ point: NSPoint, count: Int = 1, type: NSEvent.EventType = .leftMouseDown, in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }
}
