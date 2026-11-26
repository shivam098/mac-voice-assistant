import AppKit
import SwiftUI

/// A short message by the menu bar icon, as Windows' tray balloon (`TrayIcon.ShowBalloon`): "Voice Assistant", the
/// message and a warning or information sign, for 4 seconds or until it's clicked; a newer one takes its place. It's a
/// floating panel like the pill, so it never takes the focus, and it needs no permission, as a notification would.
@MainActor
final class Balloon {
    /// How long it stays (Windows' 4000 ms).
    static let shownFor: TimeInterval = 4

    private var panel: FloatingPanel?
    private var timer: Timer?

    /// Shows `message` under `anchor`, the menu bar icon's frame on screen (nil when it has none).
    func show(_ message: String, warning: Bool, anchor: CGRect?) {
        close()
        let view = BalloonView(message: message, warning: warning) { [weak self] in self?.dismiss() }
        let iconScreen: NSScreen? = anchor.flatMap { icon in NSScreen.screens.first { $0.frame.intersects(icon) } }
        let screen: NSScreen? = iconScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let panel = FloatingPanel.make(FirstClickHostingView(rootView: view))
        panel.setFrame(Self.frame(size: FloatingPanel.size(of: view), anchor: anchor, area: area), display: true)
        panel.orderFrontRegardless()
        panel.fadeIn(milliseconds: 180)
        self.panel = panel
        let timer = Timer(timeInterval: Self.shownFor, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fades it out.
    func dismiss() {
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        self.panel = nil
        panel.fadeOut(milliseconds: 160) {
            panel.orderOut(nil)
        }
    }

    /// Takes it away at once.
    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
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
