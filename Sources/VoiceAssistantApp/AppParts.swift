import Foundation
import ThumbFreeMac
import VoiceAssistantCore
import VoiceAssistantMac

/// The core's desktop as the app makes it, with how it finds the installed apps and the permissions it still needs.
public struct DesktopParts {
    public var desktop: JarvisDesktop

    /// The installed apps, for "open …" (`MacDesktop.discoverApps`); nil finds none.
    public var discoverApps: (@Sendable () -> [AppEntry])?

    /// The permissions the desktop works with that macOS hasn't given the app yet (`MacDesktop.missingPermissions`),
    /// for the app to explain; nil when it needs none.
    public var missingPermissions: (@Sendable () -> [Permissions.Kind])?

    public init(
        desktop: JarvisDesktop,
        discoverApps: (@Sendable () -> [AppEntry])? = nil,
        missingPermissions: (@Sendable () -> [Permissions.Kind])? = nil
    ) {
        self.desktop = desktop
        self.discoverApps = discoverApps
        self.missingPermissions = missingPermissions
    }
}

/// The parts the app is made of on this Mac: the one place its desktop and its AI brain are chosen.
public struct AppParts {
    /// Makes the desktop, given the insertion method to read before each typing ("Paste" or "Type"); nil gives a build
    /// without one, where the assistant doesn't start.
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

    /// This Mac's parts: VoiceAssistantMac's desktop and AI brain.
    public static var standard: AppParts { AppParts(desktop: makeDesktop, brain: makeBrain) }

    /// VoiceAssistantMac's `MacDesktop` (C#'s `WindowsDesktop`): it reads `insertMethod` before each typing ("Paste",
    /// or "Type" for key events), finds the installed apps, and its log lines (outcomes, counts, timings and app names,
    /// as Windows logs them; never text or window titles) go to the app's log.
    public static func makeDesktop(_ insertMethod: @escaping @Sendable () -> String) -> DesktopParts {
        let desktop = MacDesktop(insertMethod: insertMethod, log: { Log.info($0) })
        return DesktopParts(
            desktop: desktop, discoverApps: { desktop.discoverApps() },
            missingPermissions: { desktop.missingPermissions })
    }

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

    /// The desktop, reading `insertMethod` before each typing (settings.json's, which the self-test's `insert`
    /// switches); nil in a build without one.
    func desktopParts(insertMethod: Locked<String>) -> DesktopParts? {
        guard let make = desktop else { return nil }
        return make { insertMethod.value }
    }

    /// The host's parts: the desktop, the microphone, whisper.cpp, the model downloads and the AI brain.
    func hostParts(_ settings: AppSettings, _ paths: AppPaths, desktop: DesktopParts) -> HostParts {
        HostParts(
            desktop: desktop.desktop, discoverApps: desktop.discoverApps, microphone: SystemMicrophone(),
            speech: WhisperSpeech(), models: ModelDownloader(paths: paths),
            brain: settings.brainEnabled ? brain?(settings, paths) : nil)
    }
}
