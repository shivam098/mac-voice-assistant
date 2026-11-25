import Foundation
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantCore

/// Voice Assistant's settings, kept in settings.json in the Windows app's format (windows-voice-assistant
/// `AppSettings`): the same keys, values and defaults, so the file can move between the two, read and written as .NET's
/// `JsonSerializer` reads and writes it (camelCase keys, comments and trailing commas allowed, a key written twice
/// taking its last value, keys in another case ignored, and a value of the wrong kind making the whole file
/// unreadable). The defaults differ where Windows' can't apply on a Mac: the hotkeys (see `hotkey`) and the apps (see
/// `defaultApps`). The Mac adds `dictationKey`, which Windows ignores. Settings only Windows uses (`microphoneDevice`)
/// are kept, so the file stays the same.
public struct AppSettings: Equatable, Sendable {
    /// The Whisper model "Hey Jarvis" and commands are heard with, in the models folder.
    public var modelFile = "ggml-small.en-q8_0.bin"

    /// Silero voice-activity model: drops music and noise and splits merged phrases. Optional but strongly
    /// recommended.
    public var vadModelFile = "ggml-silero-v6.2.0.bin"

    /// Dictation model used when "Hindi + English" is switched on; types Hindi in Roman letters. Downloaded the first
    /// time it is switched on. Commands always use `modelFile`.
    public var hinglishModelFile = "ggml-hinglish-swift-q8_0.bin"

    /// "Hindi + English (accurate)": a larger model (834 MB, about 10 times slower than `hinglishModelFile`, with fewer
    /// mistakes). Typed text comes from it; the live preview keeps using the fast model.
    public var hinglishAccurateModelFile = "ggml-hinglish-apex-q8_0.bin"

    /// Switches dictation between English and Hindi + English. Windows' Alt+Shift+H types "Ó" on a Mac (see `hotkey`).
    public var dictationLanguageHotkey = AppSettings.defaultDictationLanguageHotkey

    /// Decoding threads: two thirds of the processors, 2 to 8.
    public var threads = AppSettings.defaultThreads

    /// 768 tokens cover 15.36 s of audio and are about 3 times faster than the default 30 s window.
    public var audioContextSize = 768

    /// Optional vocabulary hint. Off by default: Whisper can echo prompt text on near-silent input.
    public var vocabularyPrompt: String?

    /// Windows' recording device (-1: its default one). The Mac records from the input chosen in System Settings; the
    /// value is kept for Windows.
    public var microphoneDevice = -1

    /// The pause that ends a phrase.
    public var endSilenceMs = 600

    /// While voice typing, the pause that ends a phrase. Longer than `endSilenceMs`, so a thinking pause doesn't split
    /// a sentence into separately punctuated pieces (commands while typing wait this long too).
    public var dictationEndSilenceMs = 1100

    /// Words and names you use often (product names, jargon), given to the accurate Hindi + English model as a hint so
    /// it spells them right ("vibe coding", not "wife coding"). Keep it short; the fast model ignores it.
    public var dictationVocabulary = ["GitHub Copilot", "vibe coding", "iterate", "pull request", "commit"]

    /// While waiting for a command, longer phrases (including about 0.9 s of padding) aren't transcribed. Saves work
    /// during meetings and conversations; the longest command is about 4 s.
    public var maxCommandUtteranceMs = 6000

    public var listenOnStartup = true

    /// Pauses and resumes listening. Windows' Ctrl+Alt+Space can't be the Mac's: Control+Option+Space is macOS's
    /// "Select next source in Input menu" (Control+Space selects the previous one, ⌘Space is Spotlight, Option+⌘Space a
    /// Finder search and Control+⌘Space the Character Viewer). The Mac's three hotkeys keep Windows' keys (Space, Z and
    /// H) with Control+Shift, which no standard macOS shortcut uses with a letter or Space, which types no character
    /// (Option and Option+Shift with a letter type one, as Windows' Alt+Shift+Z and Alt+Shift+H would), and which
    /// isn't VoiceOver's Control+Option. Chords are written as the core's `ShortcutKeys` writes them.
    public var hotkey = AppSettings.defaultHotkey

    public var commandPrefix = "computer"

    public var requireCommandPrefixWhileTyping = false

    public var returnToCommandModeAfterSend = true

    /// Average token probability below which a command is ignored. Clean speech scores 0.5 to 1.0.
    public var minCommandConfidence: Float = 0.3

