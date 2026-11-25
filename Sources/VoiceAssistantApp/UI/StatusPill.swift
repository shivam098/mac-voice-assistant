import Foundation
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantCore

/// The status pill at the bottom of the screen (windows-voice-assistant `OverlayWindow`): whether the assistant is
/// waiting for "Hey Jarvis", listening for a command, typing or paused; a dictation's level meter, the words heard so
/// far and "Transcribing…"; and messages, with what was heard and where the assistant acted. It's on screen all the
/// time unless minimized, and then only while there's something to show. `Model` decides what it shows, with the same
/// states, texts, colours and timings as Windows; `Panel` puts that on screen. ThumbFree's pill (ThumbFreeMac `Pill`)
/// is the dictation-only version of the same Windows pill: its colours and its placing are used here.
public enum StatusPill {
    /// The activity while a dictation records: the level meter, the words heard so far and how to finish (Windows'
    /// `DictationLabels.Listening`, which the assistant host sends).
    public static let listening = "Listening…"

    /// The activity once a recording has stopped, while its speech is turned into text (`DictationLabels.Transcribing`).
    public static let transcribing = "Transcribing…"

    /// What the app says once the pill is minimized (Windows' tray balloon; the Mac's is `MenuBar.showBalloon`).
    public static let minimizedNote =
        "The status pill now appears only while you dictate or give a command. "
        + "Menu bar icon › Always show status pill brings it back."

    /// The pill's colours (OverlayWindow.xaml), with ThumbFree's names where the pills share one.
    public enum Colours {
        public static let typing = Colour.recording
        public static let command = Colour(0x4C8DF6)
        public static let standby = Colour(0x8AB4F8)
        public static let paused = Colour.muted
        public static let busy = Colour.busy
        public static let place = Colour(0x8AB4F8)
    }

    /// What the pill draws now. Nil parts aren't shown.
    public struct Display: Equatable, Sendable {
        /// "Say “Hey Jarvis” · tap Fn to dictate", "Listening…", "Transcribing" (its dots follow), another activity, or
        /// "Starting…" before the first mode.
        public let mode: String
        /// After "Transcribing": "", ".", ".." or "...", in a slot of their own so the text doesn't move.
        public let dots: String?
        /// The dot before the text; nil while listening, when the level meter takes its place.
        public let dot: Colour?
        /// The dot fades in and out (`Model.pulseTime` each way) while transcribing.
        public let dotPulses: Bool
        /// The level meter's five bars, in points (4 to 18), while listening.
        public let bars: [Double]?
        /// "HI + EN" while dictation is in Hindi + English.
        public let badge: String?
        /// "📍 Chrome › YouTube": where the latest message's command left the assistant.
        public let place: String?
        /// The words heard so far.
        public let preview: String?
        /// Dimmed while transcribing.
        public let previewOpacity: Double
        /// How to finish, while listening.
        public let hint: String?
        public let message: String?
        public let messageColour: Colour
        /// "Heard: “…”".
        public let heard: String?
    }

    /// What the pill shows: Windows' OverlayWindow without the window, so it can be tested. The panel calls
    /// `fadeStatus` `messageTime` after the latest `showStatus`, and `advanceDots` every `dotsInterval` while
    /// transcribing.
    public struct Model: Equatable, Sendable {
        /// How long a message, what was heard and the place stay after the latest status.
        public static let messageTime: TimeInterval = 6
        /// How often the dots after "Transcribing" move.
        public static let dotsInterval: TimeInterval = 0.35
        /// How long the dot takes to fade out, or back in, while transcribing.
        public static let pulseTime: TimeInterval = 0.5
        /// The pill fades in over 140 ms when it appears, and out over 220 ms when it goes.
        public static let fadeInMilliseconds = 140
        public static let fadeOutMilliseconds = 220
        /// The most of the words heard that's shown (the latest), in UTF-16 units as on Windows.
        public static let previewLimit = 150

        /// The level meter's bars, middle tallest.
        static let barWeights: [Double] = [0.55, 0.8, 1.0, 0.8, 0.55]

