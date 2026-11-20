import ThumbFreeCore

/// A rectangle in screen pixels, as the platform's accessibility API reports them.
public struct ScreenRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var right: Double { x + width }

    public var bottom: Double { y + height }

    public var centerX: Double { x + (width / 2) }

    public var centerY: Double { y + (height / 2) }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersects(_ other: ScreenRect) -> Bool {
        x < other.right && other.x < right && y < other.bottom && other.y < bottom
    }

    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px <= right && py >= y && py <= bottom }
}

public enum ElementRole: Sendable {
    case button
    case link
    case tab
    case menuItem
    case treeItem
    case listItem
    case checkBox
    case radioButton
    case comboBox
    case textBox
    case other
}

/// Something on screen the user can act on, as the platform's accessibility API reports it. `id` is an opaque handle
/// the desktop maps back to the live element; it is valid only for a short time.
public struct UiElement: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var role: ElementRole
    public var rect: ScreenRect

    public init(id: Int, name: String, role: ElementRole, rect: ScreenRect) {
        self.id = id
        self.name = name
        self.role = role
        self.rect = rect
    }
}

/// A browser tab. `index` is 1-based within its window; windows are listed front-most first.
public struct BrowserTab: Equatable, Sendable {
    public var id: Int
    public var title: String
    public var index: Int
    public var isSelected: Bool
    public var window: WindowInfo
    public var rect: ScreenRect

    public init(id: Int, title: String, index: Int, isSelected: Bool, window: WindowInfo, rect: ScreenRect) {
        self.id = id
        self.title = title
        self.index = index
        self.isSelected = isSelected
        self.window = window
        self.rect = rect
    }
}

public enum ScreenRegion: Sendable {
    case left
    case right
    case top
    case bottom
}

/// What the user named: "the second Issues on the left" is name "issues", ordinal 2, region left. Ordinal -1 is the
/// last.
public struct ElementTarget: Hashable, Sendable, CustomStringConvertible {
    public var name: String
    public var region: ScreenRegion?
    public var ordinal: Int?

    public init(name: String, region: ScreenRegion? = nil, ordinal: Int? = nil) {
        self.name = name
        self.region = region
        self.ordinal = ordinal
    }

    public var description: String { name }
}

/// A number shown next to a candidate so the user can pick it by saying the number.
public struct ChoiceBadge: Hashable, Sendable {
    public var number: Int
    public var rect: ScreenRect
    public var label: String

    public init(number: Int, rect: ScreenRect, label: String) {
        self.number = number
        self.rect = rect
        self.label = label
    }
}

/// Per-website defaults: which text box "start typing" means on that site. Matched against the browser window's
/// cleaned title: a title segment (split on " - ") must equal a token, or start with it when the token ends in "*".
public struct SiteProfile: Hashable, Sendable {
    public var name: String
    public var titleContains: [String]
    public var textBoxNames: [String]
    public var focusKeys: String?

    public init(name: String, titleContains: [String], textBoxNames: [String], focusKeys: String? = nil) {
        self.name = name
        self.titleContains = titleContains
        self.textBoxNames = textBoxNames
        self.focusKeys = focusKeys
    }

    public static let defaults = [
        SiteProfile(name: "YouTube", titleContains: ["YouTube"], textBoxNames: ["Search"], focusKeys: "/"),
        SiteProfile(name: "Google", titleContains: ["Google", "Google Search"], textBoxNames: ["Search"]),
        SiteProfile(name: "Bing", titleContains: ["Bing"], textBoxNames: ["Search", "Enter your search"]),
        SiteProfile(name: "Wikipedia", titleContains: ["Wikipedia"], textBoxNames: ["Search Wikipedia", "Search"]),
        SiteProfile(
            name: "WhatsApp", titleContains: ["WhatsApp", "WhatsApp Web"], textBoxNames: ["Type a message", "message"]),
        SiteProfile(name: "Gmail", titleContains: ["Gmail"], textBoxNames: ["Search mail"]),
        SiteProfile(name: "ChatGPT", titleContains: ["ChatGPT"], textBoxNames: ["Ask anything", "Message", "prompt"]),
        SiteProfile(
            name: "Copilot", titleContains: ["Microsoft Copilot*", "Copilot"],
            textBoxNames: ["Message Copilot", "Ask", "message"]),
        SiteProfile(name: "Amazon", titleContains: ["Amazon*"], textBoxNames: ["Search Amazon", "Search"]),
    ]