    /// "Paste": insert dictated text through the clipboard (reliable everywhere; your clipboard is put back). "Type":
    /// key events (some apps drop characters).
    public var insertMethod = "Paste"

    /// Also open the apps installed on this Mac by name (the app bundles in /Applications, /System/Applications and
    /// ~/Applications; on Windows, the Start menu's apps, hence the name).
    public var discoverStartMenuApps = true

    /// When true, commands need "Hey Jarvis" first (then work without it for `awakeSeconds`).
    public var wakeWordEnabled = true

    /// Accepted wake phrases (Whisper's common spellings of "Hey Jarvis" are included).
    public var wakeWords = CommandParser.defaultWakeWords

    public var awakeSeconds = 30

    /// Short tones when the wake word is heard, typing starts or stops, and dictation starts or ends.
    public var soundFeedback = true

    /// Learn rephrasings of commands and which apps you open most (kept in learned.json).
    public var learnFromUsage = true

    /// Requests the fixed commands don't cover ("open the MrBeast video on YouTube") go to an AI model on this Mac.
    /// Its files (about 2.4 GB) are downloaded only when you ask.
    public var brainEnabled = true

    /// Where the AI brain's files are kept; empty means brain/ in Voice Assistant's folder (`AppPaths.brainFolder`).
    public var brainFolder: String?

    /// Advanced: an existing llama-server to use instead of the downloaded one.
    public var brainServerPath: String?

    /// Advanced: an existing GGUF model to use instead of the downloaded one (the prompt is measured with Qwen3 4B).
    public var brainModelPath: String?

    /// The model (about 3 GB of memory) is unloaded after this many minutes unused and reloads on the next request; 0
    /// keeps it loaded.
    public var brainKeepLoadedMinutes = 60

    /// The dictation key (`dictationKey`) is on: tap it to dictate into any app, tap it again to type the text (Esc
    /// cancels). The name is from when Windows' keys (Ctrl+Win) had to be held, so existing files still work.
    public var pushToTalk = true

    /// Show the words in the pill as you speak while dictation records (uses extra processing while recording).
    public var livePreview = true

    /// A recording still going after this many seconds (the key was never tapped again) is finished and typed, so the
    /// microphone can't stay on by mistake. 0 turns the limit off.
    public var maxDictationSeconds = 600

    /// Pastes the last dictation again. Windows' Alt+Shift+Z types "¸" on a Mac (see `hotkey`).
    public var pasteLastHotkey = AppSettings.defaultPasteLastHotkey

    public var removeFillerWords = true

    public var spokenPunctuation = true

    /// Whole-word fixes applied to dictated text (the personal dictionary), such as "git hub" → "GitHub".
    public var replacements = SettingsPairs(
        [(key: "git hub", value: "GitHub"), (key: "co-pilot", value: "Copilot"), (key: "co pilot", value: "Copilot")],
        ignoringCase: true)

    /// Say the trigger (or "insert <trigger>") to type the text, such as "my signature" → "Thanks,\nShivam".
    public var snippets = SettingsPairs(ignoringCase: true)

    /// The apps it knows how to open and type into (`defaultApps`).
    public var apps = AppSettings.defaultApps

    /// The key that starts and finishes dictation: Fn (🌐), or Right Option, as in ThumbFree for Mac. Mac only:
    /// Windows ignores it (and leaves it out when it saves the file).
    public var dictationKey = FnTapKeys.TapKey.fn

    public init() {}

    /// Two thirds of the processors, 2 to 8, as on Windows.
    public static var defaultThreads: Int { min(max(ProcessInfo.processInfo.activeProcessorCount * 2 / 3, 2), 8) }

    /// What the dictation formatter does, with the replacements and snippets in the file's order, which decides which
    /// of two wins.
    public var dictationOptions: DictationOptions {
        DictationOptions(
            removeFillerWords: removeFillerWords, spokenPunctuation: spokenPunctuation,
            replacements: replacements.pairs, snippets: snippets.pairs)
    }

