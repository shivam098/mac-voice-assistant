import VoiceAssistantApp

// Voice Assistant in the menu bar: VoiceAssistantApp's AppController is the app; this only starts it.
MainActor.assumeIsolated {
    AppController.main(CommandLine.arguments)
}