import AppKit
import SwiftUI
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore

/// Home (windows-voice-assistant `HomePage`): whether it's listening, with the button that pauses or starts it; the
/// dictation language; the next reminders; a quick start; and what happened this session (never saved). The Mac's
/// addition: a card at the top that names the permissions macOS hasn't given yet, each with a button that asks for it
/// or opens System Settings where it's switched on.
@MainActor
public final class HomeModel: ObservableObject {
    /// How the status card shows a mode.
    public struct ModeLine: Equatable, Sendable {
        public let title: String
        public let hint: String
        public let colour: Colour
        /// The button: "Pause listening" or "Start listening".
        public let toggle: String
    }

    /// A line of text in its colour.
    public struct Line: Equatable, Identifiable, Sendable {
        public let id: Int
        public let text: String
        public let colour: Colour
    }

    /// The most lines of recent activity kept.
    public nonisolated static let maxActivity = 30

    /// The dictation language's choices, in order: English, then Hindi + English with the fast or the accurate model.
    public nonisolated static let languages = [
        "English", "Hindi + English: fast (typed in Roman letters)",
        "Hindi + English: accurate (slower, 830 MB download)",
    ]

    /// What "Recent activity" says before anything happens.
    public nonisolated static let noActivity = "Nothing yet this session."

    /// What "Coming up" says without reminders.
    public nonisolated static let noReminders =
        "No reminders. Try “Hey Jarvis, remind me to call mom tomorrow at 5 pm”."

    @Published public private(set) var mode: InteractionMode
    /// 0 English, 1 Hindi + English (fast), 2 Hindi + English (accurate).
    @Published public private(set) var languageIndex: Int
    /// The next four open reminders.
    @Published public private(set) var upcoming: [Line] = []
    /// This session's messages, newest first.
    @Published public private(set) var activity: [Line] = []
    /// What macOS hasn't allowed yet.
    @Published public private(set) var permissions: [PermissionRow] = []

    /// Opens the window at the board ("Open board": the whole board).
    public var openBoard: @MainActor (BoardList?) -> Void = { _ in }

    public let keys: KeyNames
    private let assistant: AssistantControls
    private let board: BoardStore?
    private let checks: Permissions
    private let dictationKeyOn: Bool
    private let clock: () -> Date
    private let timeZone: TimeZone
    private var lines = 0
    /// What macOS has been asked for here (Accessibility, Input Monitoring): it shows its prompt once, so their
    /// buttons open System Settings after.
    private var asked: Set<Permissions.Kind> = []

