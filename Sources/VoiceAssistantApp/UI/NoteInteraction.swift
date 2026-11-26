import AppKit
import SwiftUI
import VoiceAssistantBoard

/// The mouse on a sticky note, in AppKit (Windows' card handlers): dragging it moves the note (the board catches it
/// with `BoardDropCatcher`), a double-click edits it, a right-click opens its menu, and its tooltip says so. It lies
/// behind the note's text, which lets the mouse through, and leaves the tick box its own clicks.
struct NoteInteraction: NSViewRepresentable {
    let model: BoardModel
    let note: BoardModel.Note

    func makeNSView(context: Context) -> NoteInteractionView {
        let view = NoteInteractionView()
        view.update(model: model, note: note)
        return view
    }

    func updateNSView(_ view: NoteInteractionView, context: Context) {
        view.update(model: model, note: note)
    }
}

/// See `NoteInteraction`. A drag starts once the mouse has moved 4 points held down (Windows' minimum drag distance),
/// and it can only land on the board: other apps can't take a note.
final class NoteInteractionView: NSView, NSDraggingSource {
    /// What a dragged note is on the pasteboard: its id, for this app only.
    static let dragType = NSPasteboard.PasteboardType(VoiceAssistantApp.bundleIdentifier + ".board-note")

    /// How far the mouse moves, held, before a drag starts.
    static let dragDistance: CGFloat = 4

    /// The note being dragged, kept while the drag lasts even if its card goes meanwhile.
    private static var dragged: NoteInteractionView?

    private(set) weak var model: BoardModel?
    private(set) var note: BoardModel.Note?
    private var pressedAt: NSPoint?

    func update(model: BoardModel, note: BoardModel.Note) {
        self.model = model
        self.note = note
        if toolTip != note.help {
            toolTip = note.help
        }
    }

    /// A note in the window behind another app's can be dragged with the first click, as Finder's icons can.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let note else { return }
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }

        // A click on another note closes an open editor, saving it, as on Windows (where the editor loses the
        // keyboard).
        if let editing = model.editing, editing != note.id {
            model.finishEdit(save: true)
        }

        if event.clickCount == 2 {
            pressedAt = nil
            model.beginEdit(note.id)
            return
        }

        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, let model, model.editing == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let moved: CGFloat = max(abs(point.x - start.x), abs(point.y - start.y))
        guard moved >= Self.dragDistance else { return }
        pressedAt = nil
        beginDrag(event, grab: start)
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let note, !note.menu.isEmpty else { return nil }
        let id = note.id
        return NoteMenu.make(note.menu) { [weak model = self.model] (action: BoardModel.MenuAction) in
            model?.perform(action, on: id)
        }
    }

    private func beginDrag(_ event: NSEvent, grab: NSPoint) {
        guard let note else { return }
        let item = NSPasteboardItem()
        _ = item.setString(note.id, forType: Self.dragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        if let ghost = NoteGhost.make(from: self, grab: grab) {
            dragging.setDraggingFrame(ghost.frame, contents: ghost.image)
        } else {
            dragging.setDraggingFrame(bounds, contents: nil)
        }

        Self.dragged = self
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard let note else { return }
        model?.dragBegan(note.id)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model?.dragEnded()
        Self.dragged = nil
    }
}

/// A note's right-click menu as AppKit shows it, from the model's entries; the entries that can't be chosen now are
/// disabled.
@MainActor
enum NoteMenu {
    static func make(
        _ items: [BoardModel.MenuItem], choose: @escaping @MainActor (BoardModel.MenuAction) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }

            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            if !item.submenu.isEmpty {
                entry.submenu = make(item.submenu, choose: choose)
            } else if let action = item.action {
                let choice = MenuChoice { choose(action) }
                entry.target = choice
                entry.action = #selector(MenuChoice.chosen(_:))
                // The menu item holds its target only weakly.
                entry.representedObject = choice
            }

