import ThumbFreeCore

/// The assistant's logic (docs/design.md), a Swift port of windows-voice-assistant `src/VoiceAssistant.Core` with its
/// tests: the command parser and wake word, the navigation and editing grammars, text editing, the utterance
/// segmenter, phrase memory, the app catalog, name matching, the desktop the core drives (`JarvisDesktop`), and the AI
/// brain's prompt, plan reader, safety limits, screen summary and llama-server client. The platform's shortcuts come
/// from a `ShortcutKeys`, and what the brain's limits mean there from a `BrainPlatform`. Dictation itself is
/// ThumbFree's (ThumbFreeCore).
public enum VoiceAssistantCore {
    public static let version = "0.1.0"
    public static let thumbFreeCoreVersion = ThumbFreeCore.version
}
