import AppKit
import SwiftUI
import ThumbFreeCore
import VoiceAssistantBoard
import VoiceAssistantCore

/// The idea board (windows-voice-assistant `IdeasPage`): one column of sticky notes per list. Notes come from voice
/// ("add to my ideas …") or the box at the top of each column; tick them off, drag them to reorder or to another list,
/// double-click to edit, right-click for more. Each change goes straight to the board, which saves it, and the columns
/// follow the board whoever changed it (a voice command, a reminder card's Snooze).
@MainActor
public final class BoardModel: ObservableObject {
    /// A sticky note as its column shows it.
    public struct Note: Equatable, Identifiable, Sendable {
        /// The board item's.
        public let id: String
        /// Its place in the column, from 0 at the top.
        public let position: Int
        public let text: String
        public let done: Bool
        /// Its list's colour, or the page's grey once it's done.
        public let colour: Colour
        /// "⏰ today 5:00 PM", and " (due)" once the time has come; nil without a time.
        public let due: String?
        /// The time has come and it isn't done: the time is red.
        public let overdue: Bool
        /// Its tooltip: when it was added, and what can be done with it.
        public let help: String
        /// Its right-click menu.
        public let menu: [MenuItem]
        /// It's new in its column, or was ticked or unticked, since the board was last drawn: it fades in.
        public internal(set) var fresh: Bool

        /// Who it is in its column: a note ticked or unticked is drawn afresh, as Windows draws it.
        var key: String { done ? id + "/done" : id }
    }

    /// A list's column.
    public struct Column: Equatable, Identifiable, Sendable {
        public var id: BoardList { list }
        public let list: BoardList
        public let name: String
        /// How many notes are open, or nothing for none.
        public let count: String
        /// The open notes in their order, then, while "Show done" is on, the done ones newest first.
        public internal(set) var notes: [Note]
        /// The add box's placeholder and tooltip.
        public let placeholder: String
        public let addHelp: String
        /// What it says without notes.
        public let empty: String
    }

    /// Where a dragged note would land (Windows' `DropTarget`): a list, a place among its open notes (0 = top), and
    /// the position in the column of the note the drop line is drawn above (the column's end: after the last note).
    /// Reminders keep their time order, so there's no line there: only the column lights up.
    public struct DropTarget: Equatable, Sendable {
        public let list: BoardList
        public let index: Int
        public let line: Int?
    }

    /// What a note's menu does.
    public enum MenuAction: Equatable, Sendable {
        case edit
        case move(BoardList)
        case moveUp
        case moveDown
        case snooze
        case delete
    }

    /// An entry of a note's menu: an action, a submenu, or a separator (no title).
    public struct MenuItem: Equatable, Sendable {
        public var title = ""
        public var action: MenuAction?
        public var enabled = true
        public var submenu: [MenuItem] = []

        public var isSeparator: Bool { title.isEmpty }
    }

    /// Where the columns, their notes' visible part and the notes are, in the board's coordinates (`space`), as laid
    /// out and scrolled: what a drag is measured against.
    public struct Layout: Equatable, Sendable {
        public var columns: [BoardList: CGRect] = [:]
        public var viewports: [BoardList: CGRect] = [:]
        public var notes: [String: CGRect] = [:]
    }

    /// The board's coordinate space, which its frames and a drag's point are in.
    nonisolated static let space = "board"

    /// The drop line and the gap below it, which push the notes below the line down.
    nonisolated static let lineSpace: CGFloat = 11

    /// How long Snooze puts a reminder off.
    nonisolated static let snooze: TimeInterval = 10 * 60

    /// How long a list stays lit for "show my reminders", and how long it takes to ease back (milliseconds).
    nonisolated static let glowSeconds: TimeInterval = 1.8
    nonisolated static let glowFade = 900

    /// "Show done": the done notes are at the bottom of their lists.
    @Published public var showDone = true {
        didSet { refresh() }
    }

    @Published public private(set) var columns: [Column] = []
    /// The note being edited, and the editor's text.
    @Published public internal(set) var editing: String?
    @Published public var editText = ""
    /// The note being dragged, dimmed in its place meanwhile, and where it would land.
    @Published public internal(set) var dragging: String?
    @Published public internal(set) var dropTarget: DropTarget?
    /// The list "show my reminders" lights up, for a moment.
    @Published public internal(set) var glowing: BoardList?
    /// What's typed in each list's add box.
    @Published public var adding: [BoardList: String] = [:]

