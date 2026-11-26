import AppKit
import SwiftUI
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantMac

/// Settings (windows-voice-assistant `SettingsPage`): settings.json as a form. Saving reads the file again and changes
/// only the fields edited here, so hand edits to the file (the apps, anything not on this page) survive. Most changes
/// apply after a restart (one click: "Save and restart"); "Start when I log in" applies at once. The AI brain's card
/// shows its state live: downloading, loading, ready…, with Download, Stop and Open its folder.
@MainActor
public final class SettingsModel: ObservableObject {
    /// A setting on the page (Windows' `Setting`): what its control holds, its value as last saved, and how it's
    /// written into the settings.
    public struct Field: Identifiable {
        public enum Input: Equatable, Sendable {
            /// A check box: "True" or "False", as C# writes a bool.
            case check
            case number
            case choice([String])
            case text
            /// One entry a line.
            case lines
        }

        /// Its key in settings.json.
        public let id: String
        public let label: String
        public let hint: String?
        public let input: Input
        /// What the control holds.
        public var text: String
        /// The value as last saved, as `value` gives it.
        public internal(set) var saved: String
        fileprivate let read: (String) -> String
        fileprivate let write: (inout AppSettings, String) throws -> Void

        fileprivate init(
            _ id: String, _ label: String, hint: String? = nil, _ input: Input, text: String,
            read: @escaping (String) -> String = { $0 }, write: @escaping (inout AppSettings, String) throws -> Void
        ) {
            self.id = id
            self.label = label
            self.hint = hint
            self.input = input
            self.text = text
            self.read = read
            self.write = write
            saved = read(text)
        }

        /// The value now, as it's compared with `saved` (Windows' `Current`): trimmed, and a box's lines without the
        /// empty ones.
        public var value: String { read(text) }

        public var isChanged: Bool { value != saved }
    }

    /// The fields, in the page's order.
    @Published public var fields: [Field]
    /// The line under the buttons: saved, nothing to save, or why it wasn't saved.
    @Published public private(set) var message: String?
    @Published public private(set) var messageColour = Theme.muted
    /// "Start when I log in" is on.
    @Published public private(set) var startsAtLogin: Bool
    /// Why "Start when I log in" isn't what was asked for.
    @Published public private(set) var loginProblem: String?
    @Published public private(set) var brainCard: BrainCard

    private let launch: AppSettings
    private let paths: AppPaths
    private let assistant: AssistantControls
    private let brain: BrainControls?
    private let login: StartAtLogin
    private let restartApp: @MainActor () -> Void
    private let opener: FileOpener
    private let clock: () -> Date
    private let timeZone: TimeZone
    private var loginWanted: Bool?

    /// - Parameters:
    ///   - settings: The settings as read at launch: what the page shows first, and what's written to a settings file
    ///     opened before there is one.
    ///   - brain: The AI brain; nil while it's switched off.
    ///   - keys: The keys the labels name.
    ///   - restart: Starts a fresh copy of the app, which reads the saved settings ("Save and restart").
    ///   - clock: Now, and the clock it's told on, for "Saved at 14:05".
    public init(
        settings: AppSettings, paths: AppPaths, assistant: AssistantControls, brain: BrainControls?, keys: KeyNames,
        startAtLogin: StartAtLogin, restart: @escaping @MainActor () -> Void, opener: FileOpener = WorkspaceOpener(),
        clock: @escaping () -> Date = { Date() }, timeZone: TimeZone = .autoupdatingCurrent
    ) {
        launch = settings
        self.paths = paths
        self.assistant = assistant
        self.brain = brain
        login = startAtLogin
        restartApp = restart
        self.opener = opener
        self.clock = clock
        self.timeZone = timeZone
        fields = Self.fields(settings, key: keys.dictation)
        startsAtLogin = startAtLogin.isEnabled()
        brainCard = BrainCard.describe(brain)
    }

    /// The field whose key in settings.json is `key`.
    public func index(_ key: String) -> Int {
        guard let index = fields.firstIndex(where: { $0.id == key }) else {
            preconditionFailure("no field \(key)")
        }

        return index
    }

    /// Reads again what isn't kept in settings.json, as Windows does each time the page shows: "Start when I log in"
    /// and the AI brain.
    public func refresh() {
        startsAtLogin = login.isEnabled()
        if loginWanted == startsAtLogin {
            loginWanted = nil
            loginProblem = nil
        }

        brainChanged()
    }

