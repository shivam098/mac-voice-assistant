import AppKit
import SwiftUI
import ThumbFreeCore
import VoiceAssistantBoard
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// Draws the pill in each of its states, the menu and the menu bar icon, the reminder cards stacked, the balloon, the
/// theme and the logo (see `Renderer`), to compare with the Windows app's XAML and C#.
final class UIRenderTests: XCTestCase {
    @MainActor
    func testThePillInEachState() {
        var pill = StatusPill.Model()
        var states: [(String, StatusPill.Model)] = [("pill-01-starting", pill)]
        pill.showMode(.standby)
        states.append(("pill-02-waiting-for-hey-jarvis", pill))
        pill.showMode(.standby, activity: "Hearing you…")
        states.append(("pill-03-hearing-you", pill))
        pill.showMode(.command)
        states.append(("pill-04-listening-for-a-command", pill))
        pill.showStatus(
            AssistantStatus(
                mode: .command, kind: .success, message: "Opened YouTube in a new tab.", place: "Google Chrome › YouTube"))
        states.append(("pill-05-success-with-place", pill))
        pill.showStatus(
            AssistantStatus(mode: .command, kind: .warning, message: "Sorry, I didn't catch that.", heard: "open crom"))
        states.append(("pill-06-warning-with-heard", pill))
        pill.showStatus(
            AssistantStatus(
                mode: .standby, kind: .error,
                message: "The microphone isn't working. Check System Settings › Privacy & Security › Microphone, "
                    + "then try again."))
        states.append(("pill-07-error-cut-short", pill))
        pill.fadeStatus()
        pill.showMode(.dictation)
        states.append(("pill-08-typing", pill))

        pill.setDictationLanguage(hinglish: true, accurate: false)
        pill.showMode(.standby, activity: StatusPill.listening)
        pill.showInputLevel(0.7) { 0.5 }
        pill.showPreview("Kal ki meeting cancel ho gayi hai, please sabko bata dena")
        states.append(("pill-09-dictating-meter-words-and-hi-en", pill))
        pill.showInputLevel(0.2) { 0.9 }
        pill.showPreview(
            "Notes from the design review: the guide needs a shorter welcome, the settings page should save as you go, "
                + "and the board should open from the menu bar. We agreed to keep everything on this Mac, no uploads "
                + "and no accounts, and to look at every page before the release.")
        states.append(("pill-10-dictating-long-words", pill))

        pill.setDictationLanguage(hinglish: true, accurate: true)
        pill.showMode(.standby, activity: StatusPill.transcribing)
        pill.advanceDots()
        pill.advanceDots()
        states.append(("pill-11-transcribing-dimmed-hi-en-accurate", pill))

        pill.showMode(.paused)
        pill.setDictationLanguage(hinglish: false, accurate: false)
        pill.showStatus(AssistantStatus(mode: .paused, kind: .info, message: "Listening paused. ⌃⇧Space resumes."))
        states.append(("pill-12-paused-with-message", pill))

        var minimized = StatusPill.Model(keyName: "Right Option", minimized: true)
        minimized.showMode(.standby, activity: StatusPill.listening)
        minimized.showInputLevel(0.4) { 0.3 }
        states.append(("pill-13-minimized-shows-while-dictating-right-option", minimized))

        for (name, model) in states {
            Renderer.render(Self.pillScene(model), name)
        }
    }

    @MainActor
    func testTheMenuAndTheMenuBarIcon() {
        let recorder = MenuRecorder()
        recorder.state = MenuState(hinglish: true, accurate: false, pillAlwaysShown: true, startsAtLogin: true)
        let menu = StatusMenu(hotkeys: MenuHotkeys(), actions: recorder.actions)
        menu.showMode(.standby)
        menu.prepare()
        Renderer.render(MenuPicture(menu.menu), "menu-1-waiting-for-hey-jarvis")
        if let languages = menu.language.submenu {
            Renderer.render(MenuPicture(languages), "menu-2-dictation-language")
        }

        menu.showMode(.paused)
        Renderer.render(MenuPicture(menu.menu), "menu-3-paused")

        let icons = Self.iconStrip()
        Renderer.render(icons, size: icons.fittingSize, "menu-bar-icons")
    }

    @MainActor
    func testTheReminderCardsStacked() {
        Renderer.render(Self.cornerScene(["Call mom"]), "reminders-1-card")
        Renderer.render(
            Self.cornerScene([
                "Call mom",
                "Book the dentist for Thursday morning and ask about moving the cleaning to next month",
                "Stretch",
            ]),
            "reminders-3-cards")
    }

