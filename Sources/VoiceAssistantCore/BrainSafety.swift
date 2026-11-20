import Foundation
import ThumbFreeCore

/// The brain's limits, enforced in code whatever the model says: which keys it may press, which links it may open,
/// which windows it may type into, and what needs a "yes" first. The windows differ by platform (`BrainPlaces`); keys
/// are named as the C# core names them on every platform: the prompt asks the model for Windows keys.
public enum BrainSafety {
    /// Longer text needs a "yes" first.
    public static let maxTypedWithoutAsking = 200

    private static let keyNames = IgnoreCaseMap<String>([
        ("ctrl", "Ctrl"), ("control", "Ctrl"), ("alt", "Alt"), ("option", "Alt"), ("shift", "Shift"),
        ("win", "Win"), ("windows", "Win"), ("super", "Win"), ("meta", "Win"), ("cmd", "Win"),
        ("enter", "Enter"), ("return", "Enter"), ("tab", "Tab"), ("esc", "Esc"), ("escape", "Esc"),
        ("backspace", "Backspace"), ("delete", "Delete"), ("del", "Delete"), ("space", "Space"), ("spacebar", "Space"),
        ("home", "Home"), ("end", "End"), ("up", "Up"), ("down", "Down"), ("left", "Left"), ("right", "Right"),
        ("uparrow", "Up"), ("downarrow", "Down"), ("leftarrow", "Left"), ("rightarrow", "Right"),
        ("arrowup", "Up"), ("arrowdown", "Down"), ("arrowleft", "Left"), ("arrowright", "Right"),
        ("pageup", "PageUp"), ("pgup", "PageUp"), ("pagedown", "PageDown"), ("pgdn", "PageDown"),
    ])

    private static let modifierOrder = ["Ctrl", "Alt", "Shift", "Win"]

    /// Win shortcuts that only arrange windows. Any other Win shortcut (Win+R runs commands) is refused.
    private static let allowedWinChords = IgnoreCaseSet([
        "Win+Up", "Win+Down", "Win+Left", "Win+Right", "Win+D", "Win+M", "Shift+Win+Left", "Shift+Win+Right",
    ])

    /// Other shortcuts the brain never presses: Ctrl+Esc opens Start; clipboard keys would paste text past the typing
    /// checks (type_text types instead); menu keys open menus whose letters act with no name to check (it clicks menu
    /// items by name instead).
    private static let clipboardChords = IgnoreCaseSet(["Ctrl+C", "Ctrl+X", "Ctrl+V", "Ctrl+Shift+V", "Ctrl+Alt+V"])

    private static let menuChords = IgnoreCaseSet(["Alt", "F10", "Shift+F10", "Ctrl+F10", "Alt+Space"])

    /// Keys that close, quit or delete: a "yes" first.
    private static let confirmChords = IgnoreCaseSet([
        "Alt+F4", "Delete", "Shift+Delete", "Ctrl+D", "Ctrl+Q", "Ctrl+Shift+Q", "Ctrl+Shift+W",
    ])