    /// The apps it knows how to open and type into, matched by bundle identifier: how "start typing" finds the text
    /// box, and the keys that send, start a new line, focus the address bar, or give a new window or document. Windows
    /// lists GitHub Copilot, Notepad, Chrome, Edge and Firefox. The Mac has no Notepad, so TextEdit takes its place;
    /// Notes and Safari join the apps that exist on both (docs/design.md). GitHub Copilot's Windows entry also needs
    /// "GitHub Copilot" in the window's title, to tell its window from others of the process "github"; a bundle
    /// identifier names the app, and Mac window titles don't carry the app's name, so the Mac's doesn't.
    public static let defaultApps: [AppEntry] = [
        AppEntry(
            name: "GitHub Copilot", aliases: ["github copilot", "copilot app"], launch: "com.github.githubapp",
            processNames: ["com.github.githubapp"], submitKeys: "Enter", newLineKeys: "Shift+Enter", textArea: "Bottom",
            textAreaName: "Message"),
        document("TextEdit", "com.apple.TextEdit"),
        document("Notes", "com.apple.Notes"),
        browser("Google Chrome", ["chrome", "google chrome"], "com.google.Chrome"),
        browser("Microsoft Edge", ["edge", "microsoft edge"], "com.microsoft.edgemac"),
        browser("Firefox", ["firefox", "mozilla firefox"], "org.mozilla.firefox"),
        browser("Safari", ["safari"], "com.apple.Safari"),
    ]

    /// Where you write rather than send, as Windows' Notepad: nothing sends, Return starts a new line, typing goes to
    /// the largest text area, and ⌘N gives a blank document (a new note in Notes) both when "open" finds the app
    /// running and after launching it, since both reopen what was open last.
    private static func document(_ name: String, _ bundle: String) -> AppEntry {
        AppEntry(
            name: name, launch: bundle, processNames: [bundle], submitKeys: "", newLineKeys: "Enter",
            textArea: "Largest", newWindowKeys: "Cmd+N", newDocumentKeys: "Cmd+N")
    }

    /// A browser: Return sends, Shift+Return starts a new line, ⌘L focuses the address and search bar.
    private static func browser(_ name: String, _ aliases: [String], _ bundle: String) -> AppEntry {
        AppEntry(
            name: name, aliases: aliases, launch: bundle, processNames: [bundle], submitKeys: "Enter",
            newLineKeys: "Shift+Enter", searchKeys: "Cmd+L", addressBarKeys: "Cmd+L")
    }
}

// MARK: The Mac's hotkeys

extension AppSettings {
    /// The Mac's default hotkeys (see `hotkey`).
    public static let defaultHotkey = "Ctrl+Shift+Space"
    public static let defaultPasteLastHotkey = "Ctrl+Shift+Z"
    public static let defaultDictationLanguageHotkey = "Ctrl+Shift+H"

    /// Windows' default hotkeys, which a settings.json copied from Windows holds.
    public static let windowsHotkey = "Ctrl+Alt+Space"
    public static let windowsPasteLastHotkey = "Alt+Shift+Z"
    public static let windowsDictationLanguageHotkey = "Alt+Shift+H"

    /// The pause hotkey as the Mac registers it. Windows' defaults clash with macOS or type a character here (see
    /// `hotkey`), so in a settings.json copied from Windows a hotkey that is Windows' default chord, in any case or
    /// order, means the Mac's default. Any other hotkey is used as written, Ctrl as ⌃, Alt as ⌥, Shift as ⇧ and Win as
    /// ⌘. The file keeps what it says, so it means the same on Windows.
    public var macHotkey: String {
        HotkeyChord.onMac(hotkey, windowsDefault: Self.windowsHotkey, macDefault: Self.defaultHotkey)
    }

    /// The paste-last hotkey as the Mac registers it (see `macHotkey`).
    public var macPasteLastHotkey: String {
        HotkeyChord.onMac(
            pasteLastHotkey, windowsDefault: Self.windowsPasteLastHotkey, macDefault: Self.defaultPasteLastHotkey)
    }

    /// The dictation language hotkey as the Mac registers it (see `macHotkey`).
    public var macDictationLanguageHotkey: String {
        HotkeyChord.onMac(
            dictationLanguageHotkey, windowsDefault: Self.windowsDictationLanguageHotkey,
            macDefault: Self.defaultDictationLanguageHotkey)
    }

    /// A hotkey as macOS shows shortcuts ("⌃⇧Space"); as written when it can't be read.
    public static func hotkeyLabel(_ chord: String) -> String {
        (try? HotkeyChord.parse(chord))?.displayName ?? chord
    }

    /// The dictation key as people know it: "Fn" or "Right Option".
    public var dictationKeyLabel: String {
        switch dictationKey {
        case .fn: return "Fn"
        case .rightOption: return "Right Option"
        }
    }
}