    /// Saves the edited fields into settings.json as it is now (Windows' `Save`). False when nothing could be saved;
    /// `message` says why.
    @discardableResult
    public func save() -> Bool {
        let changed = fields.indices.filter { fields[$0].isChanged }
        guard !changed.isEmpty else {
            show("Nothing to save.", Theme.muted)
            return true
        }

        var file: AppSettings
        do {
            file = try AppSettings.loadForEdit(from: paths.settingsFile)
        } catch {
            let reason: String = (error as? AppSettings.ReadError)?.message ?? error.localizedDescription
            show(
                "Not saved: \(reason). Fix it with Open settings file, or delete the file to start over.", Theme.danger)
            return false
        }

        do {
            for index in changed {
                try fields[index].write(&file, fields[index].text)
            }
        } catch {
            let problem: String = (error as? SettingsProblem)?.message ?? error.localizedDescription
            show("Not saved: \(problem)", Theme.danger)
            return false
        }

        do {
            try file.save(to: paths.settingsFile)
        } catch {
            show("Couldn't save: \(error.localizedDescription)", Theme.danger)
            return false
        }

        for index in changed {
            fields[index].saved = fields[index].value
        }

        let time = HomeModel.time(clock(), timeZone)
        show("Saved at \(time). Restart to apply dictation and hotkey changes.", Theme.muted)
        return true
    }

    /// "Save and restart": restarts once it's saved.
    public func saveAndRestart() {
        if save() {
            restartApp()
        }
    }

    /// "Start when I log in", applied at once; a line says so when macOS didn't change it.
    public func setStartsAtLogin(_ on: Bool) {
        login.set(on)
        startsAtLogin = login.isEnabled()
        guard startsAtLogin != on else {
            loginWanted = nil
            loginProblem = nil
            return
        }

        loginWanted = on
        loginProblem = on
            ? "Not on yet: allow Voice Assistant in System Settings › General › Login Items, or move it to your "
                + "Applications folder and try again."
            : "Still on: remove Voice Assistant in System Settings › General › Login Items."
    }

    /// The AI brain's status changed.
    public func brainChanged() {
        brainCard = BrainCard.describe(brain)
    }

    /// "Download (one time)".
    public func downloadBrain() {
        brain?.startDownload()
    }

    /// "Stop download".
    public func stopBrainDownload() {
        brain?.cancelDownload()
    }

    /// "Open its folder", made first if it isn't there.
    public func openBrainFolder() {
        guard let folder = brain?.folder else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        opener.open(URL(fileURLWithPath: folder, isDirectory: true))
    }

    /// "Open settings file": settings.json in TextEdit, written first from the settings read at launch when there's no
    /// file.
    public func openSettingsFile() {
        let path = paths.settingsFile
        if !FileManager.default.fileExists(atPath: path) {
            try? launch.save(to: path)
        }

        opener.openText(URL(fileURLWithPath: path))
    }

    /// "Open logs folder", made first if it isn't there.
    public func openLogsFolder() {
        try? FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        opener.open(URL(fileURLWithPath: paths.logs, isDirectory: true))
    }

    /// The Mac records from the input chosen in System Settings › Sound (Windows chooses the device here).
    public func openSoundSettings() {
        opener.open(Self.soundSettings)
    }

    /// "Forget what I've learned".
    public func forgetLearned() {
        assistant.forgetLearned()
    }

    /// System Settings › Sound, at the input.
    static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!

    private func show(_ text: String, _ colour: Colour) {
        message = text
        messageColour = colour
    }

    // MARK: The fields

    /// The choices of the dictation key: Fn and Right Option.
    nonisolated static let dictationKeys = ["Fn (🌐)", "Right Option"]

    /// How text is inserted.
    nonisolated static let insertMethods = ["Paste", "Type"]

