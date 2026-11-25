import Foundation
import ThumbFreeCore
import VoiceAssistantCore

// Tap-to-dictate (Fn or Right Option), its live preview, Hindi + English, paste-last, and the text that couldn't be
// typed: the dictation half of windows-voice-assistant `AssistantHost`.
extension AssistantHost {
    // MARK: Tap-to-dictate

    /// Starts recording for a dictation, which works while listening is paused too. `id` names this recording in
    /// `captureStopped`.
    public func beginDictationCapture(_ id: Int) {
        enqueue { [self] in await beginCapture(id) }
    }

    /// Stops the dictation's recording; transcribes and types it unless `cancel`.
    public func endDictationCapture(cancel: Bool) {
        enqueue { [self] in try await endCapture(cancel: cancel) }
    }

    private func beginCapture(_ id: Int) async {
        if capturing.value {
            return
        }

        captureId.value = id
        guard let english = englishModel.value else {
            report(.warning, "Still loading the speech model…")
            raise(captureStopped, id)
            return
        }

        // A recording that ended early (cancelled, silence) may have kept a model that's no longer chosen.
        releaseAccurateIfUnused()
        captured.value = []
        if !parts.microphone.isRunning {
            do {
                try await parts.microphone.start()
                captureStartedMicrophone = true
            } catch {
                Log.error("microphone start failed: \(Log.kind(of: error))")
                report(.error, Self.microphoneProblem)
                raise(captureStopped, id)
                return
            }
        }

        limitReached.value = false
        lastLevel.value = 0
        dictationBusy.value = true

        // Phrases voice listening finished before the key was tapped (still queued) are dropped, not run mid-recording.
        generation.update { $0 += 1 }
        capturing.value = true
        captureModel = english
        var previewModel: SpeechModel? = english
        if hinglishOn.value {
            let chosen = hinglishForTyping()
            if accurateOn.value && accurateModel.value == nil {
                // Retries after a failed download or load, too.
                ensureHinglishLoading()
            }

            if let chosen {
                captureModel = chosen

                // The accurate model takes seconds per pass: the live preview uses the fast one (or is skipped).
                previewModel = chosen === accurateModel.value ? hinglishModel.value : chosen
                if accurateOn.value && chosen !== accurateModel.value {
                    report(
                        .warning,
                        "The accurate Hindi + English model is still loading; this dictation uses the fast one.")
                }
            } else {
                ensureHinglishLoading()
                report(.warning, "The Hindi + English model isn't ready yet; this dictation uses English.")
            }
        }

        sounds.play(.startTyping)
        postActivity(DictationLabels.listening)
        if settings.livePreview, let previewModel {
            previewTask.value = Task.detached { [self] in await runPreview(previewModel) }
        }
    }