// MARK: The file

extension AppSettings {
    /// Why settings.json can't be read, as the Settings page says it ("settings.json has an error near line 3"), or
    /// what the system said about the file.
    public struct ReadError: Error, Equatable, LocalizedError {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    /// Reads settings.json at `path` (`LoadOrCreate`). A file that can't be read gives the defaults and is left alone,
    /// so a mistake in it is never replaced; the log has a warning. A missing file, or one that holds `null`, gets the
    /// defaults, which are saved there. Windows stops if it can't save them; the Mac logs it.
    public static func loadOrCreate(from path: String) -> AppSettings {
        let file: AppSettings??
        do {
            file = try read(path)
        } catch {
            Log.warn("settings unreadable, using defaults: \(logKind(error))")
            return AppSettings()
        }

        if case .some(.some(let settings)) = file {
            return settings
        }

        let settings = AppSettings()
        do {
            try settings.save(to: path)
        } catch {
            Log.warn("couldn't save the default settings: \(logKind(error))")
        }

        return settings
    }

    /// The file as it is now, for the Settings page to change a few values in and save (`LoadForEdit`): the defaults
    /// when there's no file (or it holds `null`). Throws a `ReadError` when it can't be read, so a mistake in it is
    /// never replaced by defaults.
    public static func loadForEdit(from path: String) throws -> AppSettings {
        let file: AppSettings??
        do {
            file = try read(path)
        } catch let mistake as NetJSON.Mistake {
            throw ReadError("settings.json has an error near line \(mistake.line + 1)")
        } catch {
            throw ReadError(error.localizedDescription)
        }

        if case .some(.some(let settings)) = file {
            return settings
        }

        return AppSettings()
    }

    /// Writes every setting to `path` through a temporary file (`Save`), as Windows writes them, with "\n" line ends
    /// (Windows writes "\r\n"; both read the same). Throws when the file can't be written, or for a
    /// `minCommandConfidence` that isn't finite, which Windows can't write either.
    public func save(to path: String) throws {
        let text = try fileText()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temp = path + ".tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: temp))
        if rename(temp, path) != 0 {
            let code = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The settings in a file's text as Windows reads them (`JsonSerializer.Deserialize<AppSettings>`); nil for a file
    /// that holds `null`. Throws a `NetJSON.Mistake` where .NET throws a JsonException: at the first mistake in the
    /// file, whether its JSON is broken or a value is of the wrong kind.
    static func parse(_ text: String) throws -> AppSettings? {
        var reader = NetJSON.Reader(text, relaxed: true)
        let settings: AppSettings?
        switch try reader.value() {
        case .null:
            settings = nil
        case .objectStart:
            var loaded = AppSettings()
            while case .name(let name) = try reader.nextMember() {
                let key = try reader.readable(name)
                if let field = fieldsByKey[DotNet.ordinal(key)] {
                    try field.read(&loaded, &reader)
                } else {
                    let value = try reader.value()
                    try reader.skip(value)
                }
            }

            settings = loaded
        default:
            throw reader.mistake(cannotConvert("AppSettings"))
        }

        try reader.end()
        return settings
    }

    /// The file's text as Windows' `Save` writes it: every setting that has a value, indented, in `fields` order.
    func fileText() throws -> String {
        let properties = Self.fields.compactMap { field in field.value(self).map { NetJSON.Property(field.key, $0) } }
        return try NetJSON.write(.object(properties), indented: true)
    }

    /// The settings in the file at `path`: nil when there's no file (a folder counts as none, as `File.Exists` says),
    /// and .some(nil) when it holds `null`.
    private static func read(_ path: String) throws -> AppSettings?? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
            return nil
        }

        let bytes = try Array(Data(contentsOf: URL(fileURLWithPath: path)))
        return try .some(parse(NetJSON.text(bytes)))
    }

    /// An error as the log names it: Windows logs a JsonException's type; the Mac says where the mistake is.
    private static func logKind(_ error: Error) -> String {
        (error as? NetJSON.Mistake).map { "JSON mistake near line \($0.line + 1)" } ?? Log.kind(of: error)
    }