    /// Every field, in the page's order, from `settings`, with labels that name the dictation key `key`.
    nonisolated static func fields(_ settings: AppSettings, key: String) -> [Field] {
        var fields: [Field] = []
        fields.append(
            check(
                "listenOnStartup", "Start listening for “Hey Jarvis” when the app starts", \.listenOnStartup,
                settings))
        fields.append(check("soundFeedback", "Short sounds when listening starts and stops", \.soundFeedback, settings))
        fields.append(check("learnFromUsage", "Learn my rephrasings and favourite apps", \.learnFromUsage, settings))

        fields.append(
            check("pushToTalk", "Tap \(key) to dictate into any app (tap again to finish)", \.pushToTalk, settings))
        let keyChoice = settings.dictationKey == .rightOption ? dictationKeys[1] : dictationKeys[0]
        fields.append(
            Field(
                "dictationKey", "Dictation key",
                hint: "Right Option suits a keyboard whose Fn key macOS doesn't see, or when Fn does something else.",
                .choice(dictationKeys), text: keyChoice,
                write: { (settings: inout AppSettings, text: String) in
                    let rightOption = text == dictationKeys[1]
                    settings.dictationKey = rightOption ? FnTapKeys.TapKey.rightOption : FnTapKeys.TapKey.fn
                }))
        fields.append(
            number(
                "maxDictationSeconds", "Stop a \(key) dictation by itself after (seconds, 0 = never)",
                \.maxDictationSeconds, 0...3600, settings,
                hint: "If you forget to tap \(key) again, the recording is typed after this long so the microphone "
                    + "doesn't stay on (default 600 = 10 minutes)."))
        fields.append(check("livePreview", "Show my words in the status pill while I speak", \.livePreview, settings))
        fields.append(
            check(
                "removeFillerWords", "Remove filler words (“um”, “basically”, “thik hai na”, “haan to like”…)",
                \.removeFillerWords, settings))
        fields.append(
            check("spokenPunctuation", "Say punctuation (“comma”, “new line”)", \.spokenPunctuation, settings))
        let insertMethod = insertMethods.first { DotNet.equalsOrdinalIgnoreCase($0, settings.insertMethod) }
        fields.append(
            Field(
                "insertMethod", "How text is inserted",
                hint: "Paste works everywhere (your clipboard is restored); Type sends keystrokes.",
                .choice(insertMethods), text: insertMethod ?? insertMethods[0],
                write: { settings, text in settings.insertMethod = text }))
        fields.append(
            number(
                "dictationEndSilenceMs", "Pause that ends a phrase while voice typing (ms)", \.dictationEndSilenceMs,
                600...3000, settings,
                hint: "Longer keeps sentences together when you pause to think; commands wait this long too."))
        fields.append(
            Field(
                "dictationVocabulary", "Words I use often (one per line)",
                hint: "Helps the accurate Hindi + English model spell names and jargon.", .lines,
                text: settings.dictationVocabulary.joined(separator: "\n"), read: { rows($0).joined(separator: "\n") },
                write: { settings, text in settings.dictationVocabulary = rows(text) }))
        fields.append(
            pairs(
                "replacements", "Personal dictionary (heard = typed, one per line)", \.replacements, settings,
                hint: "e.g. git hub = GitHub"))
        fields.append(
            pairs(
                "snippets", "Snippets (say = type, one per line; \\n for a new line, \\\\ for a backslash)", \.snippets,
                settings, hint: "e.g. my signature = Thanks,\\nShivam"))

        fields.append(check("wakeWordEnabled", "Commands need “Hey Jarvis” first", \.wakeWordEnabled, settings))
        fields.append(
            number(
                "awakeSeconds", "Keep listening for commands after “Hey Jarvis” (seconds)", \.awakeSeconds, 2...120,
                settings))
        fields.append(text("hotkey", "Pause / resume listening hotkey", \.hotkey, settings))
        fields.append(text("pasteLastHotkey", "Paste last dictation hotkey", \.pasteLastHotkey, settings))
        fields.append(
            text(
                "dictationLanguageHotkey", "Switch dictation language hotkey", \.dictationLanguageHotkey, settings,
                hint: "Written as in settings.json: Ctrl+Shift+Space is ⌃⇧Space; Alt is ⌥ Option and Win is ⌘ "
                    + "Command."))

        fields.append(
            check(
                "brainEnabled", "Use the AI brain for requests the fixed commands don't know", \.brainEnabled,
                settings))
        fields.append(
            number(
                "brainKeepLoadedMinutes", "Unload the AI model after this many minutes unused (0 = keep it loaded)",
                \.brainKeepLoadedMinutes, 0...1440, settings,
                hint: "While loaded it uses about 3 GB of memory; after unloading, the next request takes about 10 "
                    + "seconds longer."))
        return fields
    }

