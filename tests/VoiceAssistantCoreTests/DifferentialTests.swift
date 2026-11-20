import Foundation
import ThumbFreeCore
import VoiceAssistantBoard
import XCTest
@testable import VoiceAssistantCore

/// A differential check against the C# core: 3,000 generated utterances through the parser (four parsers, every
/// mode), the wake-word checks, name cleaning and scoring, site profiles, the app catalog and phrase memory; 1,500
/// generated texts through the editing plans; and 800 generated screens of elements and tabs through the resolver.
/// The inputs are drawn with .NET's seeded `Random` from the same lists as the harness (jarvis-core-harness in the
/// session files: Gen.cs, Diff.cs); each case's outputs must hash to what the C# core gives (`differentialHashes`).
/// A failure prints the Swift outputs; `dotnet run -- show u|e|r <index>` prints the C# ones.
final class DifferentialTests: XCTestCase {
    func testTheSwiftCoreGivesTheCSharpCoresOutputs() {
        let golden = differentialHashes.split(separator: "\n").map(String.init)
        XCTAssertEqual(3000 + 1500 + 800, golden.count)
        var failures: [String] = []
        var mismatches = 0
        var next = 0
        func record(_ section: String, _ index: Int, _ outputs: [String]) {
            let actual = Serialized.hash(outputs.joined(separator: "\u{1}"))
            if next < golden.count && actual != golden[next] {
                mismatches += 1
                if failures.count < 8 {
                    let shown = outputs.enumerated().map { "    \($0.offset): \(Escaped.encode($0.element))" }
                    failures.append("\(section) \(index):\n" + shown.joined(separator: "\n"))
                }
            }

            next += 1
        }

        let context = Context()
        var random = DotNetRandom(2026)
        for i in 0..<3000 {
            record("u", i, utterance(&random, context))
        }

        random = DotNetRandom(2027)
        for i in 0..<1500 {
            record("e", i, edit(&random))
        }

        random = DotNetRandom(2028)
        for i in 0..<800 {
            record("r", i, resolution(&random))
        }

        XCTAssertEqual(0, mismatches, "\(mismatches) cases differ; the first:\n" + failures.joined(separator: "\n"))
    }
}

// MARK: The harness's Diff.cs

private let now = Date(timeIntervalSince1970: 1_794_387_600)
private let india = TimeZone(secondsFromGMT: 19_800)!

private final class Context {
    let parser = CommandParser(boardClock: { now }, boardTimeZone: india)
    let strict = CommandParser(requirePrefixWhileTyping: true, boardClock: { now }, boardTimeZone: india)
    let memory = PhraseMemory()
    let learning: CommandParser
    let catalog: AppCatalog

    init() {
        memory.learn("get notepad going", "open notepad")
        memory.learn("fire up chrome now", "open chrome")
        memory.learn("tab three please", "go to tab 3")
        memory.learn("scrap the last word", "delete the last word")
        memory.learn("make coffee", "open notepad")
        memory.recordAppUse("Terminal")
        memory.recordAppUse("terminal")
        memory.recordAppUse("Notepad")
        learning = CommandParser(
            commandPrefix: "", wakeWords: ["hey friday", "jarvis", "computer"], memory: memory, boardClock: { now },
            boardTimeZone: india)
        catalog = AppCatalog(
            [
                AppEntry(name: "Notepad", launch: "notepad.exe", processNames: ["Notepad"]),
                AppEntry(name: "Google Chrome", aliases: ["chrome"], launch: "chrome.exe", processNames: ["chrome"]),
                AppEntry(
                    name: "GitHub Copilot", launch: "github", processNames: ["github"],
                    windowTitleContains: "GitHub Copilot"),
            ],
            memory: memory)
        catalog.setDiscoveredApps([
            AppEntry(name: "Copilot", launch: "copilot"), AppEntry(name: "Microsoft Teams", launch: "teams"),
            AppEntry(name: "Outlook (new)", launch: "olk"), AppEntry(name: "Microsoft Edge", launch: "msedge"),
            AppEntry(name: "Edge", launch: "edge2"), AppEntry(name: "Terminal", launch: "a"),
            AppEntry(name: "Terminal", launch: "b"), AppEntry(name: "Terminal Preview", launch: "c"),
            AppEntry(name: "Visual Studio 2022", launch: "vs"), AppEntry(name: "Paint.NET", launch: "paintdotnet"),
            AppEntry(name: "Notepad", launch: "notepad.exe"),
        ])
    }
}

