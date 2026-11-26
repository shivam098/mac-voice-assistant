import Foundation
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech
import VoiceAssistantBoard
import VoiceAssistantCore
import VoiceAssistantMac
import XCTest
@testable import VoiceAssistantApp

/// The desktop the host types into and opens apps on, in memory.
final class FakeDesktop: JarvisDesktop, @unchecked Sendable {
    static let textEdit = WindowInfo(
        handle: 7, processId: 70, processName: "com.apple.TextEdit", title: "Notes.txt", appName: "TextEdit")

    let brainPlatform = BrainPlatform.mac

    private let lock = NSLock()
    private var frontWindow: WindowInfo? = FakeDesktop.textEdit
    private var fieldCheck = AssistantFieldCheck.safe
    private var focusInfo: FocusInfo?
    private var typedTexts: [String] = []
    private var openedApps: [String] = []

    var front: WindowInfo? {
        get { lock.withLock { frontWindow } }
        set { lock.withLock { frontWindow = newValue } }
    }

    var field: AssistantFieldCheck {
        get { lock.withLock { fieldCheck } }
        set { lock.withLock { fieldCheck = newValue } }
    }

    var focus: FocusInfo? {
        get { lock.withLock { focusInfo } }
        set { lock.withLock { focusInfo = newValue } }
    }

    var typed: [String] { lock.withLock { typedTexts } }

    var opened: [String] { lock.withLock { openedApps } }

    func foregroundWindow() -> WindowInfo? { front }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        lock.withLock { openedApps.append(app.name) }
        return .ok("Opened \(app.name).", window: front)
    }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        TextTargetResult(success: true, message: "Ready.", hasTrailingText: false, focusIsEditable: true)
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "There's no search box.")
    }

    func checkFocusedField() -> AssistantFieldCheck { field }

    func focusedTextEndsWithNonWhitespace() -> Bool? { false }

    func typeText(_ text: String) throws {
        lock.withLock { typedTexts.append(text) }
    }

    func pressKeys(_ chord: String) throws {}

    func backspace(_ count: Int) throws {}

    func describeFocus() -> FocusInfo? { focus }
}

/// A microphone the test speaks into.
final class FakeMicrophone: Microphone, @unchecked Sendable {
    struct Unplugged: Error {}

    private let lock = NSLock()
    private var running = false
    private var problem: Error?
    private var samplesHandler: (@Sendable ([Float]) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?

    var isRunning: Bool { lock.withLock { running } }

    /// What `start` throws.
    var startError: Error? {
        get { lock.withLock { problem } }
        set { lock.withLock { problem = newValue } }
    }

    func setHandlers(samples: @escaping @Sendable ([Float]) -> Void, failure: @escaping @Sendable (Error) -> Void) {
        lock.withLock {
            samplesHandler = samples
            failureHandler = failure
        }
    }

    func start() async throws {
        try lock.withLock {
            if let problem {
                throw problem
            }

            running = true
        }
    }

    func stop() async {
        lock.withLock { running = false }
    }

    /// Sends `audio` as the microphone does: in 30 ms chunks, here and now.
    func feed(_ audio: [Float]) {
        let handler = lock.withLock { samplesHandler }
        var at = 0
        while at < audio.count {
            let end = min(at + 480, audio.count)
            handler?(Array(audio[at..<end]))
            at = end
        }
    }

    /// The microphone stops by itself, as when it's unplugged.
    func fail() {
        let handler: (@Sendable (Error) -> Void)? = lock.withLock {
            running = false
            return failureHandler
        }

        handler?(Unplugged())
    }
}

/// A speech model that hears what the test says it hears.
final class FakeModel: SpeechModel, @unchecked Sendable {
    let name: String

    private let lock = NSLock()
    private var replies: [String] = []
    private var standing = ""
    private var heard: [Int] = []
    private var isClosed = false

    init(_ name: String) {
        self.name = name
    }

    /// What it hears next, one call each, before `always`.
    func hears(_ texts: String...) {
        lock.withLock { replies += texts }
    }

    /// What it hears when nothing else is queued.
    var always: String {
        get { lock.withLock { standing } }
        set { lock.withLock { standing = newValue } }
    }