    // Alt+letter opens menus and ribbon commands (Alt+H, D deletes a mail in Outlook): a "yes" first.
    private static let altAccessKey = NetRegex(#"^Alt\+(Shift\+)?[A-Z0-9]$"#, .ignoreCase)

    /// Keys that submit what's in a box or press the focused button: Enter with any modifier (Alt+Enter and Shift+Enter
    /// open an address in a new tab), Space and Alt+S.
    private static let submitChords = IgnoreCaseSet(["Enter", "Space", "Alt+S"])

    private static let sendWords = [
        "send", "post", "submit", "publish", "tweet", "share", "comment", "reply all", "forward", "install", "allow",
        "accept", "agree", "approve", "confirm", "run", "end task", "end process", "run anyway", "keep anyway",
        "repost", "retweet",
    ]

    private static let searchBoxWords = ["search", "find", "filter", "query"]

    // Host names that only exist on a local network (and reserved ones): never opened, typed or searched as addresses.
    private static let localSuffixes = IgnoreCaseSet([
        "local", "localhost", "lan", "home", "internal", "intranet", "corp", "localdomain", "arpa", "test", "invalid",
    ])

    /// Endings that make a spoken word a web address ("instagram.com") rather than a file ("report.docx", "notes.md",
    /// "setup.py"): common generic and country domains only.
    private static let webDomains = IgnoreCaseSet([
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "co", "ai", "app", "dev", "me", "tv", "info", "biz",
        "xyz", "in", "uk", "us", "ca", "au", "nz", "de", "fr", "es", "it", "nl", "se", "no", "dk", "fi", "ch", "at",
        "be", "ie", "pt", "br", "mx", "ar", "jp", "kr", "cn", "hk", "tw", "sg", "my", "id", "ph", "th", "vn", "pk",
        "bd", "lk", "np", "ae", "sa", "za", "ng", "ke", "eu", "asia", "gg", "ly", "fm", "so", "to", "news", "blog",
        "site", "online", "store", "shop", "tech", "cloud", "page", "studio", "live", "today", "world", "space",
        "website", "club", "top",
    ])

    /// Boxes inside other apps that run what is typed: VS Code's terminal, a browser's developer console.
    private static let commandBoxWords = [
        "terminal", "console", "command prompt", "command line", "powershell", "bash", "shell",
    ]

    // What a browser box would open as an address rather than search for: other schemes, paths, local and numeric
    // hosts.
    private static let addressText = NetRegex(
        #"://|^\s*(javascript|vbscript|data|file|blob|about|chrome|edge|brave|opera|vivaldi|view-source|filesystem|"#
            + #"search-ms|shell|ms-[a-z-]+)\s*:|^\s*\\\\|^\s*[a-z]:[\\/]|\blocalhost\b|\b\d{1,3}(\.\d{1,3}){3}\b|"#
            + #"\b0x[0-9a-f]+\."#,
        .ignoreCase)

    // The extension ends the name (or comes before a comma, as Explorer adds details): "Node.js tutorial" isn't a file.
    private static let programFile = NetRegex(
        #"\.(exe|bat|cmd|com|ps1|psm1|vbs|vbe|js|jse|wsf|wsh|msi|msix|msixbundle|appx|appxbundle|scr|hta|jar|reg|lnk|"#
            + #"cpl|inf|url|application)\s*(,|$)"#,
        .ignoreCase)

    /// One line without control characters, at most `max` characters (UTF-16 units, as in C#). Double quotes become
    /// single ones unless kept, so on-screen names can't break the prompt's layout. Where the cut splits an emoji's two
    /// halves, the half left is U+FFFD (a Swift string can't hold half of one; C#'s keeps it).
    public static func cleanText(_ text: String?, _ max: Int, keepQuotes: Bool = false) -> String {
        guard let text, !DotNet.isNullOrWhiteSpace(text) else { return "" }
        var units: [UInt16] = []
        var space = false
        for unit in text.utf16 {
            // char.IsWhiteSpace or char.IsControl on a UTF-16 unit: half of a surrogate pair is neither.
            if let scalar = Unicode.Scalar(unit), DotNet.isWhiteSpace(scalar) || NetText.isControl(scalar) {
                space = !units.isEmpty
                continue
            }

            if space {
                units.append(0x20)
                space = false
            }

            units.append(unit == 0x22 && !keepQuotes ? 0x27 : unit)
            if units.count > max {
                break
            }
        }

        if units.count <= max {
            return NetText.string(utf16: units)
        }

        return DotNet.trimEnd(NetText.string(utf16: units[..<Swift.max(0, max - 1)])) + "…"
    }

    /// "ctrl + w" → "Ctrl+W", "win+up" → "Win+Up", "m" → "M". Nil if a key isn't one the assistant can press.
    public static func normalizeChord(_ keys: String?) -> String? {
        guard let keys, !DotNet.isNullOrWhiteSpace(keys) else { return nil }
        let parts = DotNet.split(DotNet.trim(keys), ["+"]).map { DotNet.trim($0) }
        if parts.contains(where: \.isEmpty) {
            return nil
        }

        var modifiers = Set<String>()
        var key: String?
        for raw in parts {
            let part = DotNet.replace(DotNet.replace(raw, " ", ""), "_", "")
            var name = keyNames[part]
            let units = Array(part.utf16)
            if name == nil && units.count == 1, let c = Unicode.Scalar(units[0]), isAsciiLetterOrDigit(c) {
                name = DotNet.upperInvariant(String(c))
            } else if name == nil && (units.count == 2 || units.count == 3) && (units[0] == 0x46 || units[0] == 0x66),
                      let f = NetText.parseInteger(NetText.string(utf16: units[1...])), (1...24).contains(f) {
                name = "F\(f)"
            }

            guard let keyName = name else { return nil }
            if modifierOrder.contains(keyName) && parts.count > 1 && key == nil
                && !DotNet.ordinalEquals(raw, parts[parts.count - 1]) {
                modifiers.insert(keyName)
            } else if key == nil {
                key = keyName
            } else {
                // Two keys that aren't modifiers ("ctrl+a+c"): not a chord.
                return nil
            }
        }

        guard let pressed = key else { return nil }
        return (modifierOrder.filter { modifiers.contains($0) } + [pressed]).joined(separator: "+")
    }

    /// Why the brain never presses `chord`, or nil if it may.
    public static func refusalReason(_ chord: String) -> String? {
        let pieces = NetText.split(chord, "+")
        if DotNet.equalsOrdinalIgnoreCase(chord, "Ctrl+Esc")
            || (NetText.contains(pieces, "Win") && !allowedWinChords.contains(chord)) {
            return "it can run commands"
        }

        if clipboardChords.contains(chord) {
            return "I type text myself rather than use the clipboard"
        }

        return menuChords.contains(chord) ? "I click menu items by name instead" : nil
    }

    /// Win shortcuts other than window arranging (Win+R, Win+X, the Start menu…), Ctrl+Esc, clipboard and menu keys.
    public static func isBlockedChord(_ chord: String) -> Bool { refusalReason(chord) != nil }

    public static func needsConfirmation(_ chord: String) -> Bool {
        confirmChords.contains(chord) || altAccessKey.isMatch(chord)
    }

    public static func isSubmitChord(_ chord: String) -> Bool {
        submitChords.contains(chord) || NetText.endsWithOrdinalIgnoreCase(chord, "+Enter")
    }

    /// A key that types a character when a text box has the focus ("M", "Shift+7"): typing, as far as the limits go.
    public static func isCharacterKey(_ chord: String) -> Bool {
        let length = chord.utf16.count
        return length == 1 || (length == 7 && NetText.startsWithOrdinalIgnoreCase(chord, "Shift+"))
    }

    /// A window where text or keys can run a command: terminals, the Run box, Task Manager, launchers, the Start menu
    /// and search, File Explorer and the desktop on Windows (by process; the desktop may add windows it recognises).
    public static func isCommandWindow(_ window: WindowInfo, _ places: BrainPlaces = .windows) -> Bool {
        places.isCommand(window.processName)
    }

    /// A file or folder in the file manager or on the desktop: opening it needs a "yes", as known extensions are
    /// hidden.
    public static func isShellItem(
        _ window: WindowInfo, _ role: ElementRole, _ places: BrainPlaces = .windows
    ) -> Bool {
        role == .listItem && places.isFileManager(window.processName)
    }

    /// Clicking these sends, publishes, installs, runs or agrees to something: a "yes" first (on top of
    /// `TargetResolver.isDestructive`).
    public static func isSendLike(_ name: String) -> Bool {
        let n = TranscriptText.normalize(NameMatcher.cleanElementName(name))
        return sendWords.contains { w in
            DotNet.ordinalEquals(n, w) || DotNet.startsWith(n, w + " ") || DotNet.endsWith(n, " " + w)
        }
    }

    /// A file that starts a program or script when opened ("setup.exe", "run.bat"): opening it needs a "yes".
    public static func runsProgram(_ name: String) -> Bool { programFile.isMatch(name) }

    /// A search or filter box: pressing Enter there searches rather than sends.
    public static func isSearchBox(_ name: String?) -> Bool { hasWord(name, searchBoxWords) }

    /// A box inside an app that runs what is typed (a terminal or console): the brain never types there.
    public static func isCommandBox(_ name: String?) -> Bool { hasWord(name, commandBoxWords) }

    public static func isBrowser(_ window: WindowInfo, _ places: BrainPlaces = .windows) -> Bool {
        places.isBrowser(window.processName)
    }

    /// Text a browser's search box would open as an address that `normalizeUrl` refuses: another scheme, a path, a
    /// local or numeric host. One word with a dot, slash or colon is opened rather than searched for, so it must be a
    /// web host.
    public static func isRefusedAddress(_ text: String?) -> Bool {
        let t = DotNet.trim(text ?? "")
        return addressText.isMatch(t)
            || (!t.isEmpty && !t.unicodeScalars.contains(where: DotNet.isWhiteSpace)
                && t.unicodeScalars.contains(where: { ".:/\\".unicodeScalars.contains($0) }) && normalizeUrl(t) == nil)
    }

    private static func hasWord(_ name: String?, _ words: [String]) -> Bool {
        let n = TranscriptText.normalize(name)
        return !n.isEmpty && words.contains { DotNet.contains(" " + n + " ", " " + $0) }
    }

    /// An http(s) web address, adding https:// to a bare one ("youtube.com"). Other schemes (files, scripts, settings)
    /// and local or numeric hosts are refused.
    public static func normalizeUrl(_ target: String?) -> WebLink? {
        var text = DotNet.trim(target ?? "")
        if text.isEmpty {
            return nil
        }

        if !DotNet.contains(text, "://") {
            if DotNet.contains(text, ":") {
                // "javascript:…", "file:…", "ms-settings:…"
                return nil
            }

            text = "https://" + text
        }

        guard let parsed = NetUri.parse(text), !parsed.hasUserInfo else { return nil }

        // A trailing dot ("localhost.") still names the same host, and browsers read a host ending in a number
        // ("0x7f.1.", "10.0.0.1.") as an IP address. (The C# also refuses what IPAddress.TryParse reads; a host that
        // passes these checks never is one: an IP address ends in a number, a hex number or has a colon.)
        let host = DotNet.trimEnd(parsed.link.idnHost, ["."])
        let last = lastLabel(host)
        let isHex = NetText.startsWithOrdinalIgnoreCase(last, "0x")
            && last.unicodeScalars.dropFirst(2).allSatisfy { $0.properties.isASCIIHexDigit }
        if !DotNet.contains(host, ".") || DotNet.contains(host, "..") || localSuffixes.contains(last)
            || !host.unicodeScalars.contains(where: DotNet.isLetter)
            || last.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) || isHex {
            return nil
        }

        return parsed.link
    }