    /// .NET's message for a value of the wrong kind.
    static func cannotConvert(_ type: String) -> String { "The JSON value could not be converted to \(type)." }
}

// MARK: The settings, one by one

extension AppSettings {
    /// One setting as settings.json holds it: how its value is read and written, the C# serializer's reflection over
    /// AppSettings' properties spelled out. .NET reads `null` for any setting that isn't a number or true/false; where
    /// the Windows app then works without the value, the Mac does the same (`vocabularyPrompt` and the brain's paths
    /// are cleared, `dictationVocabulary` is empty and `wakeWords` the default ones), and where the Windows app would
    /// stop with an error, the Mac keeps the setting's default, or leaves out a null item of a list, or entry of
    /// `replacements` and `snippets`.
    struct Field {
        let key: String

        /// Reads the value at the reader into the settings; throws a mistake for a value of the wrong kind.
        let read: (inout AppSettings, inout NetJSON.Reader) throws -> Void

        /// The value to write; nil leaves the setting out (C#'s `JsonIgnoreCondition.WhenWritingNull`).
        let value: (AppSettings) -> NetJSON.Value?
    }

    /// Every setting, by its key in settings.json, in the order a file lists them: Windows' order, then the Mac's.
    static let fields: [Field] = [
        text("modelFile", \.modelFile),
        text("vadModelFile", \.vadModelFile),
        text("hinglishModelFile", \.hinglishModelFile),
        text("hinglishAccurateModelFile", \.hinglishAccurateModelFile),
        text("dictationLanguageHotkey", \.dictationLanguageHotkey),
        number("threads", \.threads),
        number("audioContextSize", \.audioContextSize),
        optionalText("vocabularyPrompt", \.vocabularyPrompt),
        number("microphoneDevice", \.microphoneDevice),
        number("endSilenceMs", \.endSilenceMs),
        number("dictationEndSilenceMs", \.dictationEndSilenceMs),
        list("dictationVocabulary", \.dictationVocabulary, whenNull: []),
        number("maxCommandUtteranceMs", \.maxCommandUtteranceMs),
        flag("listenOnStartup", \.listenOnStartup),
        text("hotkey", \.hotkey),
        text("commandPrefix", \.commandPrefix),
        flag("requireCommandPrefixWhileTyping", \.requireCommandPrefixWhileTyping),
        flag("returnToCommandModeAfterSend", \.returnToCommandModeAfterSend),
        fraction("minCommandConfidence", \.minCommandConfidence),
        text("insertMethod", \.insertMethod),
        flag("discoverStartMenuApps", \.discoverStartMenuApps),
        flag("wakeWordEnabled", \.wakeWordEnabled),
        list("wakeWords", \.wakeWords),
        number("awakeSeconds", \.awakeSeconds),
        flag("soundFeedback", \.soundFeedback),
        flag("learnFromUsage", \.learnFromUsage),
        flag("brainEnabled", \.brainEnabled),
        optionalText("brainFolder", \.brainFolder),
        optionalText("brainServerPath", \.brainServerPath),
        optionalText("brainModelPath", \.brainModelPath),
        number("brainKeepLoadedMinutes", \.brainKeepLoadedMinutes),
        flag("pushToTalk", \.pushToTalk),
        flag("livePreview", \.livePreview),
        number("maxDictationSeconds", \.maxDictationSeconds),
        text("pasteLastHotkey", \.pasteLastHotkey),
        flag("removeFillerWords", \.removeFillerWords),
        flag("spokenPunctuation", \.spokenPunctuation),
        pairs("replacements", \.replacements),
        pairs("snippets", \.snippets),
        appsField,
        dictationKeyField,
    ]

    /// The settings by key, matched as .NET matches them: exactly, case included.
    private static let fieldsByKey = Dictionary(uniqueKeysWithValues: fields.map { (DotNet.ordinal($0.key), $0) })

    /// The defaults, for a null that keeps one.
    private static var defaults: AppSettings { AppSettings() }

    /// Text (C#'s `string`).
    private static func text(_ key: String, _ path: WritableKeyPath<AppSettings, String>) -> Field {
        Field(key: key, read: { settings, reader in
            switch try reader.value() {
            case .string(let text):
                settings[keyPath: path] = try reader.readable(text)
            case .null:
                settings[keyPath: path] = Self.defaults[keyPath: path]
            default:
                throw reader.mistake(Self.cannotConvert("System.String"))
            }
        }, value: { NetJSON.Value.string($0[keyPath: path]) })
    }