    public static func forTitle(_ windowTitle: String?) -> SiteProfile? {
        let segments = NetText.split(NameMatcher.cleanTabTitle(windowTitle), " - ", removeEmpty: true, trim: true)
        return defaults.first { profile in
            profile.titleContains.contains { token in segments.contains { matches($0, token) } }
        }
    }

    private static func matches(_ segment: String, _ token: String) -> Bool {
        if !DotNet.endsWith(token, "*") {
            return DotNet.equalsOrdinalIgnoreCase(segment, token)
        }

        let prefix = Array(NetText.dropSuffix(token, "*").unicodeScalars)
        let scalars = Array(segment.unicodeScalars)
        guard NetText.startsWithOrdinalIgnoreCase(segment, DotNet.string(prefix)) else { return false }
        return scalars.count == prefix.count || !DotNet.isLetter(scalars[prefix.count])
    }
}

/// Cleans accessibility names and scores how well a spoken phrase matches them, by the same rules on every platform,
/// so "click New on the left" behaves the same everywhere.
public enum NameMatcher {
    public static let exact = 100
    public static let strong = 80
    public static let words = 70
    public static let partial = 60
    public static let fuzzy = 50

    /// Drops the keyboard-shortcut and state suffixes apps append to accessible names: "New project, Ctrl + Alt + Shift
    /// + N" is "New project"; "Fix login, unread" is "Fix login".
    public static func cleanElementName(_ name: String?) -> String {
        guard let name, !DotNet.isNullOrWhiteSpace(name) else { return "" }
        var text = shortcutSuffixRegex.replace(DotNet.trim(name), "")
        text = stateSuffixRegex.replace(text, "")

        // Chat lists: "1 unread message Bibhash Morang 11:27 am aise bante…" is "Bibhash Morang aise bante…".
        text = unreadPrefixRegex.replace(text, "")
        text = clockTimeRegex.replace(text, " ")
        text = multiSpaceRegex.replace(text, " ")
        return DotNet.trim(DotNet.trimEnd(DotNet.trim(text), [",", ";"]))
    }

    /// Browser tab names carry extras: "(53) WhatsApp - Pinned - Memory usage - 120 MB" is "WhatsApp"; "Inbox - Gmail -
    /// Google Chrome" is "Inbox - Gmail".
    public static func cleanTabTitle(_ title: String?) -> String {
        guard let title, !DotNet.isNullOrWhiteSpace(title) else { return "" }
        var text = DotNet.trim(DotNet.replace(title, "\u{200B}", " "))
        text = notificationCountRegex.replace(text, "")
        var kept: [String] = []
        for part in NetText.split(text, " - ").map({ DotNet.trim($0) }) {
            if tabStatusRegex.isMatch(part) {
                // Status segments ("Memory usage - 54 MB") end the useful part of the title.
                break
            }

            kept.append(part)
        }

        while kept.count > 1 && browserNameRegex.isMatch(kept[kept.count - 1]) {
            kept.removeLast()
        }

        return DotNet.trim(kept.joined(separator: " - "))
    }

