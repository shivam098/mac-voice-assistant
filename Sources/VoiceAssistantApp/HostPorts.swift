import AppKit
import Foundation
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech
import VoiceAssistantCore
import VoiceAssistantMac

// The assistant host's ports: what it uses of the Mac, each behind a protocol so the tests can use fakes, with the
// Mac's own implementations.

/// The microphone as the host uses it (windows-voice-assistant `MicrophoneCapture`): 16 kHz mono samples from -1 to 1,
/// on the capture thread. ThumbFreeMac's `AudioCapture` in the app (`SystemMicrophone`), a fake in tests.
public protocol Microphone: AnyObject, Sendable {
    /// Started, and not stopped since (by `stop` or by itself).
    var isRunning: Bool { get }

    /// What gets the samples, on the capture thread, and the error when the microphone stopped by itself (it was
    /// unplugged and there's no other one). Set once, before the first `start`.
    func setHandlers(samples: @escaping @Sendable ([Float]) -> Void, failure: @escaping @Sendable (Error) -> Void)

    /// Throws when it can't start (no microphone, or not allowed to use it).
    func start() async throws

    func stop() async
}

/// The Mac's microphone, through ThumbFreeMac's `AudioCapture`, which follows the input chosen in System Settings
/// (Windows uses settings.json's `microphoneDevice`). Audio stays in memory and is never written to disk.
public final class SystemMicrophone: Microphone, @unchecked Sendable {
    /// Why the microphone couldn't start.
    public enum Problem: Error, Equatable, Sendable {
        /// macOS doesn't let Voice Assistant use it (System Settings › Privacy & Security › Microphone).
        case notAllowed
    }

    private let lock = NSLock()
    private var running = false
    private var samplesHandler: (@Sendable ([Float]) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?

    /// Main thread only.
    private var capture: AudioCapture?

    public init() {}

    public var isRunning: Bool { lock.withLock { running } }

    public func setHandlers(
        samples: @escaping @Sendable ([Float]) -> Void, failure: @escaping @Sendable (Error) -> Void
    ) {
        lock.withLock {
            samplesHandler = samples
            failureHandler = failure
        }
    }

    /// Starts the microphone. Without permission macOS would send silence, so this asks first, with macOS's own prompt
    /// the first time, and throws `Problem.notAllowed` when it's refused: Windows fails to open a microphone it may not
    /// use, and says so.
    public func start() async throws {
        try await Self.checkPermission()
        try await MainActor.run {
            let capture: AudioCapture
            if let existing = self.capture {
                capture = existing
            } else {
                capture = self.makeCapture()
                self.capture = capture
            }

            try capture.start()
            self.lock.withLock { self.running = true }
        }
    }

    public func stop() async {
        await MainActor.run {
            self.capture?.stop()
            self.lock.withLock { self.running = false }
        }
    }

    @MainActor
    private func makeCapture() -> AudioCapture {
        let capture = AudioCapture()
        capture.onChunk = { [weak self] chunk in self?.received(chunk.samples) }
        capture.onFailure = { [weak self] error in self?.failed(error) }
        return capture
    }

    private func received(_ samples: [Float]) {
        lock.withLock { samplesHandler }?(samples)
    }

    private func failed(_ error: Error) {
        let handler: (@Sendable (Error) -> Void)? = lock.withLock {
            running = false
            return failureHandler
        }

        handler?(error)
    }

    private static func checkPermission() async throws {
        switch Permissions().status(.microphone) {
        case .granted:
            return
        case .denied:
            throw Problem.notAllowed
        case .notDetermined:
            let status: Permissions.Status = await withCheckedContinuation { continuation in
                Permissions().request(.microphone) { continuation.resume(returning: $0) }
            }

            if status != .granted {
                throw Problem.notAllowed
            }
        }
    }
}

/// What a Whisper model heard (C#'s `TranscriptionResult`): the text, the mean probability of its tokens, and how long
/// it took, in seconds.
public struct Transcription: Equatable, Sendable {
    public var text: String
    public var probability: Float
    public var elapsed: TimeInterval

    public init(text: String, probability: Float = 1, elapsed: TimeInterval = 0) {
        self.text = text
        self.probability = probability
        self.elapsed = elapsed
    }
}

/// How a Whisper model runs (C#'s `RecognizerOptions`).
public struct WhisperOptions: Equatable, Sendable {
    public var threads: Int

    /// The encoder's window (0: the model's own, 1500 = 30 s). Smaller is faster but caps how long a phrase can be.
    public var audioContextSize: Int

    /// A vocabulary hint. Keep it short: Whisper can repeat it on near-silent audio.
    public var prompt: String?

    /// Stop after this many tokens (0: no limit); the standby check needs only the first few words.
    public var maxTokens: Int

    /// Decode again at higher temperatures when the first attempt looks unreliable (whisper.cpp's default).
    public var temperatureFallback: Bool

