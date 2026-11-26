import AppKit
import SwiftUI
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore
import VoiceAssistantMac
import XCTest
@testable import VoiceAssistantApp

/// The window's pages (see `Renderer`), to compare with the Windows app's: the window at each page, Home with and
/// without the permissions card, Settings with the AI brain downloading, ready and failed, and "What you can say" with
/// searches. Reduce motion is on, so the pages show without their fades.
extension UIRenderTests {
    @MainActor
    func testTheWindowAtHome() throws {
        try Self.withoutMotion {
            let rig = PageRig()
            defer { rig.folder.remove() }
            let board = try rig.board()
            try board.add(.reminders, "Call mom", due: rig.now.value.addingTimeInterval(25 * 60))
            try board.add(.reminders, "Book the dentist for Thursday morning", due: PageRig.date("2026-11-27 09:00"))
            rig.system.microphone = .notDetermined
            rig.system.accessibility = false
            rig.system.postEvents = false
            rig.system.listen = false
            let first = rig.home(board: board)
            first.showStatus(
                AssistantStatus(mode: .standby, kind: .info, message: "Ready. Press ⌃⇧Space to start listening."))
            Renderer.render(Self.window(rig, home: first), "window-1-home-permissions-needed")

            let other = PageRig()
            defer { other.folder.remove() }
            let full = try other.board()
            let now = other.now.value
            try full.add(.reminders, "Water the plants", due: nil)
            try full.add(.reminders, "Stretch", due: PageRig.date("2026-11-26 18:00"))
            try full.add(.reminders, "Call mom", due: now.addingTimeInterval(25 * 60))
            try full.add(.reminders, "Pay the rent", due: now.addingTimeInterval(-10 * 60))
            other.assistant.mode = .command
            other.assistant.hinglishDictation = true
            let home = other.home(board: full)
            for (minute, kind, message) in Self.session {
                other.now.update { $0 = PageRig.date("2026-11-26 16:0\(minute)") }
                home.showStatus(AssistantStatus(mode: .command, kind: kind, message: message))
            }

            Renderer.render(Self.window(other, home: home), "window-2-home")
            Renderer.render(
                HomeContent(model: home).frame(width: 950).background(Color(Theme.background)), "home-full-page")

            let ideas = Self.model(other)
            ideas.showBoard(.reminders)
            Renderer.render(Self.window(ideas), "window-3-idea-board-placeholder")
        }
    }

    @MainActor
    func testTheSettingsPage() {
        Self.withoutMotion {
            let rig = PageRig()
            defer { rig.folder.remove() }
            rig.brain.status = .downloading(received: 1_073_741_824, total: 2_392_985_300)
            rig.brain.canDownload = false
            let downloading = rig.settings()
            let window = Self.model(rig, settings: downloading)
            window.show(.settings)
            Renderer.render(Self.window(window), "window-4-settings")
            Renderer.render(Self.settings(downloading), "settings-1-brain-downloading")

            rig.brain.status = .ready
            let ready = rig.settings()
            ready.fields[ready.index("soundFeedback")].text = "False"
            ready.save()
            Renderer.render(Self.settings(ready), "settings-2-brain-ready-saved")

            rig.brain.status = .failed("The download stopped: the network connection was lost. Download carries on.")
            rig.brain.canDownload = true
            rig.login.works = false
            let failed = rig.settings(keys: KeyNames(dictation: "Right Option"))
            failed.setStartsAtLogin(true)
            failed.fields[failed.index("awakeSeconds")].text = "500"
            failed.save()
            Renderer.render(Self.settings(failed), "settings-3-brain-failed-not-saved-right-option")

            Renderer.render(Self.brainCards(rig), "settings-4-brain-card-states")
            Renderer.render(
                SettingsContent(model: ready).padding(24).frame(width: 670).background(Color(Theme.background)),
                "settings-5-narrowest-window")
        }
    }

