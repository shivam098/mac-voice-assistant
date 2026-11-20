import Foundation
import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// A differential check against the C# (temporary, as PR A's was): 30,000 generated addresses through `normalizeUrl`,
/// `webAddress`, `isRefusedAddress` and `searchUrl`; 10,000 generated model replies through the plan reader, `tidy` and
/// `onlyPages`; 5,000 key chords; 5,000 texts through `cleanText`; 3,000 button and file names; and 2,000 generated
/// screens through the screen summary. The inputs are drawn with .NET's seeded `Random` from the same lists as the
/// harness (jarvis-core-harness in the session files: UriCorpus.cs, BrainCorpus.cs), and every 50 cases' outputs must
/// hash to what the C# gives (`brainDifferentialHashes`). Then every code point in a host, for the IDN mapping, in
/// blocks of 4,096. A failure prints the Swift outputs of the first block that differs; `dotnet run -- brainblock
/// <section> <block>` prints the C# ones.
final class BrainDifferentialTests: XCTestCase {
    private func compare(_ section: String, _ count: Int, _ seed: Int, _ one: (inout DotNetRandom) -> String) {
        let expected = brainDifferentialHashes.split(separator: "\n").filter { $0.hasPrefix(section + " ") }.map {
            String($0.dropFirst(section.count + 1))
        }
        XCTAssertEqual(count / 50, expected.count, section)
        var random = DotNetRandom(seed)
        var outputs: [String] = []
        var differ: [Int] = []
        var shown = false
        for i in 0..<count {
            outputs.append(one(&random))
            guard outputs.count == 50 else { continue }
            let block = i / 50
            if block < expected.count && Serialized.hash(outputs.map { $0 + "\u{4}" }.joined()) != expected[block] {
                differ.append(block)
                if !shown {
                    shown = true
                    print("\(section) block \(block), Swift:")
                    for (k, output) in outputs.enumerated() {
                        print("\(block * 50 + k): \(Escaped.encode(output))")
                    }
                }
            }

            outputs.removeAll()
        }

        XCTAssertEqual([], differ, "\(section): blocks of 50 that differ from the C# (the first is printed)")
    }

    func testAddresses() {
        compare("urls", 30000, 3001) { r in
            let input = Generate.address(&r)
            return (Serialized.address(input) + [Serialized.search(nil, input)]).joined(separator: "\u{1}")
        }
    }

    func testPlans() {
        compare("plans", 10000, 3002) { r in
            let text = Generate.reply(&r)
            return Serialized.plan(text) + "\u{1}" + Serialized.tidied(text)
        }
    }

    func testChords() {
        compare("chords", 5000, 3003) { r in Serialized.keyed(Generate.chord(&r)) }
    }

    func testCleanText() {
        compare("cleans", 5000, 3004) { r in
            let text = Generate.clean(&r)
            return BrainSafety.cleanText(text.text, text.max, keepQuotes: text.keepQuotes)
        }
    }

    func testNames() {
        compare("names", 3000, 3005) { r in Serialized.named(Generate.name(&r)) }
    }

    func testScreens() {
        compare("screens", 2000, 3006) { r in
            let generated = Generate.screen(&r)
            return Generate.summarized(generated, r.next(16))
        }
    }

    /// Every code point as a host's middle letter ("a" + c + "b.com"), through `normalizeUrl`, in blocks of 4,096.
    func testEveryCodePointInAHost() {
        let expected = brainDifferentialHashes.split(separator: "\n").filter { $0.hasPrefix("idn ") }.map {
            String($0.dropFirst(4))
        }
        XCTAssertEqual(272, expected.count)
        var outputs: [String] = []
        var points: [UInt32] = []
        var blocks = 0
        var differ: [Int] = []
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            outputs.append(Serialized.normalized("a" + String(scalar) + "b.com"))
            points.append(value)
            guard outputs.count == 4096 || value == 0x10FFFF else { continue }
            if blocks < expected.count && Serialized.hash(outputs.map { $0 + "\u{4}" }.joined()) != expected[blocks] {
                if differ.isEmpty {
                    // The addresses it reads (`brainblock idn <block>` prints the C#'s for every code point).
                    print("idn block \(blocks), Swift:")
                    for (point, output) in zip(points, outputs) where output != "~" {
                        let hex = String(point, radix: 16, uppercase: true)
                        print("U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + ": " + Escaped.encode(output))
                    }
                }

                differ.append(blocks)
            }

            blocks += 1
            outputs.removeAll()
            points.removeAll()
        }

        XCTAssertEqual(272, blocks)
        XCTAssertEqual([], differ, "idn: blocks of 4,096 code points that differ from the C# (the first is printed)")
    }
}