    public init(
        threads: Int, audioContextSize: Int = 0, prompt: String? = nil, maxTokens: Int = 0,
        temperatureFallback: Bool = true
    ) {
        self.threads = threads
        self.audioContextSize = audioContextSize
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperatureFallback = temperatureFallback
    }
}

/// A loaded Whisper model (windows-voice-assistant `WhisperRecognizer`). Calls on one model run one at a time;
/// different models run side by side.
public protocol SpeechModel: AnyObject, Sendable {
    /// The text of 16 kHz mono audio. It blocks until done (seconds for the accurate Hindi + English model), so the
    /// host calls it off its own tasks' threads.
    func transcribe(_ samples: [Float]) throws -> Transcription

    /// Frees the model once a call in progress is over (5 s at most). Safe to call twice.
    func close()
}

/// Silero's voice activity detection (windows-voice-assistant `SpeechDetector`): speech, as opposed to music and
/// noise.
public protocol SpeechDetecting: AnyObject, Sendable {
    /// The speech in 16 kHz mono audio, in order.
    func detect(_ samples: [Float]) throws -> [SpeechRegion]

    func close()
}

/// Loads the speech models (the Windows host makes them itself): whisper.cpp through ThumbFreeSpeech in the app
/// (`WhisperSpeech`), fakes in tests. Loading blocks, so the host calls it off its own tasks' threads.
public protocol SpeechEngine: AnyObject, Sendable {
    func loadModel(at path: String, options: WhisperOptions) throws -> SpeechModel

    /// The same loaded model with other options, without a second copy in memory (C#'s `WithOptions`).
    func variant(of model: SpeechModel, options: WhisperOptions) throws -> SpeechModel

    func loadDetector(at path: String) throws -> SpeechDetecting

    /// Gets whisper.cpp ready in the background, so the first model doesn't wait for it.
    func warmUp()
}

/// whisper.cpp and Silero through ThumbFreeSpeech, set up as Windows sets them up through Whisper.net: English, greedy,
/// no context from earlier calls, one segment, and the probabilities; Silero with a 0.5 threshold, 150 ms of speech at
/// least, 250 ms pauses and no padding.
public final class WhisperSpeech: SpeechEngine, @unchecked Sendable {
    public init() {}

    public func loadModel(at path: String, options: WhisperOptions) throws -> SpeechModel {
        let recognizer = try WhisperRecognizer(
            modelPath: path,
            options: RecognizerOptions(
                threads: options.threads, audioContextSize: options.audioContextSize, prompt: options.prompt))
        return WhisperModel(recognizer)
    }

    /// The model itself: ThumbFreeSpeech can't yet run a loaded model with a second set of options, cap the tokens, or
    /// turn off temperature fallback, so the standby check runs with the model's own options rather than load a second
    /// copy of it.
    public func variant(of model: SpeechModel, options: WhisperOptions) throws -> SpeechModel { model }

    public func loadDetector(at path: String) throws -> SpeechDetecting {
        SileroDetector(try SpeechDetector(modelPath: path))
    }

    public func warmUp() {
        ThumbFreeSpeech.warmUp()
    }
}

/// ThumbFreeSpeech's Whisper recognizer as a `SpeechModel`.
final class WhisperModel: SpeechModel, @unchecked Sendable {
    private let recognizer: WhisperRecognizer

    init(_ recognizer: WhisperRecognizer) {
        self.recognizer = recognizer
    }

    func transcribe(_ samples: [Float]) throws -> Transcription {
        let result = try recognizer.transcribeResult(samples)
        return Transcription(text: result.text, probability: result.probability, elapsed: result.elapsed)
    }

    func close() {
        recognizer.close()
    }
}

/// ThumbFreeSpeech's Silero detector as a `SpeechDetecting`.
final class SileroDetector: SpeechDetecting, @unchecked Sendable {
    private let detector: SpeechDetector

    init(_ detector: SpeechDetector) {
        self.detector = detector
    }

    func detect(_ samples: [Float]) throws -> [SpeechRegion] { try detector.detect(samples) }

    func close() {
        detector.close()
    }
}

/// The speech model files: where they are, and downloading them (windows-voice-assistant `ModelDownloader` with
/// `AppPaths.ModelsDir`). `ModelDownloader` in the app, a fake in tests.
public protocol ModelFiles: Sendable {
    /// Where downloads go, for messages.
    var folder: String { get }

    /// Where the file called `name` is; nil when it isn't on this Mac.
    func find(_ name: String) -> String?

    /// Whether `name` is a model it can download.
    func isDownloadable(_ name: String) -> Bool

    /// Downloads `name`, reporting whole percents. Throws a `DownloadError`, or `CancellationError`.
    func download(_ name: String, progress: @escaping @Sendable (Int) -> Void) async throws
}

extension ModelDownloader: ModelFiles {
    public var folder: String { store.primaryFolder }