    @MainActor
    func testWhatYouCanSay() {
        Self.withoutMotion {
            let rig = PageRig()
            defer { rig.folder.remove() }
            let window = Self.model(rig)
            window.show(.help)
            Renderer.render(Self.window(window), "window-5-what-you-can-say")
            for (index, search) in ["remind", "tab", "delete", "zzz"].enumerated() {
                window.help.filter = search
                Renderer.render(Self.window(window), "help-\(index + 1)-search-\(search)")
            }
        }
    }

    /// A session's messages: minute, kind and text.
    private static let session: [(Int, StatusKind, String)] = [
        (1, .info, "Ready. Press ⌃⇧Space to start listening."),
        (2, .success, "Opened Google Chrome."),
        (3, .success, "Opened YouTube in a new tab."),
        (4, .warning, "Sorry, I didn't catch that."),
        (
            5, .error,
            "The microphone isn't working. Check System Settings › Privacy & Security › Microphone, then try again."
        ),
        (6, .success, "Added to your ideas: a voice game for kids."),
    ]

    /// Runs `body` with Reduce motion on.
    @MainActor
    private static func withoutMotion(_ body: () throws -> Void) rethrows {
        let reduceMotion = Motion.reduceMotion
        defer { Motion.reduceMotion = reduceMotion }
        Motion.reduceMotion = { true }
        try body()
    }

    @MainActor
    private static func model(
        _ rig: PageRig, home: HomeModel? = nil, settings: SettingsModel? = nil, keys: KeyNames = KeyNames()
    ) -> WindowModel {
        WindowModel(
            home: home ?? rig.home(board: nil, keys: keys), settings: settings ?? rig.settings(keys: keys),
            help: HelpModel(keys: keys))
    }

    /// The window's contents at its size when it opens.
    @MainActor
    private static func window(_ model: WindowModel) -> some View {
        MainWindowView(model: model).frame(width: MainWindow.size.width, height: MainWindow.size.height)
    }

    @MainActor
    private static func window(_ rig: PageRig, home: HomeModel) -> some View {
        window(model(rig, home: home))
    }

    /// The whole Settings page, without its scroll.
    @MainActor
    private static func settings(_ model: SettingsModel) -> some View {
        SettingsContent(model: model).padding(24).background(Color(Theme.background))
    }

    /// The AI brain's card in each state.
    @MainActor
    private static func brainCards(_ rig: PageRig) -> some View {
        var cards: [(String, BrainCard)] = []
        rig.brain.canDownload = true
        rig.brain.status = .notInstalled
        cards.append(("Not downloaded", BrainCard.describe(rig.brain)))
        rig.brain.canDownload = false
        let states: [(String, BrainStatus)] = [
            ("Downloading", .downloading(received: 361_758_720, total: 2_392_985_300)),
            ("Installed", .installed), ("Loading", .starting), ("Ready", .ready), ("Unloaded", .unloaded),
            ("Failed", .failed("llama-server stopped (exit 6). Open logs folder for details.")),
            ("Failed, no reason", .failed("")),
            ("Unavailable", .unavailable("The AI brain needs a Mac with Apple silicon and 8 GB of memory.")),
        ]
        for (name, status) in states {
            rig.brain.status = status
            cards.append((name, BrainCard.describe(rig.brain)))
        }

        rig.brain.missingBytes = 0
        rig.brain.status = .notInstalled
        cards.append(("Files not where settings.json says", BrainCard.describe(rig.brain)))
        cards.append(("Switched off", BrainCard.describe(nil)))
        let shown = cards
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown.indices, id: \.self) { (index: Int) in
                VStack(alignment: .leading, spacing: 0) {
                    Theme.label(shown[index].0, size: 11, colour: Theme.muted).padding(.bottom, 6)
                    BrainCardView(card: shown[index].1, download: {}, stop: {}, openFolder: {})
                }
                .themeCard()
            }
        }
        .padding(24)
        .frame(width: 808)
        .background(Color(Theme.background))
    }
}