    /// Text that may be null (C#'s `string?`): null clears it, and the file then leaves it out.
    private static func optionalText(_ key: String, _ path: WritableKeyPath<AppSettings, String?>) -> Field {
        Field(key: key, read: { settings, reader in
            settings[keyPath: path] = try Self.readOptionalText(&reader)
        }, value: { settings in settings[keyPath: path].map { NetJSON.Value.string($0) } })
    }

    /// A whole number in C#'s `int` range, without a fraction or an exponent; null is a mistake, as in .NET.
    private static func number(_ key: String, _ path: WritableKeyPath<AppSettings, Int>) -> Field {
        Field(key: key, read: { settings, reader in
            guard case .number(let text) = try reader.value(), let number = NetJSON.Reader.int(text) else {
                throw reader.mistake(Self.cannotConvert("System.Int32"))
            }

            settings[keyPath: path] = number
        }, value: { NetJSON.Value.int($0[keyPath: path]) })
    }

    /// A number with a fraction (C#'s `float`).
    private static func fraction(_ key: String, _ path: WritableKeyPath<AppSettings, Float>) -> Field {
        Field(key: key, read: { settings, reader in
            guard case .number(let text) = try reader.value() else {
                throw reader.mistake(Self.cannotConvert("System.Single"))
            }

            settings[keyPath: path] = NetJSON.Reader.float(text)
        }, value: { NetJSON.Value.float($0[keyPath: path]) })
    }

    /// true or false; null is a mistake, as in .NET.
    private static func flag(_ key: String, _ path: WritableKeyPath<AppSettings, Bool>) -> Field {
        Field(key: key, read: { settings, reader in
            guard case .bool(let value) = try reader.value() else {
                throw reader.mistake(Self.cannotConvert("System.Boolean"))
            }

            settings[keyPath: path] = value
        }, value: { NetJSON.Value.bool($0[keyPath: path]) })
    }

    /// A list of text (C#'s `List<string>`). Null gives what Windows then uses: `whenNull` where it says, else the
    /// default.
    private static func list(
        _ key: String, _ path: WritableKeyPath<AppSettings, [String]>, whenNull: [String]? = nil
    ) -> Field {
        Field(key: key, read: { settings, reader in
            settings[keyPath: path] = try Self.readList(&reader) ?? whenNull ?? Self.defaults[keyPath: path]
        }, value: { settings in NetJSON.Value.array(settings[keyPath: path].map { NetJSON.Value.string($0) }) })
    }

    /// Text by text, in the file's order (C#'s `Dictionary<string, string>`).
    private static func pairs(_ key: String, _ path: WritableKeyPath<AppSettings, SettingsPairs>) -> Field {
        Field(key: key, read: { settings, reader in
            switch try reader.value() {
            case .objectStart:
                settings[keyPath: path] = try Self.readPairs(&reader)
            case .null:
                settings[keyPath: path] = Self.defaults[keyPath: path]
            default:
                throw reader.mistake(Self.cannotConvert("Dictionary<String, String>"))
            }
        }, value: { settings in
            NetJSON.Value.object(settings[keyPath: path].pairs.map { NetJSON.Property($0.key, .string($0.value)) })
        })
    }

    private static let appsField = Field(key: "apps", read: { settings, reader in
        settings.apps = try AppSettings.readApps(&reader)
    }, value: { settings in NetJSON.Value.array(settings.apps.map(AppSettings.appValue)) })

    private static let dictationKeyField = Field(key: "dictationKey", read: { settings, reader in
        settings.dictationKey = try AppSettings.readDictationKey(&reader)
    }, value: { settings in NetJSON.Value.string(AppSettings.dictationKeyName(settings.dictationKey)) })

    /// Text, or nil for null.
    static func readOptionalText(_ reader: inout NetJSON.Reader) throws -> String? {
        switch try reader.value() {
        case .string(let text):
            return try reader.readable(text)
        case .null:
            return nil
        default:
            throw reader.mistake(cannotConvert("System.String"))
        }
    }

    /// A list of text, or nil for null. A null item is left out.
    static func readList(_ reader: inout NetJSON.Reader) throws -> [String]? {
        switch try reader.value() {
        case .arrayStart:
            var items: [String] = []
            while try reader.nextItem() {
                switch try reader.value() {
                case .string(let text):
                    try items.append(reader.readable(text))
                case .null:
                    break
                default:
                    throw reader.mistake(cannotConvert("System.String"))
                }
            }

            return items
        case .null:
            return nil
        default:
            throw reader.mistake(cannotConvert("List<String>"))
        }
    }