    public let keys: KeyNames
    /// The frames a drag is measured against; set as the page is laid out.
    var layout = Layout()

    private let board: BoardStore
    private let report: @MainActor (String) -> Void
    private let clock: () -> Date
    private let timeZone: TimeZone
    private let addedFormat: DateFormatter
    private let after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    /// Each note's list and state when the board was last drawn; nil before the first time.
    private var drawn: [String: Placement]?
    /// The edited note's text when its editor opened.
    private var textBeforeEdit = ""
    private var settles = 0
    private var glows = 0

    /// - Parameters:
    ///   - board: The idea board.
    ///   - keys: The dictation key, which the tip names.
    ///   - report: Says what went wrong when a change can't be saved (Windows' "Something went wrong" balloon).
    ///   - clock: Now, for the reminders' times.
    ///   - timeZone: The wall clock the times are on.
    ///   - locale: How the tooltips write when a note was added.
    ///   - after: Runs something on the main thread after a while: the glow's end, and the fade-ins' (tests run it
    ///     when they like).
    public init(
        board: BoardStore, keys: KeyNames, report: @escaping @MainActor (String) -> Void = { _ in },
        clock: @escaping () -> Date = { Date() }, timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        after: @escaping @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void =
            BoardModel.afterOnMain
    ) {
        self.board = board
        self.keys = keys
        self.report = report
        self.clock = clock
        self.timeZone = timeZone
        self.after = after
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = timeZone
        format.dateStyle = .short
        format.timeStyle = .short
        addedFormat = format
        board.onChange { [weak self] in
            // The board tells on the thread that changed it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }

        refresh()
    }

    /// Under the heading: how notes get here by voice.
    public var tip: String {
        let key = keys.dictation
        return "Tap \(key) and say “Add to my ideas, …” or “Add … to my to-do list”, then tap \(key) again. After "
            + "“Hey Jarvis”: “remind me to call mom tomorrow at 5 pm”. Everything stays on this Mac."
    }

    /// Draws the board again from what it holds now (Windows' `Refresh`). The notes that are new in their column, or
    /// were ticked or unticked, since the last time fade in.
    public func refresh() {
        let items = board.items
        let now = clock()
        var fresh = Set<String>()
        if let drawn {
            for item in items where drawn[item.id] != Placement(list: item.list, done: item.done) {
                fresh.insert(item.id)
            }
        }

        var shown: [Column] = []
        for list in BoardList.allCases {
            shown.append(column(list, items, now: now, fresh: fresh))
        }

        columns = shown
        var placements: [String: Placement] = [:]
        for item in items where placements[item.id] == nil {
            placements[item.id] = Placement(list: item.list, done: item.done)
        }

        drawn = placements
        if let id = editing, placements[id] == nil {
            editing = nil
        }

        if !fresh.isEmpty {
            settles += 1
            let settle = settles
            after(0.5) { [weak self] in self?.settle(settle) }
        }
    }

    /// Return in `list`'s box: its text goes on top of the list; in Reminders, the time it names ("call mom tomorrow
    /// 5 pm") becomes the reminder's. The box empties. Nothing happens while it's blank.
    public func add(to list: BoardList) {
        let text = DotNet.trim(adding[list] ?? "")
        guard !text.isEmpty else { return }
        var task = text
        var due: Date?
        if list == .reminders {
            let parsed = ReminderTime.parse(text, now: clock(), timeZone: timeZone)
            task = parsed.task
            due = parsed.due
        }

        if !task.isEmpty {
            change { _ = try board.add(list, task, due: due) }
        }

        adding[list] = ""
        refresh()
    }

    /// A note's tick box.
    public func setDone(_ id: String, _ done: Bool) {
        change { try board.setDone(id, done) }
        refresh()
    }

    /// Opens a note's editor, with its text (a double-click, or Edit; Windows' `BeginEdit`). One open already saves
    /// first.
    public func beginEdit(_ id: String) {
        guard editing != id, let item = board.items.first(where: { $0.id == id }) else { return }
        finishEdit(save: true)
        textBeforeEdit = item.text
        editText = item.text
        editing = id
    }

    /// Closes the editor: Return and leaving it save, Esc doesn't. A blank or unchanged text isn't saved; the board
    /// tidies what is, as any note.
    public func finishEdit(save: Bool) {
        guard let id = editing else { return }
        editing = nil
        let text = DotNet.trim(editText)
        if save && !text.isEmpty && text != textBeforeEdit {
            let edited = editText
            change { try board.setText(id, edited) }
        }

        refresh()
    }

    /// The menu of the note `id`, as it's shown now.
    public func menu(for id: String) -> [MenuItem] {
        for column in columns {
            if let note = column.notes.first(where: { $0.id == id }) {
                return note.menu
            }
        }

        return []
    }

    /// Does what a note's menu entry says (Windows' menu handlers).
    public func perform(_ action: MenuAction, on id: String) {
        switch action {
        case .edit:
            beginEdit(id)
            return
        case .move(let list):
            change { try board.move(id, to: list) }
        case .moveUp, .moveDown:
            let items = board.items
            guard let item = items.first(where: { $0.id == id }) else { return }
            let open = Self.openNotes(item.list, items)
            guard let at = open.firstIndex(where: { $0.id == id }) else { return }
            let to = action == .moveUp ? at - 1 : at + 1
            guard open.indices.contains(to) else { return }
            change { try board.place(id, in: item.list, at: to) }
        case .snooze:
            change { try board.snooze(id, by: Self.snooze) }
        case .delete:
            change { try board.remove(id) }
        }

        refresh()
    }

    /// Lights up `list` ("show my reminders"; Windows' `Highlight`): its outline takes the accent colour at once, then
    /// eases back after 1.8 seconds, over 900 ms.
    public func highlight(_ list: BoardList) {
        glows += 1
        let glow = glows
        glowing = list
        after(Self.glowSeconds) { [weak self] in
            guard let self, self.glows == glow else { return }
            withAnimation(Motion.animation(BoardModel.glowFade)) {
                self.glowing = nil
            }
        }
    }

    // MARK: Dragging

    /// A note's drag began (Windows' `StartDrag`): it's dimmed in its place until the drag ends.
    public func dragBegan(_ id: String) {
        finishEdit(save: true)
        dragging = id
        dropTarget = nil
    }

    /// The drag is at `point` over the board (Windows' `OnDragOver`): the drop line shows where the note would land.
    /// False where it can't land.
    @discardableResult
    public func dragMoved(to point: CGPoint) -> Bool {
        guard let id = dragging else { return false }
        let target = Self.dropTarget(at: point, dragged: id, columns: columns, layout: layout, current: dropTarget)
        if target != dropTarget {
            dropTarget = target
        }

        return target != nil
    }

    /// The drag left the board.
    public func dragExited() {
        if dropTarget != nil {
            dropTarget = nil
        }
    }

    /// Dropped at `point` (Windows' `OnDrop`): the note goes where the line showed. False where it can't land.
    @discardableResult
    public func drop(at point: CGPoint) -> Bool {
        guard let id = dragging else { return false }
        let target = Self.dropTarget(at: point, dragged: id, columns: columns, layout: layout, current: dropTarget)
        dropTarget = nil
        guard let target else { return false }
        change { try board.place(id, in: target.list, at: target.index) }
        refresh()
        return true
    }

    /// The drag ended, dropped or not.
    public func dragEnded() {
        dragging = nil
        dropTarget = nil
    }

    /// Where the columns and notes are now.
    func layoutChanged(_ frames: [BoardFrame: CGRect]) {
        var layout = Layout()
        for (frame, rect) in frames {
            switch frame {
            case .column(let list):
                layout.columns[list] = rect
            case .viewport(let list):
                layout.viewports[list] = rect
            case .note(let id):
                layout.notes[id] = rect
            }
        }

        self.layout = layout
    }

    /// Where a note dragged to `point` would land (Windows' `DropTarget`): in the column under it, before the first
    /// open note whose middle is below it (the dragged note aside), measured as the notes would be without the drop
    /// line `current` (which pushes the notes below it down). Over the column's title or add box means its top, and
    /// below the notes you can see, after the last one you can see. Nil outside the columns.
    nonisolated static func dropTarget(
        at point: CGPoint, dragged: String, columns: [Column], layout: Layout, current: DropTarget?
    ) -> DropTarget? {
        for column in columns {
            guard let frame = layout.columns[column.list], frame.contains(point) else { continue }
            var y = point.y
            if let viewport = layout.viewports[column.list] {
                if y < viewport.minY {
                    y = -CGFloat.infinity
                } else if y > viewport.maxY {
                    y = viewport.maxY
                }
            }

            let shown: Int? = current?.list == column.list ? current?.line : nil
            var index = 0
            var line = 0
            for note in column.notes {
                // The done notes are below the open ones.
                if note.done {
                    break
                }

                if note.id == dragged {
                    line = note.position + 1
                    continue
                }

                guard let card = layout.notes[note.id] else { continue }
                var middle = card.midY
                if let shown, note.position >= shown {
                    middle -= lineSpace
                }

                if y < middle {
                    line = note.position
                    break
                }

                index += 1
                line = note.position + 1
            }

            if column.list == .reminders {
                return DropTarget(list: column.list, index: 0, line: nil)
            }

            return DropTarget(list: column.list, index: index, line: line)
        }

        return nil
    }

    /// Near the top or bottom of a column's notes during a drag, the column scrolls (Windows scrolls 16 points at a
    /// time within 24 of an edge; over the title or add box counts as the top): the list, and by how much, down
    /// positive. Nil elsewhere.
    nonisolated static func autoscroll(at point: CGPoint, layout: Layout) -> (list: BoardList, by: CGFloat)? {
        for (list, frame) in layout.columns where frame.contains(point) {
            guard let viewport = layout.viewports[list] else { return nil }
            let inView: CGFloat = point.y - viewport.minY
            if inView < 24 {
                return (list, -16)
            }

            if inView > viewport.height - 24 && inView <= viewport.height {
                return (list, 16)
            }

            return nil
        }

        return nil
    }

    /// Runs `body` on the main queue after `seconds`.
    public nonisolated static func afterOnMain(
        _ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    // MARK: The columns

    /// A note's list and whether it's done.
    private struct Placement: Equatable {
        let list: BoardList
        let done: Bool
    }

    /// The column of `list`, with the notes in `fresh` fading in.
    private func column(_ list: BoardList, _ items: [BoardItem], now: Date, fresh: Set<String>) -> Column {
        let open = Self.openNotes(list, items)
        var finished: [BoardItem] = []
        if showDone {
            let done: [BoardItem] = items.filter { $0.list == list && $0.done }
            finished = DotNet.orderByDescending(done) { (item: BoardItem) -> Date in item.created }
        }

        var notes: [Note] = []
        for (position, item) in open.enumerated() {
            let menu = Self.menu(item, place: position, of: open.count)
            notes.append(note(item, position: position, now: now, menu: menu, fresh: fresh.contains(item.id)))
        }

        for item in finished {
            let menu = Self.menu(item, place: nil, of: open.count)
            notes.append(note(item, position: notes.count, now: now, menu: menu, fresh: fresh.contains(item.id)))
        }

        let reminders = list == .reminders
        let tip = reminders
            ? "Type a reminder with a time (“call mom tomorrow 5 pm”) and press Return" : "Type a note and press Return"
        return Column(
            list: list, name: Theme.listName(list), count: open.isEmpty ? "" : String(open.count), notes: notes,
            placeholder: reminders ? "Add a reminder… (with a time)" : "Add a note…", addHelp: tip,
            empty: reminders ? "No reminders yet." : "Nothing here yet.")
    }

    /// A note as its column shows it.
    private func note(_ item: BoardItem, position: Int, now: Date, menu: [MenuItem], fresh: Bool) -> Note {
        var due: String?
        var overdue = false
        if let at = item.due {
            let passed = at <= now
            let when = InteractionController.describeDue(at, now, timeZone)
            let suffix = passed ? " (due)" : ""
            due = "⏰ " + when + suffix
            overdue = passed && !item.done
        }

        let colour: Colour = item.done ? Theme.background : Theme.listColour(item.list)
        let added = addedFormat.string(from: item.created)
        let help = "Added \(added). Drag to move, double-click to edit, right-click for more."
        return Note(
            id: item.id, position: position, text: item.text, done: item.done, colour: colour, due: due,
            overdue: overdue, help: help, menu: menu, fresh: fresh)
    }

    /// A note's menu (Windows' `Menu`): Edit; Move to › each other list; for an open note outside Reminders, Move up
    /// and Move down (the keyboard's way to reorder, as dragging needs a mouse), at `place` of the list's `count` open
    /// notes; for an open reminder with a time, Snooze 10 minutes; then Delete.
    private static func menu(_ item: BoardItem, place: Int?, of count: Int) -> [MenuItem] {
        var menu = [MenuItem(title: "Edit", action: .edit)]
        var lists: [MenuItem] = []
        for list in BoardList.allCases where list != item.list {
            lists.append(MenuItem(title: Theme.listName(list), action: .move(list)))
        }

        menu.append(MenuItem(title: "Move to", submenu: lists))
        if let place, item.list != .reminders {
            menu.append(MenuItem(title: "Move up", action: .moveUp, enabled: place > 0))
            menu.append(MenuItem(title: "Move down", action: .moveDown, enabled: place < count - 1))
        }

        if item.list == .reminders && item.due != nil && !item.done {
            menu.append(MenuItem(title: "Snooze 10 minutes", action: .snooze))
        }

        menu.append(MenuItem())
        menu.append(MenuItem(title: "Delete", action: .delete))
        return menu
    }

    /// `list`'s open notes in their order.
    private static func openNotes(_ list: BoardList, _ items: [BoardItem]) -> [BoardItem] {
        BoardStore.arrange(items.filter { $0.list == list && !$0.done }, list)
    }

    /// The notes that faded in show as they are from now on: opening the page again doesn't fade them.
    private func settle(_ settle: Int) {
        guard settle == settles else { return }
        var settled = columns
        for column in settled.indices {
            for note in settled[column].notes.indices {
                settled[column].notes[note].fresh = false
            }
        }

        columns = settled
    }

    /// Makes a change on the board. When it can't be saved (a full disk, say), the app says so, as Windows' "Something
    /// went wrong" balloon does, and the log has the error's kind; the board keeps the change in memory.
    private func change(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.error("the board couldn't save a change: \(Log.kind(of: error))")
            report("Something went wrong: \(error.localizedDescription)")
        }
    }
}

/// What a frame in the board's coordinates is of.
enum BoardFrame: Hashable, Sendable {
    case column(BoardList)
    case viewport(BoardList)
    case note(String)
}

/// The frames of the board's columns, their notes' visible parts and its notes, as laid out.
struct BoardFrames: PreferenceKey {
    static let defaultValue: [BoardFrame: CGRect] = [:]

