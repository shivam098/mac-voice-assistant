import Foundation
import ThumbFreeCore
import VoiceAssistantBoard
import VoiceAssistantCore
import VoiceAssistantMac

/// What the pill shows besides status lines (C#'s `Activity` event): the mode, and a passing label such as
/// "Listening…", "Transcribing…", "Hearing you…" or a download's progress; nil clears it.
public struct AssistantActivity: Equatable, Sendable {
    public var mode: InteractionMode
    public var label: String?

    public init(mode: InteractionMode, label: String?) {
        self.mode = mode
        self.label = label
    }
}

/// What dictation types: English, or Hindi + English (Hindi in Roman letters) with the fast or the accurate model.
public struct DictationLanguage: Equatable, Sendable {
    public var hinglish: Bool
    public var accurate: Bool

    public init(hinglish: Bool, accurate: Bool) {
        self.hinglish = hinglish
        self.accurate = accurate
    }
}

/// Voice Assistant's engine (windows-voice-assistant `AssistantHost`): microphone → utterance segmenter → Silero →
/// Whisper → interaction controller, always listening for "Hey Jarvis"; tap-to-dictate (Fn or Right Option: tap to
/// start, tap again to finish, Esc cancels) with its live preview, Hindi + English, paste-last and time limit; the AI
/// brain's download and Esc; the cues; and what it learns. Every controller call runs on one work queue, each awaited
/// before the next, so utterances are handled strictly in order (the controller's threading contract). Its events come
/// through `post`, on the main thread in the app. Its methods are safe from any thread.
public final class AssistantHost: @unchecked Sendable {
    public typealias Post = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// The app's `post`: the main thread, later.
    public static let postToMain: Post = { work in DispatchQueue.main.async(execute: work) }

    static let knownHallucinations: Set<String> = [
        "you", "thanks for watching", "thank you for watching", "please subscribe",
    ]
    static let maxQueuedUtterances = 6
    static let sampleRate = Decoding.sampleRate
    static let previewInterval: UInt64 = 600_000_000
    static let levelInterval: TimeInterval = 0.05

    // Standby hears everything near the microphone (meetings, videos, people talking). The wake-word check transcribes
    // only the start of each phrase, with a small audio window, a few tokens, two threads and no retries; the full pass
    // runs only when it may hold the wake word or a command (windows-voice-assistant docs/BENCHMARKS.md, "Standby
    // cost").
    static let wakeCheckThreads = 2
    static let wakeCheckAudioContext = 256
    static let wakeCheckMaxTokens = 8
    static let wakeCheckSeconds = 3

    /// The standby check's options: Windows' (no prompt, and one pass without temperature fallback).
    static let wakeCheckOptions = WhisperOptions(
        threads: wakeCheckThreads, audioContextSize: wakeCheckAudioContext, maxTokens: wakeCheckMaxTokens,
        temperatureFallback: false)

    // MARK: Events (C#'s events), raised through `post`

    /// A status line, from the controller or the host.
    public let status = HostEvent<AssistantStatus>()

    /// The id given to `beginDictationCapture` when that recording couldn't start or stopped by itself (the model is
    /// still loading, a microphone error, the time limit), so the keys stop acting as if recording.
    public let captureStopped = HostEvent<Int>()

    /// A passing label for the pill: a dictation shows `DictationLabels.listening`, then
    /// `DictationLabels.transcribing`.
    public let activity = HostEvent<AssistantActivity>()

    /// The microphone's level (0 to 1), about 20 times a second while a dictation records.
    public let inputLevel = HostEvent<Float>()

    /// The live transcript while a dictation records; nil clears it.
    public let dictationPreview = HostEvent<String?>()

    /// The dictation language changed.
    public let dictationLanguageChanged = HostEvent<DictationLanguage>()

    /// Numbers to draw on screen; nil hides them.
    public let choicesChanged = HostEvent<[ChoiceBadge]?>()

    /// Something to outline briefly: just clicked, selected or focused.
    public let highlight = HostEvent<ScreenRect>()

    /// "Show my ideas" and the like: open the window on the idea board (that list, or the whole board for nil).
    public let showBoardRequested = HostEvent<BoardList?>()

