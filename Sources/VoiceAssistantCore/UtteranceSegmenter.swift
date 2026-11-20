import Foundation

public struct SegmenterOptions: Equatable, Sendable {
    public var sampleRate: Int

    public var frameMs: Int

    /// The pause that ends an utterance. Commands must be separated from dictation by at least this pause.
    public var endSilenceMs: Int

    /// The share of frames in the last `endSilenceMs` that must be quiet to end an utterance. Below 1 so a burst of
    /// background music or a click during the pause doesn't keep the utterance open.
    public var endQuietFraction: Double

    public var preRollMs: Int

    public var minSpeechMs: Int

    /// The longest utterance; it must stay below the recognizer's audio context (768 tokens are 15.36 s).
    public var maxUtteranceMs: Int

    /// Loud frames in a row that start an utterance.
    public var startFrames: Int

    /// Recent non-speech audio used to estimate the background level.
    public var backgroundWindowMs: Int

    /// Speech must be this much louder than the background to start an utterance.
    public var startAboveBackgroundDb: Double

    /// Frames this much louder than the background count as speech while an utterance is open.
    public var continueAboveBackgroundDb: Double

    /// The quietest speech, so near-silent rooms don't start utterances on hiss.
    public var minSpeechDbfs: Double

    public init(
        sampleRate: Int = 16000,
        frameMs: Int = 30,
        endSilenceMs: Int = 600,
        endQuietFraction: Double = 0.8,
        preRollMs: Int = 300,
        minSpeechMs: Int = 200,
        maxUtteranceMs: Int = 14000,
        startFrames: Int = 3,
        backgroundWindowMs: Int = 5000,
        startAboveBackgroundDb: Double = 10,
        continueAboveBackgroundDb: Double = 6,
        minSpeechDbfs: Double = -55
    ) {
        self.sampleRate = sampleRate
        self.frameMs = frameMs
        self.endSilenceMs = endSilenceMs
        self.endQuietFraction = endQuietFraction
        self.preRollMs = preRollMs
        self.minSpeechMs = minSpeechMs
        self.maxUtteranceMs = maxUtteranceMs
        self.startFrames = startFrames
        self.backgroundWindowMs = backgroundWindowMs
        self.startAboveBackgroundDb = startAboveBackgroundDb
        self.continueAboveBackgroundDb = continueAboveBackgroundDb
        self.minSpeechDbfs = minSpeechDbfs
    }
}

/// A pause-delimited stretch of 16 kHz mono audio. `followsForcedCut`: the previous utterance was cut at the length
/// cap mid-speech, so this one continues a sentence and must never be taken as a command on its own.
public struct Utterance: Equatable, Sendable {
    public var samples: [Float]
    public var followsForcedCut: Bool

    public init(samples: [Float], followsForcedCut: Bool) {
        self.samples = samples
        self.followsForcedCut = followsForcedCut
    }
}

/// An energy-based voice activity detector that splits a 16 kHz mono stream into pause-delimited utterances. The
/// background level is the median of recent non-speech frames, which stays meaningful with fans, music or meeting
/// audio in the room (a minimum-tracking floor sits far below such noise and makes every pause look like speech).
/// Not thread-safe: feed it from one capture thread. Only `longPauseMs` may be set from another thread.
public final class UtteranceSegmenter {
    private static let defaultBackgroundDb = -60.0
    private static let warmUpFrames = 10
    private static let steadySoundRangeDb = 12.0

    private let o: SegmenterOptions
    private let frameSamples: Int
    private var frame: [Float]
    private var preRoll: [[Float]] = []
    private var utterance: [Float] = []
    private var utteranceLevels: [Double] = []
    private var background: [Double]
    private var endWindow: [Bool]
    private var backgroundCount = 0
    private var backgroundNext = 0
    private var backgroundDb = UtteranceSegmenter.defaultBackgroundDb
    private var endWindowNext = 0
    private var endWindowQuiet = 0
    private var frameFill = 0
    private var speaking = false
    private var afterForcedCut = false
    private var quietFrames = 0
    private var loudRun = 0
    private var speechFrames = 0
    private var quietFlags: [Bool] = []
    private let pauseLock = NSLock()
    private var longPause = 0

