import Foundation
import ThumbFreeCore

/// The brain's limits, enforced in code whatever the model says: which keys it may press, which links it may open,
/// which windows it may type into, and what needs a "yes" first. What the places, button words, program files and keys
/// mean depends on the platform (`BrainPlatform`), which every such check takes.
///
/// Plans name keys the C# core's way, as on Windows, on every platform: the prompt is Windows', for parity.
/// `keyPress` judges a chord once and returns the exact keys to press with the verdict, so what is pressed is always
/// what was judged. On Windows a chord is pressed as named. On the Mac it is pressed as its Mac chord, and it is
/// refused, or needs a "yes", if Windows' rules say so for the chord as named or the Mac's say so for the Mac chord.
/// The Mac chords:
/// - a `ShortcutKeys` shortcut is the Mac's: Ctrl+Y is ⇧⌘Z, Alt+Left ⌘[, Alt+Right ⌘], Alt+Up ⌘↑, F5 ⌘R, Ctrl+Tab
///   stays ⌃Tab and Ctrl+Backspace is ⌥⌫; Win+Up (maximize) has no Mac key, so the window in front is zoomed instead
///   (`BrainKeyPress.zooms`);
/// - Alt+F4 and Ctrl+F4 are ⌘W, Ctrl+F5 ⇧⌘R, F11 ⌃⌘F, Win+Down ⌘M and Win+M ⌥⌘M;
/// - the other Win chords, F21 to F24 (Macs stop at F20) and a modifier on its own have no Mac key and are refused;
/// - Ctrl with an arrow, Backspace or Delete, and without Alt, becomes ⌥, the Mac's word and paragraph key
///   (Ctrl+Shift+Left is ⌥⇧←, Ctrl+Down ⌥↓); any other Ctrl becomes ⌘ (Ctrl+L is ⌘L, Ctrl+Space ⌘Space);
/// - Alt, Shift and the keys stay as they are.
///
/// The Mac refuses ⌘Space and ⌥⌘Space (Spotlight, Finder's search), ⌘Q and ⌥⌘Q (quit), ⇧⌘Q and ⌥⇧⌘Q (log out),
/// ⌃⌘Q (lock the screen), ⌥⌘⎋ and ⌥⇧⌘⎋ (force quit), ⌘⌫ and ⌥⌘⌫ (delete), ⇧⌘⌫ and ⌥⇧⌘⌫ (empty the Trash), ⌘D
/// (Don't Save), ⌘↓ with any other modifiers (open, in Finder and file dialogs), ⇧⌘3, ⇧⌘4, ⇧⌘5 and ⇧⌘6 with any
/// other modifiers (screenshots, which Windows' rules never allow either), ⌘F5 and ⌥⌘F5 (VoiceOver and the
/// accessibility shortcuts), ⌃F2, ⌃F3 and ⌃F8 (the menu bar, the Dock and the status menus) and the clipboard's ⌘C,
/// ⌘X, ⌘V, ⇧⌘V, ⌥⌘V, ⌥⇧⌘V and ⌥⌘C. It asks before any ⌘ chord on W (closing), ⇧⌘D (Mail's Send), Delete (⌦) with any
/// modifiers, and Backspace (⌫) with any modifiers unless the focus is an editable text box: elsewhere ⌫ deletes the
/// selected message, note or event. So Win+D, Win+Down, Ctrl+Space, Ctrl+Alt+Esc and Ctrl+Backspace can't become ⌘D,
/// ⌘↓, ⌘Space, ⌥⌘⎋ or ⌘⌫. (The keys pressed are named as `ShortcutKeys` says the desktop presses them.) On the Mac
/// Return also presses the front window's default button, whatever has the focus, so the interaction controller
/// judges that button before a key that submits (`JarvisDesktop.describeDefaultButton`).
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

    /// How `platform` presses `chord` (a plan's keys, as `normalizeChord` writes them), judged once: the exact keys to
    /// press and the verdict on them. The interaction controller presses `keys` of the result and nothing else, and for
    /// one that `zooms` presses nothing and zooms the window in front.
    public static func keyPress(_ chord: String, _ platform: BrainPlatform) -> BrainKeyPress {
        guard platform.kind == .mac else {
            return BrainKeyPress(
                named: chord, keys: chord, refusal: windowsRefusalReason(chord), focusDecides: false, zooms: false,
                kind: .windows)
        }

        let keys = macChord(chord)
        var refusal = windowsRefusalReason(chord)
        let zooms = refusal == nil && macZooms(chord)
        if refusal == nil && !zooms {
            if let keys {
                refusal = macRefusalReason(keys)
            } else {
                refusal = "a Mac has no key for it"
            }
        }

        let focusDecides = keys.map { DotNet.ordinalEquals(lastPiece($0), "Backspace") } ?? false
        return BrainKeyPress(
            named: chord, keys: keys, refusal: refusal, focusDecides: focusDecides, zooms: zooms, kind: .mac)
    }

    /// Why the brain never presses `chord` (a plan's keys, as `normalizeChord` writes them), or nil if it may. On the
    /// Mac, also why it never presses the chord's Mac keys, or that there are none.
    public static func refusalReason(_ chord: String, _ platform: BrainPlatform) -> String? {
        keyPress(chord, platform).refusal
    }

    /// Win shortcuts other than window arranging (Win+R, Win+X, the Start menu…), Ctrl+Esc, clipboard and menu keys;
    /// on the Mac also what `macRefusalReason` refuses.
    public static func isBlockedChord(_ chord: String, _ platform: BrainPlatform) -> Bool {
        refusalReason(chord, platform) != nil
    }

    /// Whether pressing `chord` needs a "yes" first (`BrainKeyPress.needsConfirmation`).
    public static func needsConfirmation(_ chord: String, _ platform: BrainPlatform, focus: FocusInfo?) -> Bool {
        keyPress(chord, platform).needsConfirmation(focus: focus)
    }

    /// The C#'s keys that need a "yes", on the chord as named: closing, quitting and deleting keys, and Alt+letter.
    static func windowsNeedsConfirmation(_ chord: String) -> Bool {
        confirmChords.contains(chord) || altAccessKey.isMatch(chord)
    }

    /// Enter, Space, Alt+S or Enter with modifiers: they submit what's in a box or press the focused button. Judged on
    /// the chord as named, whose Mac chord submits in the same way.
    public static func isSubmitChord(_ chord: String) -> Bool {
        submitChords.contains(chord) || NetText.endsWithOrdinalIgnoreCase(chord, "+Enter")
    }

    /// A key that types a character when a text box has the focus ("M", "Shift+7"): typing, as far as the limits go.
    /// The Mac chord is the same key.
    public static func isCharacterKey(_ chord: String) -> Bool {
        let length = chord.utf16.count
        return length == 1 || (length == 7 && NetText.startsWithOrdinalIgnoreCase(chord, "Shift+"))
    }

    /// The C#'s refusals, on the chord as named.
    private static func windowsRefusalReason(_ chord: String) -> String? {
        let pieces = NetText.split(chord, "+")
        if DotNet.equalsOrdinalIgnoreCase(chord, "Ctrl+Esc")
            || (NetText.contains(pieces, "Win") && !allowedWinChords.contains(chord)) {
            return "it can run commands"
        }

        if clipboardChords.contains(chord) {
            return clipboardReason
        }

        return menuChords.contains(chord) ? "I click menu items by name instead" : nil
    }

    private static let clipboardReason = "I type text myself rather than use the clipboard"

    /// Windows chords whose Mac chord is neither a `ShortcutKeys` shortcut's nor what the modifier rule gives.
    private static let macEquivalents = IgnoreCaseMap<String>([
        ("Alt+F4", "Cmd+W"), ("Ctrl+F4", "Cmd+W"), ("Ctrl+F5", "Shift+Cmd+R"), ("F11", "Ctrl+Cmd+F"),
        ("Win+Down", "Cmd+M"), ("Win+M", "Alt+Cmd+M"),
    ])

    private static let macModifierOrder = ["Ctrl", "Alt", "Shift", "Cmd"]

    /// Keys Windows has and Macs don't: Mac keyboards stop at F20.
    private static let keysMacsLack = ["F21", "F22", "F23", "F24"]

    /// Keys whose Ctrl moves are the Mac's ⌥ moves: by word left and right, by paragraph up and down.
    private static let wordMoveKeys = ["Left", "Right", "Up", "Down", "Backspace", "Delete"]

    /// The Mac chord for a chord a plan names (as `normalizeChord` writes it), or nil if the Mac has no key for it.
    static func macChord(_ chord: String) -> String? {
        guard DotNet.ordinalEquals(normalizeChord(chord) ?? "", chord) else { return nil }
        if let shortcut = Shortcut.allCases.first(where: {
            DotNet.equalsOrdinalIgnoreCase(ShortcutKeys.windows.keys(for: $0), chord)
        }) {
            return ShortcutKeys.mac.keys(for: shortcut)
        }

        if DotNet.equalsOrdinalIgnoreCase(ShortcutKeys.windows.deleteWordBefore, chord) {
            return ShortcutKeys.mac.deleteWordBefore
        }

        if case .keys(let maximize) = ShortcutKeys.windows.maximize, DotNet.equalsOrdinalIgnoreCase(maximize, chord) {
            guard case .keys(let zoom) = ShortcutKeys.mac.maximize else { return nil }
            return zoom
        }

        if let equivalent = macEquivalents[chord] {
            return equivalent
        }

        let pieces = NetText.split(chord, "+")
        let key = pieces[pieces.count - 1]
        var modifiers = Array(pieces.dropLast())
        if NetText.contains(modifiers, "Win") || NetText.contains(modifierOrder, key)
            || NetText.contains(keysMacsLack, key) {
            return nil
        }

        if let ctrl = modifiers.firstIndex(of: "Ctrl") {
            modifiers[ctrl] = NetText.contains(wordMoveKeys, key) && !NetText.contains(modifiers, "Alt") ? "Alt" : "Cmd"
        }

        return (macModifierOrder.filter { NetText.contains(modifiers, $0) } + [key]).joined(separator: "+")
    }

    /// Whether the Mac zooms the window in front for `chord` (a plan's keys, as `normalizeChord` writes them): it's
    /// Windows' maximize keys, and no Mac key maximizes (`ShortcutKeys.Maximize.zoomThroughAccessibility`).
    private static func macZooms(_ chord: String) -> Bool {
        guard case .keys(let maximize) = ShortcutKeys.windows.maximize,
              ShortcutKeys.mac.maximize == .zoomThroughAccessibility
        else { return false }
        return DotNet.equalsOrdinalIgnoreCase(maximize, chord)
    }

    /// Mac chords the brain never presses, and why.
    private static let macRefusals = IgnoreCaseMap<String>([
        ("Cmd+Space", "it can run commands"), ("Alt+Cmd+Space", "it can run commands"),
        ("Ctrl+F3", "it can run commands"), ("Ctrl+F2", "I click menu items by name instead"),
        ("Ctrl+F8", "I click menu items by name instead"), ("Cmd+Q", "it quits the app"),
        ("Alt+Cmd+Q", "it quits the app"), ("Shift+Cmd+Q", "it logs you out"), ("Alt+Shift+Cmd+Q", "it logs you out"),
        ("Ctrl+Cmd+Q", "it locks the screen"), ("Alt+Cmd+Esc", "it force quits apps"),
        ("Alt+Shift+Cmd+Esc", "it force quits apps"), ("Cmd+Backspace", "it deletes files and documents"),
        ("Alt+Cmd+Backspace", "it deletes files and documents"), ("Shift+Cmd+Backspace", "it empties the Trash"),
        ("Alt+Shift+Cmd+Backspace", "it empties the Trash"), ("Cmd+D", "in a Save dialog it throws the changes away"),
        ("Cmd+F5", "it turns VoiceOver on or off"), ("Alt+Cmd+F5", "it changes the accessibility settings"),
        ("Cmd+C", clipboardReason), ("Cmd+X", clipboardReason), ("Cmd+V", clipboardReason),
        ("Shift+Cmd+V", clipboardReason), ("Alt+Cmd+V", clipboardReason), ("Alt+Shift+Cmd+V", clipboardReason),
        ("Alt+Cmd+C", clipboardReason),
    ])

    /// Why the brain never presses `macChord` (a Mac chord) on the Mac, or nil.
    static func macRefusalReason(_ macChord: String) -> String? {
        if let reason = macRefusals[macChord] {
            return reason
        }

        let key = lastPiece(macChord)
        let modifiers = pieces(macChord).dropLast()
        let command = NetText.contains(Array(modifiers), "Cmd")

        // ⌘↓, with any other modifiers, opens the selected item in Finder and in file dialogs.
        if command && DotNet.ordinalEquals(key, "Down") {
            return "it opens the selected file"
        }

        // ⇧⌘3 to ⇧⌘6, with any other modifiers, take screenshots or open the screenshot tools.
        let shift = NetText.contains(Array(modifiers), "Shift")
        return command && shift && ["3", "4", "5", "6"].contains(key) ? "it takes screenshots" : nil
    }

    /// Whether `macChord` (a Mac chord) needs a "yes" first on the Mac: any ⌘ chord on W (closing), Mail's Send,
    /// Delete, and Backspace unless `focus` is an editable text box.
    static func macNeedsConfirmation(_ macChord: String, focus: FocusInfo?) -> Bool {
        let key = lastPiece(macChord)
        let closes = DotNet.ordinalEquals(key, "W") && NetText.contains(pieces(macChord), "Cmd")
        return closes || DotNet.equalsOrdinalIgnoreCase(macChord, "Shift+Cmd+D") || DotNet.ordinalEquals(key, "Delete")
            || (DotNet.ordinalEquals(key, "Backspace") && focus?.editable != true)
    }

    private static func pieces(_ chord: String) -> [String] { NetText.split(chord, "+") }

    private static func lastPiece(_ chord: String) -> String { pieces(chord).last ?? "" }

    /// A window where text or keys can run a command: terminals, the Run box, Task Manager, launchers, the Start menu
    /// and search, the file manager (by process; the desktop may add windows it recognises).
    public static func isCommandWindow(_ window: WindowInfo, _ platform: BrainPlatform) -> Bool {
        platform.isCommand(window.processName)
    }

    /// A file or folder in the file manager or on the desktop: opening it needs a "yes", as known extensions are
    /// hidden.
    public static func isShellItem(_ window: WindowInfo, _ role: ElementRole, _ platform: BrainPlatform) -> Bool {
        role == .listItem && platform.isFileManager(window.processName)
    }

    /// Clicking these sends, publishes, installs, runs or agrees to something: a "yes" first (on top of
    /// `TargetResolver.isDestructive`).
    public static func isSendLike(_ name: String, _ platform: BrainPlatform) -> Bool {
        let n = TranscriptText.normalize(NameMatcher.cleanElementName(name))
        return platform.sendWords.contains { w in
            DotNet.ordinalEquals(n, w) || DotNet.startsWith(n, w + " ") || DotNet.endsWith(n, " " + w)
        }
    }

    /// A file that starts a program or script, or opens a link, when opened ("setup.exe", "run.bat"; "Install.pkg"
    /// on the Mac): opening it needs a "yes".
    public static func runsProgram(_ name: String, _ platform: BrainPlatform) -> Bool {
        platform.programFile.isMatch(name)
    }

    /// A search or filter box: pressing Enter there searches rather than sends.
    public static func isSearchBox(_ name: String?) -> Bool { hasWord(name, searchBoxWords) }

    /// A box inside an app that runs what is typed (a terminal or console): the brain never types there.
    public static func isCommandBox(_ name: String?) -> Bool { hasWord(name, commandBoxWords) }

    public static func isBrowser(_ window: WindowInfo, _ platform: BrainPlatform) -> Bool {
        platform.isBrowser(window.processName)
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

/// A chord a plan names, as one platform presses it and judged once (`BrainSafety.keyPress`). `keys` is what the
/// desktop is asked to press, and the verdict is of the chord as named (Windows' rules) and of `keys` (the Mac's), so
/// what is pressed is always what was judged.
public struct BrainKeyPress: Equatable, Sendable {
    /// The chord as the plan names it, as `normalizeChord` writes it: Windows' keys on every platform.
    public let named: String

    /// The platform's keys for it: `named` on Windows, its Mac chord on the Mac; nil when the Mac has no key for it
    /// (then it's refused, unless it `zooms`).
    public let keys: String?

    /// Why it's never pressed, or nil if it may be.
    public let refusal: String?

    /// Whether `needsConfirmation` depends on what has the focus (on the Mac, for a Backspace): read it first.
    public let focusDecides: Bool

    /// On the Mac, Windows' maximize keys (Win+Up): nothing is pressed, and the window in front is zoomed instead
    /// (`JarvisDesktop.zoom`), with no "yes", as Windows presses Win+Up. Never on Windows.
    public let zooms: Bool

    let kind: BrainPlatform.Kind

    /// The keys to press, or nil when it's refused or `zooms`. A "yes" may still be needed first (`needsConfirmation`).
    public var pressable: String? { refusal == nil ? keys : nil }

    /// How the messages name it: the platform's keys, else the chord as named.
    public var shown: String { keys ?? named }

    /// Whether pressing it needs a "yes" first. `focus` is what has the focus, nil if it wasn't read or isn't known;
    /// on the Mac, Backspace asks unless the focus is an editable text box.
    public func needsConfirmation(focus: FocusInfo?) -> Bool {
        if BrainSafety.windowsNeedsConfirmation(named) {
            return true
        }

        guard kind == .mac, let keys else { return false }
        return BrainSafety.macNeedsConfirmation(keys, focus: focus)
    }
}