    private nonisolated static func check(
        _ key: String, _ label: String, _ path: WritableKeyPath<AppSettings, Bool>, _ settings: AppSettings
    ) -> Field {
        Field(
            key, label, .check, text: settings[keyPath: path] ? "True" : "False",
            write: { settings, text in settings[keyPath: path] = text == "True" })
    }

    private nonisolated static func number(
        _ key: String, _ label: String, _ path: WritableKeyPath<AppSettings, Int>, _ range: ClosedRange<Int>,
        _ settings: AppSettings, hint: String? = nil
    ) -> Field {
        Field(
            key, label, hint: hint, .number, text: String(settings[keyPath: path]), read: { DotNet.trim($0) },
            write: { settings, text in
                guard let number = Int(DotNet.trim(text)), range.contains(number) else {
                    throw SettingsProblem(
                        message: "“\(label)” must be a number from \(range.lowerBound) to \(range.upperBound).")
                }

                settings[keyPath: path] = number
            })
    }

    private nonisolated static func text(
        _ key: String, _ label: String, _ path: WritableKeyPath<AppSettings, String>, _ settings: AppSettings,
        hint: String? = nil
    ) -> Field {
        Field(
            key, label, hint: hint, .text, text: settings[keyPath: path], read: { DotNet.trim($0) },
            write: { settings, text in settings[keyPath: path] = DotNet.trim(text) })
    }

    /// "heard = typed" a line; in a value, a line break is written \n and a backslash \\ (Windows' `Pairs`).
    private nonisolated static func pairs(
        _ key: String, _ label: String, _ path: WritableKeyPath<AppSettings, SettingsPairs>, _ settings: AppSettings,
        hint: String
    ) -> Field {
        let shown = settings[keyPath: path].pairs.map { "\($0.key) = \(escape($0.value))" }.joined(separator: "\n")
        return Field(
            key, label, hint: hint, .lines, text: shown, read: { rows($0).joined(separator: "\n") },
            write: { settings, text in
                // A key given twice keeps its first place and takes its last value, case aside, as on Windows.
                var pairs = SettingsPairs(ignoringCase: true)
                for line in rows(text) {
                    let units = Array(line.utf16)
                    guard let equals = units.firstIndex(of: 0x3D), equals > 0 else {
                        throw SettingsProblem(message: "“\(line)” in “\(label)” needs the form: heard = typed.")
                    }

                    let heard = DotNet.trim(String(decoding: units[..<equals], as: UTF16.self))
                    pairs[heard] = unescape(DotNet.trim(String(decoding: units[(equals + 1)...], as: UTF16.self)))
                }

                settings[keyPath: path] = pairs
            })
    }

    /// A box's lines, trimmed, without the empty ones.
    nonisolated static func rows(_ text: String) -> [String] {
        DotNet.split(text, ["\n"]).map { DotNet.trim($0) }.filter { !$0.isEmpty }
    }

    /// A value on one line: a backslash is shown as \\ and a line break as \n (Windows' `Escape`).
    nonisolated static func escape(_ value: String) -> String {
        DotNet.replace(DotNet.replace(DotNet.replace(value, "\\", "\\\\"), "\r\n", "\\n"), "\n", "\\n")
    }

    /// Windows' `Unescape`: \\ is a backslash and \n a line break; any other backslash stays.
    nonisolated static func unescape(_ value: String) -> String {
        let backslash: UInt16 = 0x5C
        let n: UInt16 = 0x6E
        let lineFeed: UInt16 = 0x0A
        let units = Array(value.utf16)
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            let next: UInt16? = index + 1 < units.count ? units[index + 1] : nil
            if unit == backslash, let escaped = next, escaped == backslash || escaped == n {
                result.append(escaped == n ? lineFeed : backslash)
                index += 2
            } else {
                result.append(unit)
                index += 1
            }
        }

        return String(decoding: result, as: UTF16.self)
    }
}

/// Why a value can't be saved (Windows' `FormatException`).
private struct SettingsProblem: Error {
    let message: String
}

/// The AI brain's card on the Settings page (Windows' `BrainStatus`): its state in a sentence, and which buttons show.
public struct BrainCard: Equatable, Sendable {
    public var text: String
    /// The sentence is why it failed, shown in red.
    public var isError = false
    public var showsDownload = false
    public var showsStop = false
    public var showsFolder = false