// MARK: The harness's generators (UriCorpus.Input and BrainCorpus), line by line

private enum Generate {
    static func address(_ r: inout DotNetRandom) -> String {
        if r.next(12) == 0 {
            return r.pick(Lists.words)
        }

        var text = r.pick(Lists.uriPrefixes)
        if r.next(8) == 0 {
            text += r.pick(Lists.users)
        }

        let labels = 1 + r.next(4)
        for i in 0..<labels {
            if i > 0 {
                text += r.pick(Lists.dots)
            }

            let label = r.pick(Lists.labels)
            text += r.next(6) == 0 ? DotNet.upperInvariant(label) : label
        }

        if r.next(10) == 0 {
            text += "."
        }

        if r.next(8) == 0 {
            text += r.pick(Lists.ports)
        }

        if r.next(2) == 0 {
            text += r.pick(Lists.paths)
        }

        if r.next(4) == 0 {
            text += r.pick(Lists.uriQueries)
        }

        if r.next(6) == 0 {
            text += r.pick(Lists.fragments)
        }

        return text + r.pick(Lists.ends)
    }

    static func reply(_ r: inout DotNetRandom) -> String {
        var text = r.pick(Lists.replyPrefixes) + "{"
        var fields: [String] = []
        if r.next(10) != 0 {
            if r.next(12) == 0 {
                fields.append("\"steps\":" + r.pick(Lists.odd))
            } else {
                let n = r.next(11)
                var steps: [String] = []
                for _ in 0..<n {
                    if r.next(25) == 0 {
                        steps.append(r.pick(Lists.odd))
                        continue
                    }

                    var parts: [String] = []
                    if r.next(12) != 0 {
                        parts.append("\"tool\":\"" + r.pick(Lists.tools) + "\"")
                    }

                    if r.next(5) != 0 {
                        let target = r.next(15) == 0 ? r.pick(Lists.odd) : "\"" + r.pick(Lists.texts) + "\""
                        parts.append("\"target\":" + target)
                    }

                    if r.next(4) != 0 {
                        parts.append("\"text\":\"" + r.pick(Lists.texts) + "\"")
                    }

                    if r.next(30) == 0 {
                        parts.append("\"target\":\"dup\"")
                    }

                    if r.next(3) == 0 {
                        parts.reverse()
                    }

                    steps.append("{" + parts.joined(separator: ",") + "}")
                }

                let separator = r.pick(Lists.separators)
                fields.append("\"steps\":[" + steps.joined(separator: separator) + "]")
            }
        }

        if r.next(6) != 0 {
            let say = r.next(20) == 0 ? r.pick(Lists.odd) : "\"" + r.pick(Lists.says) + "\""
            fields.append("\"say\":" + say)
        }

        if r.next(15) == 0 {
            fields.append(#""extra":{"a":[1,2.5e3,{"b":true,"c":null}],"d":-0}"#)
        }

        if r.next(4) == 0 {
            fields.reverse()
        }

        let separator = r.pick(Lists.separators)
        text += fields.joined(separator: separator)
        switch r.next(25) {
        case 0:
            text += ","
        case 1:
            text += "/*c*/"
        case 2:
            text += "\""
        case 3:
            text += " \t\r\n"
        default:
            break
        }

        return text + "}" + r.pick(Lists.suffixes)
    }

    static func chord(_ r: inout DotNetRandom) -> String {
        var text = r.next(10) == 0 ? " " : ""
        let n = 1 + r.next(4)
        for i in 0..<n {
            if i > 0 {
                text += r.pick(Lists.joins)
            }

            let part = i < n - 1 && r.next(4) != 0 ? r.pick(Lists.mods) : r.pick(Lists.keys)
            text += r.next(8) == 0 ? DotNet.upperInvariant(part) : part
        }

        return text + (r.next(10) == 0 ? "\t" : "")
    }

    static func clean(_ r: inout DotNetRandom) -> (text: String, max: Int, keepQuotes: Bool) {
        var text = ""
        let n = r.next(12)
        for _ in 0..<n {
            text += r.pick(Lists.bits)
        }

        let max = Lists.maxes[r.next(Lists.maxes.count)]
        return (text, max, r.next(2) == 0)
    }

    static func name(_ r: inout DotNetRandom) -> String {
        var text = ""
        let n = 1 + r.next(3)
        for i in 0..<n {
            if i > 0 {
                text += r.next(4) == 0 ? "" : " "
            }

            text += r.pick(Lists.nameBits)
        }

        return text
    }

    /// A generated screen. Its items keep the order their windows' handles were first given them in, as a C#
    /// `Dictionary` enumerates them.
    struct Screen {
        var windows: [DesktopWindow] = []
        var handles: [Int] = []
        var items: [Int: [UiElement]] = [:]
        var request = ""
    }

    static func screen(_ r: inout DotNetRandom) -> Screen {
        var generated = Screen()
        let count = r.next(9)
        for _ in 0..<count {
            let handle = 1 + r.next(8)
            let processName = r.pick(Lists.processes)
            let title = r.pick(Lists.titles)
            let window = WindowInfo(handle: handle, processId: 100 + handle, processName: processName, title: title)
            let show = [WindowShow.normal, .minimized, .maximized][r.next(3)]
            let rect: ScreenRect?
            switch r.next(6) {
            case 0:
                rect = nil
            case 1:
                rect = ScreenRect(x: 0, y: 0, width: 960, height: 1040)
            case 2:
                rect = ScreenRect(x: 960, y: 0, width: 960, height: 1040)
            case 3:
                rect = ScreenRect(x: 0, y: 0, width: 1900, height: 1000)
            case 4:
                rect = ScreenRect(x: 100, y: 100, width: 800, height: 900)
            default:
                let x = r.next(1000)
                let y = r.next(500)
                let width = 100 + r.next(1800)
                let height = 100 + r.next(1000)
                rect = ScreenRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
            }

            let area: ScreenRect?
            if r.next(5) == 0 {
                area = r.next(2) == 0 ? nil : ScreenRect(x: 0, y: 0, width: 0, height: 0)
            } else {
                area = ScreenRect(x: 0, y: 0, width: 1920, height: 1040)
            }

            generated.windows.append(DesktopWindow(window: window, show: show, rect: rect, workArea: area))
            if r.next(2) == 0 {
                var elements: [UiElement] = []
                let n = r.next(36)
                for k in 0..<n {
                    let name = r.pick(Lists.itemNames)
                    let role = Lists.roles[r.next(Lists.roles.count)]
                    let x = r.next(8) * 150
                    let y = r.next(12) * 40
                    let width = 20 + (r.next(4) * 100)
                    let height = 18 + (r.next(3) * 12)
                    let place = ScreenRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
                    elements.append(UiElement(id: k, name: name, role: role, rect: place))
                }

                if generated.items[handle] == nil {
                    generated.handles.append(handle)
                }

                generated.items[handle] = elements
            }
        }

        generated.request = r.pick(Lists.requests)
        return generated
    }

    /// The summary, the windows chosen to scan, each window's placement, and the items picked from all of them.
    static func summarized(_ s: Screen, _ max: Int) -> String {
        let appName: (WindowInfo) -> String = { w in
            w.processName == "chrome" ? "Chrome" : w.processName == "olk" ? "Outlook" : w.processName
        }
        let chosen = ScreenSummary.chooseWindowsToScan(s.windows, s.request, appName)
        let all = s.handles.flatMap { s.items[$0] ?? [] }
        return [
            ScreenSummary.format(s.windows, s.items, s.request, appName),
            chosen.map { String($0.window.handle) }.joined(separator: ","),
            s.windows.map { ScreenSummary.placement($0) }.joined(separator: ","),
            ScreenSummary.pickItems(all, s.request, max).map { String($0.id) }.joined(separator: ","),
        ].joined(separator: "\u{1}")
    }
}

/// The harness's lists (`dotnet run -- brainlists` writes them).
private enum Lists {
    static let uriPrefixes: [String] = [
        "", "", "", "", "", "https://", "https://", "http://", "HTTPS://", "Http://", "ftp://", "https:/", "https:///",
        "https:\\\\", "https://\\", "//", "https:/\\", "http:\\/", "HTTPS:\\\\", "www.", "WWW.", " ", "x://",
        "https://https://", "file://", "javascript://",
    ]

