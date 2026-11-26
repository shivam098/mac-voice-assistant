import Foundation
import ThumbFreeCore
import ThumbFreeSpeech

/// Where Voice Assistant keeps its files on this Mac (windows-voice-assistant `AppPaths`), in the same formats as
/// Windows so they can move between the two. Windows splits them between %APPDATA% (settings, the board, what it has
/// learned) and %LOCALAPPDATA% (models, the AI brain, logs and the state flags); the Mac keeps them together in
/// Application Support, and the logs where Console finds them. Every folder can be changed, for tests.
public struct AppPaths: Equatable, Sendable {
    /// ~/Library/Application Support/VoiceAssistant: settings.json, board.json, learned.json and the state flags.
    public var data: String

    /// ~/Library/Logs/VoiceAssistant.
    public var logs: String

    /// Where speech models are downloaded: models/ in `data`.
    public var models: String

    /// Where the AI brain's files go unless the `brainFolder` setting names another folder: brain/ in `data`.
    public var brain: String

    /// Other apps' model folders, read only, so a model one of them has isn't downloaded again: ThumbFree for Mac's.
    public var sharedModels: [String]

    public init(data: String, logs: String, models: String? = nil, brain: String? = nil, sharedModels: [String] = []) {
        self.data = data
        self.logs = logs
        self.models = models ?? (data as NSString).appendingPathComponent("models")
        self.brain = brain ?? (data as NSString).appendingPathComponent("brain")
        self.sharedModels = sharedModels
    }

    /// This Mac's folders.
    public static var standard: AppPaths {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (library as NSString).appendingPathComponent("Application Support")
        return AppPaths(
            data: (support as NSString).appendingPathComponent("VoiceAssistant"),
            logs: (library as NSString).appendingPathComponent("Logs/VoiceAssistant"),
            sharedModels: [ModelStore.defaultFolder])
    }

    /// settings.json, in the Windows app's format.
    public var settingsFile: String { file("settings.json") }

    /// The idea board (VoiceAssistantBoard's `BoardStore`): ideas, brainstorm, to-do and reminders.
    public var boardFile: String { file("board.json") }

    /// What it has learned: rephrasings and how often each app is opened (`LearnedStore`).
    public var learnedFile: String { file("learned.json") }

    /// Present while the status pill is minimized (shown only while it has something to say).
    public var overlayMinimizedFlag: String { file("overlay-minimized") }

    /// Present while dictation uses the Hindi + English model.
    public var hinglishDictationFlag: String { file("dictation-hinglish") }

    /// Present while Hindi + English dictation uses the larger, more accurate (slower) model.
    public var hinglishAccurateFlag: String { file("dictation-hinglish-accurate") }

    /// The AI brain's folder: `brain`, unless `setting` (the `brainFolder` setting) names another, which is trimmed
    /// and expanded as `expand` says.
    public func brainFolder(_ setting: String?) -> String {
        guard let setting, !DotNet.isNullOrWhiteSpace(setting) else { return brain }
        return Self.expand(DotNet.trim(setting))
    }

    /// A file chosen in settings.json (`brainServerPath`, `brainModelPath`), trimmed and expanded as `expand` says;
    /// nil when the setting is blank, for the default.
    public static func chosenFile(_ setting: String?) -> String? {
        guard let setting, !DotNet.isNullOrWhiteSpace(setting) else { return nil }
        return expand(DotNet.trim(setting))
    }

    /// A path from settings.json (`brainFolder`, `brainServerPath`, `brainModelPath`): environment variables written
    /// %NAME% are replaced, as .NET's `Environment.ExpandEnvironmentVariables` does on a Mac, and a leading "~" is the
    /// home folder, the Mac's way of writing it.
    public static func expand(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        let name = Array(path.unicodeScalars)
        var result = String.UnicodeScalarView()
        var last = 0
        while last < name.count, let next = name[(last + 1)...].firstIndex(of: "%") {
            if name[last] == "%", let value = environment[DotNet.string(name[(last + 1)..<next])] {
                result.append(contentsOf: value.unicodeScalars)
                last = next + 1
                continue
            }

            result.append(contentsOf: name[last..<next])
            last = next
        }

        if last < name.count {
            result.append(contentsOf: name[last...])
        }

        let expanded = String(result)
        return expanded.hasPrefix("~") ? (expanded as NSString).expandingTildeInPath : expanded
    }

    private func file(_ name: String) -> String { (data as NSString).appendingPathComponent(name) }
}

/// On/off choices remembered as empty flag files (windows-voice-assistant `StateFlags`), so settings.json is never
/// rewritten for them.
public enum StateFlags {
    public static func isSet(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Creates or deletes the flag file; a failure is logged, never thrown.
    public static func set(_ path: String, _ on: Bool) {
        do {
            if on {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: path))
            } else if unlink(path) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Log.warn("couldn't save \((path as NSString).lastPathComponent): \(Log.kind(of: error))")
        }
    }
}