    /// The card for `brain`, nil while it's switched off.
    static func describe(_ brain: BrainControls?) -> BrainCard {
        guard let brain else { return BrainCard(text: "Off. Switch it on and restart to use it.") }
        let model = BrainFiles.modelName
        var card = BrainCard(text: "", showsDownload: brain.canDownload, showsFolder: true)
        switch brain.status {
        case .downloading(let received, let total):
            let percent: Int64 = total > 0 ? received * 100 / total : 0
            card.text = "Downloading… \(gb(received)) of \(gb(total)) (\(percent)%). You can keep using the app."
            card.showsDownload = false
            card.showsStop = true
        case .notInstalled:
            let missing = brain.missingBytes
            card.text = missing > 0
                ? "Not downloaded yet: \(gb(missing)), one time. It stays on this Mac (\(brain.folder))."
                : "Its files aren't where settings.json says (brainServerPath / brainModelPath)."
        case .installed, .unloaded:
            card.text = "Ready. \(model) loads when you next ask for something."
        case .starting:
            card.text = "Loading \(model)…"
        case .ready:
            card.text = "Ready: \(model), running on this Mac."
        case .failed(let reason):
            card.text = reason.isEmpty
                ? "It couldn't start. Open logs folder for details; it tries again when you next ask." : reason
            card.isError = !reason.isEmpty
        case .unavailable(let reason):
            card.text = reason
        }

        return card
    }

    /// "2.2 GB" from a gigabyte (2^30 bytes) up, else "512 MB".
    static func gb(_ bytes: Int64) -> String {
        let gigabyte: Int64 = 1_073_741_824
        let megabyte: Int64 = 1_048_576
        if bytes >= gigabyte {
            let amount: Double = Double(bytes) / Double(gigabyte)
            return String(format: "%.1f GB", amount)
        }

        let amount: Double = Double(bytes) / Double(megabyte)
        return String(format: "%.0f MB", amount)
    }
}

/// The page: `SettingsContent` in a scroll.
struct SettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            SettingsContent(model: model)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refresh() }
    }
}

/// The settings in their sections, the buttons and the line that says how saving went, 760 points wide at most.
struct SettingsContent: View {
    static let savingNote =
        "Saving changes only the fields you edited here; other entries in the file (such as apps) are kept. "
        + "Comments in the file are removed."

    static let brainIntro =
        "Ask for anything the fixed commands don't cover, like “open the MrBeast video on YouTube” or “reply thanks to "
        + "Rahul on WhatsApp”. An AI model on this Mac reads the window names and buttons on screen and plans the "
        + "steps; nothing is sent online. It asks before sending, deleting or closing anything. Esc stops it."

    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.heading("Settings")
            section("General") {
                Toggle(isOn: startsAtLogin) {
                    Text(verbatim: "Start when I log in (in the menu bar, window closed)").font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
                .padding(.bottom, loginGap)
                if let problem = model.loginProblem {
                    Theme.label(problem, size: 12, colour: Theme.danger).padding(.bottom, 10)
                }

                rows("listenOnStartup", "soundFeedback", "learnFromUsage")
            }

            section("Dictation") {
                rows(
                    "pushToTalk", "dictationKey", "maxDictationSeconds", "livePreview", "removeFillerWords",
                    "spokenPunctuation", "insertMethod", "dictationEndSilenceMs", "dictationVocabulary", "replacements",
                    "snippets")
            }

            section("Voice commands") {
                rows("wakeWordEnabled", "awakeSeconds", "hotkey", "pasteLastHotkey", "dictationLanguageHotkey")
            }

            section("AI brain (runs on this Mac)") {
                Theme.label(Self.brainIntro, size: 12, colour: Theme.muted).padding(.bottom, 10)
                rows("brainEnabled")
                BrainCardView(
                    card: model.brainCard, download: { model.downloadBrain() }, stop: { model.stopBrainDownload() },
                    openFolder: { model.openBrainFolder() })
                    .padding(.bottom, 10)
                rows("brainKeepLoadedMinutes")
            }

            section("Microphone") {
                Theme.label("Voice Assistant listens with the input chosen in System Settings › Sound.")
                    .padding(.bottom, 6)
                Button("Open Sound settings") { model.openSoundSettings() }
                    .buttonStyle(ThemeButtonStyle.standard)
                    .padding(.bottom, 10)
            }

            WrapStack(spacing: 8, lineSpacing: 8) {
                Button("Save and restart") { model.saveAndRestart() }.buttonStyle(ThemeButtonStyle.primary)
                Button("Save") { model.save() }.buttonStyle(ThemeButtonStyle.standard)
                Button("Open settings file") { model.openSettingsFile() }.buttonStyle(ThemeButtonStyle.standard)
                Button("Open logs folder") { model.openLogsFolder() }.buttonStyle(ThemeButtonStyle.standard)
                Button("Forget what I've learned") { model.forgetLearned() }.buttonStyle(ThemeButtonStyle.standard)
            }
            .padding(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            Theme.label(Self.savingNote, size: 12, colour: Theme.muted)
            if let message = model.message {
                Theme.label(message, size: 12, colour: model.messageColour)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// A card with its title, 15 points and semibold, and its rows.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(Theme.text))
                .padding(.bottom, 10)
            content()
        }
        .themeCard()
    }

    /// "Start when I log in": what macOS says, switched at once.
    private var startsAtLogin: Binding<Bool> {
        Binding<Bool>(get: { model.startsAtLogin }, set: { (on: Bool) in model.setStartsAtLogin(on) })
    }

    /// Below "Start when I log in": closer to the line that says why it didn't change, when there's one.
    private var loginGap: CGFloat {
        model.loginProblem == nil ? 10 : 2
    }

    /// The fields with these keys, 10 points apart.
    private func rows(_ keys: String...) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(keys, id: \.self) { (key: String) in
                SettingsFieldView(field: $model.fields[model.index(key)]).padding(.bottom, 10)
            }
        }
    }
}

