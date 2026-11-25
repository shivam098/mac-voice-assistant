import ThumbFreeMac
import VoiceAssistantCore

/// The app's own layer (docs/design.md), ported from windows-voice-assistant src/VoiceAssistant.App: settings and what
/// it has learned, the assistant host (always listening for "Hey Jarvis", Fn dictation), the AI brain's server, the menu
/// bar, the pill, the window and the reminders. The VoiceAssistant executable is a thin launcher for it.
public enum VoiceAssistantApp {
    public static let version = VoiceAssistantCore.version

    /// The app's bundle identifier. ThumbFree for Mac looks for it, because both apps use Fn.
    public static let bundleIdentifier = ThumbFreeMac.jarvisBundleIdentifier
}
