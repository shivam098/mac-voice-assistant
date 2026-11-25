import AppKit
import SwiftUI
import ThumbFreeMac
import VoiceAssistantCore

extension StatusPill {
    /// The pill on screen (Windows' `OverlayWindow`): a floating panel centred above the bottom of the screen that never
    /// takes the focus from the app being typed into, on every Space and over full-screen apps. It shows
    /// `model.display`, fades in when it appears and out when it goes, and its minimize button works without making the
    /// app active. Main thread only.
    @MainActor
    public final class Panel {
        public private(set) var model: Model

        /// The pill was minimized or brought back, by its button or through `minimized` (Windows' `MinimizedChanged`):
        /// the app keeps the state flag, and says what minimizing does (`StatusPill.minimizedNote`).
        public var onMinimizedChanged: ((Bool) -> Void)?

        private let languageKeys: String
        private let panel: FloatingPanel
        private let host: FirstClickHostingView<Content>
        private let measure: NSHostingController<Content>
        private var fade: Timer?
        private var dots: Timer?
        private var hiding = false

        /// - Parameters:
        ///   - commandModeIsIdle: There's no wake word (`wakeWordEnabled` is off), so listening for a command is the
        ///     resting state.
        ///   - keyName: The dictation key, as the texts name it ("Fn", "Right Option").
        ///   - languageKeys: The hotkey that switches the dictation language, as the badge's tooltip names it.
        ///   - minimized: Starts minimized (the pill's state flag), without showing first.
        public init(
            commandModeIsIdle: Bool = false, keyName: String = "Fn", languageKeys: String = "⌃⇧H",
            minimized: Bool = false
        ) {
            let model = Model(commandModeIsIdle: commandModeIsIdle, keyName: keyName, minimized: minimized)
            let content = Content(display: model.display, languageHelp: "", minimize: {})
            let host = FirstClickHostingView(rootView: content)
            self.model = model
            self.languageKeys = languageKeys
            self.host = host
            measure = NSHostingController(rootView: content)
            panel = FloatingPanel.make(host)
            render()
        }

        /// Shown only while there's something to show (and then it's said through `onMinimizedChanged`), or always.
        public var minimized: Bool {
            get { model.minimized }
            set {
                guard model.setMinimized(newValue) else { return }
                render()
                onMinimizedChanged?(newValue)
            }
        }

        /// The mode, or `activity` instead (Windows' `ShowMode`): see `Model.showMode`.
        public func showMode(_ mode: InteractionMode, activity: String? = nil) {
            model.showMode(mode, activity: activity)
            syncDots()
            render()
        }

        /// Moves the level meter while a dictation records (`level` from 0 to 1).
        public func showInputLevel(_ level: Float) {
            model.showInputLevel(level)
            render(resize: false)
        }

        /// Shows `update` for `Model.messageTime`, counted again from each new one.
        public func showStatus(_ update: AssistantStatus) {
            model.showStatus(update)
            syncDots()
            fade?.invalidate()
            fade = schedule(after: Model.messageTime, repeats: false) { pill in
                pill.fade = nil
                pill.model.fadeStatus()
                pill.render()
            }

            render()
        }

        /// The "HI + EN" badge while dictation is in Hindi + English.
        public func setDictationLanguage(hinglish: Bool, accurate: Bool) {
            model.setDictationLanguage(hinglish: hinglish, accurate: accurate)
            render()
        }

        /// The words heard so far while a dictation records; nil hides them (see `Model.showPreview`).
        public func showPreview(_ text: String?) {
            model.showPreview(text)
            render()
        }

        /// Takes the pill off the screen for good: the app is quitting.
        public func close() {
            fade?.invalidate()
            fade = nil
            dots?.invalidate()
            dots = nil
            panel.orderOut(nil)
        }

        /// The pill is on the screen, and not fading out (tests).
        var isOnScreen: Bool { panel.isVisible && !hiding }

        /// The minimize button (Windows' `MinimizeButton.Click`): minimized, and off the screen at once.
        func minimizeClicked() {
            let changed = model.minimizeNow()
            render()
            if changed {
                onMinimizedChanged?(true)
            }
        }

        /// The dots after "Transcribing" move while it shows.
        private func syncDots() {
            guard model.isTranscribing else {
                dots?.invalidate()
                dots = nil
                return
            }

            if dots == nil {
                dots = schedule(after: Model.dotsInterval, repeats: true) { pill in
                    pill.model.advanceDots()
                    pill.render(resize: false)
                }
            }
        }

        /// A timer on the main run loop that also fires while a menu is open (as ThumbFree's pill's).
        private func schedule(
            after interval: TimeInterval, repeats: Bool, _ action: @escaping @MainActor @Sendable (Panel) -> Void
        ) -> Timer {
            let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self {
                        action(self)
                    }
                }
            }

