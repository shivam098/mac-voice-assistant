import ThumbFreeCore

/// The assistant's logic (docs/design.md). The port of windows-voice-assistant src/VoiceAssistant.Core lands here, file
/// by file with its tests; dictation itself is ThumbFree's (ThumbFreeCore).
public enum VoiceAssistantCore {
    public static let version = "0.1.0"
    public static let thumbFreeCoreVersion = ThumbFreeCore.version
}
