import XCTest
@testable import VoiceAssistantApp

/// "What you can say" (windows-voice-assistant HelpPage.cs and HelpText.cs): every section until a search, then what
/// matches; the Mac's keys and apps in the lines.
final class HelpPageTests: XCTestCase {
    @MainActor
    func testEverySectionShowsUntilASearch() {
        let help = HelpModel(keys: KeyNames())
        XCTAssertEqual(
            help.sections.map(\.title),
            [
                "Dictate anywhere", "Idea board", "Voice commands (start with “Hey Jarvis”)",
                "While typing (red pill): pause briefly before each command", "Navigate (after “Hey Jarvis”)",
                "Ask for anything: the AI brain (Settings › AI brain › Download, runs on this Mac)",
            ])
        XCTAssertEqual(help.sections.map(\.lines.count), [8, 8, 8, 4, 5, 7], "as many lines as Windows")
    }

    @MainActor
    func testASearchShowsTheLinesThatMatchCaseAsideOrAWholeSectionByItsTitle() {
        let help = HelpModel(keys: KeyNames())
        help.filter = "remind"
        XCTAssertEqual(help.sections.map(\.title), ["Idea board"])
        XCTAssertEqual(
            help.sections.first?.lines,
            [
                "Fn dictation with no text box in focus (desktop, a list) → saved on the board: a task with a time → "
                    + "Reminders, “I have to …” / “buy milk” → To-do, else Ideas",
                "“Hey Jarvis, remind me to call mom tomorrow at 5 pm” → a reminder pops up then",
                "“Hey Jarvis, show my ideas / reminders / to-do list / board”",
            ])

        help.filter = "TAB"
        XCTAssertEqual(
            help.sections.map(\.title),
            [
                "Voice commands (start with “Hey Jarvis”)", "Navigate (after “Hey Jarvis”)",
                "Ask for anything: the AI brain (Settings › AI brain › Download, runs on this Mac)",
            ])
        XCTAssertEqual(help.sections.map(\.lines.count), [3, 1, 1])

        help.filter = "  delete "
        XCTAssertEqual(
            help.sections.map(\.lines),
            [
                [
                    "“Delete the last 3 words / sentence / line / paragraph”",
                    "“Delete the word very” · “Replace the word Monday with Tuesday”",
                ],
                ["Delete / merge / sign out / pay → say “yes” to confirm"],
            ])

        help.filter = "idea board"
        XCTAssertEqual(help.sections.map(\.title), ["Idea board"])
        XCTAssertEqual(help.sections.first?.lines.count, 8, "a title that matches shows all its lines")

        help.filter = "zzz"
        XCTAssertEqual(help.sections, [], "“Nothing matches.”")
        help.filter = " "
        XCTAssertEqual(help.sections.count, 6)
    }

    @MainActor
    func testTheLinesNameTheMacsKeysAndApps() {
        func text(_ keys: KeyNames) -> String {
            var lines: [String] = []
            for section in HelpText.sections(keys) {
                lines.append(section.title)
                lines.append(contentsOf: section.lines)
            }

            return lines.joined(separator: "\n")
        }

        let fn = text(KeyNames())
        for windows in ["Ctrl", "Win", "Alt+", "Notepad", "File Explorer", "PC"] {
            XCTAssertFalse(fn.contains(windows), windows)
        }

        for mac in [
            "Tap Fn (press and let go) → recording starts; no need to hold the key",
            "Right Option can be the key instead (Settings › Dictation key)",
            "Esc → cancel  ·  ⌃⇧Z → paste the last dictation again",
            "⌃⇧H → Hindi + English (typed in Roman letters); press again for English",
            "“Open TextEdit” · “Open Chrome” · “Open GitHub Copilot” · “Switch to Chrome”",
            "“Go up” (Finder)", "runs on this Mac",
        ] {
            XCTAssertTrue(fn.contains(mac), mac)
        }

        let option = HelpText.sections(
            KeyNames(dictation: "Right Option", hotkeys: MenuHotkeys(pasteLast: "", language: "")))
        XCTAssertEqual(
            option.first?.lines,
            [
                "Tap Right Option (press and let go) → recording starts; no need to hold the key",
                "Speak: the pill shows your voice level and your words as you say them",
                "Tap Right Option again → “Transcribing…”, then the text is typed where your cursor is",
                "Fn can be the key instead (Settings › Dictation key)", "Esc → cancel",
                "Say “comma”, “question mark”, “new line”; “um/uh” are removed",
                "“…scratch that…” drops the phrase before it",
            ],
            "hotkeys that aren't set aren't named")
    }
}