private func utterance(_ r: inout DotNetRandom, _ c: Context) -> [String] {
    var t = r.pick(starts) + r.pick(pads)
    let count = 1 + r.next(4)
    for i in 0..<count {
        if i > 0 {
            t += " "
        }

        var token = r.pick(tokens)
        if r.next(4) == 0 {
            token = DotNet.upperFirst(token)
        }

        t += token
    }

    t += r.pick(tails)
    let n = TranscriptText.normalize(t)
    typealias S = Serialized
    return [
        t,
        S.parsed(c.parser.parse(t, .dictation)),
        S.parsed(c.parser.parse(t, .command)),
        S.parsed(c.parser.parse(t, .standby)),
        S.parsed(c.parser.parse(t, .paused)),
        S.parsed(c.strict.parse(t, .dictation)),
        S.parsed(c.learning.parse(t, .command)),
        S.parsed(c.learning.parse(t, .dictation)),
        S.b(c.parser.mayContainWakeWord(t)),
        S.b(c.learning.mayContainWakeWord(t)),
        S.b(CommandParser.mayStartCommand(t)),
        CommandParser.simplify(n),
        S.target(CommandParser.parseTarget(n)),
        NameMatcher.cleanElementName(t),
        NameMatcher.cleanTabTitle(t),
        scoreNames.map { String(NameMatcher.score(t, $0)) }.joined(separator: ","),
        scoreNames.map { String(NameMatcher.score($0, t)) }.joined(separator: ","),
        NetText.words(n).map { NameMatcher.soundKey($0) }.joined(separator: ","),
        S.i(TargetResolver.tabScore(t, "Lofi beats - YouTube - Google Chrome")),
        S.b(TargetResolver.isDestructive(t)),
        S.s(SiteProfile.forTitle(t)?.name),
        S.app(c.catalog.resolve(t)),
        S.app(c.catalog.resolve(t, fuzzy: false)),
        S.b(c.catalog.hasExactName(t)),
        processNames.map { S.s(c.catalog.findProfileForProcess($0, t)?.name) }.joined(separator: ","),
        S.b(PhraseMemory.sharesDistinctiveWord(n, "open notepad")),
    ]
}

private let units: [EditUnit] = [.character, .word, .sentence, .line, .paragraph]

private func edit(_ r: inout DotNetRandom) -> [String] {
    var before = ""
    let count = r.next(10)
    for i in 0..<count {
        if i > 0 {
            before += r.pick(separators)
        }

        before += r.pick(words)
    }

    if r.next(3) == 0 {
        before += r.pick(separators)
    }

    let phrase = r.pick(phrases)
    let replacement = r.pick(replacements)
    let unit = units[r.next(5)]
    let times = 1 + r.next(3)
    typealias S = Serialized
    return [
        before, phrase, S.s(replacement), "\(unit)", S.i(times),
        S.plan(TextEditing.deleteLast(before, unit, times)),
        S.plan(TextEditing.replaceLast(before, phrase, replacement)),
        S.find(TextEditing.findLast(TextEditing.normalizeNewLines(before), phrase)),
        S.find(TextEditing.findLast(before, phrase)),
        TextEditing.normalizeNewLines(before),
    ]
}

private let roles: [ElementRole] = [
    .button, .link, .tab, .menuItem, .treeItem, .listItem, .checkBox, .radioButton, .comboBox, .textBox, .other,
]

private let regions: [ScreenRegion] = [.left, .right, .top, .bottom]

private let windows = [
    WindowInfo(handle: 10, processId: 1, processName: "chrome", title: "Lofi beats - YouTube - Google Chrome"),
    WindowInfo(handle: 20, processId: 2, processName: "msedge", title: "Work items - Boards"),
    WindowInfo(handle: 10, processId: 3, processName: "chrome", title: "Reused handle"),
]

/// Few distinct rows and columns, so that rows tie and nest.
private func screenRect(_ r: inout DotNetRandom) -> ScreenRect {
    let x = r.next(8) * 150 + r.next(3)
    let y = r.next(6) * 40 + r.next(5)
    let width = 20 + r.next(4) * 100
    let height = r.next(5) == 0 ? 0 : 6 + r.next(4) * 12
    return ScreenRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
}