    static func reduce(value: inout [BoardFrame: CGRect], nextValue: () -> [BoardFrame: CGRect]) {
        value.merge(nextValue()) { (_: CGRect, new: CGRect) -> CGRect in new }
    }
}

extension View {
    /// Tells the board where this view is, as `frame`.
    func boardFrame(_ frame: BoardFrame) -> some View {
        background(
            GeometryReader { (proxy: GeometryProxy) in
                let rect: CGRect = proxy.frame(in: .named(BoardModel.space))
                Color.clear.preference(key: BoardFrames.self, value: [frame: rect])
            })
    }
}

/// The page (IdeasPage.cs): the heading with "Show done", the tip, and a column for each list.
struct IdeasPage: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Theme.heading("Idea board")
                Spacer(minLength: 12)
                Toggle(isOn: $model.showDone) {
                    Text(verbatim: "Show done").font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
            }
            .padding(.bottom, 8)
            Theme.label(model.tip, size: 12, colour: Theme.muted)
                .padding(EdgeInsets(top: -6, leading: 0, bottom: 14, trailing: 0))
            BoardColumns(model: model)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The columns side by side, equally wide and 12 apart (Windows' grid), and while a note is dragged, what catches it
/// over them.
struct BoardColumns: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        let board: BoardModel = model
        HStack(alignment: .top, spacing: 12) {
            ForEach(model.columns) { (column: BoardModel.Column) in
                BoardColumnView(model: model, column: column)
            }
        }
        .padding(.trailing, 12)
        .coordinateSpace(name: BoardModel.space)
        .onPreferenceChange(BoardFrames.self) { (frames: [BoardFrame: CGRect]) in
            MainActor.assumeIsolated {
                board.layoutChanged(frames)
            }
        }
        .overlay {
            if model.dragging != nil {
                BoardDropCatcher(model: model)
            }
        }
    }
}