    public init(_ options: SegmenterOptions = SegmenterOptions()) {
        o = options
        frameSamples = options.sampleRate * options.frameMs / 1000
        frame = [Float](repeating: 0, count: frameSamples)
        background = [Double](repeating: 0, count: max(1, options.backgroundWindowMs / options.frameMs))
        endWindow = [Bool](repeating: false, count: max(1, options.endSilenceMs / options.frameMs))
    }

    /// An utterance ended (C#'s `UtteranceReady` event).
    public var onUtteranceReady: ((Utterance) -> Void)?

    /// Speech started (C#'s `SpeechStarted` event).
    public var onSpeechStarted: (() -> Void)?

    public var inSpeech: Bool { speaking }

    /// While typing, a longer pause ends a phrase: the same quiet share must hold over this many ms (when longer than
    /// `endSilenceMs`), so thinking pauses mid-sentence don't split it into separately punctuated pieces. 0 uses
    /// `endSilenceMs`. Safe to set from another thread.
    public var longPauseMs: Int {
        get {
            pauseLock.lock()
            defer { pauseLock.unlock() }
            return longPause
        }
        set {
            pauseLock.lock()
            longPause = max(0, newValue)
            pauseLock.unlock()
        }
    }

    /// The background (noise) level estimate in dBFS.
    public var noiseFloorDb: Double { backgroundDb }

    /// Drops any utterance in progress. The background estimate stays: it describes the room, not the utterance.
    public func reset() {
        preRoll.removeAll()
        utterance.removeAll()
        utteranceLevels.removeAll()
        quietFlags.removeAll()
        frameFill = 0
        speaking = false
        afterForcedCut = false
        quietFrames = 0
        loudRun = 0
        speechFrames = 0
        clearEndWindow()
    }

    public func push<C: Collection>(_ samples: C) where C.Element == Float {
        var rest = samples[...]
        while !rest.isEmpty {
            let take = min(frameSamples - frameFill, rest.count)
            let end = rest.index(rest.startIndex, offsetBy: take)
            for sample in rest[..<end] {
                frame[frameFill] = sample
                frameFill += 1
            }

            rest = rest[end...]
            if frameFill == frameSamples {
                processFrame(frame)
                frameFill = 0
            }
        }
    }

    /// Ends any utterance in progress (when listening stops).
    public func flush() {
        if speaking {
            emit(forcedCut: false)
        }

        reset()
    }

    /// The frame's level: 20·log10 of its root mean square (at least 1e-9).
    public static func levelDbfs<C: Collection>(_ frame: C) -> Double where C.Element == Float {
        var sum = 0.0
        for s in frame {
            // As C#: the square in single precision, the sum in double.
            sum += Double(s * s)
        }

        let rms = (sum / Double(max(1, frame.count))).squareRoot()
        return 20 * log10(max(rms, 1e-9))
    }