private func resolution(_ r: inout DotNetRandom) -> [String] {
    var elements: [UiElement] = []
    let count = r.next(41)
    for i in 0..<count {
        let name = r.pick(elementNames)
        let role = roles[r.next(roles.count)]
        elements.append(UiElement(id: i + 1, name: name, role: role, rect: screenRect(&r)))
    }

    var tabs: [BrowserTab] = []
    let tabCount = r.next(7)
    for i in 0..<tabCount {
        let title = r.pick(tabTitles)
        let index = 1 + r.next(4)
        let selected = r.next(2) == 0
        let window = windows[r.next(windows.count)]
        tabs.append(BrowserTab(id: 100 + i, title: title, index: index, isSelected: selected, window: window,
                               rect: screenRect(&r)))
    }

    let name = r.pick(targetNames)
    let ordinalDraw = r.next(4)
    let ordinal: Int? = ordinalDraw == 0 ? 1 + r.next(3) : ordinalDraw == 1 ? -1 : nil
    let regionDraw = r.next(5)
    let target = ElementTarget(name: name, region: regionDraw == 4 ? nil : regions[regionDraw], ordinal: ordinal)
    let window: ScreenRect? = r.next(3) == 0 ? nil : ScreenRect(x: 0, y: 0, width: 1200, height: 240)
    let minScore = [50, 60, 70][r.next(3)]
    let strip = ScreenRect(x: 0, y: 0, width: 1200, height: 240)
    typealias S = Serialized
    return [
        elements.map { e in
            "\(e.id),\(e.name),\(e.role),\(Int(e.rect.x)),\(Int(e.rect.y)),\(Int(e.rect.width)),\(Int(e.rect.height))"
        }.joined(separator: ";"),
        S.target(target), window == nil ? "~" : "w", S.i(minScore),
        S.ids(TargetResolver.deduplicate(elements)),
        S.ids(TargetResolver.sortReadingOrder(elements)),
        S.resolution(TargetResolver.resolveElement(elements, target, window)),
        S.resolution(TargetResolver.resolveElement(elements, target, window, minScore: minScore)),
        S.resolution(TargetResolver.resolveTab(tabs, target)),
        S.resolution(TargetResolver.resolveTab(tabs, target, minScore: minScore)),
        tabs.map { String(TargetResolver.tabScore(target.name, $0.title)) }.joined(separator: ","),
        elements.map { S.b(TargetResolver.inRegion($0.rect, .left, strip)) }.joined(separator: ","),
    ]
}

// MARK: The harness's lists (`dotnet run -- swiftlists`)

private let starts: [String] = [
    "", "", "", "", "Hey Jarvis, ", "hey jarvis ", "Jarvis, ", "Hey Jervis, ", "OK Jarvis. ", "Computer, ",
    "hey computer ", "Hi Jarvis! ", "a jarvis ",
]

private let pads: [String] = [
    "", "", "", "", "can you ", "Can you please ", "please ", "could you ", "I want to ", "so ", "and ", "um, ",
    "just ", "go ahead and ", "let's ", "Okay so ",
]

private let tokens: [String] = [
    "open", "launch", "start", "switch to", "go to", "go back to", "show me", "bring up", "fire up", "pull up",
    "notepad", "Notepad", "chrome", "Google Chrome", "GitHub Copilot", "co-pilot", "teams", "outlook", "terminal",
    "visual studio", "crome", "notpad", "edge", "the", "a new", "my", "app", "window", "browser",
    "and start typing", "so I can type", "to type", "tab", "the first tab", "second tab", "last tab", "tab 3",
    "tab number four", "the YouTube tab", "the tab where YouTube is open", "the tab with Gmail", "new tab",
    "next tab", "close tab", "previous tab", "in a new tab", "in another tab", "on a new tap", "in a new window",
    "in a second tab", "in the other window", "a new tab and open", "with", "instagram", "Instagram",
    "instagram.com", "github.com/shivam098", "instagram dot com", "YouTube", "website", "page", "click", "click on",
    "tap", "press", "select", "choose", "expand", "toggle", "New", "Library", "Issues", "pull requests", "button",
    "link", "on the left", "in the sidebar", "at the top", "on the right side", "the second", "first", "last",
    "one", "start typing", "type in", "start typing in", "the message box", "the search box", "the address bar",
    "text box", "here", "it", "search for", "google", "look up", "weather in Bangalore", "on Google", "online",
    "send", "send it", "submit", "post it", "scratch that", "undo that", "delete that", "clear box", "clear all",
    "new line", "next line", "new paragraph", "stop typing", "that's all", "pause listening", "go to sleep",
    "be quiet", "select all", "copy", "paste", "cut", "undo", "redo", "save", "save the file", "go back",
    "go forward", "previous page", "go to the next page", "go up one level", "parent folder", "refresh",
    "reload the page", "scroll down", "page up", "press enter", "hit the escape key", "tap backspace",
    "press shift tab", "press the up arrow", "press page down button", "show numbers", "hide numbers", "numbers",
    "yes", "no", "cancel", "never mind", "do it", "3", "three", "twelve", "the second one", "number two",
    "click 12", "choose four", "99", "100", "0", "delete", "erase", "remove", "the last", "last", "previous",
    "word", "words", "three words", "the last two sentences", "sentence", "line", "paragraph", "5 characters",
    "letters", "a few", "couple of", "that sentence", "this line", "the word", "the words", "the phrase", "very",
    "really", "see you again", "now", "replace", "change", "replace the word", "Monday", "monday", "Tuesday",
    "GitHub Actions.", "to", "into", "by", "the meeting", "the review", "with with", "add to my ideas,",
    "a voice game", "remind me to", "call mom tomorrow at 5 pm", "show my reminders", "mark renew passport as done",
    "put this on my to-do list,", "renew passport", "note down", "show my board", "go to my ideas",
    "get notepad going", "what's the weather like", "make coffee", "stop", "open it up", "Hey Jarvis", "jarvis",
    "computer", "please", "for me", "thanks", "thank you", "right now", "quickly", "again", ",", ".", "?", "!",
    "...", "-", "'", "\u{2019}", "(music)", "[BLANK_AUDIO]", "\u{E9}", "caf\u{E9}", "na\u{EF}ve", "\u{1F600}",
    "\u{1F44D}\u{1F3FD}", "\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947}", "\u{65E5}\u{672C}\u{8A9E}", "e\u{301}",
    "\u{A0}", "1st", "2nd", "10th", "tenth", "4th", "sixteen", "twenty", "21", "007", "2147483648", "\u{663}",
]