            entry.isEnabled = item.enabled
            menu.addItem(entry)
        }

        return menu
    }

    /// What a menu item runs.
    @MainActor
    final class MenuChoice: NSObject {
        private let run: @MainActor () -> Void

        init(_ run: @escaping @MainActor () -> Void) {
            self.run = run
        }

        @objc func chosen(_ sender: Any?) {
            run()
        }
    }
}

/// The picture that follows the mouse while a note is dragged (Windows' `DragGhost`): the note as it's drawn, tilted
/// 1.5° (anticlockwise) about where it was grabbed, a little see-through (0.9), over a soft shadow 2 points right and
/// 4 down.
@MainActor
enum NoteGhost {
    /// Room around the note for its tilt and shadow.
    static let margin: CGFloat = 12

    /// The picture of `view`'s note, grabbed at `grab` (in `view`'s coordinates), and where it goes in them; nil when
    /// it can't be drawn.
    static func make(from view: NSView, grab: NSPoint) -> (image: NSImage, frame: CGRect)? {
        guard let host = view.window?.contentView, view.bounds.width >= 1, view.bounds.height >= 1 else {
            return nil
        }

        let rect = host.convert(view.bounds, from: view)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        host.cacheDisplay(in: rect, to: bitmap)
        guard let card = bitmap.cgImage else { return nil }
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        guard let image = image(of: card, size: view.bounds.size, grab: grab, scale: scale) else { return nil }
        return (image, view.bounds.insetBy(dx: -margin, dy: -margin))
    }

    /// `card`, `size` points drawn at `scale` pixels a point, tilted about `grab` (from its bottom left, y up),
    /// with its shadow, `margin` points round it.
    static func image(of card: CGImage, size: CGSize, grab: CGPoint, scale: CGFloat) -> NSImage? {
        let canvas = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let width = Int((canvas.width * scale).rounded(.up))
        let height = Int((canvas.height * scale).rounded(.up))
        let alpha: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: alpha)
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setAlpha(0.9)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let pivot = CGPoint(x: margin + grab.x, y: margin + grab.y)
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: 1.5 * CGFloat.pi / 180)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        let box = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let shadow = CGPath(roundedRect: box.offsetBy(dx: 2, dy: -4), cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(shadow)
        context.setFillColor(CGColor(gray: 0, alpha: 40.0 / 255.0))
        context.fillPath()
        context.saveGState()
        context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        context.draw(card, in: box)
        context.restoreGState()
        context.endTransparencyLayer()
        guard let picture = context.makeImage() else { return nil }
        return NSImage(cgImage: picture, size: canvas)
    }
}

/// While a note is dragged, a layer over the board catches it (Windows' page-wide PreviewDragOver and PreviewDrop):
/// anywhere over a column, its title and add box included, the board says where the note would land, and near the top
/// or bottom of a column's notes the column scrolls. It's there only during the drag, so it never takes a click.
struct BoardDropCatcher: NSViewRepresentable {
    let model: BoardModel

    func makeNSView(context: Context) -> DropCatcherView {
        let view = DropCatcherView()
        view.model = model
        view.registerForDraggedTypes([NoteInteractionView.dragType])
        return view
    }

    func updateNSView(_ view: DropCatcherView, context: Context) {
        view.model = model
    }
}