    /// The AI brain loaded, unloaded, failed, or its download moved on.
    public let brainChanged = HostEvent<BrainStatus>()

    /// Whether there's dictated text that couldn't be typed (`copyUntypedText` copies it). The Mac's addition, so the
    /// menu can offer it only then.
    public let untypedTextChanged = HostEvent<Bool>()

    // MARK: Parts

    let settings: AppSettings
    let paths: AppPaths
    let parts: HostParts
    let controller: InteractionController
    let catalog: AppCatalog
    let formatter: DictationFormatter
    let memory: PhraseMemory?
    let learned: LearnedStore
    let sounds: CuePlayer
    let post: Post
    let queue = WorkQueue()
    let actions = VoiceActions()
    let segmenter: UtteranceSegmenter
    let segmenterLock = NSLock()

    // MARK: State shared between threads (C#'s volatile fields)

    let pausePending = Locked(true)
    let currentMode = Locked(InteractionMode.paused)
    let capturing = Locked(false)

    /// From the start of a dictation until its text is typed or it's cancelled: the pill belongs to the dictation, so
    /// voice listening mustn't replace its Listening and Transcribing labels.
    let dictationBusy = Locked(false)
    let captureId = Locked(0)
    let generation = Locked(0)
    let queuedUtterances = Locked(0)

    /// The AI brain's `brainChanges` when the current speech began (written on the capture thread).
    let brainChangesAtSpeech = Locked(0)
    let hinglishOn: Locked<Bool>
    let accurateOn: Locked<Bool>
    let englishModel = Locked<SpeechModel?>(nil)
    let wakeModel = Locked<SpeechModel?>(nil)
    let detector = Locked<SpeechDetecting?>(nil)
    let hinglishModel = Locked<SpeechModel?>(nil)
    let accurateModel = Locked<SpeechModel?>(nil)
    let captured = Locked<[Float]>([])
    let lastLevel = Locked<TimeInterval>(0)
    let limitReached = Locked(false)
    let previewTask = Locked<Task<Void, Never>?>(nil)
    let queueTask = Locked<Task<Void, Never>?>(nil)
    let tickTask = Locked<Task<Void, Never>?>(nil)
    let shuttingDown = Locked(false)

    /// A voice command asked to stop listening during a call: the queue turns the microphone off once it's over.
    let stopRequested = Locked(false)
    let lastBrainStatus = Locked<BrainStatus?>(nil)
    let brainDownloadFailure = Locked<String?>(nil)
    let hadUntypedText = Locked(false)

    /// The Hindi + English models' loads, behind `hinglishGate`.
    let hinglishGate = NSLock()
    var hinglishLoad: Task<Void, Never>?
    var accurateLoad: Task<Void, Never>?

    // The queue's own (only queue items use them).
    var captureStartedMicrophone = false
    var captureModel: SpeechModel?

    /// - Parameters:
    ///   - board: The idea board voice commands add to; nil turns them off.
    ///   - persistMemory: False for the self-test: nothing learned is read or saved, the language flags aren't read,
    ///     and there are no sounds.
    ///   - post: Where events are raised: the main thread in the app.
    public init(
        settings: AppSettings,
        paths: AppPaths,
        parts: HostParts,
        board: Board? = nil,
        persistMemory: Bool = true,
        post: @escaping Post = AssistantHost.postToMain
    ) {
        self.settings = settings
        self.paths = paths
        self.parts = parts
        self.post = post
        let learned = LearnedStore(path: paths.learnedFile)
        self.learned = learned
        hinglishOn = Locked(persistMemory && StateFlags.isSet(paths.hinglishDictationFlag))
        accurateOn = Locked(persistMemory && StateFlags.isSet(paths.hinglishAccurateFlag))
        sounds = parts.makeSounds(settings.soundFeedback && persistMemory)
        var memory: PhraseMemory?
        if settings.learnFromUsage {
            let made = PhraseMemory()
            if persistMemory {
                learned.load(into: made)
            }

            memory = made
        }

        self.memory = memory
        let catalog = AppCatalog(settings.apps, memory: memory)
        self.catalog = catalog
        let formatter = DictationFormatter(settings.dictationOptions)
        self.formatter = formatter
        controller = InteractionController(
            parts.desktop,
            catalog,
            CommandParser(
                commandPrefix: settings.commandPrefix,
                requirePrefixWhileTyping: settings.requireCommandPrefixWhileTyping, wakeWords: settings.wakeWords,
                memory: memory, keys: .mac),
            options: ControllerOptions(
                returnToCommandModeAfterSend: settings.returnToCommandModeAfterSend,
                minCommandConfidence: settings.minCommandConfidence, wakeWordEnabled: settings.wakeWordEnabled,
                awakeTimeout: TimeInterval(max(2, settings.awakeSeconds))),
            formatter: formatter,
            memory: memory)
        segmenter = UtteranceSegmenter(SegmenterOptions(endSilenceMs: settings.endSilenceMs))
        wire(board, persistMemory: persistMemory)
    }