    /// A web address as said, like "instagram.com" or "github.com/shivam098": one word ending in a common web domain
    /// (.com, .org, .in…) or starting with www. or http, that `normalizeUrl` allows. File names ("report.docx",
    /// "notes.md") aren't addresses; neither are local or numeric hosts.
    public static func webAddress(_ text: String?) -> WebLink? {
        let t = DotNet.trimEnd(DotNet.trim(text ?? ""), [".", ",", "!", "?", ";", ":"])
        guard !t.isEmpty, !t.unicodeScalars.contains(where: DotNet.isWhiteSpace), DotNet.contains(t, "."),
              let link = normalizeUrl(t)
        else { return nil }

        let host = DotNet.trimEnd(link.idnHost, ["."])
        return webDomains.contains(lastLabel(host)) || NetText.startsWithOrdinalIgnoreCase(t, "www.")
            || NetText.startsWithOrdinalIgnoreCase(t, "http")
            ? link
            : nil
    }

    /// The site's own search results page; Google for sites without one.
    public static func searchUrl(_ site: String?, _ query: String) -> (url: WebLink, site: String) {
        let q = escapeDataString(DotNet.trim(query))
        let compact = TranscriptText.compact(site)
        func named(_ names: String...) -> Bool { names.contains { DotNet.ordinalEquals(compact, $0) } }
        let page: (String, String)
        if named("youtube") {
            page = ("https://www.youtube.com/results?search_query=\(q)", "YouTube")
        } else if named("bing") {
            page = ("https://www.bing.com/search?q=\(q)", "Bing")
        } else if named("wikipedia") {
            page = ("https://en.wikipedia.org/w/index.php?search=\(q)", "Wikipedia")
        } else if named("github") {
            page = ("https://github.com/search?q=\(q)", "GitHub")
        } else if named("maps", "googlemaps") {
            page = ("https://www.google.com/maps/search/\(q)", "Google Maps")
        } else if named("", "google", "web", "internet") {
            page = ("https://www.google.com/search?q=\(q)", "Google")
        } else {
            let both = escapeDataString(cleanText(site, 40) + " " + DotNet.trim(query))
            page = ("https://www.google.com/search?q=\(both)", "Google")
        }

        // The escape leaves only unreserved characters and escapes, so the address always reads; dot segments may go
        // ("maps" for ".." is the maps page itself, as in C#).
        return (NetUri.parse(page.0)!.link, page.1)
    }

    /// `Uri.EscapeDataString`: everything but letters, digits and - . _ ~ as UTF-8 %XX, in upper case.
    static func escapeDataString(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let digits = Array("0123456789ABCDEF".unicodeScalars)
                out.unicodeScalars.append("%")
                out.unicodeScalars.append(digits[Int(byte >> 4)])
                out.unicodeScalars.append(digits[Int(byte & 0x0F)])
            }
        }

        return out
    }

    /// The text after the last dot (all of it if there's none).
    private static func lastLabel(_ host: String) -> String {
        guard let dot = host.unicodeScalars.lastIndex(of: ".") else { return host }
        return String(host.unicodeScalars[host.unicodeScalars.index(after: dot)...])
    }

    private static func isAsciiLetterOrDigit(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
    }
}