    /// The lengths of the audio it was given, silence aside.
    var calls: [Int] { lock.withLock { heard } }

    var closed: Bool { lock.withLock { isClosed } }

    func transcribe(_ samples: [Float]) throws -> Transcription {
        lock.withLock {
            // A warm-up's silence hears nothing and doesn't use up a reply.
            guard samples.contains(where: { $0 != 0 }) else { return Transcription(text: "", probability: 0) }
            heard.append(samples.count)
            let text = replies.isEmpty ? standing : replies.removeFirst()
            return Transcription(text: text, probability: 0.9, elapsed: 0.01)
        }
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}

/// Silero that finds speech in all of the audio, or in none of it.
final class FakeDetector: SpeechDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var finds = true

    /// False: no speech anywhere, as in music or noise.
    var findsSpeech: Bool {
        get { lock.withLock { finds } }
        set { lock.withLock { finds = newValue } }
    }

    func detect(_ samples: [Float]) throws -> [SpeechRegion] {
        guard findsSpeech, !samples.isEmpty else { return [] }
        return [SpeechRegion(start: 0, end: Double(samples.count) / 16_000)]
    }

    func close() {}
}

/// ThumbFreeSpeech's Whisper recognizer as `WhisperSpeech` uses it: its options, and the recognizers made to share its
/// model.
final class FakeRecognizer: WhisperRecognizing, @unchecked Sendable {
    let options: RecognizerOptions

    private let lock = NSLock()
    private var sharing: [FakeRecognizer] = []

    init(_ options: RecognizerOptions) {
        self.options = options
    }

    /// The recognizers `sharingModel` made, in order.
    var shared: [FakeRecognizer] { lock.withLock { sharing } }

    func transcription(_ samples: [Float]) throws -> Transcription { Transcription(text: "") }

    func sharingModel(_ options: RecognizerOptions) throws -> WhisperRecognizing {
        let other = FakeRecognizer(options)
        lock.withLock { sharing.append(other) }
        return other
    }

    func close() {}
}

/// whisper.cpp in memory: a model for each kind, by file name.
final class FakeSpeech: SpeechEngine, @unchecked Sendable {
    let english = FakeModel("english")
    let wake = FakeModel("wake")
    let hinglish = FakeModel("hinglish")
    let accurate = FakeModel("accurate")
    let detector = FakeDetector()

    private let lock = NSLock()
    private var loadedFiles: [String] = []
    private var given: [String: WhisperOptions] = [:]
    private var wakeGiven: WhisperOptions?
    private var warmed = 0

    /// The model files loaded, in order.
    var loaded: [String] { lock.withLock { loadedFiles } }

    /// The options each file was loaded with.
    var options: [String: WhisperOptions] { lock.withLock { given } }

    /// The standby check's options.
    var wakeOptions: WhisperOptions? { lock.withLock { wakeGiven } }

    var warmUps: Int { lock.withLock { warmed } }

    func loadModel(at path: String, options: WhisperOptions) throws -> SpeechModel {
        let file = (path as NSString).lastPathComponent
        lock.withLock {
            loadedFiles.append(file)
            given[file] = options
        }

        let settings = AppSettings()
        switch file {
        case settings.hinglishModelFile:
            return hinglish
        case settings.hinglishAccurateModelFile:
            return accurate
        default:
            return english
        }
    }

    func variant(of model: SpeechModel, options: WhisperOptions) throws -> SpeechModel {
        lock.withLock { wakeGiven = options }
        return wake
    }

    func loadDetector(at path: String) throws -> SpeechDetecting { detector }

    func warmUp() {
        lock.withLock { warmed += 1 }
    }
}

/// The model files, in a folder that holds `present`; a download makes a file present.
final class FakeModels: ModelFiles, @unchecked Sendable {
    static let small = "ggml-small.en-q8_0.bin"
    static let vad = "ggml-silero-v6.2.0.bin"
    static let hinglish = "ggml-hinglish-swift-q8_0.bin"
    static let accurate = "ggml-hinglish-apex-q8_0.bin"

    let folder: String

    private let lock = NSLock()
    private var present: Set<String>
    private var fetched: [String] = []

    init(folder: String, present: Set<String>) {
        self.folder = folder
        self.present = present
    }