/// See `BoardDropCatcher`. Its coordinates are the board's: from the top left.
final class DropCatcherView: NSView {
    weak var model: BoardModel?

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        moved(to: sender.draggingLocation)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        moved(to: sender.draggingLocation)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model?.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model?.dragging != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropped(at: sender.draggingLocation)
    }

    /// The drag is at `location`, in the window's coordinates: where the note would land; the column scrolls when
    /// it's near the edge of its notes.
    func moved(to location: NSPoint) -> NSDragOperation {
        guard let model, model.dragging != nil else { return [] }
        let point = convert(location, from: nil)
        if let scroll = BoardModel.autoscroll(at: point, layout: model.layout) {
            scrollColumn(scroll.list, by: scroll.by)
        }

        return model.dragMoved(to: point) ? .move : []
    }

    /// Dropped at `location`, in the window's coordinates.
    func dropped(at location: NSPoint) -> Bool {
        guard let model else { return false }
        return model.drop(at: convert(location, from: nil))
    }

    /// Scrolls the notes of `list`'s column `delta` points (down positive), as far as they go.
    private func scrollColumn(_ list: BoardList, by delta: CGFloat) {
        guard let viewport = model?.layout.viewports[list], let root = window?.contentView else { return }
        let middle = convert(CGPoint(x: viewport.midX, y: viewport.midY), to: nil)
        let scrolls = Self.scrollViews(in: root)
        guard let scroll = scrolls.first(where: { $0.convert($0.bounds, to: nil).contains(middle) }) else { return }
        let clip = scroll.contentView
        let content: CGFloat = scroll.documentView?.frame.height ?? 0
        let most: CGFloat = max(0, content - clip.bounds.height)
        let step: CGFloat = clip.isFlipped ? delta : -delta
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y + step, 0), most)
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        for subview in view.subviews {
            if let scroll = subview as? NSScrollView {
                found.append(scroll)
            }

            found += scrollViews(in: subview)
        }

        return found
    }
}

/// A note's editor (Windows' `BeginEdit`): a box with its text, which wraps, selected and ready to type over. Return
/// saves, Esc doesn't, and leaving it for another box or note saves. The field is borderless; `NoteEditorBox` draws its
/// box, as Settings' text areas have theirs.
struct NoteEditor: NSViewRepresentable {
    let model: BoardModel
    /// The editor's text (`model.editText`), so the box grows as it's typed.
    let text: String

    /// Its text's size.
    static let font = NSFont.systemFont(ofSize: 14)

    func makeNSView(context: Context) -> NoteEditorField {
        let field = NoteEditorField(string: text)
        field.measured = text
        field.font = Self.font
        field.textColor = NSColor(Color(Theme.text))
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setAccessibilityLabel("Note")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NoteEditorField, context: Context) {
        context.coordinator.model = model
        if field.currentEditor() == nil && field.stringValue != text {
            field.stringValue = text
        }

        field.measured = text
    }

    /// As tall as its text needs at the width it's given (200 points when it's asked how wide it would like to be).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NoteEditorField, context: Context) -> CGSize? {
        var width: CGFloat = 200
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        }

        return CGSize(width: width, height: Self.height(of: text, width: width))
    }

    /// The height of the field holding `text` at `width`, measured with a cell of its own (the field's cell is the
    /// field editor's while it has the keyboard).
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.isEditable = true
        cell.isBezeled = false
        cell.isBordered = false
        cell.wraps = true
        cell.isScrollable = false
        cell.lineBreakMode = .byWordWrapping
        cell.usesSingleLineMode = false
        let bounds = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        let height: CGFloat = cell.cellSize(forBounds: bounds).height
        return height.rounded(.up)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    /// Gives what's typed to the board's model, and its keys: Return, Esc and leaving.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: BoardModel

        init(model: BoardModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.editText = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                model.finishEdit(save: false)
                return true
            }

            if selector == #selector(NSResponder.insertNewline(_:)) {
                model.editText = textView.string
                model.finishEdit(save: true)
                return true
            }

            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            model.finishEdit(save: true)
        }
    }
}

/// The editor's field, which takes the keyboard as soon as it's in the window (with its text selected, as a box that
/// takes the keyboard selects it), and is as tall as its text needs at its width.
final class NoteEditorField: NSTextField {
    private var focused = false

    /// The text it's measured with: the model's, which follows what's typed.
    var measured = "" {
        didSet {
            if measured != oldValue {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        let width: CGFloat = bounds.width > 10 ? bounds.width : 200
        return NSSize(width: NSView.noIntrinsicMetric, height: NoteEditor.height(of: measured, width: width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !focused, window != nil else { return }
        focused = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                _ = window.makeFirstResponder(self)
            }
        }
    }
}