    /// - Parameters:
    ///   - board: Where the reminders are; nil shows none.
    ///   - permissions: What macOS allows.
    ///   - dictationKeyOn: Tapping the dictation key dictates (`pushToTalk`), so the key may need Input Monitoring.
    ///   - clock: Now, for the activity's times and which reminders are due.
    ///   - timeZone: The wall clock the times are on.
    public init(
        assistant: AssistantControls, board: BoardStore?, keys: KeyNames, permissions: Permissions = Permissions(),
        dictationKeyOn: Bool, clock: @escaping () -> Date = { Date() }, timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.assistant = assistant
        self.board = board
        self.keys = keys
        checks = permissions
        self.dictationKeyOn = dictationKeyOn
        self.clock = clock
        self.timeZone = timeZone
        mode = assistant.mode
        languageIndex = Self.languageIndex(hinglish: assistant.hinglishDictation, accurate: assistant.hinglishAccurate)
        board?.onChange { [weak self] in
            // The board tells on the thread that changed it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshReminders()
                }
            }
        }

        refreshReminders()
        refreshPermissions()
    }

    /// The status card's mode.
    public var modeLine: ModeLine { Self.modeLine(mode, key: keys.dictation) }

    /// Under the language's choice: the hotkey that switches it, when there is one.
    public var languageHint: String {
        let commands = "Voice commands are always English."
        let hotkey = keys.hotkeys.language
        return hotkey.isEmpty ? commands : "\(hotkey) switches between English and Hindi + English. \(commands)"
    }

    /// The quick start's tips, naming the dictation key.
    public var tips: [String] { Self.tips(key: keys.dictation) }

    /// A status from the assistant (Windows' `OnStatus`): its mode, and its message as a line of recent activity, in
    /// red for an error and brown for a warning.
    public func showStatus(_ update: AssistantStatus) {
        mode = update.mode
        guard !DotNet.isNullOrWhiteSpace(update.message) else { return }
        let colour: Colour
        switch update.kind {
        case .error: colour = Theme.danger
        case .warning: colour = Colour(0x8A5A00)
        case .info, .success: colour = Theme.text
        }

        lines += 1
        let text = "\(Self.time(clock(), timeZone))   \(update.message)"
        activity.insert(Line(id: lines, text: text, colour: colour), at: 0)
        if activity.count > Self.maxActivity {
            activity.removeLast(activity.count - Self.maxActivity)
        }
    }

    /// The dictation language changed elsewhere (the hotkey, the menu): the choice follows, without telling the host
    /// again.
    public func setDictationLanguage(hinglish: Bool, accurate: Bool) {
        languageIndex = Self.languageIndex(hinglish: hinglish, accurate: accurate)
    }

    /// A language chosen here.
    public func chooseLanguage(_ index: Int) {
        guard index != languageIndex, Self.languages.indices.contains(index) else { return }
        languageIndex = index
        assistant.setDictationLanguage(hinglish: index > 0, accurate: index == 2)
    }

    /// "Pause listening" or "Start listening".
    public func toggleListening() {
        assistant.toggleListening()
    }

    /// "Open board".
    public func showBoard() {
        openBoard(nil)
    }

    /// The next four open reminders by time, those without one last: "⏰ today 5:00 PM   Call mom", red once due
    /// (Windows' `RefreshReminders`).
    public func refreshReminders() {
        let now = clock()
        let open: [BoardItem] = (board?.items ?? []).filter { $0.list == .reminders && !$0.done }
        let byTime: [BoardItem] = DotNet.orderBy(open) { (item: BoardItem) -> Date in item.due ?? Date.distantFuture }
        var next: [Line] = []
        for (index, item) in byTime.prefix(4).enumerated() {
            guard let due = item.due else {
                next.append(Line(id: index, text: "⏰ no time   \(item.text)", colour: Theme.text))
                continue
            }

            let when = InteractionController.describeDue(due, now, timeZone)
            let colour: Colour = due <= now ? Theme.danger : Theme.text
            next.append(Line(id: index, text: "⏰ \(when)   \(item.text)", colour: colour))
        }

        upcoming = next
    }

    /// Reads again what macOS allows: when the window comes forward, and after a button here.
    public func refreshPermissions() {
        permissions = Self.permissionRows(checks, key: keys.dictation, dictationKeyOn: dictationKeyOn, asked: asked)
    }

    /// A permission's button, as ThumbFree's menu does it: macOS's own prompt where it can still ask, which also lists
    /// Voice Assistant in System Settings (an app nothing has asked for isn't in the list), and System Settings at the
    /// switch when that didn't allow it. The microphone's prompt comes the first time only; Accessibility's and Input
    /// Monitoring's are asked once here, then their buttons open System Settings.
    public func allow(_ kind: Permissions.Kind) {
        if kind == .microphone {
            guard checks.status(.microphone) == .notDetermined else {
                checks.openSettings(.microphone)
                return
            }

            checks.request(.microphone) { [weak self] _ in self?.refreshPermissions() }
            return
        }

        let pane: Permissions.Kind = kind == .inputMonitoring ? .inputMonitoring : .accessibility
        guard !asked.contains(pane) else {
            checks.openSettings(pane)
            return
        }

        asked.insert(pane)
        checks.request(pane) { [weak self] status in
            guard let self else { return }
            if status != .granted {
                self.checks.openSettings(pane)
            }

            self.refreshPermissions()
        }
    }

    /// The status card for `mode`, naming the dictation key `key` (Windows' `ShowMode`).
    nonisolated static func modeLine(_ mode: InteractionMode, key: String) -> ModeLine {
        switch mode {
        case .dictation:
            return ModeLine(
                title: "Typing", hint: "Speaking types into the chosen text box. Say “stop typing” when done.",
                colour: Colour(0xEA4335), toggle: "Pause listening")
        case .command:
            return ModeLine(
                title: "Listening for a command", hint: "Say a command now, e.g. “open TextEdit”.",
                colour: Colour(0x4C8DF6), toggle: "Pause listening")
        case .standby:
            return ModeLine(
                title: "Listening for “Hey Jarvis”", hint: "Tap \(key) any time to dictate; tap it again to finish.",
                colour: Colour(0x34A853), toggle: "Pause listening")
        case .paused:
            return ModeLine(
                title: "Paused", hint: "The microphone is off. Tapping \(key) still dictates.",
                colour: Colour(0x9AA0A6), toggle: "Start listening")
        }
    }

    /// The quick start's tips, naming the dictation key `key`.
    nonisolated static func tips(key: String) -> [String] {
        [
            "Tap \(key), speak, tap \(key) again: your words are typed where the cursor is.",
            "Say “Hey Jarvis, open Chrome”, then “go to the search box”.",
            "Tap \(key) and say “Add to my ideas, …” (tap again to finish) to save a thought without typing it "
                + "anywhere.",
            "“Hey Jarvis, remind me to stretch in 30 minutes.”",
        ]
    }

    /// What macOS hasn't allowed: the microphone; Accessibility (reading and using other apps, and typing); and Input
    /// Monitoring, which the dictation key needs only while Accessibility isn't allowed (ThumbFreeMac's `HotkeyTap`
    /// then listens with it). A button asks macOS ("Allow…") until macOS has asked, then opens System Settings.
    nonisolated static func permissionRows(
        _ checks: Permissions, key: String, dictationKeyOn: Bool, asked: Set<Permissions.Kind> = []
    ) -> [PermissionRow] {
        let allow = "Allow…"
        let settings = "Open System Settings"
        var rows: [PermissionRow] = []
        let microphone = checks.status(.microphone)
        if microphone != .granted {
            let button = microphone == .notDetermined ? allow : settings
            rows.append(
                PermissionRow(
                    kind: .microphone, name: "Microphone",
                    reason: "To hear “Hey Jarvis”, your commands and your dictation.", button: button))
        }

        let canType = checks.status(.postEvents) == .granted
        if checks.status(.accessibility) != .granted || !canType {
            let button = asked.contains(.accessibility) ? settings : allow
            rows.append(
                PermissionRow(
                    kind: .accessibility, name: "Accessibility",
                    reason: "To read and use other apps' windows, and to type what you dictate.", button: button))
        }

        if dictationKeyOn && !canType && checks.status(.inputMonitoring) != .granted {
            let button = asked.contains(.inputMonitoring) ? settings : allow
            rows.append(
                PermissionRow(
                    kind: .inputMonitoring, name: "Input Monitoring",
                    reason: "So tapping \(key) can start dictation while Accessibility isn't allowed.", button: button))
        }

        return rows
    }

    /// The choice for a language.
    nonisolated static func languageIndex(hinglish: Bool, accurate: Bool) -> Int {
        !hinglish ? 0 : accurate ? 2 : 1
    }

    /// "14:05": the hour and minute on `timeZone`'s clock, as Windows writes `HH:mm`.
    nonisolated static func time(_ date: Date, _ timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// A permission macOS hasn't given yet, as Home's card lists it.
public struct PermissionRow: Equatable, Identifiable, Sendable {
    public var id: Permissions.Kind { kind }
    public let kind: Permissions.Kind
    public let name: String
    public let reason: String
    /// "Allow…", or "Open System Settings" once macOS has asked.
    public let button: String
}

/// The page: `HomeContent` in a scroll.
struct HomePage: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ScrollView {
            HomeContent(model: model)
        }
    }
}