    var downloads: [String] { lock.withLock { fetched } }

    func find(_ name: String) -> String? {
        lock.withLock { present.contains(name) } ? (folder as NSString).appendingPathComponent(name) : nil
    }

    func isDownloadable(_ name: String) -> Bool { ModelDownloader.canDownload(name) }

    func download(_ name: String, progress: @escaping @Sendable (Int) -> Void) async throws {
        lock.withLock { fetched.append(name) }
        for percent in [0, 50, 100] {
            progress(percent)
        }

        _ = lock.withLock { present.insert(name) }
    }
}

/// The cues played, when they're on.
final class FakeCues: CuePlayer, @unchecked Sendable {
    let enabled: Bool

    private let lock = NSLock()
    private var cues: [Cue] = []

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var played: [Cue] { lock.withLock { cues } }

    func play(_ cue: Cue) {
        if enabled {
            lock.withLock { cues.append(cue) }
        }
    }

    func close() {}
}

/// An AI brain that thinks until it's stopped, and downloads as the test says.
final class FakeBrain: AssistantBrain, @unchecked Sendable {
    private let lock = NSLock()
    private let download: (@Sendable (FakeBrain) async -> Void)?
    private var current = BrainStatus.ready
    private var missing: Int64
    private var handler: (@Sendable (BrainStatus) -> Void)?
    private var asked = 0
    private var done: [String] = []

    /// - Parameters:
    ///   - missingBytes: What a download would fetch.
    ///   - download: What a download does once the status says it's downloading: it changes the status and the missing
    ///     bytes as LlamaBrain would, and the download ends when it returns. Nil: `startDownload` only records the call.
    init(missingBytes: Int64 = 0, download: (@Sendable (FakeBrain) async -> Void)? = nil) {
        missing = missingBytes
        self.download = download
    }

    var availability: BrainAvailability { .ready }

    var status: BrainStatus { lock.withLock { current } }

    var canDownload: Bool { false }

    var folder: String { "brain" }

    var missingBytes: Int64 {
        get { lock.withLock { missing } }
        set { lock.withLock { missing = newValue } }
    }

    var onStatusChange: (@Sendable (BrainStatus) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// How many requests it was given.
    var requests: Int { lock.withLock { asked } }

    /// What it was told to do, in order.
    var calls: [String] { lock.withLock { done } }

    func complete(_ messages: [ChatTurn]) async throws -> String {
        lock.withLock { asked += 1 }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return ""
    }

    @discardableResult
    func startDownload() -> Task<Void, Never> {
        record("startDownload")
        guard let download else { return Task {} }
        change(to: .downloading(received: 0, total: missingBytes))
        return Task { await download(self) }
    }

    func cancelDownload() {
        record("cancelDownload")
    }

    func ensureReady() async throws {}

    func warmUp() {
        record("warmUp")
    }

    func shutdown() {
        record("shutdown")
    }

    /// Says its status changed, as LlamaBrain does.
    func change(to status: BrainStatus) {
        let handler: (@Sendable (BrainStatus) -> Void)? = lock.withLock {
            current = status
            return self.handler
        }

        handler?(status)
    }

    private func record(_ call: String) {
        lock.withLock { done.append(call) }
    }
}

/// What the host raised, in order.
final class HostLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [AssistantStatus] = []
    private var activities: [String?] = []
    private var stoppedIds: [Int] = []
    private var previewTexts: [String?] = []
    private var languageChanges: [DictationLanguage] = []
    private var untypedChanges: [Bool] = []
    private var brainChanges: [BrainStatus] = []

    init(_ host: AssistantHost) {
        host.status.subscribe { [self] status in lock.withLock { statuses.append(status) } }
        host.activity.subscribe { [self] activity in lock.withLock { activities.append(activity.label) } }
        host.captureStopped.subscribe { [self] id in lock.withLock { stoppedIds.append(id) } }
        host.dictationPreview.subscribe { [self] text in lock.withLock { previewTexts.append(text) } }
        host.dictationLanguageChanged.subscribe { [self] language in
            lock.withLock { languageChanges.append(language) }
        }
        host.untypedTextChanged.subscribe { [self] has in lock.withLock { untypedChanges.append(has) } }
        host.brainChanged.subscribe { [self] status in lock.withLock { brainChanges.append(status) } }
    }

