// swift-tools-version: 5.10
import PackageDescription

// Voice Assistant for Mac ("Hey Jarvis"). Its dictation (formatting, speech, the Fn hotkey, the pill, typing) is
// ThumbFree for Mac's, from thumbfree-mac; this package adds the assistant: commands, navigation, the idea board and the
// AI brain. docs/design.md has the plan.
let package = Package(
    name: "VoiceAssistant",
    platforms: [.macOS(.v13)],
    products: [
        // The idea board: notes, lists, reminder times, its voice grammar and store. A Swift port of
        // windows-voice-assistant src/VoiceAssistant.Board (no OS calls).
        .library(name: "VoiceAssistantBoard", targets: ["VoiceAssistantBoard"]),
        // The assistant's logic: wake word, command parser, navigation and editing, segmenter, phrase memory, the
        // interaction controller, and the AI brain's prompt and plan reader. A Swift port of src/VoiceAssistant.Core.
        .library(name: "VoiceAssistantCore", targets: ["VoiceAssistantCore"]),
        // The Mac desktop layer: the core's IDesktop on Accessibility (AXUIElement), NSWorkspace and CGEvent, the
        // number badges, and the AI brain's llama-server.
        .library(name: "VoiceAssistantMac", targets: ["VoiceAssistantMac"]),
        .executable(name: "VoiceAssistant", targets: ["VoiceAssistant"]),
    ],
    dependencies: [
        // Both Mac apps move together on main until the first release, which will pin a version.
        .package(url: "https://github.com/shivam098/thumbfree-mac.git", branch: "main"),
    ],
    targets: [
        .target(name: "VoiceAssistantBoard"),
        .target(
            name: "VoiceAssistantCore",
            dependencies: ["VoiceAssistantBoard", .product(name: "ThumbFreeCore", package: "thumbfree-mac")]),
        .target(
            name: "VoiceAssistantMac",
            dependencies: ["VoiceAssistantCore", .product(name: "ThumbFreeMac", package: "thumbfree-mac")]),
        .executableTarget(
            name: "VoiceAssistant",
            dependencies: [
                "VoiceAssistantCore", "VoiceAssistantMac",
                .product(name: "ThumbFreeSpeech", package: "thumbfree-mac"),
            ]),
        // Lowercase tests/, as in the ThumbFree repos.
        .testTarget(name: "VoiceAssistantCoreTests", dependencies: ["VoiceAssistantCore"], path: "tests/VoiceAssistantCoreTests"),
    ]
)