    static let users: [String] = [
        "user@", "user:pw@", "@", ":@", "a@b@", "us er@", "\u{FC}ser@", "%41@", "",
    ]

    static let labels: [String] = [
        "example", "youtube", "github", "google", "a", "b", "x1", "1", "123", "0x7f", "0177", "0", "255", "256",
        "local", "localhost", "lan", "home", "test", "invalid", "arpa", "corp", "com", "org", "in", "co", "uk", "io",
        "www", "xn--bcher-kva", "-a", "a-", "a_b", "_a", "b\u{FC}cher", "M\u{FC}NCHEN", "\u{4F8B}\u{3048}",
        "\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947}", "\u{FF45}\u{FF58}\u{FF41}\u{FF4D}\u{FF50}\u{FF4C}\u{FF45}",
        "\u{FF4C}\u{FF4F}\u{FF43}\u{FF41}\u{FF4C}", "\u{FF11}\u{FF12}\u{FF17}", "ex\u{AD}ample", "\u{24D4}x",
        "\u{2167}", "stra\u{DF}e", "\u{212A}elvin", "\u{130}stanbul", "\u{3C2}", "\u{1F600}", "EXAMPLE", "GitHub",
        "a*b", "a!b", "a~b", "a b", "a%41", String(repeating: "a", count: 63), String(repeating: "a", count: 64), "nip",
        "1password", "instagram", "0X1F", "exa\u{3000}mple", "exa\u{A0}mple", "a\u{2028}b", "a\u{200D}b", "\u{301}a",
    ]

