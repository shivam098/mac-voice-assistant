import Foundation
import VoiceAssistantCore
import VoiceAssistantMac

/// The core's desktop as the app makes it, with how it finds the installed apps.
public struct DesktopParts {
    public var desktop: JarvisDesktop

    /// The installed apps, for "open …" (`MacDesktop.discoverApps`); nil finds none.
    public var discoverApps: (@Sendable () -> [AppEntry])?

    public init(desktop: JarvisDesktop, discoverApps: (@Sendable () -> [AppEntry])? = nil) {
        self.desktop = desktop
        self.discoverApps = discoverApps
    }
}

/// The parts the app is made of on this Mac: the one place its desktop and its AI brain are chosen. The desktop
/// (VoiceAssistantMac's `MacDesktop`) is still being built, so the final wiring fills it in here; until then this build
/// has none, and the assistant doesn't start.
public struct AppParts {
    /// Makes the desktop, given the insertion method to read before each typing ("Paste" or "Type").
    public var desktop: ((_ insertMethod: @escaping @Sendable () -> String) -> DesktopParts)?

    /// Makes the AI brain, when settings.json's `brainEnabled` is on.
    public var brain: ((AppSettings, AppPaths) -> AssistantBrain)?

    public init(
        desktop: ((_ insertMethod: @escaping @Sendable () -> String) -> DesktopParts)?,
        brain: ((AppSettings, AppPaths) -> AssistantBrain)?
    ) {
        self.desktop = desktop
        self.brain = brain
    }

    /// This build's parts: the AI brain, and no desktop yet.
    public static var standard: AppParts { AppParts(desktop: nil, brain: makeBrain) }

    /// VoiceAssistantMac's `LlamaBrain`, with its files where settings.json says (C#'s `new LlamaBrain(new
    /// BrainFiles(...), ...)`), unloaded after `brainKeepLoadedMinutes` unused, and its log lines in the app's log.
    public static func makeBrain(_ settings: AppSettings, _ paths: AppPaths) -> AssistantBrain {
        let files = BrainFiles(
            folder: paths.brainFolder(settings.brainFolder),
            serverPath: AppPaths.chosenFile(settings.brainServerPath),
            modelPath: AppPaths.chosenFile(settings.brainModelPath))
        let brain = LlamaBrain(files: files, keepLoaded: TimeInterval(max(0, settings.brainKeepLoadedMinutes)) * 60)
        brain.onLog = { level, line in
            switch level {
            case .info:
                Log.info(line)
            case .warning:
                Log.warn(line)
            case .error:
                Log.error(line)
            }
        }

        return brain
    }

    /// The host's parts: the desktop, the microphone, whisper.cpp, the model downloads and the AI brain; nil without a
    /// desktop.
    func hostParts(_ settings: AppSettings, _ paths: AppPaths, insertMethod: Locked<String>) -> HostParts? {
        guard let desktop else { return nil }
        let made = desktop { insertMethod.value }
        return HostParts(
            desktop: made.desktop, discoverApps: made.discoverApps, microphone: SystemMicrophone(),
            speech: WhisperSpeech(), models: ModelDownloader(paths: paths),
            brain: settings.brainEnabled ? brain?(settings, paths) : nil)
    }
}