/// A list's column (Windows' `BuildColumn`): its name and how many notes are open, the add box, and its notes in a
/// scroll. Its outline takes the accent colour while a note can be dropped in it, and while "show my reminders"
/// lights it.
struct BoardColumnView: View {
    @ObservedObject var model: BoardModel
    let column: BoardModel.Column

    var body: some View {
        let glowing: Bool = model.glowing == column.list
        let target: Bool = model.dropTarget?.list == column.list
        let outline: Colour = glowing || target ? Theme.accent : Theme.border
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 0) {
            title
            addBox
            notes
        }
        // Windows' border is outside its padding; SwiftUI draws it inside, so the padding is a point more.
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color(Theme.card)))
        .overlay(shape.strokeBorder(Color(outline), lineWidth: 1))
        .boardFrame(.column(column.list))
    }

    private var title: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: column.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(Theme.text))
            Spacer(minLength: 0)
            Theme.label(column.count, size: 12, colour: Theme.muted, wrap: false)
        }
        .padding(.bottom, 8)
    }

    private var addBox: some View {
        let list = column.list
        let text = Binding<String>(
            get: { model.adding[list] ?? "" }, set: { (value: String) in model.adding[list] = value })
        return TextField(column.placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .help(column.addHelp)
            .accessibilityLabel(Text(verbatim: "Add to " + column.name))
            .onSubmit { model.add(to: list) }
            .padding(.bottom, 10)
    }

    private var notes: some View {
        let target: BoardModel.DropTarget? = model.dropTarget
        let line: Int? = target?.list == column.list ? target?.line : nil
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(column.notes, id: \.key) { (note: BoardModel.Note) in
                    VStack(alignment: .leading, spacing: 0) {
                        if line == note.position {
                            DropLine()
                        }

                        NoteCard(model: model, note: note).padding(.bottom, 8)
                    }
                }

                if line == column.notes.count {
                    DropLine()
                }

                if column.notes.isEmpty {
                    Theme.label(column.empty, size: 12, colour: Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .boardFrame(.viewport(column.list))
    }
}

/// Where a dragged note would land (Windows' drop line): a 3-point accent bar, 2 in from the sides, 8 above the note
/// below it.
struct DropLine: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(Theme.accent))
            .frame(height: 3)
            .padding(EdgeInsets(top: 0, leading: 2, bottom: 8, trailing: 2))
            .allowsHitTesting(false)
    }
}

