import SwiftUI
import ThumbFreeCore

/// Everything you can say, grouped (windows-voice-assistant `HelpText`), with the Mac's keys and apps: the dictation
/// key (Fn or Right Option) where Windows says Ctrl+Win, the Mac's hotkeys where it says Alt+Shift+Z and Alt+Shift+H,
/// TextEdit for Notepad and Finder for File Explorer.
enum HelpText {
    static func sections(_ keys: KeyNames) -> [HelpSection] {
        let key = keys.dictation
        // Windows' second key, Ctrl+Win+Space, has no counterpart: the Mac's other dictation key is a setting.
        let otherKey = key == "Fn" ? "Right Option" : "Fn"
        let pasteLast = keys.hotkeys.pasteLast
        var dictate = [
            "Tap \(key) (press and let go) → recording starts; no need to hold the key",
            "Speak: the pill shows your voice level and your words as you say them",
            "Tap \(key) again → “Transcribing…”, then the text is typed where your cursor is",
            "\(otherKey) can be the key instead (Settings › Dictation key)",
            pasteLast.isEmpty ? "Esc → cancel" : "Esc → cancel  ·  \(pasteLast) → paste the last dictation again",
            "Say “comma”, “question mark”, “new line”; “um/uh” are removed",
            "“…scratch that…” drops the phrase before it",
        ]
        if !keys.hotkeys.language.isEmpty {
            dictate.append(
                "\(keys.hotkeys.language) → Hindi + English (typed in Roman letters); press again for English")
        }

        return [
            HelpSection(title: "Dictate anywhere", lines: dictate),
            HelpSection(
                title: "Idea board",
                lines: [
                    "Tap \(key): “Add to my ideas, a voice game for kids”, tap again → filed on the board, not typed",
                    "\(key) dictation with no text box in focus (desktop, a list) → saved on the board: a task with a "
                        + "time → Reminders, “I have to …” / “buy milk” → To-do, else Ideas",
                    "“Add renew passport to my to-do list” · “Add to brainstorming, pricing ideas”",
                    "“Hey Jarvis, remind me to call mom tomorrow at 5 pm” → a reminder pops up then",
                    "“Hey Jarvis, note down that the demo needs subtitles” → Ideas",
                    "“Hey Jarvis, show my ideas / reminders / to-do list / board”",
                    "“Hey Jarvis, mark renew passport as done”",
                    "Times: in 10 minutes · in an hour · tonight · tomorrow at 9 · on Friday at 10 am · next Monday",
                ]),
            HelpSection(
                title: "Voice commands (start with “Hey Jarvis”)",
                lines: [
                    "“Open TextEdit” · “Open Chrome” · “Open GitHub Copilot” · “Switch to Chrome”",
                    "“Start typing” (TextEdit: the document; Copilot: the message box)",
                    "“Go to the search box” · “Go to the address bar” · “Search for weather in Bangalore”",
                    "“Open instagram.com” · “Open github.com in a new tab” → opens the page in the browser you're "
                        + "using",
                    "“New tab”, “Refresh”, “Copy”, “Paste”, “Undo”, “Save”",
                    "“Go back” / “Previous page” · “Go forward” / “Next page” · “Go up” (Finder)",
                    "“Press enter / tab / escape / down …”",
                    "“Pause listening”",
                ]),
            HelpSection(
                title: "While typing (red pill): pause briefly before each command",
                lines: [
                    "“Send” / “Search” · “Scratch that” · “Clear box” · “New line” · “Stop typing”",
                    "“Delete the last 3 words / sentence / line / paragraph”",
                    "“Delete the word very” · “Replace the word Monday with Tuesday”",
                    "“Hey Jarvis, add to my ideas, …” files a note and typing carries on",
                ]),
            HelpSection(
                title: "Navigate (after “Hey Jarvis”)",
                lines: [
                    "“Go to the first tab” · “Go to the YouTube tab”",
                    "“Click New on the left” · “Click Library” · “Select Bibhash Morang” (chat lists)",
                    "“Start typing in YouTube” · “Start typing in the message box”",
                    "“Show numbers” → say a number · “Hide numbers”",
                    "Delete / merge / sign out / pay → say “yes” to confirm",
                ]),
            HelpSection(
                title: "Ask for anything: the AI brain (Settings › AI brain › Download, runs on this Mac)",
                lines: [
                    "“Open the MrBeast video on YouTube” → switches to that window and clicks the video",
                    "“Mute the video” · “Play the second video” · “Maximize this window”",
                    "“What's the weather in Bangalore?” · “Find a pasta recipe on YouTube” → opens the results",
                    "“Open Instagram in a new tab” → opens instagram.com in a new tab of the browser you're using",
                    "“Reply thanks to Rahul on WhatsApp” → types it, then asks “Send it?” → say “yes”",
                    "“How are you?” · “Tell me a joke” → answered on the pill",
                    "Start each request with “Hey Jarvis” · it asks for “yes” before sending, deleting or closing "
                        + "anything · Esc stops it",
                ]),
        ]
    }
}

/// A group of things to say: its title and its lines.
public struct HelpSection: Equatable, Sendable {
    public let title: String
    public let lines: [String]
}

/// "What you can say" (windows-voice-assistant `HelpPage`): every section, or what matches the search box ("remind",
/// "tab", "delete"), case aside: a section whose title matches shows all its lines, another only the lines that match.
@MainActor
public final class HelpModel: ObservableObject {
    /// The search box's tooltip and placeholder.
    public static let searchHelp = "Filter, e.g. “remind” or “tab”"

    /// What shows when nothing matches.
    public static let noMatch = "Nothing matches. Try a single word like “tab” or “remind”."

    @Published public var filter = ""

    private let all: [HelpSection]

    public init(keys: KeyNames) {
        all = HelpText.sections(keys)
    }

    /// What shows for the search box's text, trimmed; empty when nothing matches.
    public var sections: [HelpSection] { Self.matching(all, DotNet.trim(filter)) }

    static func matching(_ sections: [HelpSection], _ filter: String) -> [HelpSection] {
        guard !filter.isEmpty else { return sections }
        return sections.compactMap { section in
            if contains(section.title, filter) {
                return section
            }

            let lines = section.lines.filter { contains($0, filter) }
            return lines.isEmpty ? nil : HelpSection(title: section.title, lines: lines)
        }
    }

    /// `text.Contains(part, StringComparison.OrdinalIgnoreCase)`.
    static func contains(_ text: String, _ part: String) -> Bool {
        DotNet.contains(DotNet.string(DotNet.ordinalIgnoreCase(text)), DotNet.string(DotNet.ordinalIgnoreCase(part)))
    }
}

/// The page: the heading and the search box, and under them the sections in a scroll.
struct HelpPage: View {
    @ObservedObject var model: HelpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.heading("What you can say")
            TextField(HelpModel.searchHelp, text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .frame(width: 360)
                .help(HelpModel.searchHelp)
                .padding(.bottom, 12)
            ScrollView {
                HelpSections(sections: model.sections)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The sections as cards, a title and its lines in each, or what to try when nothing matches.
struct HelpSections: View {
    let sections: [HelpSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                Theme.label(HelpModel.noMatch, colour: Theme.muted)
            }

            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: section.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(Theme.text))
                        .padding(.bottom, 8)
                    ForEach(section.lines, id: \.self) { line in
                        Theme.label("•  " + line).padding(.bottom, 4)
                    }
                }
                .themeCard()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