    /// 0 (no match) to 100 (exact). Plurals, spacing, hyphens and small recognition slips are tolerated.
    public static func score(_ spoken: String, _ name: String) -> Int {
        let s = TranscriptText.normalize(spoken)
        let n = TranscriptText.normalize(name)
        if s.isEmpty || n.isEmpty {
            return 0
        }

        if DotNet.ordinalEquals(s, n) {
            return exact
        }

        let sc = singular(DotNet.replace(s, " ", ""))
        let nc = singular(DotNet.replace(n, " ", ""))
        if DotNet.ordinalEquals(sc, nc) {
            return exact - 5
        }

        let sw = DotNet.split(s, [" "]).map(singular)
        let nw = DotNet.split(n, [" "]).map(singular)
        if nw.count > sw.count && DotNet.sequenceEqual(Array(nw.prefix(sw.count)), sw) {
            // "new" vs "new project": a prefix of the name, shorter names score higher.
            return strong - min(10, nw.count - sw.count)
        }

        if sw.allSatisfy({ NetText.contains(nw, $0) }) {
            return words - min(10, nw.count - sw.count)
        }

        if nw.count >= 1 && n.utf16.count >= 3 && nw.allSatisfy({ NetText.contains(sw, $0) }) {
            // The user said more than the name: "the pull requests page" vs "Pull requests".
            return partial
        }

        let allowed = allowedSlips(sc.utf16.count)
        if allowed > 0 && levenshtein(sc, nc) <= allowed {
            return fuzzy
        }

        // Every spoken word sounds like a word of the name: "vivash morang" vs "Bibhash Morang" (Whisper often swaps
        // v/b, drops or adds the h of bh/sh/th, and doubles letters in names).
        let nameKeys = nw.map(soundKey)
        let spokenKeys = sw.map(soundKey)
        if spokenKeys.contains(where: { $0.utf16.count >= 3 })
            && spokenKeys.allSatisfy({ NetText.contains(nameKeys, $0) }) {
            return fuzzy
        }

        return 0
    }

    private static func allowedSlips(_ length: Int) -> Int { length < 4 ? 0 : length <= 7 ? 1 : 2 }

    /// A rough sound-alike key for one word: v/w become b, z j, q k, ph f, ee i and oo u; an h after a consonant is
    /// dropped (bh, sh, th, kh…), and doubled letters merge. "vivash" and "bibhash" both become "bibas".
    public static func soundKey(_ word: String) -> String {
        let w = DotNet.replace(
            DotNet.replace(DotNet.replace(DotNet.replace(word, "ph", "f"), "ck", "k"), "ee", "i"), "oo", "u")
        let vowels: Set<UInt16> = [0x61, 0x65, 0x69, 0x6F, 0x75]
        var key: [UInt16] = []
        // As C#, by UTF-16 code unit.
        for unit in w.utf16 {
            let c: UInt16
            switch unit {
            case 0x76, 0x77: c = 0x62 // v, w: b
            case 0x7A: c = 0x6A // z: j
            case 0x71: c = 0x6B // q: k
            default: c = unit
            }

            if let last = key.last, (c == 0x68 && !vowels.contains(last)) || last == c {
                continue
            }

            key.append(c)
        }

        return NetText.string(utf16: key)
    }

    private static func singular(_ word: String) -> String {
        word.utf16.count > 3 && DotNet.endsWith(word, "s") && !DotNet.endsWith(word, "ss")
            ? NetText.dropSuffix(word, "s") : word
    }

    /// Edit distance by UTF-16 code unit, as in C#; `Int.max` when the lengths differ by more than 2.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf16)
        let b = Array(b.utf16)
        if abs(a.count - b.count) > 2 {
            return Int.max
        }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in stride(from: 1, through: a.count, by: 1) {
            current[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(min(current[j - 1] + 1, previous[j] + 1), substitution)
            }

            swap(&previous, &current)
        }