        /// There's no wake word, so listening for a command is the resting state: it doesn't keep a minimized pill on
        /// screen.
        public let commandModeIsIdle: Bool
        /// The dictation key, as the texts name it ("Fn", "Right Option").
        public var keyName: String
        public private(set) var mode = InteractionMode.paused
        /// A mode has been shown; until then the pill says "Starting…".
        public private(set) var started = false
        /// `StatusPill.listening`, `StatusPill.transcribing`, or another short label such as "Hearing you…"; nil while
        /// there's none.
        public private(set) var activity: String?
        /// A dictation owns the pill, from its recording until its text is typed.
        public private(set) var dictating = false
        /// The voice level, 0 to 1: up at once, down gently.
        public private(set) var level: Double = 0
        public private(set) var bars = Model.heights(0) { 1 }
        public private(set) var dotCount = 0
        public private(set) var preview: String?
        public private(set) var message: String?
        public private(set) var messageKind = StatusKind.info
        public private(set) var heard: String?
        public private(set) var place: String?
        public private(set) var hinglish = false
        public private(set) var accurate = false
        public private(set) var minimized: Bool
        /// On screen: always unless minimized, and then while busy. The minimize button takes it off at once, busy or
        /// not, until the next change brings it back.
        public private(set) var isShown: Bool

        /// - Parameter minimized: Starts minimized (the pill's state flag), so it doesn't show first.
        public init(commandModeIsIdle: Bool = false, keyName: String = "Fn", minimized: Bool = false) {
            self.commandModeIsIdle = commandModeIsIdle
            self.keyName = keyName
            self.minimized = minimized
            isShown = !minimized
        }

        /// Something to show that keeps a minimized pill on screen: typing, listening for a command (when that isn't
        /// the resting state), an activity, the words heard, a message or what was heard.
        public var isBusy: Bool {
            mode == .dictation || (mode == .command && !commandModeIsIdle) || activity != nil || preview != nil
                || message != nil || heard != nil
        }

        /// "Transcribing" with its moving dots is showing.
        public var isTranscribing: Bool { activity == StatusPill.transcribing }

        /// Minimizes the pill or brings it back (Windows' `Minimized`). True when that changed it.
        @discardableResult
        public mutating func setMinimized(_ minimized: Bool) -> Bool {
            guard self.minimized != minimized else { return false }
            self.minimized = minimized
            updateVisibility()
            return true
        }

        /// The minimize button: minimized, and off the screen at once, busy or not. True when it wasn't minimized.
        @discardableResult
        public mutating func minimizeNow() -> Bool {
            let changed = setMinimized(true)
            isShown = false
            return changed
        }

        /// Shows `mode`, or `activity` instead when there is one (Windows' `ShowMode`). A dictation's
        /// `StatusPill.listening` shows the level meter and how to finish, then its `StatusPill.transcribing` animates
        /// until the text is typed; meanwhile the voice's activities don't replace them.
        public mutating func showMode(_ mode: InteractionMode, activity: String? = nil) {
            var activity = activity
            if dictating, let label = activity, label != StatusPill.listening, label != StatusPill.transcribing {
                // A dictation owns the pill until its text is typed; voice activity must not hide its meter.
                activity = self.activity
            }

            let wasListening = self.activity == StatusPill.listening
            let wasTranscribing = self.activity == StatusPill.transcribing
            let wasDictationTranscribing = dictating && wasTranscribing
            self.mode = mode
            self.activity = activity
            started = true
            let listening = activity == StatusPill.listening
            let transcribing = activity == StatusPill.transcribing

            // Only the Transcribing that follows a dictation's recording belongs to it (commands are transcribed too).
            dictating = listening || (transcribing && dictating)
            if listening && !wasListening {
                level = 0
                bars = Self.heights(0) { 1 }
            }

            if transcribing && !wasTranscribing {
                dotCount = 0
            }

            if wasDictationTranscribing && !dictating {
                // The words heard stayed on screen while transcribing; the typed text replaces them.
                preview = nil
            }

            updateVisibility()
        }

        /// Moves the level meter while a dictation records (`level` from 0 to 1). `jitter` (0 to 1) wobbles the bars a
        /// little.
        public mutating func showInputLevel(_ level: Float, jitter: () -> Double = { Double.random(in: 0..<1) }) {
            guard activity == StatusPill.listening else { return }

            // Rise at once, fall back gently, like a VU meter.
            let now = Double(level)
            self.level = now > self.level ? now : self.level * 0.6 + now * 0.4
            bars = Self.heights(self.level, jitter: jitter)
        }

        /// A status line (Windows' `ShowStatus`): its mode, and its message in the kind's colour with what was heard and
        /// where, until `fadeStatus`. A dictation's recording or transcription stays on screen meanwhile.
        public mutating func showStatus(_ update: AssistantStatus) {
            showMode(update.mode, activity: dictating ? activity : nil)
            message = update.message.isEmpty ? nil : update.message
            messageKind = update.kind
            heard = update.heard.flatMap { $0.isEmpty ? nil : "Heard: “\($0)”" }
            // The place shows with the message that put the assistant there, so it is never stale.
            place = update.place.flatMap { $0.isEmpty ? nil : "📍 " + $0 }
            updateVisibility()
        }