/// A sticky note (Windows' `Note`): its tick box, its text (struck through once done) and its time; or, while it's
/// edited, a box with its text. Dragging it moves it, a double-click edits it and a right-click opens its menu
/// (`NoteInteraction`, behind its text). Dimmed while it's dragged; it fades in and rises 6 points when it's new where
/// it is.
struct NoteCard: View {
    @ObservedObject var model: BoardModel
    let note: BoardModel.Note

    var body: some View {
        let editing: Bool = model.editing == note.id
        let opacity: Double = model.dragging == note.id ? 0.35 : 1
        let id = note.id
        let done = Binding<Bool>(get: { note.done }, set: { (on: Bool) in model.setDone(id, on) })
        let shape = RoundedRectangle(cornerRadius: 6)
        HStack(alignment: .top, spacing: 0) {
            Toggle(isOn: done) {
                Text(verbatim: "Done: " + note.text)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Done")
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 8))
            if editing {
                NoteEditor(model: model, text: model.editText)
            } else {
                NoteText(note: note)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoteInteraction(model: model, note: note))
        .background(shape.fill(Color(note.colour)))
        .boardFrame(.note(note.id))
        .opacity(opacity)
        .modifier(FadeInOnAppear(milliseconds: 260, rise: 6, fresh: note.fresh))
        .accessibilityActions {
            ForEach(NoteCard.spoken(note.menu), id: \.title) { (item: BoardModel.MenuItem) in
                Button(item.title) {
                    if let action = item.action {
                        model.perform(action, on: id)
                    }
                }
            }
        }
    }

    /// The menu's entries as VoiceOver's actions: those that can be chosen, a submenu's as "Move to Ideas".
    static func spoken(_ menu: [BoardModel.MenuItem]) -> [BoardModel.MenuItem] {
        var actions: [BoardModel.MenuItem] = []
        for item in menu where item.enabled && !item.isSeparator {
            if item.submenu.isEmpty {
                actions.append(item)
                continue
            }

            for entry in item.submenu where entry.enabled {
                actions.append(BoardModel.MenuItem(title: item.title + " " + entry.title, action: entry.action))
            }
        }

        return actions
    }
}

/// A note's text and its time, if it has one. The mouse goes through them to the note's `NoteInteraction`.
struct NoteText: View {
    let note: BoardModel.Note

    var body: some View {
        let colour: Colour = note.done ? Theme.muted : Theme.text
        let dueColour: Colour = note.overdue ? Theme.danger : Theme.muted
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: note.text)
                .font(.system(size: 14))
                .strikethrough(note.done, color: Color(Theme.muted))
                .foregroundStyle(Color(colour))
                .fixedSize(horizontal: false, vertical: true)
            if let due = note.due {
                Theme.label(due, size: 12, colour: dueColour)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}