    /// - Parameters:
    ///   - cancel: Throws the recording away instead of typing it.
    ///   - onlyId: Stops only if this recording is still the one in progress (the time limit).
    func endCapture(cancel: Bool, onlyId: Int? = nil) async throws {
        guard capturing.value else { return }
        if let onlyId, onlyId != captureId.value {
            return
        }

        capturing.value = false

        // "Transcribing…" straight away: stopping the live preview may wait for a pass that is still running.
        postActivity(cancel ? nil : DictationLabels.transcribing)
        defer {
            dictationBusy.value = false
            postActivity(nil)

            // The language may have changed during this recording.
            releaseAccurateIfUnused()
        }

        await stopPreview()
        let audio = captured.exchange([])
        if captureStartedMicrophone || pausePending.value || controller.mode == .paused {
            // Close the microphone if the dictation opened it, or if listening was paused while recording.
            captureStartedMicrophone = false
            await stopMicrophone()
        } else {
            // Voice listening carries on; drop any half-heard phrase from before the key was tapped, and any phrase
            // the segmenter finished while the live preview was being stopped.
            generation.update { $0 += 1 }
            resetSegmenter()
        }

        sounds.play(cancel ? .standby : .stopTyping)
        if cancel {
            report(.info, "Dictation cancelled.")
            return
        }

        guard let model = captureModel ?? englishModel.value, audio.count >= Self.sampleRate / 4 else { return }
        let chunks: [[Float]]
        if let detector = detector.value {
            let speech = try await Blocking.run { try detector.detect(audio) }
            chunks = SpeechSegments.chunk(audio, speech, sampleRate: Self.sampleRate, maxMs: 14000, padMs: 200)
        } else {
            let all = [SpeechRegion(start: 0, end: Double(audio.count) / Double(Self.sampleRate))]
            chunks = SpeechSegments.chunk(audio, all, sampleRate: Self.sampleRate, maxMs: 14000, padMs: 0)
        }

        if chunks.isEmpty {
            report(.info, "I didn't hear any speech.")
            return
        }

        var pieces: [String] = []
        for chunk in chunks {
            let result = try await transcribe(model, chunk)
            let which = model === accurateModel.value
                ? " model=hinglish-accurate" : model === hinglishModel.value ? " model=hinglish" : ""
            let audioMs = chunk.count * 1000 / Self.sampleRate
            Log.info("dictation chunk audio=\(audioMs)ms asr=\(Self.ms(result.elapsed))ms\(which)")
            if model === accurateModel.value && isPromptEcho(result.text) {
                Log.info("dropped a repeat of the vocabulary hint")
                continue
            }

            pieces.append(TranscriptText.clean(result.text))
        }

        try insertDictation(pieces.filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// The recording reached `maxDictationSeconds`: finish it as if the key was tapped.
    func finishAtLimit(_ id: Int) async throws {
        guard capturing.value, id == captureId.value else { return }
        let seconds = settings.maxDictationSeconds
        Log.info("dictation reached the \(seconds)s limit")
        raise(captureStopped, id)
        try await endCapture(cancel: false, onlyId: id)
        let limit = seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
        report(.info, "Dictation stops by itself after \(limit). Tap \(settings.dictationKeyLabel) to keep going.")
    }

    /// The controller's `insertDictation`. If another call was running, which the queue rules out, the text is kept
    /// and typed once that call has ended (the controller's contract).
    private func insertDictation(_ text: String) throws {
        do {
            try controller.insertDictation(text)
        } catch is ControllerBusy {
            enqueue { [self] in try insertDictation(text) }
        }
    }

    // MARK: The live preview

    /// Transcribes the recording so far every 0.6 s and shows it as it grows (C#'s `RunPreviewAsync`).
    private func runPreview(_ model: SpeechModel) async {
        let rate = Self.sampleRate
        var detect: (([Float]) throws -> [SpeechRegion])?
        if let detector = detector.value {
            detect = { try detector.detect($0) }
        }

        let preview = DictationPreview(
            transcribe: { [self] audio in
                // Never cancelled mid-run: the final transcription waits for it.
                let result = try await transcribe(model, audio, cancellable: false)
                let text = TranscriptText.clean(result.text)
                return audio.count < rate * 5 / 2 && Self.isHallucination(text) ? "" : text
            },
            detect: detect,
            sampleRate: rate)
        var seen = 0
        var updates = 0
        var busy: TimeInterval = 0
        var shown: String?
        do {
            while true {
                try await Task.sleep(nanoseconds: Self.previewInterval)
                let committed = preview.committedSamples
                let newAudio: [Float]? = captured.update { audio in
                    guard audio.count - seen >= rate * 3 / 10 else { return nil }
                    seen = audio.count
                    return Array(audio[min(committed, seen)..<seen])
                }

                guard let pending = newAudio, pending.count >= rate / 2 else { continue }
                let started = parts.clock()
                let text = try await preview.update(pending)
                busy += parts.clock() - started
                updates += 1
                let formatted = text.isEmpty
                    ? "" : DotNet.replace(DotNet.replace(formatter.format(text), "\r", ""), "\n", " ↵ ")
                if !Task.isCancelled && formatted != shown {
                    shown = formatted
                    raise(dictationPreview, formatted)
                }
            }
        } catch is CancellationError {
        } catch {
            Log.warn("live preview stopped: \(Log.kind(of: error))")
        }

        if updates > 0 {
            Log.info("live preview updates=\(updates) avg=\(Self.ms(busy / Double(updates)))ms")
        }
    }

    /// Stops the live preview and waits for a pass in progress, so the model is free.
    func stopPreview() async {
        if let task = previewTask.exchange(nil) {
            task.cancel()
            await task.value
        }

        raise(dictationPreview, nil)
    }

    // MARK: Paste last, and text that couldn't be typed

    /// Types the last dictation again where the cursor is.
    public func pasteLastTranscript() {
        enqueue { [self] in try repeatLastTranscript() }
    }

    private func repeatLastTranscript() throws {
        do {
            try controller.repeatLastTranscript()
        } catch is ControllerBusy {
            enqueue { [self] in try repeatLastTranscript() }
        }
    }

    /// Copies dictated text that couldn't be typed (focus moved) to the clipboard, then forgets it.
    public func copyUntypedText() {
        enqueue { [self] in copyUntyped() }
    }

    private func copyUntyped() {
        let text = controller.untypedText
        if !controller.clearUntypedText() {
            enqueue { [self] in copyUntyped() }
            return
        }

        if let text, !text.isEmpty {
            let copy = parts.copyText
            post { copy(text) }
            report(.success, "Copied the untyped text to the clipboard.")
        } else {
            report(.info, "There's no untyped text.")
        }
    }

    // MARK: Hindi + English

    /// Switches dictation between English and Hindi + English (the language hotkey), keeping the fast or accurate
    /// choice. It applies from the next phrase.
    public func toggleDictationLanguage() {
        enqueue { [self] in applyDictationLanguage(!hinglishOn.value, accurateOn.value) }
    }

    /// Sets the dictation language (the menu); `accurate` picks the larger Hindi + English model. Choosing the
    /// current one again retries a model that failed to download or load.
    public func setDictationLanguage(hinglish: Bool, accurate: Bool = false) {
        enqueue { [self] in
            if hinglish != hinglishOn.value || (hinglish && accurate != accurateOn.value) {
                applyDictationLanguage(hinglish, hinglish ? accurate : accurateOn.value)
            } else if hinglish && englishModel.value != nil {
                ensureHinglishLoading()
            }
        }
    }

    private func applyDictationLanguage(_ on: Bool, _ accurate: Bool) {
        hinglishOn.value = on
        accurateOn.value = accurate
        StateFlags.set(paths.hinglishDictationFlag, on)
        StateFlags.set(paths.hinglishAccurateFlag, accurate)
        let name = on ? accurate ? "hinglish-accurate" : "hinglish" : "english"
        Log.info("dictation language: \(name)")
        raise(dictationLanguageChanged, DictationLanguage(hinglish: on, accurate: accurate))
        if !accurate {
            // Not wanted any more: stop its download or load and free its memory (about 1 GB).
            hinglishGate.withLock { accurateLoad }?.cancel()
            releaseAccurateIfUnused()
        }

        if !on {
            report(.info, "Dictation language: English.")
        } else if let ready = hinglishForTyping(), !accurate || ready === accurateModel.value {
            report(
                .info,
                accurate
                    ? "Dictation language: Hindi + English, accurate (slower; Hindi is typed in Roman letters)."
                    : "Dictation language: Hindi + English (Hindi is typed in Roman letters).")
        } else if englishModel.value != nil {
            ensureHinglishLoading()
        }
    }

    /// The model that types Hindi + English: the accurate one when it's chosen and loaded, else the fast one.
    func hinglishForTyping() -> SpeechModel? {
        if accurateOn.value, let accurate = accurateModel.value {
            return accurate
        }

        return hinglishModel.value
    }

    /// The user's vocabulary as a Whisper prompt ("GitHub Copilot, vibe coding, …"); nil when there's none.
    var vocabularyPrompt: String? {
        let words = settings.dictationVocabulary.map { DotNet.trim($0) }.filter { !$0.isEmpty }.prefix(40)
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    /// On near-silence Whisper can repeat its prompt; such text is dropped instead of typed.
    func isPromptEcho(_ text: String) -> Bool {
        guard let prompt = vocabularyPrompt else { return false }
        let heard = TranscriptText.normalize(text)
        return !heard.isEmpty && DotNet.contains(TranscriptText.normalize(prompt), heard)
    }

    /// Frees the accurate model once it's no longer chosen. A recording that started with it keeps it until it has been
    /// transcribed.
    func releaseAccurateIfUnused() {
        guard !accurateOn.value, !capturing.value, let model = accurateModel.exchange(nil) else { return }

        // Freeing waits for a pass in progress, so it happens off the queue.
        DispatchQueue.global(qos: .utility).async { model.close() }
        Log.info("hinglish-accurate model unloaded")
    }

    /// Downloads (the first time) and loads the Hindi + English model or models in the background, so commands keep
    /// working meanwhile. The accurate choice loads both: the fast model drives the live preview.
    func ensureHinglishLoading() {
        hinglishGate.withLock {
            if hinglishModel.value == nil && hinglishLoad == nil {
                hinglishLoad = Task.detached { [self] in await loadHinglish(accurate: false) }
            }

            if accurateOn.value && accurateModel.value == nil && accurateLoad == nil {
                accurateLoad = Task.detached { [self] in await loadHinglish(accurate: true) }
            }
        }
    }

    private func loadHinglish(accurate: Bool) async {
        let file = accurate ? settings.hinglishAccurateModelFile : settings.hinglishModelFile
        let what = accurate ? "accurate Hindi + English model (about 830 MB" : "Hindi + English model (about 80 MB"
        let name = accurate ? "hinglish-accurate" : "hinglish"
        defer {
            // Allows another try after a failure.
            hinglishGate.withLock {
                if accurate {
                    accurateLoad = nil
                } else {
                    hinglishLoad = nil
                }
            }
        }

        do {
            guard try await ensureModel(file, firstRun: false, what: what), let path = parts.models.find(file) else {
                return
            }

            let started = parts.clock()
            let speech = parts.speech

            // Measured on Windows: a word list helps the accurate model spell jargon but makes the fast one output
            // garbage.
            let options = WhisperOptions(
                threads: settings.threads, audioContextSize: settings.audioContextSize,
                prompt: accurate ? vocabularyPrompt : nil)
            let model = try await Blocking.run(cancellable: false) { try speech.loadModel(at: path, options: options) }
            do {
                // Not cancellable: Whisper runs to its end, which must come before the model is freed.
                _ = try await transcribe(model, Self.silence, cancellable: false)
            } catch {
                model.close()
                throw error
            }

            if Task.isCancelled || (accurate && !accurateOn.value) {
                // Another language was chosen (or the app is quitting) while it loaded.
                model.close()
                Log.info("\(name) model no longer needed after loading; unloaded")
                return
            }

            if accurate {
                accurateModel.value = model
            } else {
                hinglishModel.value = model
            }

            Log.info("\(name) model loaded in \(Self.ms(parts.clock() - started)) ms")
            if hinglishOn.value && accurate == accurateOn.value {
                report(
                    .success,
                    accurate
                        ? "Accurate Hindi + English dictation is ready (a few seconds per phrase; Hindi is typed in "
                            + "Roman letters)."
                        : "Hindi + English dictation is ready (Hindi is typed in Roman letters).")
            }
        } catch is CancellationError {
        } catch {
            Log.error("\(name) model load failed: \(Log.kind(of: error))")
            let short = what.components(separatedBy: " (")[0]
            report(.error, "Couldn't load the \(short). Delete it from the models folder and switch it on again.")
        }
    }
}