    /// One of its models, in Voice Assistant's folder or ThumbFree's, or any other file of that name in Voice
    /// Assistant's models folder: as on Windows, a model you put there yourself and name in settings.json is used.
    public func find(_ name: String) -> String? {
        if let path = path(of: name) {
            return path
        }

        var isFolder: ObjCBool = false
        let own = (store.primaryFolder as NSString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: own, isDirectory: &isFolder) && !isFolder.boolValue ? own : nil
    }

    public func isDownloadable(_ name: String) -> Bool { file(named: name) != nil }
}

/// The tones that say you were heard (windows-voice-assistant `SoundFeedback.Cue`).
public enum Cue: Sendable {
    /// The wake word was heard: commands work now.
    case wake

    case startTyping
    case stopTyping

    /// Back to waiting for the wake word, or a dictation was cancelled.
    case standby
}

/// Plays the cues: `SoundFeedback` in the app, a fake in tests. Safe from any thread.
public protocol CuePlayer: AnyObject, Sendable {
    func play(_ cue: Cue)

    func close()
}

extension BrainStatus {
    /// Bytes so far and in all while it downloads (C#'s `BrainDownloadProgress`); nil otherwise.
    var downloadProgress: (received: Int64, total: Int64)? {
        if case .downloading(let received, let total) = self {
            return (received, total)
        }

        return nil
    }

    /// Its files are here, whether the model is loaded or not.
    var isInstalled: Bool {
        switch self {
        case .installed, .starting, .ready, .unloaded:
            return true
        default:
            return false
        }
    }
}

/// The AI brain as the host, the self-test and Settings use it (C#'s `LlamaBrain`, with the AI brain members of
/// `AssistantHost`): VoiceAssistantMac's `LlamaBrain` in the app, a fake in tests. It's also the model the controller
/// asks (`BrainModel`).
public protocol AssistantBrain: BrainModel {
    /// What it's doing, for Settings and the menu.
    var status: BrainStatus { get }

    /// Settings offers the download: this Mac can run it, something is missing, and no download is running.
    var canDownload: Bool { get }

    /// Where its files go (Settings' "Open its folder").
    var folder: String { get }

    /// Bytes a download would fetch now.
    var missingBytes: Int64 { get }

    /// Downloads what's missing in the background, carrying on where a download stopped, then loads the model.
    @discardableResult
    func startDownload() -> Task<Void, Never>

    /// Stops the download; the next one carries on where it stopped.
    func cancelDownload()

    /// Loads the model if it isn't loaded, and waits until it answers.
    func ensureReady() async throws

    /// Loads the model in the background, so the first request is quick.
    func warmUp()

    /// Stops it for good, as the app quits.
    func shutdown()

    /// Called on a background queue after `status` changes, in order.
    var onStatusChange: (@Sendable (BrainStatus) -> Void)? { get set }
}

extension LlamaBrain: AssistantBrain {
    public var folder: String { files.folder }

    public var missingBytes: Int64 { files.missingBytes }
}

/// What the assistant host is built from: the Mac's parts in the app (`AppParts`), fakes in tests. Sendable for the
/// self-test, which hands them over to its host: the desktop is used only from the host's queue, as the core's
/// contract says.
public struct HostParts: @unchecked Sendable {
    /// The core's desktop: VoiceAssistantMac's `MacDesktop` in the app.
    public var desktop: JarvisDesktop

    /// The apps installed on this Mac, for "open …" (`MacDesktop.discoverApps`, C#'s `StartMenuApps.Discover`). It
    /// reads folders, so the host calls it in the background. Nil finds none.
    public var discoverApps: (@Sendable () -> [AppEntry])?

    public var microphone: Microphone
    public var speech: SpeechEngine
    public var models: ModelFiles

    /// The AI brain, when settings.json's `brainEnabled` is on.
    public var brain: AssistantBrain?

    /// The cues' player, playing or silent (settings.json's `soundFeedback`).
    public var makeSounds: (_ enabled: Bool) -> CuePlayer

    /// Puts text on the clipboard; the host calls it through its `post`, on the main thread in the app.
    public var copyText: @Sendable (String) -> Void

    /// Seconds on a clock that doesn't jump, for the level meter and timings.
    public var clock: @Sendable () -> TimeInterval

    public init(
        desktop: JarvisDesktop,
        discoverApps: (@Sendable () -> [AppEntry])? = nil,
        microphone: Microphone,
        speech: SpeechEngine,
        models: ModelFiles,
        brain: AssistantBrain? = nil,
        makeSounds: @escaping (_ enabled: Bool) -> CuePlayer = { SoundFeedback(enabled: $0) },
        copyText: @escaping @Sendable (String) -> Void = HostParts.copyToPasteboard,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.desktop = desktop
        self.discoverApps = discoverApps
        self.microphone = microphone
        self.speech = speech
        self.models = models
        self.brain = brain
        self.makeSounds = makeSounds
        self.copyText = copyText
        self.clock = clock
    }

    /// The general pasteboard, as Windows' `Clipboard.SetText`. Main thread.
    public static let copyToPasteboard: @Sendable (String) -> Void = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