    var messages: [String] { lock.withLock { statuses.map { $0.message } } }

    var labels: [String?] { lock.withLock { activities } }

    var stopped: [Int] { lock.withLock { stoppedIds } }

    var previews: [String?] { lock.withLock { previewTexts } }

    /// The last preview cleared it.
    var previewCleared: Bool {
        lock.withLock {
            guard let last = previewTexts.last else { return false }
            return last == nil
        }
    }

    var languages: [DictationLanguage] { lock.withLock { languageChanges } }

    var untyped: [Bool] { lock.withLock { untypedChanges } }

    var brain: [BrainStatus] { lock.withLock { brainChanges } }
}

/// A host on fakes, in a temporary folder, with its events raised on a queue of their own.
final class HostRig {
    static let listening = "Say “Hey Jarvis” to give a command."

    let folder: TempFolder
    let paths: AppPaths
    let desktop = FakeDesktop()
    let microphone = FakeMicrophone()
    let speech = FakeSpeech()
    let models: FakeModels
    let brain: FakeBrain?
    let host: AssistantHost
    let log: HostLog
    let events = DispatchQueue(label: "VoiceAssistantAppTests.events")

    private let sounds = Locked<FakeCues?>(nil)
    private let copiedTexts = Locked<[String]>([])

    /// - Parameters:
    ///   - present: The model files already on this Mac.
    ///   - prepare: Runs before the host is made, with its folders.
    ///   - post: Where the host raises its events: `events` by default; the main thread for the app's UI. After
    ///     `prepare`, so `HostRig { paths in … }` gives `prepare`.
    init(
        settings: AppSettings = HostRig.settings(),
        present: Set<String> = [FakeModels.small, FakeModels.vad],
        brain: FakeBrain? = nil,
        board: Board? = nil,
        persistMemory: Bool = true,
        prepare: (AppPaths) -> Void = { _ in },
        post: AssistantHost.Post? = nil
    ) {
        folder = TempFolder()
        paths = AppPaths(data: folder.path, logs: folder.file("logs"))
        prepare(paths)
        models = FakeModels(folder: paths.models, present: present)
        self.brain = brain
        let sounds = self.sounds
        let copied = copiedTexts
        let events = self.events
        let onEvents: AssistantHost.Post = { events.async(execute: $0) }
        let parts = HostParts(
            desktop: desktop, microphone: microphone, speech: speech, models: models, brain: brain,
            makeSounds: { enabled in
                let cues = FakeCues(enabled: enabled)
                sounds.value = cues
                return cues
            },
            copyText: { text in copied.update { $0.append(text) } })
        host = AssistantHost(
            settings: settings, paths: paths, parts: parts, board: board, persistMemory: persistMemory,
            post: post ?? onEvents)
        log = HostLog(host)
    }

    /// The defaults, with a fixed number of threads.
    static func settings() -> AppSettings {
        var settings = AppSettings()
        settings.threads = 4
        return settings
    }

    var cues: [Cue] { sounds.value?.played ?? [] }

    var copied: [String] { copiedTexts.value }

    /// The host is listening for the wake word.
    func startListening() async -> Bool {
        host.start()
        return await eventually { self.log.messages.contains(HostRig.listening) }
    }

    /// Waits for the queue to run everything before this, then for the events it raised.
    func settle() async throws {
        try await host.runOnQueue {}
        events.sync {}
    }

    func close() async {
        await host.shutdown()
        folder.remove()
    }
}

/// Audio the segmenter takes for speech: tones and silence at 16 kHz.
enum TestAudio {
    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    static func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000) * 0.3) }
    }

    /// A quiet room, a phrase, and the pause that ends it.
    static func phrase(_ seconds: Double = 1) -> [Float] { silence(0.5) + tone(seconds) + silence(1) }

    /// A phrase while voice typing, which a longer pause ends (`dictationEndSilenceMs`).
    static func typedPhrase(_ seconds: Double) -> [Float] { silence(0.5) + tone(seconds) + silence(1.5) }
}

/// Waits until `condition` holds, checking every 20 ms, for `timeout` seconds at most. False if it never did.
func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    return condition()
}