    private func wire(_ board: Board?, persistMemory: Bool) {
        controller.onStatus = { [unowned self] update in
            let before = self.currentMode.exchange(update.mode)
            self.playTransitionCue(before, update.mode)

            // Typing tolerates longer thinking pauses before a phrase ends; commands stay snappy.
            self.segmenter.longPauseMs = update.mode == .dictation ? self.settings.dictationEndSilenceMs : 0
            self.raise(self.status, update)
        }

        controller.onPauseRequested = { [unowned self] in
            self.pausePending.value = true
            self.stopRequested.value = true
        }

        controller.onTrace = { Log.info($0) }
        controller.onChoicesChanged = { [unowned self] badges in self.raise(self.choicesChanged, badges) }
        controller.onHighlight = { [unowned self] rect in self.raise(self.highlight, rect) }
        controller.board = board
        controller.onShowBoardRequested = { [unowned self] list in self.raise(self.showBoardRequested, list) }
        if let brain = parts.brain {
            brain.onStatusChange = { [weak self] status in self?.brainStatusChanged(status) }
            controller.brain = brain
        }

        if persistMemory, let memory {
            let learned = self.learned
            controller.onMemoryChanged = { learned.save(memory) }
        }

        segmenter.onSpeechStarted = { [unowned self] in
            // What the AI brain was doing as this speech began: a "yes" said before it asked must never answer it.
            self.brainChangesAtSpeech.value = self.controller.brainChanges
            if self.currentMode.value != .standby {
                self.postVoiceActivity("Hearing you…")
            }
        }

        segmenter.onUtteranceReady = { [unowned self] utterance in self.onUtterance(utterance) }
        parts.microphone.setHandlers(
            samples: { [weak self] samples in self?.onSamples(samples) },
            failure: { [weak self] error in self?.microphoneFailed(error) })
    }

    // MARK: State for the UI

    /// Standby, command, dictation or paused.
    public var mode: InteractionMode { currentMode.value }

    /// True when dictation uses the Hindi + English model.
    public var hinglishDictation: Bool { hinglishOn.value }

    /// True when Hindi + English dictation uses the accurate (larger, slower) model.
    public var hinglishAccurate: Bool { accurateOn.value }

    /// The AI brain, or nil when it's switched off in Settings (C#'s `AiBrain`).
    public var brain: AssistantBrain? { parts.brain }

    /// What the AI brain is doing; nil when it's switched off.
    public var brainStatus: BrainStatus? { parts.brain?.status }

    /// Bytes so far and in all while the AI brain downloads; nil otherwise.
    public var brainDownloadProgress: (received: Int64, total: Int64)? { brainStatus?.downloadProgress }

    /// Why the AI brain's last download or start failed; nil otherwise.
    public var brainError: String? {
        if case .failed(let reason)? = brainStatus {
            return reason
        }

        return nil
    }

    /// Why the AI brain's last download failed (C#'s `BrainError`): nil after a good download, and once another starts.
    /// A model that downloaded but then couldn't start didn't fail to download; `brainError` says why it couldn't start.
    public var brainDownloadError: String? { brainDownloadFailure.value }

