import VoiceAssistantApp

// Voice Assistant in the menu bar. VoiceAssistantApp's AppLauncher is the app until the assistant host and the UI
// land; this only starts it.
MainActor.assumeIsolated {
    AppLauncher.main(CommandLine.arguments)
}
