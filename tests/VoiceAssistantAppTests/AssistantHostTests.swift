import Foundation
import ThumbFreeCore
import ThumbFreeSpeech
import VoiceAssistantCore
import VoiceAssistantMac
import XCTest
@testable import VoiceAssistantApp

/// The assistant host (windows-voice-assistant `AssistantHost`) on fakes: the microphone, the speech models and the
/// desktop are the test's, the controller, the segmenter and the work queue are the real ones.
final class AssistantHostTests: XCTestCase {
    func testItLoadsTheModelsThenListensForTheWakeWord() async throws {
        let rig = HostRig()
        let listening = await rig.startListening()

        XCTAssertTrue(listening)
        XCTAssertTrue(rig.microphone.isRunning)
        XCTAssertEqual(rig.host.mode, .standby)
        XCTAssertEqual(rig.speech.warmUps, 1)
        XCTAssertEqual(rig.speech.loaded, [FakeModels.small])
        XCTAssertEqual(rig.speech.options[FakeModels.small], WhisperOptions(threads: 4, audioContextSize: 768))
        XCTAssertEqual(
            rig.speech.wakeOptions,
            WhisperOptions(threads: 2, audioContextSize: 256, maxTokens: 8, temperatureFallback: false))
        await rig.close()
    }

    /// ThumbFreeSpeech runs the standby check with exactly Windows' options, on the loaded small.en rather than a
    /// second copy of it (Whisper.net's `WithOptions`).
    func testTheStandbyCheckSharesTheLoadedModelWithWindowsOptions() throws {
        let loaded = Locked<[FakeRecognizer]>([])
        let speech = WhisperSpeech { _, options in
            let recognizer = FakeRecognizer(options)
            loaded.update { $0.append(recognizer) }
            return recognizer
        }

        let model = try speech.loadModel(
            at: "/models/ggml-small.en-q8_0.bin", options: WhisperOptions(threads: 4, audioContextSize: 768))
        _ = try speech.variant(of: model, options: AssistantHost.wakeCheckOptions)

        XCTAssertEqual(loaded.value.count, 1)
        let english = try XCTUnwrap(loaded.value.first)
        XCTAssertEqual(english.options, RecognizerOptions(threads: 4, audioContextSize: 768))
        let standby = RecognizerOptions(
            threads: 2, audioContextSize: 256, prompt: nil, maxTokens: 8, temperatureFallback: false)
        XCTAssertEqual(english.shared.map(\.options), [standby])
    }

    func testTheFirstRunDownloadsTheModelsWithTheProgressInThePill() async throws {
        let rig = HostRig(present: [])
        let listening = await rig.startListening()

        XCTAssertTrue(listening)
        XCTAssertEqual(rig.models.downloads, [FakeModels.small, FakeModels.vad])
        let firstRun = "First run: downloading the speech model (one time, stays on this Mac)…"
        XCTAssertEqual(rig.log.messages.filter { $0 == firstRun }.count, 2)
        XCTAssertTrue(rig.log.labels.contains("Downloading speech model… 50%"))
        XCTAssertTrue(rig.log.labels.contains("Loading speech model…"))
        await rig.close()
    }

    func testAModelItCantDownloadSaysWhereItLooked() async throws {
        var settings = HostRig.settings()
        settings.modelFile = "ggml-custom.bin"
        let rig = HostRig(settings: settings, present: [FakeModels.vad])
        rig.host.start()

        let said = await eventually {
            rig.log.messages.contains("Speech model ggml-custom.bin not found in \(rig.paths.models).")
        }
        XCTAssertTrue(said)
        XCTAssertFalse(rig.microphone.isRunning)
        XCTAssertEqual(rig.host.mode, .paused)
        await rig.close()
    }

    func testHeyJarvisAndACommandPassTheStandbyCheckAndRun() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.speech.wake.hears("Hey Jarvis, open TextEdit.")
        rig.speech.english.hears("Hey Jarvis, open TextEdit.")
        rig.microphone.feed(TestAudio.phrase())

