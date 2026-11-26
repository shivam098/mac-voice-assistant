import AVFoundation
import Foundation
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore
import VoiceAssistantMac
@testable import VoiceAssistantApp

/// The window's pages on fakes: the assistant, the AI brain, what macOS allows, Finder and TextEdit, and the login
/// item, with settings.json in a temporary folder and a clock that stands still.
@MainActor
final class PageRig {
    let folder = TempFolder()
    let paths: AppPaths
    let assistant = PageAssistant()
    let brain: PageBrain
    let system = PagePermissionSystem()
    let opener = PageOpener()
    let login = PageLogin()
    let timeZone = PageRig.timeZone
    /// Now: 26 November 2026, 4 PM in India.
    let now = Locked(PageRig.date("2026-11-26 16:00"))
    private(set) var restarts = 0

    nonisolated static let timeZone = TimeZone(identifier: "Asia/Kolkata")!

    init() {
        paths = AppPaths(data: folder.path, logs: folder.file("logs"))
        brain = PageBrain(folder: folder.file("brain"))
    }

    /// "2026-11-26 16:00" on India's clock.
    nonisolated static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func home(board: BoardStore?, keys: KeyNames = KeyNames(), dictationKeyOn: Bool = true) -> HomeModel {
        let now = now
        return HomeModel(
            assistant: assistant, board: board, keys: keys, permissions: Permissions(system: system),
            dictationKeyOn: dictationKeyOn, clock: { now.value }, timeZone: timeZone)
    }

    func settings(
        _ settings: AppSettings = AppSettings(), keys: KeyNames = KeyNames(), brainOn: Bool = true
    ) -> SettingsModel {
        let now = now
        return SettingsModel(
            settings: settings, paths: paths, assistant: assistant, brain: brainOn ? brain : nil, keys: keys,
            startAtLogin: login.item, restart: { [weak self] in self?.restarts += 1 }, opener: opener,
            clock: { now.value }, timeZone: timeZone)
    }

    /// A board in memory, on this clock.
    func board() throws -> BoardStore {
        let now = now
        return try BoardStore(path: nil, clock: { now.value }, timeZone: timeZone)
    }

    /// Runs the main loop until `done` or 2 seconds: what the main queue was given runs.
    static func waitForMain(until done: () -> Bool = { false }, seconds: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(done() ? 0 : 2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        } while !done() && Date() < deadline
    }
}

/// The assistant host, recording what it's asked.
final class PageAssistant: AssistantControls {
    var mode = InteractionMode.standby
    var hinglishDictation = false
    var hinglishAccurate = false
    private(set) var calls: [String] = []

    func toggleListening() {
        calls.append("toggle listening")
    }

    func setDictationLanguage(hinglish: Bool, accurate: Bool) {
        calls.append("language hinglish: \(hinglish) accurate: \(accurate)")
    }

    func forgetLearned() {
        calls.append("forget learned")
    }
}

/// The AI brain, in whatever state a test sets.
final class PageBrain: BrainControls {
    var status = BrainStatus.notInstalled
    var canDownload = true
    let folder: String
    /// The pinned llama.cpp build and model, about 2.2 GB.
    var missingBytes: Int64 = 2_392_985_300
    private(set) var calls: [String] = []

    init(folder: String) {
        self.folder = folder
    }

    func startDownload() -> Task<Void, Never> {
        calls.append("download")
        return Task {}
    }

    func cancelDownload() {
        calls.append("stop download")
    }
}

/// What macOS allows, and what its prompts answer.
final class PagePermissionSystem: Permissions.System, @unchecked Sendable {
    var microphone = AVAuthorizationStatus.authorized
    var accessibility = true
    var postEvents = true
    var listen = true
    /// What you answer to macOS's prompts.
    var grantsMicrophone = true
    var grantsPostEvents = false
    var grantsListen = false
    private(set) var calls: [String] = []

    func microphoneStatus() -> AVAuthorizationStatus { microphone }

    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        calls.append("ask for the microphone")
        microphone = grantsMicrophone ? .authorized : .denied
        completion(grantsMicrophone)
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            calls.append("ask for Accessibility")
        }

        return accessibility
    }

    func canPostEvents() -> Bool { postEvents }

    func requestPostEvents() -> Bool {
        calls.append("ask to post events")
        postEvents = grantsPostEvents
        accessibility = grantsPostEvents
        return grantsPostEvents
    }

    func canListenToEvents() -> Bool { listen }

    func requestListenToEvents() -> Bool {
        calls.append("ask to listen to events")
        listen = grantsListen
        return grantsListen
    }

    func open(_ url: URL) -> Bool {
        calls.append("open " + url.absoluteString)
        return true
    }
}

/// Finder, TextEdit and System Settings, recording what they're asked to open.
@MainActor
final class PageOpener: FileOpener {
    private(set) var opened: [String] = []

    func open(_ url: URL) {
        opened.append(url.isFileURL ? url.path : url.absoluteString)
    }

    func openText(_ url: URL) {
        opened.append("TextEdit " + url.path)
    }
}

/// The login item: on or off, and whether macOS does what it's asked.
@MainActor
final class PageLogin {
    var enabled = false
    var works = true
    private(set) var asked: [Bool] = []

    var item: StartAtLogin {
        StartAtLogin(
            isEnabled: { [unowned self] in self.enabled },
            set: { [unowned self] on in
                self.asked.append(on)
                if self.works {
                    self.enabled = on
                }
            })
    }
}