    @MainActor
    func testTheBalloonTheThemeAndTheLogo() {
        Renderer.render(
            Self.backdrop(
                BalloonView(message: "⌃⇧Space (pause/resume) is used by another app.", warning: true, dismiss: {})),
            "balloon-warning")
        Renderer.render(
            Self.backdrop(BalloonView(message: StatusPill.minimizedNote, warning: false, dismiss: {})), "balloon-info")
        Renderer.render(Self.themeScene, "theme")
        Renderer.render(
            HStack(spacing: 24) {
                ForEach([22, 28, 64, 128, 256] as [CGFloat], id: \.self) { size in
                    AppLogo.Mark(size: size)
                }
            }
            .padding(24)
            .background(Color.white),
            "logo")
    }

    /// The pill over a light backdrop, as on a desktop.
    @MainActor
    private static func pillScene(_ model: StatusPill.Model) -> some View {
        StatusPill.Content(display: model.display, languageHelp: "", minimize: {})
            .padding(20)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.93), Color(white: 0.62)], startPoint: .topLeading,
                    endPoint: .bottomTrailing))
    }

    @MainActor
    private static func backdrop<Content: View>(_ content: Content) -> some View {
        content.padding(20).background(Color(white: 0.75))
    }

    /// The bottom-right corner of a 1440 × 900 screen with the Dock along its bottom 70 points, and a card for each of
    /// `texts`, stacked as the app stacks them.
    @MainActor
    private static func cornerScene(_ texts: [String]) -> some View {
        let area = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let cards = texts.map { ReminderCard(text: $0, answer: { _ in }) }
        let frames = ReminderCards.stack(cards.map { FloatingPanel.size(of: $0) }, in: area)
        let region = CGRect(x: 740, y: 0, width: 700, height: max(320, (frames.last?.maxY ?? 0) + 60))
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.53, blue: 0.78), Color(red: 0.62, green: 0.48, blue: 0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: region.width, height: 70)
                .offset(y: region.height - 70)
            ForEach(frames.indices, id: \.self) { index in
                cards[index].offset(x: frames[index].minX - region.minX, y: region.maxY - frames[index].maxY)
            }
        }
        .frame(width: region.width, height: region.height, alignment: .topLeading)
        .clipped()
    }

    /// The theme's pieces: a heading, a card with text and the buttons, the lists' colours, and the danger colour.
    @MainActor
    private static var themeScene: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.heading("Voice Assistant")
            VStack(alignment: .leading, spacing: 8) {
                Theme.label("A card holds one part of a page.", size: 15)
                Theme.label(
                    "Muted text says more about it, and wraps when it's long enough to need a second line, as this "
                        + "one is.", size: 12, colour: Theme.muted)
                HStack(spacing: 8) {
                    Button("Start listening") {}.buttonStyle(ThemeButtonStyle.primary)
                    Button("Open board") {}.buttonStyle(ThemeButtonStyle.standard)
                    Button("Disabled") {}.buttonStyle(ThemeButtonStyle.standard).disabled(true)
                }
            }
            .themeCard()
            HStack(spacing: 12) {
                ForEach(BoardList.allCases, id: \.self) { list in
                    Theme.label(Theme.listName(list))
                        .frame(width: 120, height: 72)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(Theme.listColour(list))))
                }
            }
            .themeCard(Theme.accentSoft)
            Theme.label("Something went wrong: the danger colour.", colour: Theme.danger)
        }
        .padding(24)
        .frame(width: 640)
        .background(Color(Theme.background))
    }

    /// The menu bar icon in each mode (starting, paused, waiting for "Hey Jarvis", listening for a command, typing), on
    /// a light and a dark menu bar, at its size and four times it.
    @MainActor
    private static func iconStrip() -> NSView {
        let modes: [InteractionMode?] = [nil, .paused, .standby, .command, .dictation]
        let strip = NSStackView()
        strip.orientation = .vertical
        strip.alignment = .leading
        strip.spacing = 0
        for (dark, scale) in [(false, 1.0), (true, 1.0), (false, 4.0), (true, 4.0)] as [(Bool, CGFloat)] {
            let bar = NSStackView()
            bar.orientation = .horizontal
            bar.spacing = 14 * scale
            bar.edgeInsets = NSEdgeInsets(top: 3 * scale, left: 14, bottom: 3 * scale, right: 14)
            bar.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).cgColor
            for mode in modes {
                let icon = NSImageView(image: AppLogo.menuBarImage(dot: MenuBar.dot(mode)))
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 20 * scale).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 18 * scale).isActive = true
                bar.addArrangedSubview(icon)
            }

            strip.addArrangedSubview(bar)
        }

        strip.layoutSubtreeIfNeeded()
        return strip
    }
}