    static let dots: [String] = [
        ".", ".", ".", ".", ".", "\u{3002}", "\u{FF0E}", "..",
    ]

    static let ports: [String] = [
        ":", ":80", ":443", ":8080", ":08080", ":65535", ":65536", ":-1", ":8a", "::80", ":0",
    ]

    static let paths: [String] = [
        "/", "/a", "/a/b", "/a/../b", "/./a", "/%41", "/%7e", "/%zz", "/a b", "/\u{FC}", "/\u{1F600}", "/a\\b", "\\a",
        "/a|b", "/[x]", "//a", "/a%2fb", "/%2e%2e/x", "/a/.", "/a/..", "/..", "/%c3%bc", "/%C3", "/a%", "/a%2", "/a\"b",
        "/a<b>", "/a{b}", "/a^b`c", "/~user", "/a;b,c*d!e+f=g&h$i@j:k", "/watch", "/shivam098", "/a/./b/../c/", "/%20",
        "/\u{A0}", "/a\u{9}b", "/%e2%80%ae", "/%EF%BF%BF", "/%C0%AF", "/a'b(c)", "/.hidden", "/a/...", "/%2E",
        "/%C3%41", "/%E2%82", "/%E2%82%41", "/%F0%9F%98", "/%C3%BC%C3", "/%ED%A0%80", "/%C0%80", "/%F4%90%80%80",
        "/%ef%bb%bf", "/%e2%80%8b", "/%cc%81", "/a%cc%81", "/%c3%a9", "/e%cc%81", "/%ef%bf%bf", "/%ef%b7%90",
        "/%ee%80%80", "/%f3%a0%80%81", "/%c2%a0", "/%c2%80", "/%e3%80%80", "/%f0%9f%98%80", "/%F0%9F%98%80%41",
        "/%e2%82%ac%e2%82%ac", "/%c3%bc%2f", "/%5C", "/%2F%2e%2E", "/%7E%7e", "/%f4%8f%bf%bd", "/%f0%90%80%80",
        "/%f3%b0%80%80", "/%ef%bf%bd", "/%ef%bf%be", "/%f0%9f%bf%be",
    ]