        /// The message, what was heard and the place go, `messageTime` after the latest status.
        public mutating func fadeStatus() {
            message = nil
            heard = nil
            place = nil
            updateVisibility()
        }

        /// The "HI + EN" badge while dictation is in Hindi + English ("HI + EN · accurate" with the larger model).
        public mutating func setDictationLanguage(hinglish: Bool, accurate: Bool) {
            self.hinglish = hinglish
            self.accurate = accurate
        }

        /// The words heard so far while a dictation records; nil or empty hides them, except while that dictation is
        /// transcribed, when the last words stay until its text is typed. Long text keeps its latest words. Hides the
        /// message and what was heard.
        public mutating func showPreview(_ text: String?) {
            guard let text, !text.isEmpty else {
                if dictating && activity == StatusPill.transcribing {
                    // Keep the last words on screen until the transcription is typed.
                    return
                }

                preview = nil
                updateVisibility()
                return
            }

            preview = Self.latestWords(text)
            message = nil
            heard = nil
            updateVisibility()
        }

        /// The dots after "Transcribing" move on: "", ".", "..", "...", then "" again.
        public mutating func advanceDots() {
            dotCount = (dotCount + 1) % 4
        }

        public var display: Display {
            let listening = activity == StatusPill.listening
            let transcribing = activity == StatusPill.transcribing
            var text: String
            var dot: Colour
            if !started {
                text = "Starting…"
                dot = Colours.paused
            } else {
                switch mode {
                case .dictation:
                    text = "Typing — say “stop typing” when done"
                    dot = Colours.typing
                case .command:
                    text = "Listening for a command"
                    dot = Colours.command
                case .standby:
                    text = "Say “Hey Jarvis” · tap \(keyName) to dictate"
                    dot = Colours.standby
                case .paused:
                    text = "Paused · tap \(keyName) to dictate"
                    dot = Colours.paused
                }
            }

            if let activity {
                text = transcribing ? Self.trimmingEllipsis(activity) : activity
                dot = listening ? Colours.typing : Colours.busy
            }

            let colour: Colour
            switch messageKind {
            case .warning: colour = .warning
            case .error: colour = .error
            case .success: colour = .ready
            case .info: colour = .text
            }

            return Display(
                mode: text,
                dots: transcribing ? String(repeating: ".", count: dotCount) : nil,
                dot: listening ? nil : dot,
                dotPulses: transcribing,
                bars: listening ? bars : nil,
                badge: hinglish ? (accurate ? "HI + EN · accurate" : "HI + EN") : nil,
                place: place,
                preview: preview,
                previewOpacity: transcribing ? 0.6 : 1,
                hint: listening ? "\(keyName) to finish · Esc to cancel" : nil,
                message: message,
                messageColour: colour,
                heard: heard)
        }

        /// Always on screen unless minimized; minimized, only while busy (Windows' `UpdateVisibility`).
        private mutating func updateVisibility() {
            isShown = !minimized || isBusy
        }

        /// The bars' heights for `level`: 4 points, up to 18 for the middle one at full level, each wobbling by up to
        /// 20% once there's sound (Windows' `SetBars`; ThumbFreeMac `Pill.Model.heights`, which isn't public).
        static func heights(_ level: Double, jitter: () -> Double) -> [Double] {
            barWeights.map { weight in
                let wobble = level > 0.05 ? 0.8 + jitter() * 0.4 : 1
                return 4 + 14 * min(max(level * weight * wobble, 0), 1)
            }
        }

        /// The last `previewLimit` UTF-16 units after "…", from the first word that starts in them (Windows'
        /// `ShowPreview`). A cut never splits a character made of two units. ThumbFreeMac `Pill.Model.latestWords`,
        /// which isn't public.
        static func latestWords(_ text: String) -> String {
            let units = Array(text.utf16)
            guard units.count > previewLimit else { return text }
            let start = units.count - previewLimit
            var from = start
            if let space = units[start...].firstIndex(of: 0x20), space > 0, space < units.count - 1 {
                from = space + 1
            }

            while from < units.count, UTF16.isTrailSurrogate(units[from]) {
                from += 1
            }

            return "…" + String(decoding: units[from...], as: UTF16.self)
        }

        /// "Transcribing…" without its "…" (C#'s `TrimEnd('…')`): the moving dots take its place.
        static func trimmingEllipsis(_ text: String) -> String {
            var trimmed = Substring(text)
            while trimmed.hasSuffix("…") {
                trimmed = trimmed.dropLast()
            }

            return String(trimmed)
        }
    }
}