private let tails: [String] = [
    "", "", "", "", ".", "?", "!", " please", " for me", " now", " thanks.", " again", ",", " right now.",
    " quickly",
]

private let words: [String] = [
    "Hello", "hello", "there", "my", "friend", "friend.", "very", "very,", "good", "It", "is", "Monday", "monday",
    "Mondays", "don't", "dont", "do", "not", "as", "soon", "possible", "ASAP", "co-pilot", "copilot", "a", "b",
    "Version", "1.5", "One.", "Two", "is", "here?", "Three", "next!", "\"quoted.\"", "(see)", "\u{E9}t\u{E9}",
    "caf\u{E9}", "cafe\u{301}", "\u{1F600}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1EE}\u{1F1F3}",
    "\u{915}\u{94D}\u{937}", "\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947}", "\u{65E5}\u{672C}", "e\u{301}", "new",
    "line", "x", "rock-and-roll", "rock", "and", "roll", "it's", "its", "O'Brien", "obrien", "\u{2019}s", "go",
    "on", "then",
]

private let separators: [String] = [
    " ", " ", " ", " ", "  ", "\u{A}", ". ", "\u{A}\u{A}", ", ", "\u{D}\u{A}", "\u{9}", "\u{A0}", "-", "\u{2014}",
    "",
]

private let phrases: [String] = [
    "very", "monday", "dont", "do not", "as soon as possible", "copilot", "co pilot", "a", "a b", "b a", "a a",
    "hello there", "friend", "its", "it s", "obrien", "rock and roll", "and roll", "roll rock", "cafe", "caf\u{E9}",
    "\u{E9}t\u{E9}", "one", "two is", "version 1 5", "1 5", "new line", "x", "", "  ", "the", "Monday,", "Very!",
    "\u{1F600}", "\u{65E5}\u{672C}", "go on", "on then",
]

private let replacements: [String?] = [
    nil, "", " ", "Tuesday", "tuesday", "NOW", "now", "GitHub Actions", "\u{E9}t\u{E9}", "x y",
]

private let elementNames: [String] = [
    "New", "New project, Ctrl + Alt + Shift + N", "New chat", "Pull requests", "Issues", "Library", "Settings",
    "Delete repository", "Sign out", "1 unread message Bibhash Morang 11:27 am aise bante hai richest",
    "Bibhash Morang", "Family 11:25 am", "9:30 AM", "Resolving an Unspecified Issue, unread", "Search",
    "Type a message", "Send", "Sent items", "Getting started", "Now playing",
    "Session review request. Status: Done.", "", "  ", "Lofi beats - YouTube", "YouTube Music", "Clear history",
    "Prabhatee 11:19 am Sticker",
]

private let tabTitles: [String] = [
    "(53) WhatsApp - Pinned - Memory usage - 120 MB", "Lofi beats - YouTube", "Inbox (3) - Gmail",
    "Work items - Boards", "YouTube Music", "Song A - YouTube", "Song B - YouTube - Google Chrome", "New Tab",
    "GitHub Copilot - Microsoft\u{200B} Edge", "Amazon.in: Shoes", "what is fleurs in ai - Google Search",
]

private let scoreNames: [String] = [
    "New project", "Pull requests", "GitHub", "Library", "Bibhash Morang", "Sent items", "Notepad", "YouTube Music",
]

private let targetNames: [String] = [
    "new", "pull request", "issues", "bibhash", "vivash morang", "youtube", "gmail", "whatsapp", "", "settings",
    "library", "libary", "send", "boards", "music", "song", "inbox", "new tab", "search", "clear history",
]

private let processNames: [String] = [
    "notepad", "GitHub", "chrome", "olk",
]
