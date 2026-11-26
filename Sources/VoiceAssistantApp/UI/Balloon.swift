import AppKit
import SwiftUI

/// Short messages by the menu bar icon, as Windows' tray balloons (`TrayIcon.ShowBalloon`): "Voice Assistant", the
/// message and a warning or information sign, for 4 seconds or until it's clicked. One shows at a time, and the next
/// waits for it to go, as Windows shows its balloons one after another: at launch the app can say several things
/// within a few milliseconds (a hotkey another app has, the Fn key it can't see yet). A message just like the one
/// showing or one waiting isn't said again, and at most 3 wait (the oldest go first). It's a floating panel like the
/// pill, so it never takes the focus, and it needs no permission, as a notification would.
@MainActor
final class Balloon {
    /// What a balloon says: the message, with a warning sign or an information sign.
    struct Notice: Equatable {
        let message: String
        let warning: Bool
    }

    /// How long one stays (Windows' 4000 ms).
    static let shownFor: TimeInterval = 4

    /// How many wait their turn at most.
    static let waitingAtMost = 3

    /// The one on the screen, or going.
    private(set) var showing: Notice?
    /// The ones waiting their turn, first first.
    private(set) var waiting: [Notice] = []

    private let present: @MainActor (Notice, CGRect?, _ clicked: @escaping @MainActor () -> Void) -> BalloonPanel?
    private let after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private var panel: BalloonPanel?
    private var anchor: CGRect?
    /// Counts the balloons shown and taken away, so an old balloon's time running out or its fade ending does nothing.
    private var shows = 0

    /// The app's: floating panels, each going after 4 seconds.
    convenience init() {
        self.init(
            present: { (notice: Notice, anchor: CGRect?, clicked: @escaping @MainActor () -> Void) in
                Balloon.panel(notice, anchor: anchor, clicked: clicked)
            },
            after: { (seconds: TimeInterval, body: @escaping @MainActor @Sendable () -> Void) in
                let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        body()
                    }
                }

                RunLoop.main.add(timer, forMode: .common)
            })
    }

    /// - Parameters:
    ///   - present: Puts a balloon on the screen under the menu bar icon's frame, calling `clicked` when it's clicked;
    ///     nil when there's no screen.
    ///   - after: Runs something after a while (the time a balloon stays).
    init(
        present: @escaping @MainActor (Notice, CGRect?, _ clicked: @escaping @MainActor () -> Void) -> BalloonPanel?,
        after: @escaping @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        self.present = present
        self.after = after
    }

    /// Says `message` under `anchor`, the menu bar icon's frame on screen (nil when it has none): at once, or when the
    /// balloons before it have gone.
    func show(_ message: String, warning: Bool, anchor: CGRect?) {
        self.anchor = anchor
        let notice = Notice(message: message, warning: warning)
        guard notice != showing, !waiting.contains(notice) else { return }
        guard showing == nil else {
            waiting.append(notice)
            if waiting.count > Self.waitingAtMost {
                waiting.removeFirst(waiting.count - Self.waitingAtMost)
            }

            return
        }

        put(notice)
    }

    /// Fades the balloon out (its time is up, or it was clicked); the next one shows once it has gone.
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        shows += 1
        let show = shows
        panel.fadeOut(milliseconds: 160) { [weak self] in
            panel.orderOut(nil)
            guard let self, self.shows == show else { return }
            self.showNext()
        }
    }

    /// Takes the balloon away at once, and the ones waiting: the app is quitting.
    func close() {
        shows += 1
        showing = nil
        waiting = []
        panel?.orderOut(nil)
        panel = nil
    }

    /// Shows `notice` for its time.
    private func put(_ notice: Notice) {
        shows += 1
        let show = shows
        showing = notice
        panel = present(notice, anchor) { [weak self] in
            self?.dismiss(show)
        }

        guard panel != nil else {
            showNext()
            return
        }

        after(Self.shownFor) { [weak self] in
            self?.dismiss(show)
        }
    }

    /// Fades out the balloon `show`, if it's still the one showing.
    private func dismiss(_ show: Int) {
        guard show == shows else { return }
        dismiss()
    }

    /// The balloon has gone: the next one waiting shows.
    private func showNext() {
        showing = nil
        guard !waiting.isEmpty else { return }
        put(waiting.removeFirst())
    }

    /// The app's balloon for `notice`, under the menu bar icon's frame `anchor`; nil without a screen.
    private static func panel(
        _ notice: Notice, anchor: CGRect?, clicked: @escaping @MainActor () -> Void
    ) -> BalloonPanel? {
        let view = BalloonView(message: notice.message, warning: notice.warning, dismiss: clicked)
        let iconScreen: NSScreen? = anchor.flatMap { icon in NSScreen.screens.first { $0.frame.intersects(icon) } }
        let screen: NSScreen? = iconScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return nil }
        let panel = FloatingPanel.make(FirstClickHostingView(rootView: view))
        panel.setFrame(frame(size: FloatingPanel.size(of: view), anchor: anchor, area: area), display: true)
        panel.orderFrontRegardless()
        panel.fadeIn(milliseconds: 180)
        return panel
    }

    /// Under the menu bar icon (`anchor`), centred on it, 8 points below it and inside the screen's visible `area`;
    /// without an icon, at the area's top right.
    static func frame(size: CGSize, anchor: CGRect?, area: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let centred: CGFloat? = anchor.map { $0.midX - size.width / 2 }
        let top: CGFloat = anchor.map { min($0.minY, area.maxY) } ?? area.maxY
        var x: CGFloat = centred ?? area.maxX - size.width - margin
        var y: CGFloat = top - margin - size.height
        x = min(max(x, area.minX + margin), area.maxX - size.width - margin)
        y = max(y, area.minY + margin)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// A balloon on the screen, which fades out and goes: the app's floating panel, a recorder in tests.
@MainActor
protocol BalloonPanel: AnyObject {
    func fadeOut(milliseconds: Int, then done: @escaping @MainActor () -> Void)
    func orderOut(_ sender: Any?)
}

extension FloatingPanel: BalloonPanel {}

/// The balloon's look: a white card with the sign, "Voice Assistant" and the message.
struct BalloonView: View {
    let message: String
    let warning: Bool
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            sign
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Voice Assistant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(Theme.text))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(Theme.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 300, alignment: .leading)
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(Theme.card)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(Theme.border), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }

    /// Windows' warning or information sign, as macOS draws them.
    @ViewBuilder private var sign: some View {
        if warning {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 18))
        } else {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color(Theme.accent))
                .font(.system(size: 18))
        }
    }
}