    private func processFrame(_ frame: [Float]) {
        let db = Self.levelDbfs(frame)
        let startThreshold = max(backgroundDb + o.startAboveBackgroundDb, o.minSpeechDbfs)
        let continueThreshold = max(backgroundDb + o.continueAboveBackgroundDb, o.minSpeechDbfs - 4)

        if !speaking {
            preRoll.append(frame)
            while preRoll.count > o.preRollMs / o.frameMs {
                preRoll.removeFirst()
            }

            // Learn the room for the first ~300 ms before allowing speech, so a loud room isn't one long utterance.
            if backgroundCount < Self.warmUpFrames {
                addBackground(db)
                return
            }

            if db >= startThreshold {
                loudRun += 1
                if loudRun >= o.startFrames {
                    startUtterance()
                }

                return
            }

            loudRun = 0
            addBackground(db)
            if afterForcedCut {
                quietFrames += 1
                if quietFrames * o.frameMs >= o.endSilenceMs {
                    // A real pause after a length-capped cut means the next phrase is a fresh utterance again.
                    afterForcedCut = false
                }
            }

            return
        }

        utterance.append(contentsOf: frame)
        utteranceLevels.append(db)
        let quiet = db < continueThreshold
        if !quiet {
            speechFrames += 1
        }

        pushEndWindow(quiet)
        quietFlags.append(quiet)
        let windowFull = utteranceLevels.count >= endWindow.count
        let durationMs = utterance.count * 1000 / o.sampleRate
        if windowFull && Double(endWindowQuiet) >= (Double(endWindow.count) * o.endQuietFraction).rounded(.up)
            && longPauseHeld() {
            emit(forcedCut: false)
        } else if durationMs >= o.maxUtteranceMs {
            // No pause for the whole cap: a long sentence, or steady background (fan, hum) louder than the estimate.
            // Steady sound has little dynamic range; speech has syllables and gaps. Only for steady sound, adopt its
            // level as the background so it stops looking like endless speech.
            let sorted = utteranceLevels.sorted()
            let p10 = sorted[sorted.count / 10]
            let p90 = sorted[sorted.count * 9 / 10]
            if p90 - p10 < Self.steadySoundRangeDb {
                let level = sorted[sorted.count / 2]
                for _ in 0...(background.count / 2) {
                    addBackground(level)
                }
            }

            emit(forcedCut: true)
        }
    }

    private func startUtterance() {
        speaking = true
        speechFrames = loudRun
        clearEndWindow()
        for frame in preRoll {
            utterance.append(contentsOf: frame)
        }

        preRoll.removeAll()
        onSpeechStarted?()
    }

    private func emit(forcedCut: Bool) {
        let enoughSpeech = speechFrames * o.frameMs >= o.minSpeechMs
        let ready = Utterance(samples: utterance, followsForcedCut: afterForcedCut)

        // Quiet frames already at the end of a capped utterance count toward the pause that clears the flag.
        afterForcedCut = forcedCut && endWindowQuiet * o.frameMs < o.endSilenceMs
        quietFrames = endWindowQuiet
        utterance.removeAll()
        utteranceLevels.removeAll()
        quietFlags.removeAll()
        speaking = false
        loudRun = 0
        speechFrames = 0
        clearEndWindow()
        if enoughSpeech {
            onUtteranceReady?(ready)
        }
    }

    /// With `longPauseMs` set, the same quiet share must hold over that longer stretch.
    private func longPauseHeld() -> Bool {
        let frames = longPauseMs / o.frameMs
        if frames <= endWindow.count {
            return true
        }

        if quietFlags.count < frames {
            return false
        }

        let quiet = quietFlags[(quietFlags.count - frames)...].filter { $0 }.count
        return Double(quiet) >= (Double(frames) * o.endQuietFraction).rounded(.up)
    }

    private func addBackground(_ db: Double) {
        background[backgroundNext] = db
        backgroundNext = (backgroundNext + 1) % background.count
        backgroundCount = min(backgroundCount + 1, background.count)
        backgroundDb = background[..<backgroundCount].sorted()[backgroundCount / 2]
    }

    private func pushEndWindow(_ quiet: Bool) {
        if endWindow[endWindowNext] {
            endWindowQuiet -= 1
        }

        endWindow[endWindowNext] = quiet
        if quiet {
            endWindowQuiet += 1
        }

        endWindowNext = (endWindowNext + 1) % endWindow.count
    }

    private func clearEndWindow() {
        for i in endWindow.indices {
            endWindow[i] = false
        }

        endWindowNext = 0
        endWindowQuiet = 0
    }
}