/// A field's control: a check box, or its label above a box, a menu or a text area, with its hint below (Windows'
/// `Field`).
struct SettingsFieldView: View {
    @Binding var field: SettingsModel.Field

    var body: some View {
        switch field.input {
        case .check:
            Toggle(isOn: checked) {
                Text(verbatim: field.label).font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
        case .number:
            labelled(TextField("", text: $field.text).textFieldStyle(.roundedBorder).frame(width: 100))
        case .text:
            labelled(TextField("", text: $field.text).textFieldStyle(.roundedBorder).frame(width: 220))
        case .choice(let options):
            labelled(
                Picker("", selection: $field.text) {
                    ForEach(options, id: \.self) { (option: String) in
                        Text(verbatim: option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160, alignment: .leading))
        case .lines:
            labelled(
                TextEditor(text: $field.text)
                    .font(.system(size: 13))
                    .padding(4)
                    .frame(width: 460, height: Self.height(field.text))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(Theme.border), lineWidth: 1)))
        }
    }

    /// A check box's field holds "True" or "False", as C# writes a bool.
    private var checked: Binding<Bool> {
        Binding<Bool>(
            get: { field.text == "True" },
            set: { (on: Bool) in
                let text: String = on ? "True" : "False"
                field.text = text
            })
    }

    /// The label above the control and the hint below it.
    private func labelled<Control: View>(_ control: Control) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.label(field.label)
            control.font(.system(size: 13)).padding(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0))
            if let hint = field.hint {
                Theme.label(hint, size: 12, colour: Theme.muted)
            }
        }
    }

    /// A text area grows with its lines, from 70 points to 160 (Windows' MinHeight and MaxHeight); past that it
    /// scrolls.
    static func height(_ text: String) -> CGFloat {
        let lines = CGFloat(DotNet.split(text, ["\n"]).count)
        let natural: CGFloat = lines * 17 + 12
        return min(max(natural, 70), 160)
    }
}

/// The AI brain's card: its state, and Download, Stop download and Open its folder as they apply.
struct BrainCardView: View {
    let card: BrainCard
    let download: () -> Void
    let stop: () -> Void
    let openFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.label(card.text, colour: card.isError ? Theme.danger : Theme.text)
            WrapStack(spacing: 8, lineSpacing: 8) {
                if card.showsDownload {
                    Button("Download (one time)", action: download).buttonStyle(ThemeButtonStyle.primary)
                }

                if card.showsStop {
                    Button("Stop download", action: stop).buttonStyle(ThemeButtonStyle.standard)
                }

                if card.showsFolder {
                    Button("Open its folder", action: openFolder).buttonStyle(ThemeButtonStyle.standard)
                }
            }
            .padding(.top, 6)
        }
    }
}