        return previous[b.count]
    }

    // MARK: Patterns: Navigation.cs's, verbatim (NetRegex translates them)

    private static let shortcutSuffixRegex = NetRegex(
        #",\s*((Ctrl|Control|Alt|Shift|Win|Windows|Cmd|Command)\s*\+.*|(Ctrl|Alt|Shift)\s*\w)$"#, .ignoreCase)

    private static let stateSuffixRegex = NetRegex(
        #"([,.]\s*(unread|read|selected|not selected|expanded|collapsed|checked|unchecked|pinned|new|draft"#
            + #"|status:.*|\d+ unread.*))+$"#,
        .ignoreCase)

    private static let unreadPrefixRegex = NetRegex(#"^\d+\s+unread\s+messages?[,.]?\s*"#, .ignoreCase)

    // Only after other text, so time-slot buttons ("9:30 AM", "7:00 AM, Good morning") keep their names.
    private static let clockTimeRegex = NetRegex(
        #"(?<=\S\s+)\b\d{1,2}:\d{2}(\s*[ap]\.?m\.?)?(?=\s|$|[,.])"#, .ignoreCase)

    private static let multiSpaceRegex = NetRegex(#"\s{2,}"#)

    private static let notificationCountRegex = NetRegex(#"^\(\d+\+?\)\s*"#)

    private static let tabStatusRegex = NetRegex(
        #"^(Pinned|Memory usage.*|Audio playing|Muted|Network error|Crashed|Sharing your screen|Camera in use"#
            + #"|Microphone in use|Recording.*|Loading.*|Bluetooth.*|\d+(\.\d+)?\s*(KB|MB|GB))$"#,
        .ignoreCase)

    private static let browserNameRegex = NetRegex(
        #"^(Google Chrome|Microsoft\s*Edge|Mozilla Firefox|Firefox|Brave|Opera|Vivaldi|Personal|Work|Profile \d+)$"#,
        .ignoreCase)
}

/// What a name resolved to (C#'s `Resolution<T>`).
public enum Resolution<T> {
    case single(T)

    /// Several equally good matches: the caller shows numbers.
    case ambiguous([T])

    /// C#'s `None` (`.none` would be read as Optional's).
    case noMatch
}

extension Resolution: Equatable where T: Equatable {}

extension Resolution: Sendable where T: Sendable {}

/// Picks the element or tab the user meant, by the same rules on every platform.
public enum TargetResolver {
    private static func rolePriority(_ role: ElementRole) -> Int {
        switch role {
        case .button, .link, .tab, .menuItem: return 0
        case .treeItem, .checkBox, .radioButton, .comboBox, .textBox: return 1
        case .listItem: return 2
        case .other: return 3
        }
    }

    /// Merges the same control reported twice (a list item wrapping a button of the same name, as in GitHub Copilot's
    /// sidebar), keeping the most clickable role.
    public static func deduplicate(_ elements: [UiElement]) -> [UiElement] {
        var kept: [UiElement] = []
        for element in DotNet.orderBy(elements, { rolePriority($0.role) }) {
            let name = NameMatcher.cleanElementName(element.name)
            let duplicate = kept.contains { k in
                DotNet.equalsOrdinalIgnoreCase(NameMatcher.cleanElementName(k.name), name)
                    && (k.rect.contains(element.rect.centerX, element.rect.centerY)
                        || element.rect.contains(k.rect.centerX, k.rect.centerY))
            }

            if !duplicate {
                kept.append(element)
            }
        }

        return sortReadingOrder(kept)
    }

    /// Top to bottom, then left to right (rows grouped within half an element's height). The same order as C#'s, also
    /// where the grouping makes it inconsistent (`NetSort`).
    public static func sortReadingOrder<T>(_ items: [T], _ rect: (T) -> ScreenRect) -> [T] {
        var list = items
        NetSort.sort(&list) { a, b in
            let ra = rect(a)
            let rb = rect(b)
            let row = netMax(4, netMin(ra.height, rb.height) / 2)
            if abs(ra.y - rb.y) > row {
                return NetSort.compare(ra.y, rb.y)
            }

            return NetSort.compare(ra.x, rb.x)
        }

        return list
    }

    public static func sortReadingOrder(_ items: [UiElement]) -> [UiElement] { sortReadingOrder(items) { $0.rect } }

    public static func inRegion(_ rect: ScreenRect, _ region: ScreenRegion, _ window: ScreenRect) -> Bool {
        switch region {
        case .left: return rect.centerX < window.x + (window.width * 0.35)
        case .right: return rect.centerX > window.x + (window.width * 0.65)
        case .top: return rect.centerY < window.y + (window.height * 0.3)
        case .bottom: return rect.centerY > window.y + (window.height * 0.7)
        }
    }

    /// Elements whose cleaned name best matches the target (score at least `minScore`), narrowed by region and ordinal.
    /// One clear winner is `single`; ties are `ambiguous` (the caller shows numbers); nothing is `noMatch`.
    public static func resolveElement(
        _ elements: [UiElement],
        _ target: ElementTarget,
        _ window: ScreenRect?,
        minScore: Int = NameMatcher.fuzzy
    ) -> Resolution<UiElement> {
        var candidates = deduplicate(elements)
        if let region = target.region, let window {
            candidates = candidates.filter { inRegion($0.rect, region, window) }
        }

        if !target.name.isEmpty {
            let scored = candidates
                .map { (element: $0, score: NameMatcher.score(target.name, NameMatcher.cleanElementName($0.name))) }
                .filter { $0.score >= minScore }
            guard let best = scored.map({ $0.score }).max() else { return .noMatch }
            candidates = sortReadingOrder(collapseNested(scored.filter { $0.score == best }.map { $0.element }))
        }

        return pick(candidates, target.ordinal)
    }

    /// Equally good matches where one sits inside the other are the same thing on screen (a chat row and its name
    /// cell): the innermost is kept.
    private static func collapseNested(_ tied: [UiElement]) -> [UiElement] {
        tied.indices
            .filter { o in
                let outer = tied[o]
                return !tied.indices.contains { i in
                    let inner = tied[i]
                    return i != o && inner.rect.width * inner.rect.height < outer.rect.width * outer.rect.height
                        && outer.rect.contains(inner.rect.centerX, inner.rect.centerY)
                }
            }
            .map { tied[$0] }
    }

    /// Tabs by position ("first tab" is in the front-most browser window) or by cleaned title. Titles are long, so a
    /// name must match whole words ("YouTube" in "Lofi beats - YouTube").
    public static func resolveTab(
        _ tabs: [BrowserTab],
        _ target: ElementTarget,
        minScore: Int = NameMatcher.words - 10
    ) -> Resolution<BrowserTab> {
        guard let first = tabs.first else { return .noMatch }
        if target.name.isEmpty {
            let inFront = DotNet.orderBy(tabs.filter { $0.window.sameWindow(first.window) }) { $0.index }
            return pick(inFront, target.ordinal ?? 1)
        }

        let scored = tabs.map { (tab: $0, score: tabScore(target.name, $0.title)) }.filter { $0.score >= minScore }
        guard let best = scored.map({ $0.score }).max() else { return .noMatch }
        let top = scored.filter { $0.score == best }.map { $0.tab }
        if top.count > 1 && target.ordinal == nil {
            // The same site open in several windows: the front-most browser window wins.
            let front = top.filter { $0.window.sameWindow(first.window) }
            if front.count == 1 {
                return .single(front[0])
            }
        }

        return pick(top, target.ordinal)
    }

    /// The best score of the spoken name against the whole cleaned title and each " - " segment of it.
    public static func tabScore(_ spoken: String, _ title: String) -> Int {
        let clean = NameMatcher.cleanTabTitle(title)
        var best = NameMatcher.score(spoken, clean)
        for segment in NetText.split(clean, " - ", removeEmpty: true) {
            best = max(best, NameMatcher.score(spoken, segment))
        }

        return best
    }

    private static func pick<T>(_ candidates: [T], _ ordinal: Int?) -> Resolution<T> {
        if candidates.isEmpty {
            return .noMatch
        }

        if let n = ordinal {
            let index = n == -1 ? candidates.count - 1 : n - 1
            return index >= 0 && index < candidates.count ? .single(candidates[index]) : .noMatch
        }

        return candidates.count == 1 ? .single(candidates[0]) : .ambiguous(candidates)
    }

    private static let destructiveWords = [
        "delete", "remove", "merge", "discard", "uninstall", "erase", "format", "reset", "sign out", "log out",
        "logout", "signout", "unsubscribe", "deactivate", "close account", "leave", "block", "empty trash",
        "empty recycle bin", "pay", "buy", "purchase", "place order", "send money", "transfer", "dont save",
        "do not save", "close without saving", "force push", "revoke", "terminate", "shut down", "restart", "clear",
        "move to trash", "move to bin", "move to recycle bin", "empty bin",
    ]

    /// Clicking these changes or loses data, sends money, or leaves something: ask before clicking.
    public static func isDestructive(_ name: String) -> Bool {
        let n = TranscriptText.normalize(NameMatcher.cleanElementName(name))
        return destructiveWords.contains { w in
            DotNet.ordinalEquals(n, w) || DotNet.startsWith(n, w + " ") || DotNet.endsWith(n, " " + w)
                || DotNet.contains(n, " " + w + " ")
        }
    }

    /// `Math.Max` and `Math.Min` for doubles: NaN if either is NaN (Swift's `max` and `min` don't propagate it).
    private static func netMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : max(a, b) }

    private static func netMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : min(a, b) }
}