            RunLoop.main.add(timer, forMode: .common)
            return timer
        }

        /// Draws the display, and shows or hides the pill as the model says (Windows' `UpdateVisibility`); when its size
        /// may have changed, sizes and places it.
        private func render(resize: Bool = true) {
            let content = Content(
                display: model.display,
                languageHelp: "Dictation is in Hindi + English (\(languageKeys) switches back to English)",
                minimize: { [weak self] in self?.minimizeClicked() })
            host.rootView = content
            guard model.isShown else {
                hideSmoothly()
                return
            }

            if resize || !panel.isVisible || hiding {
                measure.rootView = content
                place(measure.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)))
            }

            if !panel.isVisible || hiding {
                hiding = false
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }

                panel.fadeIn(milliseconds: Model.fadeInMilliseconds)
            }
        }

        /// Centred, 16 points above the bottom of the visible area (the Dock's top) of the screen in use, as Windows
        /// puts it above the taskbar.
        private func place(_ size: CGSize) {
            let screens = NSScreen.screens.map { Pill.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            let main = NSScreen.main.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
            if let frame = Pill.frame(size: size, window: nil, screens: screens, fallback: main), frame != panel.frame {
                panel.setFrame(frame, display: true)
            }
        }

        private func hideSmoothly() {
            guard panel.isVisible, !hiding else { return }
            hiding = true
            panel.fadeOut(milliseconds: Model.fadeOutMilliseconds) { [weak self] in
                guard let self, self.hiding else { return }
                self.hiding = false
                self.panel.orderOut(nil)
            }
        }
    }

    /// The pill's look (OverlayWindow.xaml): the logo, the dot or the level meter, the mode or activity with the
    /// language badge, and under them the place, the words heard, the hint, the message and what was heard; the
    /// minimize button at the top right.
    struct Content: View {
        let display: Display
        let languageHelp: String
        let minimize: @MainActor () -> Void

        var body: some View {
            Limited(width: 560) {
                HStack(spacing: 0) {
                    AppLogo.Mark(size: 22).padding(.trailing, 8)
                    indicator.padding(.trailing, 10)
                    texts
                    // The minimize button's room: 10 points before it and its 20, less the 4 it reaches past the edge
                    // (Windows' margins). The button is laid over the top right.
                    Color.clear.frame(width: 26, height: 18)
                }
                .overlay(alignment: .topTrailing) {
                    MinimizeButton(action: minimize).offset(x: 4, y: -2)
                }
                // Windows' padding is 14 by 8 inside a 1-point border; SwiftUI draws the border inside the padding.
                .padding(EdgeInsets(top: 9, leading: 15, bottom: 9, trailing: 15))
                .background { RoundedRectangle(cornerRadius: 18).fill(Color(Colour.background)) }
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color(Colour.border), lineWidth: 1) }
            }
            .fixedSize()
        }

        /// The level meter while a dictation records, else the dot (fading in and out while transcribing).
        @ViewBuilder private var indicator: some View {
            if let bars = display.bars {
                HStack(spacing: 2) {
                    ForEach(bars.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(Colours.typing))
                            .frame(width: 3, height: bars[index])
                    }
                }
                .frame(height: 18)
            } else if let dot = display.dot, display.dotPulses {
                PulsingDot(colour: dot)
            } else if let dot = display.dot {
                Circle().fill(Color(dot)).frame(width: 10, height: 10)
            }
        }

        private var texts: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(display.mode)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(Colour.white))
                    if let dots = display.dots {
                        Text(dots)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(Colour.white))
                            .frame(width: 14, alignment: .leading)
                    }

                    if let badge = display.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(Colour.badgeText))
                            .padding(EdgeInsets(top: 0, leading: 6, bottom: 1, trailing: 6))
                            .background { RoundedRectangle(cornerRadius: 6).fill(Color(Colour.badge)) }
                            .help(languageHelp)
                            .padding(.leading, 8)
                    }
                }

                if let place = display.place {
                    line(place, size: 11, colour: Colours.place).padding(.top, 1)
                }

                if let preview = display.preview {
                    Limited(width: 440) {
                        Text(preview).font(.system(size: 13)).foregroundStyle(Color(Colour.text)).lineLimit(3)
                    }
                    .opacity(display.previewOpacity)
                    .padding(.top, 3)
                }

                if let hint = display.hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Color(Colour.muted)).padding(.top, 2)
                }

                if let message = display.message {
                    line(message, size: 12, colour: display.messageColour)
                }

                if let heard = display.heard {
                    line(heard, size: 11, colour: Colour.muted, italic: true)
                }
            }
        }

        /// One line, cut short with "…" past 500 points.
        private func line(_ text: String, size: CGFloat, colour: Colour, italic: Bool = false) -> some View {
            Limited(width: 500) {
                Text(text)
                    .font(italic ? Font.system(size: size).italic() : Font.system(size: size))
                    .foregroundStyle(Color(colour))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The "–" at the pill's top right (Windows' MinimizeButton): a 20-point circle that lights up under the mouse.
    struct MinimizeButton: View {
        static let help =
            "Hide until needed (it reappears when you dictate or say “Hey Jarvis”). "
            + "Show it again from the menu bar icon."

        let action: @MainActor () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(verbatim: "–")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(Colour.muted))
                    .offset(y: -1)
                    .frame(width: 20, height: 20)
                    .background { Circle().fill(hovering ? Color(Colour.border) : Color.clear) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(HoverTracker { hovering = $0 })
            .help(Self.help)
        }
    }

    /// The dot while transcribing: fades to 30% and back, `Model.pulseTime` each way, from when it appears (as
    /// ThumbFreeMac `Pill.PulsingDot`, which isn't public; Windows' animation is linear).
    struct PulsingDot: View {
        let colour: Colour
        @State private var faded = false

        var body: some View {
            Circle()
                .fill(Color(colour))
                .frame(width: 10, height: 10)
                .opacity(faded ? 0.3 : 1)
                .onAppear {
                    withAnimation(.linear(duration: Model.pulseTime).repeatForever(autoreverses: true)) {
                        faded = true
                    }
                }
        }
    }

    /// Lays its view out at its own width up to `width`, wrapping or cutting text beyond it, as a TextBlock with a
    /// MaxWidth does on Windows (ThumbFreeMac `Pill.Limited`, which isn't public: a frame's maxWidth gives text nothing
    /// to wrap at when the pill sizes itself).
    struct Limited: Layout {
        var width: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let view = subviews.first else { return .zero }
            let limit = min(width, proposal.width ?? width)
            let natural = view.sizeThatFits(.unspecified)
            return natural.width <= limit ? natural : view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}
