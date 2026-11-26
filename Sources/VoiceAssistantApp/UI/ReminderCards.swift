import AppKit
import SwiftUI
import VoiceAssistantBoard

/// What a reminder card's buttons say.
public enum ReminderAnswer: Sendable {
    /// Done: the reminder is ticked off.
    case done
    /// Snooze 10 min: it comes back in 10 minutes.
    case snooze
    /// Open board: the window opens at the reminders.
    case openBoard
}

/// A reminder card on the screen, as `ReminderCards` sees it (`ReminderCardPanel` in the app, a fake in tests).
@MainActor
public protocol ReminderCardWindow: AnyObject {
    /// The card's size, known before it shows.
    var size: CGSize { get }
    /// Moves it to `frame` (screen coordinates, y up).
    func place(_ frame: CGRect)
    func show()
    func close()
}

/// Reminders pop up as cards in the bottom-right corner of the screen when they're due (windows-voice-assistant App's
/// `ShowDueReminders` and `StackPopups`). The board is checked every 15 seconds and as soon as it starts, so reminders
/// that came due while the app wasn't running pop up too, and each is shown once (`BoardStore.markNotified`). At most
/// four cards are open, stacked upwards from the corner with the oldest at the bottom, each until it's answered: Done,
/// Snooze 10 min or Open board. The cards never take the focus, and a sound says they came, as on Windows (Windows'
/// "Asterisk"; the Mac's alert sound).
@MainActor
public final class ReminderCards {
    /// The most cards open at once.
    public static let maxOpen = 4
    /// How often the board is checked.
    public static let checkInterval: TimeInterval = 15
    /// How long Snooze puts a reminder off.
    public static let snoozeTime: TimeInterval = 10 * 60

    /// Makes the card for a reminder; it calls back with the button clicked.
    public typealias MakeCard = @MainActor (BoardItem, @escaping @MainActor (ReminderAnswer) -> Void) -> ReminderCardWindow

    private struct OpenCard {
        let id: String
        let window: ReminderCardWindow
    }

    private let board: BoardStore
    private let openBoard: @MainActor () -> Void
    private let report: @MainActor (String) -> Void
    private let sound: @MainActor () -> Void
    private let makeCard: MakeCard
    private let area: @MainActor () -> CGRect?
    private var cards: [OpenCard] = []
    private var timer: Timer?

    /// - Parameters:
    ///   - board: Where the reminders are; its clock says which are due.
    ///   - openBoard: Opens the window at the board's reminders (Windows' `ShowBoard(BoardList.Reminders)`).
    ///   - report: Says that an answer, or a card's being shown, couldn't be saved, as Windows' balloon for an error
    ///     does ("Something went wrong: …").
    ///   - sound: Played once when cards pop up.
    ///   - makeCard: The cards (`ReminderCardPanel` by default).
    ///   - area: Where the cards stack: the main screen's visible area (without the menu bar and the Dock).
    public init(
        board: BoardStore,
        openBoard: @escaping @MainActor () -> Void,
        report: @escaping @MainActor (String) -> Void = { _ in },
        sound: @escaping @MainActor () -> Void = { NSSound.beep() },
        makeCard: @escaping MakeCard = { item, answer in ReminderCardPanel(item, answer: answer) },
        area: @escaping @MainActor () -> CGRect? = { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame }
    ) {
        self.board = board
        self.openBoard = openBoard
        self.report = report
        self.sound = sound
        self.makeCard = makeCard
        self.area = area
    }

    /// The reminders whose cards are open, oldest first.
    public var openReminders: [String] { cards.map(\.id) }