    // MARK: Starting and stopping

    /// Starts the work queue, loads the speech models (downloading them the first time), then listens if settings say
    /// so. whisper.cpp gets ready in the background meanwhile.
    public func start() {
        parts.speech.warmUp()
        startQueue()
        enqueue { [self] in try await load() }
        startTicking()
        discoverApps()
    }

    /// Starts only the queue (no microphone or models) and finds the installed apps, for scripted self-tests.
    func startForSelfTest() async {
        startQueue()
        guard settings.discoverStartMenuApps, let discover = parts.discoverApps else { return }
        let found = Task.detached(priority: .userInitiated) { [self] in
            // The desktop logs how many it found.
            let apps = discover()
            try? await runOnQueue { [self] in catalog.setDiscoveredApps(apps) }
        }

        _ = await Blocking.finished(found, within: 25)
    }

    /// Runs `work` on the queue, between the controller's calls, and waits for it (the self-test's calls).
    func runOnQueue(_ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queued = enqueue {
                do {
                    try await work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if !queued {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Stops listening and the work queue, and frees the models (C#'s `Dispose`). Waits up to 5 s for each piece of
    /// work still running; a speech model still transcribing is left to the end of the process rather than freed.
    public func shutdown() async {
        tickTask.exchange(nil)?.cancel()
        cancelPendingWork()
        let preview = previewTask.value
        preview?.cancel()
        shuttingDown.value = true
        queue.finish()
        let running = queueTask.value
        running?.cancel()
        let loads = hinglishGate.withLock { (hinglishLoad, accurateLoad) }
        loads.0?.cancel()
        loads.1?.cancel()
        let queueDone = await Blocking.finished(running, within: 5)
        let previewDone = await Blocking.finished(preview, within: 5)
        let fastDone = await Blocking.finished(loads.0, within: 5)
        let accurateDone = await Blocking.finished(loads.1, within: 5)
        let drained = queueDone && previewDone && fastDone && accurateDone
        parts.brain?.shutdown()
        await parts.microphone.stop()
        sounds.close()
        if drained {
            // The standby check shares the English model's weights, which are freed once both have closed.
            wakeModel.value?.close()
            englishModel.value?.close()
            hinglishModel.value?.close()
            accurateModel.value?.close()
            detector.value?.close()
        } else {
            Log.warn("queue did not drain; leaving speech model to process exit")
        }
    }

    // MARK: Listening

    /// The hotkey's and the menu's pause and resume. Pausing takes effect at once, before any queued speech is handled.
    public func toggleListening() {
        if currentMode.value != .paused && !pausePending.value {
            cancelPendingWork()
            enqueue { [self] in
                await stopMicrophone()
                setListening(false)
            }

            return
        }

        enqueue { [self] in
            if controller.mode == .paused {
                await startListening()
            }
        }
    }

    /// Esc while the AI brain plans or acts: stops it. Listening carries on.
    public func cancelBrainAction() {
        if controller.isBrainRunning {
            Log.info("brain: stopped with Esc")
            actions.cancel()
        }
    }

    /// Downloads the AI brain's files in the background (carrying on where a download stopped), then loads it.
    public func startBrainDownload() {
        guard let brain = parts.brain else { return }
        brainDownloadFailure.value = nil
        let download = brain.startDownload()
        Task.detached(priority: .utility) { [weak self] in
            await download.value

            // As the download ends, a failed one shows in the status with files still missing. The model starting
            // afterwards, or failing to, is another matter.
            if case .failed(let reason) = brain.status, brain.missingBytes > 0 {
                self?.brainDownloadFailure.value = reason
            }
        }
    }

    /// Stops the AI brain's download; the next one carries on where it stopped.
    public func cancelBrainDownload() {
        parts.brain?.cancelDownload()
    }

    /// Forgets learned rephrasings and app use, in memory and on disk.
    public func forgetLearned() {
        enqueue { [self] in
            memory?.clear()
            learned.delete()
            report(.info, "Forgot everything I'd learned.")
        }
    }

    // MARK: The queue

    private func startQueue() {
        queueTask.value = Task.detached(priority: .userInitiated) { [self] in await processQueue() }
    }

    /// C#'s `ProcessQueueAsync`: each item in turn; a pause or Esc cancels the one running, and what an item throws is
    /// logged and said.
    private func processQueue() async {
        for await work in queue.items {
            if shuttingDown.value {
                return
            }

            do {
                try await work()
            } catch is CancellationError where shuttingDown.value {
                return
            } catch is CancellationError {
                Log.info("action cancelled by pause")
            } catch {
                Log.error("action failed: \(Log.kind(of: error))")
                report(.error, "That didn't work: " + Self.message(error))
            }

            if stopRequested.exchange(false) {
                await stopMicrophone()
            }

            noteUntypedText()
        }
    }

    @discardableResult
    func enqueue(_ work: @escaping WorkQueue.Work) -> Bool { queue.enqueue(work) }

    private func startTicking() {
        tickTask.value = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.enqueue { [self] in _ = self.controller.tick() }
            }
        }
    }

    private func discoverApps() {
        guard settings.discoverStartMenuApps, let discover = parts.discoverApps else { return }

        // The catalog belongs to the controller's queue, so the list is handed over there. The desktop logs how many
        // it found (C#'s host logs it itself).
        Task.detached(priority: .utility) { [self] in
            let apps = discover()
            enqueue { [self] in catalog.setDiscoveredApps(apps) }
        }
    }

    /// Drops queued speech and cancels a voice action in progress, at once, from any thread.
    func cancelPendingWork() {
        pausePending.value = true
        generation.update { $0 += 1 }
        actions.cancel()
    }

    /// `setListening`, called again once the running call has ended if one was running (the controller's contract).
    func setListening(_ listening: Bool) {
        if !controller.setListening(listening) {
            enqueue { [self] in setListening(listening) }
        }
    }

    /// Whether there's untyped text now, said when that changes. Queue only.
    private func noteUntypedText() {
        let has = !(controller.untypedText?.isEmpty ?? true)
        if hadUntypedText.exchange(has) != has {
            raise(untypedTextChanged, has)
        }
    }

    // MARK: Loading the models

    private func load() async throws {
        for file in [settings.modelFile, settings.vadModelFile] {
            let ready = try await ensureModel(file)
            if !ready && file == settings.modelFile {
                return
            }
        }

        guard let modelPath = parts.models.find(settings.modelFile) else { return }
        postActivity("Loading speech model…")
        let started = parts.clock()
        do {
            let speech = parts.speech
            let options = WhisperOptions(
                threads: settings.threads, audioContextSize: settings.audioContextSize,
                prompt: settings.vocabularyPrompt)
            let model = try await Blocking.run(cancellable: false) {
                try speech.loadModel(at: modelPath, options: options)
            }
            englishModel.value = model
            _ = try await transcribe(model, Self.silence)

            // The standby pre-check: the same model on the first seconds of each phrase, cut short.
            let check = try speech.variant(of: model, options: Self.wakeCheckOptions)
            wakeModel.value = check
            _ = try await transcribe(check, Self.silence)
            if let vadPath = parts.models.find(settings.vadModelFile) {
                detector.value = try await Blocking.run(cancellable: false) { try speech.loadDetector(at: vadPath) }
            } else {
                Log.warn("vad model missing; using energy detection only")
            }
        } catch is CancellationError {
            postActivity(nil)
            throw CancellationError()
        } catch {
            Log.error("model load failed: \(Log.kind(of: error))")
            report(
                .error, "Couldn't load the speech model. Delete it from the models folder and restart to re-download.")
            postActivity(nil)
            return
        }

        postActivity(nil)
        Log.info("models loaded in \(Self.ms(parts.clock() - started)) ms (vad=\(Self.csharp(detector.value != nil)))")
        if hinglishOn.value {
            ensureHinglishLoading()
        }

        if let brain = parts.brain, brain.availability == .sleeping {
            // Loads in the background (about 10 s) so the first request is quick.
            brain.warmUp()
        }

        if settings.listenOnStartup {
            await startListening()
        } else {
            report(.info, "Ready. Press \(AppSettings.hotkeyLabel(settings.macHotkey)) to start listening.")
        }
    }

    /// Makes sure a model file is here, downloading and checking it the first time (`EnsureModelAsync`). False when
    /// it's still missing. `what` names a later download in messages, as "<name> (about <size>".
    func ensureModel(_ file: String, firstRun: Bool = true, what: String? = nil) async throws -> Bool {
        let models = parts.models
        if models.find(file) != nil {
            return true
        }

        if !models.isDownloadable(file) {
            report(.error, "Speech model \(file) not found in \(models.folder).")
            return false
        }

        Log.info("downloading \(file)")
        let what = what ?? "Hindi + English model (about 80 MB"
        let name = what.components(separatedBy: " (")[0]
        report(
            .info,
            firstRun
                ? "First run: downloading the speech model (one time, stays on this Mac)…"
                : "Downloading the \(what), one time)…")
        defer {
            if firstRun {
                postActivity(nil)
            }
        }

        do {
            // Progress shows in the pill only on first run; later downloads mustn't replace a "Listening…" label, so
            // they say every 10% in a status line instead.
            let lastTenth = Locked(0)
            try await models.download(file) { [weak self] percent in
                guard let self else { return }
                if firstRun {
                    self.postActivity("Downloading speech model… \(percent)%")
                } else if percent / 10 > lastTenth.value && percent < 100 {
                    lastTenth.value = percent / 10
                    self.report(.info, "Downloading the \(name)… \(percent)%")
                }
            }

            Log.info("downloaded \(file)")
            return true
        } catch is CancellationError {
            if shuttingDown.value {
                throw CancellationError()
            }

            Log.info("download of \(file) cancelled")
            return false
        } catch {
            Log.error("download of \(file) failed: \(Log.kind(of: error))")
            report(
                .error,
                firstRun
                    ? "Couldn't download the speech model. Check the internet connection and restart Voice Assistant."
                    : "Couldn't download the \(name). Check the internet connection and switch it on again.")
            return false
        }
    }

    private func startListening() async {
        guard englishModel.value != nil else {
            report(.warning, "Still loading the speech model…")
            return
        }

        resetSegmenter()
        do {
            try await parts.microphone.start()
        } catch {
            Log.error("microphone start failed: \(Log.kind(of: error))")
            report(.error, Self.microphoneProblem)
            return
        }

        captureStartedMicrophone = false
        generation.update { $0 += 1 }
        pausePending.value = false
        setListening(true)
        Log.info("listening")
    }

    /// Turns the microphone off, unless a dictation is recording: it owns the microphone until it ends.
    func stopMicrophone() async {
        if capturing.value {
            return
        }

        await parts.microphone.stop()
        generation.update { $0 += 1 }
        resetSegmenter()
        Log.info("microphone stopped")
    }

    func resetSegmenter() {
        segmenterLock.withLock { segmenter.reset() }
    }

    private func microphoneFailed(_ error: Error) {
        Log.error("microphone failed: \(Log.kind(of: error))")
        cancelPendingWork()
        enqueue { [self] in
            let wasCapturing = capturing.value
            await stopPreview()
            await stopMicrophone()
            capturing.value = false
            dictationBusy.value = false
            if wasCapturing {
                raise(captureStopped, captureId.value)
            }

            postActivity(nil)
            setListening(false)
            report(.error, "The microphone stopped. Press \(AppSettings.hotkeyLabel(settings.macHotkey)) to try again.")
        }
    }

    // MARK: Speech

    /// The capture thread's samples: a dictation's recording, or voice listening's segmenter.
    private func onSamples(_ samples: [Float]) {
        if capturing.value {
            let recorded = captured.update { audio -> Int in
                audio.append(contentsOf: samples)
                return audio.count
            }

            let now = parts.clock()
            let showLevel = lastLevel.update { last -> Bool in
                guard now - last >= Self.levelInterval else { return false }
                last = now
                return true
            }

            if showLevel {
                raise(inputLevel, AudioLevel.of(samples))
            }

            let limit = settings.maxDictationSeconds
            if limit > 0 && recorded >= limit * Self.sampleRate && !limitReached.exchange(true) {
                let id = captureId.value
                enqueue { [self] in try await finishAtLimit(id) }
            }

            return
        }

        segmenterLock.withLock { segmenter.push(samples) }
    }

    private func onUtterance(_ utterance: Utterance) {
        if pausePending.value {
            return
        }

        if controller.isBrainRunning {
            // Speech while the AI brain plans or acts would otherwise run once it's done: late, on a changed screen,
            // and often just the request said again. It's dropped; Esc stops the brain at once.
            Log.info("speech while the AI brain was busy: ignored")
            postVoiceActivity(nil)
            report(
                .info,
                settings.pushToTalk
                    ? "Still working on your last request. Press Esc to stop it."
                    : "Still working on your last request.")
            return
        }

        let generation = self.generation.value
        let brainChanges = brainChangesAtSpeech.value
        let accepted: Bool = queuedUtterances.update { count in
            guard count < Self.maxQueuedUtterances else { return false }
            count += 1
            return true
        }

        guard accepted else {
            Log.warn("utterance queue full; dropped one")
            return
        }

        enqueue { [self] in try await transcribeAndHandle(utterance, generation, brainChanges) }
    }

    func isStale(_ generation: Int) -> Bool { pausePending.value || generation != self.generation.value }

    private func transcribeAndHandle(_ utterance: Utterance, _ generation: Int, _ brainChanges: Int) async throws {
        defer {
            queuedUtterances.update { $0 -= 1 }
            postVoiceActivity(nil)
        }

        guard !isStale(generation), englishModel.value != nil else { return }

        // Silero drops music and noise and splits phrases that background sound merged, at the pause length the
        // segmenter uses, so a typing pause doesn't split a sentence here either.
        let pause = currentMode.value == .dictation
            ? max(settings.endSilenceMs, settings.dictationEndSilenceMs) : settings.endSilenceMs
        let pieces: [[Float]]
        if let detector = detector.value {
            let samples = utterance.samples
            let speech = try await Blocking.run { try detector.detect(samples) }
            pieces = SpeechSegments.split(samples, speech, sampleRate: Self.sampleRate, minGapMs: pause, padMs: 250)
        } else {
            pieces = [utterance.samples]
        }

        if pieces.isEmpty {
            Log.info("no speech in \(utterance.samples.count * 1000 / Self.sampleRate)ms utterance")
            return
        }

        for (i, piece) in pieces.enumerated() {
            try await handlePiece(piece, utterance.followsForcedCut && i == 0, generation, brainChanges)
        }
    }

    private func handlePiece(_ samples: [Float], _ followsForcedCut: Bool, _ generation: Int, _ brainChanges: Int)
        async throws
    {
        guard !isStale(generation), let english = englishModel.value else { return }
        let audioMs = samples.count * 1000 / Self.sampleRate
        if controller.mode == .command || controller.mode == .standby, audioMs > settings.maxCommandUtteranceMs {
            // Commands are short; long speech while not typing is conversation or meeting audio.
            Log.info("skipped \(audioMs)ms utterance while waiting for a command")
            return
        }

        // Pausing and Esc cancel it (C#'s token from `_shutdown` and `_actionCts`).
        try await actions.run { [self] in
            try await recognize(samples, english, audioMs, followsForcedCut, generation, brainChanges)
        }
    }

    private func recognize(
        _ samples: [Float], _ english: SpeechModel, _ audioMs: Int, _ followsForcedCut: Bool, _ generation: Int,
        _ brainChanges: Int
    ) async throws {
        if controller.mode == .standby, let check = wakeModel.value {
            let limit = Self.wakeCheckSeconds * Self.sampleRate
            let head = samples.count > limit ? Array(samples[..<limit]) : samples
            let rough = try await transcribe(check, head)
            if isStale(generation)
                || !controller.worthTranscribingInStandby(rough.text, cutShort: head.count < samples.count) {
                Log.info("standby: no wake word in \(audioMs)ms utterance (check \(Self.ms(rough.elapsed))ms)")
                return
            }
        } else if controller.mode != .standby {
            postVoiceActivity("Transcribing…")
        }

        let result = try await transcribe(english, samples)
        let probability = String(format: "%.2f", result.probability)
        Log.info(
            "utterance audio=\(audioMs)ms asr=\(Self.ms(result.elapsed))ms p=\(probability) "
                + "continuation=\(Self.csharp(followsForcedCut))")
        if isStale(generation) {
            return
        }

        // While typing in Hindi + English, commands are still recognized in English; text to type comes from the
        // Hindi model.
        let hinglish = hinglishOn.value && controller.mode == .dictation ? hinglishForTyping() : nil
        if hinglish == nil && audioMs < 2500 && Self.isHallucination(result.text) {
            return
        }

        var dictation: (() async throws -> String)?
        if let hinglish {
            dictation = { [self] in
                let typed = try await transcribe(hinglish, samples)
                Log.info("utterance hinglish asr=\(Self.ms(typed.elapsed))ms")
                let echo = hinglish === accurateModel.value && isPromptEcho(typed.text)
                return (audioMs < 2500 && Self.isHallucination(typed.text)) || echo ? "" : typed.text
            }
        }

        do {
            try await controller.handleTranscript(
                result.text, result.probability, followsForcedCut: followsForcedCut, dictationTranscript: dictation,
                brainChangesWhenSpoken: brainChanges)
        } catch is ControllerBusy {
            // Another call was running, which the queue rules out: the speech is dropped, never queued, so a "yes"
            // can't run after a plan.
            report(.info, "Still working on your last request.")
        }
    }

    /// A model's text for `samples`, on a thread of its own. With `cancellable`, cancelling the waiting task returns
    /// at once while the model runs to its end.
    func transcribe(_ model: SpeechModel, _ samples: [Float], cancellable: Bool = true) async throws -> Transcription {
        try await Blocking.run(cancellable: cancellable) { try model.transcribe(samples) }
    }

    /// Whisper's usual output for noise ("you", "thanks for watching").
    static func isHallucination(_ text: String) -> Bool { knownHallucinations.contains(TranscriptText.normalize(text)) }

    // MARK: The AI brain

    private func brainStatusChanged(_ status: BrainStatus) {
        let before = lastBrainStatus.exchange(status)
        if before?.downloadProgress != nil && status.isInstalled {
            report(.success, "The AI brain is ready. Ask for anything, like “open the MrBeast video on YouTube”.")
        }

        raise(brainChanged, status)
    }

    // MARK: Cues and events

    private func playTransitionCue(_ from: InteractionMode, _ to: InteractionMode) {
        if from == to {
            return
        }

        if to == .dictation {
            sounds.play(.startTyping)
        } else if from == .dictation && to != .paused {
            sounds.play(.stopTyping)
        } else if from == .standby && to == .command {
            sounds.play(.wake)
        } else if from == .command && to == .standby {
            sounds.play(.standby)
        }
    }

    /// A status line, with the mode as it is when it's shown.
    func report(_ kind: StatusKind, _ message: String) {
        post { [self] in status.send(AssistantStatus(mode: currentMode.value, kind: kind, message: message)) }
    }

    func postActivity(_ label: String?) {
        post { [self] in activity.send(AssistantActivity(mode: currentMode.value, label: label)) }
    }

    /// Voice listening's and commands' activity, which a dictation's labels take precedence over.
    func postVoiceActivity(_ label: String?) {
        if !dictationBusy.value {
            postActivity(label)
        }
    }

    func raise<Value: Sendable>(_ event: HostEvent<Value>, _ value: Value) {
        post { event.send(value) }
    }

    // MARK: Helpers

    static let silence = [Float](repeating: 0, count: sampleRate)

    static let microphoneProblem =
        "Couldn't open the microphone. Check System Settings › Privacy & Security › Microphone."

    /// Milliseconds as C#'s `{x:F0}` writes them.
    static func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f", seconds * 1000) }

    /// A Boolean as C# writes it in the log.
    static func csharp(_ value: Bool) -> String { value ? "True" : "False" }

    /// An error's message, as C#'s `Exception.Message`.
    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