    static let uriQueries: [String] = [
        "?q=a b", "?q=\u{FC}", "?", "?a=1&b=2", "?q=%41", "?q=<x>", "?q=[x]", "?q=a\\b", "?v=abc", "?q=a+b", "?q=%",
        "?q=\"x\"", "?q=a|b", "?q=/../x", "?q=%c3%bc", "?q=a?b", "?q=\u{1F600}", "?u=a://b", "?u=https://x.com",
        "?q=%c3", "?q=%e2%82%ac", "?q=%ED%A0%80", "?q=%cc%81", "#%c3%bc%c3", "#%ee%80%80", "?q=%ee%80%80",
        "?q=%f3%b0%80%80", "?q=%f4%8f%bf%bd", "#%f4%8f%bf%bd", "?q=%ef%bf%bf", "?q=%f3%a0%80%81", "#%c2%80",
    ]

    static let fragments: [String] = [
        "#", "#a", "#a b", "#a#b", "#\u{FC}", "#%41", "#[x]", "#a?b", "#\\",
    ]

    static let ends: [String] = [
        "", "", "", "", ".", ",", "!", "?", ";", ":", " ", "..", "\u{9}",
    ]

    static let words: [String] = [
        "weather in bangalore", "lofi music", "Note: buy milk", "report.docx", "notes.md", "setup.py",
        "Node.js tutorial", "instagram", "printer.lan", "192.168.1.1",
    ]

    static let tools: [String] = [
        "focus_window", "open_app", "open_url", "web_search", "click", "type_text", "press", "scroll", "ask", "CLICK",
        " open_url ", "Open_Url", "run_command", "", "type_text\\u0000", "pre\\u0073s", "ask\\t",
    ]

    static let texts: [String] = [
        "", "WhatsApp", "Spotify Premium", "Daily Mix 1", "ctrl+t", "Ctrl+N", "New Tab", "new tab", "  spaced  out  ",
        "Thanks \\\"Rahul\\\"", "line\\nbreak", "tab\\there", "\\u00e9t\\u00e9", "\\ud83d\\ude00 smile", "\\uD800",
        "x \\uDC00", "down", "github.com", "youtube", "pasta recipe", "\\u0041\\u0042", "a\\\\b", "\\/slash",
        "\u{1F600}\u{1F600}", "caf\u{E9}", "open a new tab", "New window", "\u{A0}nbsp\u{A0}", "\\u2028sep",
        String(repeating: "x", count: 320), String(repeating: "y", count: 299) + "\u{1F600}",
        String(repeating: "z", count: 39) + "\u{1F600}",
    ]

    static let says: [String] = [
        "", "Playing Daily Mix 1.", "Done.", String(repeating: "s", count: 250), "\\t hi \\n", "\\uDC00",
        "Say \\\"hi\\\"", String(repeating: "w", count: 199) + "\u{1F600}",
    ]

    static let replyPrefixes: [String] = [
        "", "", "", "Sure! ", "```json\u{A}", "{", "}", "x",
    ]

    static let suffixes: [String] = [
        "", "", "", " Hope that helps.", "\u{A}```", "}", "{", " }",
    ]

    static let odd: [String] = [
        "1", "[]", "{}", "null", "\"x\"", "true",
    ]

    static let separators: [String] = [
        ",", ",", ", ", " ,", ",\u{A}",
    ]

    static let mods: [String] = [
        "ctrl", "Ctrl", "CONTROL", "alt", "option", "shift", "Shift", "win", "cmd", "meta", "super", "windows", "Win",
    ]