    /// The members of the object just entered, as .NET reads them into a `Dictionary<string, string>`: a key written
    /// twice keeps its first place and takes its last value, and keys in different cases are different keys. An entry
    /// whose value ends up null is left out.
    static func readPairs(_ reader: inout NetJSON.Reader) throws -> SettingsPairs {
        var entries: [(key: String, value: String?)] = []
        var places: [[Unicode.Scalar]: Int] = [:]
        while case .name(let name) = try reader.nextMember() {
            let key = try reader.readable(name)
            let value: String?
            switch try reader.value() {
            case .string(let text):
                value = try reader.readable(text)
            case .null:
                value = nil
            default:
                throw reader.mistake(cannotConvert("System.String"))
            }

            if let place = places[DotNet.ordinal(key)] {
                entries[place].value = value
            } else {
                places[DotNet.ordinal(key)] = entries.count
                entries.append((key: key, value: value))
            }
        }

        return SettingsPairs(entries.compactMap { entry in entry.value.map { (key: entry.key, value: $0) } })
    }

    /// `apps`: a null list gives the default apps, and a null entry is left out.
    private static func readApps(_ reader: inout NetJSON.Reader) throws -> [AppEntry] {
        switch try reader.value() {
        case .arrayStart:
            var apps: [AppEntry] = []
            while try reader.nextItem() {
                switch try reader.value() {
                case .objectStart:
                    if let app = try readApp(&reader) {
                        apps.append(app)
                    }
                case .null:
                    break
                default:
                    throw reader.mistake(cannotConvert("AppEntry"))
                }
            }

            return apps
        case .null:
            return defaultApps
        default:
            throw reader.mistake(cannotConvert("List<AppEntry>"))
        }
    }

    /// The keys of an app in settings.json (C#'s `AppEntry` record), in the order Windows writes them.
    private enum AppKey: String, CaseIterable {
        case name, aliases, launch, processNames, windowTitleContains, submitKeys, newLineKeys, textArea, textAreaName
        case searchKeys, addressBarKeys, newWindowKeys, newDocumentKeys
    }

    private static let appKeys = Dictionary(
        uniqueKeysWithValues: AppKey.allCases.map { (DotNet.ordinal($0.rawValue), $0) })

    /// One app, from the object just entered. `name` and `launch` are required (C#'s `required`): one that's missing
    /// is a mistake at the app's closing brace, and one that's null leaves the app out (Windows would stop with an
    /// error where it uses it). A null `submitKeys` sends nothing, as on Windows; another null keeps the default.
    private static func readApp(_ reader: inout NetJSON.Reader) throws -> AppEntry? {
        var app = AppEntry(name: "", launch: "")
        var nameRead: String??
        var launchRead: String??
        while case .name(let name) = try reader.nextMember() {
            let key = try reader.readable(name)
            switch appKeys[DotNet.ordinal(key)] {
            case .name?: nameRead = try .some(readOptionalText(&reader))
            case .aliases?: app.aliases = try readList(&reader) ?? []
            case .launch?: launchRead = try .some(readOptionalText(&reader))
            case .processNames?: app.processNames = try readList(&reader) ?? []
            case .windowTitleContains?: app.windowTitleContains = try readOptionalText(&reader)
            case .submitKeys?: app.submitKeys = try readOptionalText(&reader) ?? ""
            case .newLineKeys?: app.newLineKeys = try readOptionalText(&reader) ?? "Shift+Enter"
            case .textArea?: app.textArea = try readOptionalText(&reader)
            case .textAreaName?: app.textAreaName = try readOptionalText(&reader)
            case .searchKeys?: app.searchKeys = try readOptionalText(&reader)
            case .addressBarKeys?: app.addressBarKeys = try readOptionalText(&reader)
            case .newWindowKeys?: app.newWindowKeys = try readOptionalText(&reader)
            case .newDocumentKeys?: app.newDocumentKeys = try readOptionalText(&reader)
            case nil:
                let value = try reader.value()
                try reader.skip(value)
            }
        }

        guard let nameOrNull = nameRead, let launchOrNull = launchRead else {
            throw reader.mistake(
                "JSON deserialization for type 'AppEntry' was missing required properties including: 'name', 'launch'.")
        }

        guard let name = nameOrNull, let launch = launchOrNull else { return nil }
        app.name = name
        app.launch = launch
        return app
    }