/// Home's cards, 24 points in from the page's edges.
struct HomeContent: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.heading("Voice Assistant")
            if !model.permissions.isEmpty {
                PermissionsCard(rows: model.permissions) { model.allow($0) }
            }

            status
            language
            upcoming
            tips
            activity
        }
        .padding(24)
    }

    private var status: some View {
        let line = model.modeLine
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Circle()
                    .fill(Color(line.colour))
                    .frame(width: 14, height: 14)
                    .padding(.trailing, 10)
                    .animation(Motion.animation(220), value: line.colour)
                Text(line.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(Theme.text))
                Spacer(minLength: 12)
                Button(line.toggle) { model.toggleListening() }.buttonStyle(ThemeButtonStyle.primary)
            }

            Theme.label(line.hint, colour: Theme.muted).padding(EdgeInsets(top: 6, leading: 24, bottom: 0, trailing: 0))
        }
        .themeCard()
    }

    private var language: some View {
        let choice = Binding<Int>(get: { model.languageIndex }, set: { (index: Int) in model.chooseLanguage(index) })
        return VStack(alignment: .leading, spacing: 0) {
            Self.title("Dictation language")
            Picker("", selection: choice) {
                ForEach(HomeModel.languages.indices, id: \.self) { (index: Int) in
                    Text(verbatim: HomeModel.languages[index]).tag(index)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 13))
            .frame(width: 320)
            .padding(.bottom, 4)
            Theme.label(model.languageHint, size: 12, colour: Theme.muted)
        }
        .themeCard()
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: "Coming up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(Theme.text))
                Spacer(minLength: 12)
                Button("Open board") { model.showBoard() }.buttonStyle(ThemeButtonStyle.standard)
            }
            .padding(.bottom, 8)
            if model.upcoming.isEmpty {
                Theme.label(HomeModel.noReminders, size: 12, colour: Theme.muted)
            }

            ForEach(model.upcoming) { line in
                Theme.label(line.text, colour: line.colour).padding(.bottom, 4)
            }
        }
        .themeCard()
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 0) {
            Self.title("Quick start")
            ForEach(model.tips, id: \.self) { tip in
                Theme.label("•  " + tip)
            }
        }
        .themeCard()
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Self.title("Recent activity")
            if model.activity.isEmpty {
                Theme.label(HomeModel.noActivity, size: 12, colour: Theme.muted)
            }

            ForEach(model.activity) { line in
                Theme.label(line.text, size: 12, colour: line.colour)
                    .padding(.bottom, 4)
                    .modifier(FadeInOnAppear(milliseconds: 220))
            }
        }
        .themeCard()
    }

    /// A card's title: 15 points, semibold, 8 above what follows.
    static func title(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(Theme.text))
            .padding(.bottom, 8)
    }
}

/// The Mac's addition to Home: what macOS hasn't allowed yet, each with a button that asks for it or opens System
/// Settings where it's switched on.
struct PermissionsCard: View {
    static let intro =
        "macOS asks for these once; after that they're switched on in System Settings › Privacy & Security."

    let rows: [PermissionRow]
    let allow: (Permissions.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeContent.title("Permissions needed").padding(.bottom, -4)
            Theme.label(Self.intro, size: 12, colour: Theme.muted).padding(.bottom, 10)
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(Theme.text))
                        Theme.label(row.reason, size: 12, colour: Theme.muted)
                    }

                    Spacer(minLength: 12)
                    Button(row.button) { allow(row.kind) }.buttonStyle(ThemeButtonStyle.standard)
                }
                .padding(.bottom, 10)
            }
        }
        .themeCard(Theme.accentSoft)
    }
}