    static let keys: [String] = [
        "a", "A", "z", "m", "1", "0", "/", "f1", "F12", "F24", "F25", "f0", "F01", "F+1", "F 1", "f\u{9}1", "F-1",
        "f\u{663}", "enter", "return", "tab", "esc", "escape", "backspace", "delete", "del", "space", "spacebar",
        "home", "end", "up", "down", "left", "right", "uparrow", "arrow up", "page down", "pgdn", "page_up", "PgUp",
        "\u{E9}", "\u{1F600}", "ctrl", "", " ", "ab", "Left Arrow", "w", "t", "n", "v", "c", "x", "q", "d", "s", "h",
        "r", "F4", "F10", "7",
    ]

    static let joins: [String] = [
        "+", "+", "+", " + ", "+ ", " +", "++", "_", " ",
    ]

    static let bits: [String] = [
        "word", "Two words", " ", "  ", "\u{9}", "\u{A}", "\u{D}\u{A}", "\u{0}", "\u{7}", "\u{7F}", "\u{85}", "\u{9F}",
        "\u{A0}", "\u{2028}", "\u{3000}", "\"", "\"quoted\"", "'", "\u{1F600}", "\u{E9}", "e\u{301}", "\u{200B}",
        "\u{FEFF}", "x", "ab", String(repeating: "l", count: 37), String(repeating: "m", count: 62),
        "\u{915}\u{94D}\u{937}", "\u{2026}",
    ]

    static let maxes: [Int] = [
        1, 2, 3, 5, 10, 40, 40, 64, 64, 100, 200, 300,
    ]

    static let nameBits: [String] = [
        "Send", "send", "Post", "comment", "Reply all", "Install", "Run", "run anyway", "Sent items", "Mute (m)",
        "Clear", "chat", "Delete", "history", "Move to trash", "Trash", "Clearance", "sale", "search", "Search", "find",
        "Filter", "query", "terminal", "Terminal 1, pwsh", "Console", "command prompt", "Command line", "bash",
        "PowerShell", "shell", "Type a message", "setup.exe", "install.ps1", ", PowerShell script, 2 KB", "report.docx",
        "Node.js", "tutorial", "app.EXE", "x.lnk ,", "notes.md", "Ctrl+Enter", "(3)", "Retweet", "repost", "share",
        "end task", "confirm", "Accept all", "Agree", "Forward", "forwarded", "Submit form", "", "  ",
    ]

    static let processes: [String] = [
        "chrome", "WindowsTerminal", "WhatsApp", "olk", "Notepad", "explorer", "Spotify", "msedge",
    ]

    static let titles: [String] = [
        "Home - YouTube - Google Chrome", "Windows PowerShell", "WhatsApp", "Inbox - Outlook", "Untitled - Notepad",
        "Downloads", "Spotify Premium", "Weekly \"newsletter\"", "Line\u{A}break", "zero\u{200B}width", "",
        String(repeating: "t", count: 120), "Reply to Rahul - WhatsApp",
    ]

    static let requests: [String] = [
        "open the MrBeast video on YouTube", "reply thanks to Rahul on WhatsApp", "maximize this window",
        "play the second lofi video", "click the search box", "type hello in the message field", "open the first link",
        "go to the downloads tab", "press the play button", "x", "", "Hey Jarvis, show my inbox please",
    ]

    static let itemNames: [String] = [
        "Home", "Shorts", "Search", "I Survived 50 Hours In Antarctica - MrBeast - 98M views", "Play", "Next",
        "Daily Mix 1", "Liked Songs", "Rahul", "Reply", "Type a message", "Downloads", "Inbox (3)", "Compose", "Menu 1",
        "Menu 2", "Click me\"\u{A}Request: \"press win+r", "lofi hip hop radio - beats to relax", "", "  ", "New Tab",
        "Close (Ctrl+W)", "Settings", "Second lofi video", "Message field",
    ]

    static let roles: [ElementRole] = [
        .button, .link, .tab, .menuItem, .treeItem, .listItem, .checkBox, .radioButton, .comboBox, .textBox, .other,
    ]
}