        let opened = await eventually { rig.desktop.opened == ["TextEdit"] }
        XCTAssertTrue(opened)
        XCTAssertEqual(rig.speech.wake.calls.count, 1)
        XCTAssertEqual(rig.speech.english.calls.count, 1)
        XCTAssertTrue(rig.cues.contains(.wake))
        await rig.close()
    }

    func testSpeechWithoutTheWakeWordIsOnlyCheckedInStandby() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.speech.wake.hears("and then we went to the cinema")
        rig.microphone.feed(TestAudio.phrase())

        let checked = await eventually { rig.speech.wake.calls.count == 1 }
        try await rig.settle()
        XCTAssertTrue(checked)
        XCTAssertEqual(rig.speech.english.calls, [])
        await rig.close()
    }

    func testPausingTurnsTheMicrophoneOffAndResumingOn() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.host.toggleListening()

        let paused = await eventually { rig.log.messages.contains("Paused. Microphone is off.") }
        XCTAssertTrue(paused)
        XCTAssertFalse(rig.microphone.isRunning)
        XCTAssertEqual(rig.host.mode, .paused)

        rig.host.toggleListening()
        let resumed = await eventually { rig.log.messages.filter { $0 == HostRig.listening }.count == 2 }
        XCTAssertTrue(resumed)
        XCTAssertTrue(rig.microphone.isRunning)
        await rig.close()
    }

    func testADictationTypesWhatWasSaidAndClosesTheMicrophoneItOpened() async throws {
        var settings = HostRig.settings()
        settings.listenOnStartup = false
        settings.livePreview = false
        let rig = HostRig(settings: settings)
        rig.host.start()
        let ready = await eventually { rig.log.messages.contains("Ready. Press ⌃⇧Space to start listening.") }
        XCTAssertTrue(ready)

        rig.host.beginDictationCapture(1)
        let recording = await eventually { rig.log.labels.contains(DictationLabels.listening) }
        XCTAssertTrue(recording)
        rig.microphone.feed(TestAudio.tone(1))
        rig.speech.english.hears("hello world")
        rig.host.endDictationCapture(cancel: false)

        let typed = await eventually { rig.desktop.typed.count == 1 }
        try await rig.settle()
        XCTAssertTrue(typed)
        XCTAssertEqual(rig.desktop.typed, [DictationFormatter(settings.dictationOptions).format("hello world")])
        XCTAssertFalse(rig.microphone.isRunning)
        XCTAssertEqual(rig.cues, [.startTyping, .stopTyping])
        XCTAssertEqual(Array(rig.log.labels.suffix(3)), [DictationLabels.listening, DictationLabels.transcribing, nil])
        XCTAssertEqual(rig.log.stopped, [])

        // Paste last types it again.
        rig.host.pasteLastTranscript()
        let again = await eventually { rig.desktop.typed.count == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(rig.desktop.typed[1], rig.desktop.typed[0])
        await rig.close()
    }

    func testACancelledDictationTypesNothing() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.host.beginDictationCapture(1)
        let recording = await eventually { rig.log.labels.contains(DictationLabels.listening) }
        XCTAssertTrue(recording)
        rig.microphone.feed(TestAudio.tone(1))
        rig.host.endDictationCapture(cancel: true)

        let cancelled = await eventually { rig.log.messages.contains("Dictation cancelled.") }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(rig.desktop.typed, [])
        XCTAssertEqual(rig.cues.last, .standby)

        // Voice listening opened the microphone, so it stays on.
        XCTAssertTrue(rig.microphone.isRunning)
        await rig.close()
    }

    func testADictationBeforeTheModelHasLoadedSaysSoAndStopsTheKeys() async throws {
        let rig = HostRig()
        await rig.host.startForSelfTest()
        rig.host.beginDictationCapture(4)

        let stopped = await eventually { rig.log.stopped == [4] }
        XCTAssertTrue(stopped)
        XCTAssertTrue(rig.log.messages.contains("Still loading the speech model…"))
        await rig.close()
    }

    func testARecordingStopsByItselfAtTheTimeLimit() async throws {
        var settings = HostRig.settings()
        settings.listenOnStartup = false
        settings.livePreview = false
        settings.maxDictationSeconds = 1
        let rig = HostRig(settings: settings)
        rig.host.start()
        _ = await eventually { rig.log.messages.contains("Ready. Press ⌃⇧Space to start listening.") }
        rig.host.beginDictationCapture(9)
        let recording = await eventually { rig.log.labels.contains(DictationLabels.listening) }
        XCTAssertTrue(recording)
        rig.speech.english.always = "a long note"
        rig.microphone.feed(TestAudio.tone(1.2))

        let said = await eventually {
            rig.log.messages.contains("Dictation stops by itself after 1 seconds. Tap Fn to keep going.")
        }
        XCTAssertTrue(said)
        XCTAssertEqual(rig.log.stopped, [9])
        XCTAssertEqual(rig.desktop.typed, [DictationFormatter(settings.dictationOptions).format("a long note")])
        await rig.close()
    }

    func testTheLivePreviewShowsTheWordsAsTheyAreSaid() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.speech.english.always = "hello there"
        rig.host.beginDictationCapture(1)
        _ = await eventually { rig.log.labels.contains(DictationLabels.listening) }
        rig.microphone.feed(TestAudio.tone(1))

        let expected = DictationFormatter(HostRig.settings().dictationOptions).format("hello there")
        let shown = await eventually { rig.log.previews.contains(expected) }
        XCTAssertTrue(shown)

        rig.host.endDictationCapture(cancel: false)
        let typed = await eventually { rig.desktop.typed == [expected] }
        try await rig.settle()
        XCTAssertTrue(typed)
        XCTAssertTrue(rig.log.previewCleared)
        await rig.close()
    }

    func testHindiAndEnglishLoadsItsModelAndTypesWithIt() async throws {
        var settings = HostRig.settings()
        settings.livePreview = false
        let rig = HostRig(settings: settings, present: [FakeModels.small, FakeModels.vad, FakeModels.hinglish])
        _ = await rig.startListening()
        rig.host.setDictationLanguage(hinglish: true)

        let ready = await eventually {
            rig.log.messages.contains("Hindi + English dictation is ready (Hindi is typed in Roman letters).")
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(rig.host.hinglishDictation)
        XCTAssertFalse(rig.host.hinglishAccurate)
        XCTAssertEqual(rig.log.languages, [DictationLanguage(hinglish: true, accurate: false)])
        XCTAssertTrue(StateFlags.isSet(rig.paths.hinglishDictationFlag))
        XCTAssertNil(rig.speech.options[FakeModels.hinglish]?.prompt)

        rig.host.beginDictationCapture(1)
        _ = await eventually { rig.log.labels.contains(DictationLabels.listening) }
        rig.microphone.feed(TestAudio.tone(1))
        rig.speech.hinglish.hears("kal meeting hai")
        rig.host.endDictationCapture(cancel: false)

        let typed = await eventually { rig.desktop.typed.count == 1 }
        XCTAssertTrue(typed)
        XCTAssertEqual(rig.desktop.typed, [DictationFormatter(settings.dictationOptions).format("kal meeting hai")])
        XCTAssertEqual(rig.speech.english.calls, [])
        await rig.close()
    }

    func testTheAccurateModelsRepeatOfTheVocabularyIsntTypedAndLeavingItFreesTheModel() async throws {
        var settings = HostRig.settings()
        settings.livePreview = false
        let rig = HostRig(
            settings: settings,
            present: [FakeModels.small, FakeModels.vad, FakeModels.hinglish, FakeModels.accurate])
        _ = await rig.startListening()
        rig.host.setDictationLanguage(hinglish: true, accurate: true)

        let ready = await eventually {
            rig.log.messages.contains(
                "Accurate Hindi + English dictation is ready (a few seconds per phrase; Hindi is typed in Roman "
                    + "letters).")
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(
            rig.speech.options[FakeModels.accurate]?.prompt,
            "GitHub Copilot, vibe coding, iterate, pull request, commit")

        rig.host.beginDictationCapture(1)
        _ = await eventually { rig.log.labels.contains(DictationLabels.listening) }
        rig.microphone.feed(TestAudio.tone(1))
        rig.speech.accurate.hears("GitHub Copilot, vibe coding")
        rig.host.endDictationCapture(cancel: false)

        let dropped = await eventually { rig.log.messages.contains("I didn't catch anything to type.") }
        XCTAssertTrue(dropped)
        XCTAssertEqual(rig.desktop.typed, [])

        rig.host.setDictationLanguage(hinglish: true, accurate: false)
        let freed = await eventually { rig.speech.accurate.closed }
        XCTAssertTrue(freed)
        XCTAssertFalse(StateFlags.isSet(rig.paths.hinglishAccurateFlag))
        await rig.close()
    }

    func testTextThatCouldntBeTypedIsCopiedOnRequest() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.host.copyUntypedText()
        let none = await eventually { rig.log.messages.contains("There's no untyped text.") }
        XCTAssertTrue(none)

        // Voice typing into a field that can't be checked keeps the text instead of typing it.
        rig.desktop.field = .unknown
        let host = rig.host
        try await host.runOnQueue { try await host.controller.handleTranscript("Hey Jarvis, start typing.", 0.9) }
        try await host.runOnQueue { try await host.controller.handleTranscript("hello there", 0.9) }
        try await rig.settle()
        XCTAssertEqual(rig.log.untyped, [true])
        XCTAssertEqual(rig.desktop.typed, [])

        rig.host.copyUntypedText()
        let copied = await eventually { rig.log.messages.contains("Copied the untyped text to the clipboard.") }
        try await rig.settle()
        XCTAssertTrue(copied)
        XCTAssertEqual(rig.copied, ["hello there"])
        XCTAssertEqual(rig.log.untyped, [true, false])
        await rig.close()
    }

    func testForgettingDeletesWhatWasLearned() async throws {
        let rig = HostRig { paths in
            let memory = PhraseMemory()
            memory.recordAppUse("Notes")
            LearnedStore(path: paths.learnedFile).save(memory)
        }
        XCTAssertTrue(TestFiles.exists(rig.paths.learnedFile))
        await rig.host.startForSelfTest()
        rig.host.forgetLearned()

        let forgot = await eventually { rig.log.messages.contains("Forgot everything I'd learned.") }
        XCTAssertTrue(forgot)
        XCTAssertFalse(TestFiles.exists(rig.paths.learnedFile))
        XCTAssertEqual(rig.host.memory?.appUses.count, 0)
        await rig.close()
    }

    func testSpeechWhileTheBrainWorksIsDroppedAndEscStopsIt() async throws {
        let brain = FakeBrain()
        let rig = HostRig(brain: brain)
        _ = await rig.startListening()
        let request = "Hey Jarvis, what's the weather in Bangalore?"
        rig.speech.wake.hears(request)
        rig.speech.english.hears(request)
        rig.microphone.feed(TestAudio.phrase())

        let thinking = await eventually { brain.requests == 1 }
        XCTAssertTrue(thinking)
        XCTAssertTrue(rig.host.controller.isBrainRunning)

        rig.microphone.feed(TestAudio.phrase())
        let dropped = await eventually {
            rig.log.messages.contains("Still working on your last request. Press Esc to stop it.")
        }
        XCTAssertTrue(dropped)

        rig.host.cancelBrainAction()
        let stopped = await eventually { rig.log.messages.contains("Stopped.") }
        XCTAssertTrue(stopped)

        // The brain's run ends just after it says so.
        let ended = await eventually { !rig.host.controller.isBrainRunning }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.speech.english.calls.count, 1)
        await rig.close()
    }

    func testAFinishedBrainDownloadSaysTheBrainIsReady() async throws {
        let brain = FakeBrain()
        let rig = HostRig(brain: brain)
        rig.host.startBrainDownload()
        brain.change(to: .downloading(received: 8 << 20, total: 2 << 30))
        XCTAssertEqual(rig.host.brainDownloadProgress?.received, Int64(8 << 20))
        brain.change(to: .installed)

        // Both changes have posted their events by now.
        rig.events.sync {}
        XCTAssertTrue(
            rig.log.messages.contains(
                "The AI brain is ready. Ask for anything, like “open the MrBeast video on YouTube”."))
        XCTAssertEqual(rig.log.brain, [.downloading(received: 8 << 20, total: 2 << 30), .installed])
        XCTAssertEqual(brain.calls, ["startDownload"])
        XCTAssertNil(rig.host.brainDownloadProgress)
        await rig.close()
        XCTAssertEqual(brain.calls, ["startDownload", "shutdown"])
    }

    func testAMicrophoneThatStopsSaysHowToStartAgain() async throws {
        let rig = HostRig()
        _ = await rig.startListening()
        rig.microphone.fail()

        let said = await eventually {
            rig.log.messages.contains("The microphone stopped. Press ⌃⇧Space to try again.")
        }
        XCTAssertTrue(said)
        XCTAssertEqual(rig.host.mode, .paused)
        await rig.close()
    }

    func testAMicrophoneItMayNotUseSaysWhereToAllowIt() async throws {
        let rig = HostRig()
        rig.microphone.startError = SystemMicrophone.Problem.notAllowed
        rig.host.start()

        let said = await eventually { rig.log.messages.contains(AssistantHost.microphoneProblem) }
        XCTAssertTrue(said)
        XCTAssertEqual(rig.host.mode, .paused)
        await rig.close()
    }

    func testWorkThatFailsSaysSoAndTheQueueCarriesOn() async throws {
        struct Broken: LocalizedError {
            var errorDescription: String? { "The box went away." }
        }

        let rig = HostRig()
        await rig.host.startForSelfTest()
        let ran = Locked(false)
        rig.host.enqueue { throw Broken() }
        rig.host.enqueue { ran.value = true }
        try await rig.settle()

        XCTAssertTrue(rig.log.messages.contains("That didn't work: The box went away."))
        XCTAssertTrue(ran.value)
        await rig.close()
    }

    func testQuittingStopsTheBrainAndFreesTheModels() async throws {
        let brain = FakeBrain()
        let rig = HostRig(brain: brain)
        _ = await rig.startListening()
        await rig.host.shutdown()

        XCTAssertEqual(brain.calls, ["shutdown"])
        XCTAssertFalse(rig.microphone.isRunning)
        XCTAssertTrue(rig.speech.english.closed)
        XCTAssertTrue(rig.speech.wake.closed)
        rig.folder.remove()
    }
}
