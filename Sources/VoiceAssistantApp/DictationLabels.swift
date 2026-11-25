/// Activity labels for a dictation (windows-voice-assistant `DictationLabels`); the pill shows each with its own look.
public enum DictationLabels {
    /// Recording: the level meter, the live preview and how to finish.
    public static let listening = "Listening…"

    /// Recording has stopped and the speech is being turned into text.
    public static let transcribing = "Transcribing…"

    /// Shown under `listening`: "Fn to finish · Esc to cancel" (Windows: "Ctrl+Win to finish · Esc to cancel").
    public static func listeningHint(_ settings: AppSettings) -> String {
        "\(settings.dictationKeyLabel) to finish · Esc to cancel"
    }
}