    /// An app as Windows writes it: its properties in the record's order, without the ones that are nil.
    private static func appValue(_ app: AppEntry) -> NetJSON.Value {
        var properties: [NetJSON.Property] = []
        func add(_ key: AppKey, _ text: String?) {
            if let text {
                properties.append(NetJSON.Property(key.rawValue, .string(text)))
            }
        }

        func addList(_ key: AppKey, _ list: [String]) {
            properties.append(NetJSON.Property(key.rawValue, .array(list.map { NetJSON.Value.string($0) })))
        }

        add(.name, app.name)
        addList(.aliases, app.aliases)
        add(.launch, app.launch)
        addList(.processNames, app.processNames)
        add(.windowTitleContains, app.windowTitleContains)
        add(.submitKeys, app.submitKeys)
        add(.newLineKeys, app.newLineKeys)
        add(.textArea, app.textArea)
        add(.textAreaName, app.textAreaName)
        add(.searchKeys, app.searchKeys)
        add(.addressBarKeys, app.addressBarKeys)
        add(.newWindowKeys, app.newWindowKeys)
        add(.newDocumentKeys, app.newDocumentKeys)
        return .object(properties)
    }

    /// `dictationKey`: "Fn" or "RightOption", in any case and with spaces around it, as ThumbFree for Mac reads it;
    /// anything else is a mistake, as a value of the wrong kind is in every other setting.
    private static func readDictationKey(_ reader: inout NetJSON.Reader) throws -> FnTapKeys.TapKey {
        switch try reader.value() {
        case .string(let text):
            let name = try DotNet.trim(reader.readable(text))
            guard let key = FnTapKeys.TapKey.allCases.first(where: {
                DotNet.equalsOrdinalIgnoreCase(dictationKeyName($0), name)
            }) else {
                throw reader.mistake("The dictation key must be \"Fn\" or \"RightOption\".")
            }

            return key
        case .null:
            return defaults.dictationKey
        default:
            throw reader.mistake(cannotConvert("System.String"))
        }
    }

    /// The key's name in settings.json, as ThumbFree for Mac writes it ("Fn" or "RightOption").
    static func dictationKeyName(_ key: FnTapKeys.TapKey) -> String { key.settingsName }
}

/// A { } of text by text in settings.json (`replacements`, `snippets`), in the file's order, which decides which of two
/// replacements or two snippets wins. Read from a file, as .NET reads one, a key written twice keeps its first place
/// and takes its last value, and keys that differ only in case are different keys. The defaults, like Windows', ignore
/// case (`ignoresCase`), which matters only when a key is set.
public struct SettingsPairs: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var pairs: [(key: String, value: String)] = []

    /// Keys compare as `StringComparer.OrdinalIgnoreCase` compares them, rather than exactly.
    public let ignoresCase: Bool

    public init(ignoringCase: Bool = false) {
        ignoresCase = ignoringCase
    }

    /// The pairs in order; of a key given twice, the first keeps its place and the last its value.
    public init(_ pairs: [(key: String, value: String)], ignoringCase: Bool = false) {
        ignoresCase = ignoringCase
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements.map { (key: $0.0, value: $0.1) })
    }

    public var count: Int { pairs.count }

    public var isEmpty: Bool { pairs.isEmpty }

    /// The value for `key`. A new key goes at the end; nil removes the key.
    public subscript(key: String) -> String? {
        get { index(of: key).map { pairs[$0].value } }
        set {
            if let i = index(of: key) {
                if let newValue {
                    pairs[i].value = newValue
                } else {
                    pairs.remove(at: i)
                }
            } else if let newValue {
                pairs.append((key: key, value: newValue))
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: String)]> { pairs.makeIterator() }

    /// The same entries in the same order, compared as C# compares text (ordinal), whatever the keys' comparison.
    public static func == (lhs: SettingsPairs, rhs: SettingsPairs) -> Bool {
        lhs.pairs.count == rhs.pairs.count && zip(lhs.pairs, rhs.pairs).allSatisfy { a, b in
            DotNet.ordinalEquals(a.key, b.key) && DotNet.ordinalEquals(a.value, b.value)
        }
    }

    private func index(of key: String) -> Int? {
        if ignoresCase {
            let wanted = DotNet.ordinalIgnoreCase(key)
            return pairs.firstIndex { DotNet.ordinalIgnoreCase($0.key) == wanted }
        }

        return pairs.firstIndex { DotNet.ordinalEquals($0.key, key) }
    }
}