    /// Checks the board now and then every `checkInterval`.
    public func start() {
        stop()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showDue()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.showDue()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Pops up the reminders that are due and haven't been shown, including ones that came due while the app wasn't
    /// running, while fewer than `maxOpen` cards are open (Windows' `ShowDueReminders`).
    public func showDue() {
        var shown = false
        for item in board.dueReminders() {
            if cards.count >= Self.maxOpen {
                break
            }

            // Its card is open already: saving that it was shown failed.
            if cards.contains(where: { $0.id == item.id }) {
                continue
            }

            let id = item.id
            let window = makeCard(item, { [weak self] reply in self?.answer(id, reply) })
            cards.append(OpenCard(id: id, window: window))
            stack()
            window.show()
            do {
                try board.markNotified(id)
            } catch {
                failed(error)
            }

            Log.info("reminder shown")
            shown = true
        }

        if shown {
            sound()
        }
    }

    /// A card's button: Done ticks the reminder off, Snooze puts it off 10 minutes, Open board opens the window at the
    /// reminders, and the card closes. When the answer can't be saved, the card stays and the problem is reported.
    func answer(_ id: String, _ answer: ReminderAnswer) {
        do {
            switch answer {
            case .done:
                try board.setDone(id, true)
            case .snooze:
                try board.snooze(id, by: Self.snoozeTime)
            case .openBoard:
                openBoard()
            }
        } catch {
            failed(error)
            return
        }

        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards.remove(at: index).window.close()
        stack()
    }

    /// Puts the open cards in their places (Windows' `StackPopups`).
    private func stack() {
        guard let area = area() else { return }
        for (card, frame) in zip(cards, Self.stack(cards.map { $0.window.size }, in: area)) {
            card.window.place(frame)
        }
    }

    /// The cards' frames, first (oldest) at the bottom: 16 points from the right of `area`, 4 above its bottom, and 12
    /// between cards, each card's upwards from the one before (y up, as AppKit's screen coordinates).
    public static func stack(_ sizes: [CGSize], in area: CGRect) -> [CGRect] {
        var bottom = area.minY + 4
        return sizes.map { size in
            let frame = CGRect(
                x: (area.maxX - size.width - 16).rounded(), y: bottom.rounded(), width: size.width,
                height: size.height)
            bottom = frame.maxY + 12
            return frame
        }
    }

    private func failed(_ error: Error) {
        Log.warn("couldn't save a reminder's change: \(Log.kind(of: error))")
        report("Something went wrong: \(error.localizedDescription)")
    }
}

/// A reminder's card on the screen (Windows' `ReminderPopup`): a floating panel that never takes the keyboard focus, so
/// it can't take what you're typing, and fades in over 260 ms.
@MainActor
public final class ReminderCardPanel: ReminderCardWindow {
    static let fadeInMilliseconds = 260

    public let size: CGSize
    private let panel: FloatingPanel

    public init(_ item: BoardItem, answer: @escaping @MainActor (ReminderAnswer) -> Void) {
        let card = ReminderCard(text: item.text, answer: answer)
        size = FloatingPanel.size(of: card)
        panel = FloatingPanel.make(FirstClickHostingView(rootView: card))
    }

    public func place(_ frame: CGRect) {
        panel.setFrame(frame, display: true)
    }

    public func show() {
        panel.orderFrontRegardless()
        panel.fadeIn(milliseconds: Self.fadeInMilliseconds)
    }

    public func close() {
        panel.orderOut(nil)
    }
}

/// A reminder card's look (Windows' `ReminderPopup`): "⏰ Reminder", the reminder's words, and Done, Snooze 10 min and
/// Open board, on the reminders' pink, 320 points wide inside its border.
struct ReminderCard: View {
    let text: String
    let answer: @MainActor (ReminderAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "⏰ Reminder")
                .font(.system(size: 12))
                .foregroundStyle(Color(Theme.muted))
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(Theme.text))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button("Done") { answer(.done) }.buttonStyle(ThemeButtonStyle.primary)
                Button("Snooze 10 min") { answer(.snooze) }.buttonStyle(ThemeButtonStyle.standard)
                Button("Open board") { answer(.openBoard) }.buttonStyle(ThemeButtonStyle.standard)
            }
            .padding(.top, 10)
        }
        .frame(width: 320, alignment: .leading)
        // Windows' padding is 16 inside a 1-point border; SwiftUI draws the border inside the padding.
        .padding(17)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(Theme.listColour(.reminders))))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(Theme.border), lineWidth: 1))
    }
}
