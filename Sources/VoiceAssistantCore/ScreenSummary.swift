import ThumbFreeCore

/// The brain's view of the screen, in the layout the prompt was measured with: the windows front first, then what can
/// be clicked or typed into in a few of them. Pages list hundreds of items, so only those that share words with the
/// request, look like content (titles, messages) or take text are kept: a short prompt is both faster and clearer.
public enum ScreenSummary {
    // About 300 prompt tokens in all: reading the prompt costs ~4 ms a token on a Snapdragon X
    // (docs/design/ai-brain.md).
    public static let maxWindows = 6
    public static let maxScannedWindows = 2
    public static let maxItemsPerWindow = 14
    public static let maxItems = 28
    public static let maxNameLength = 64

    private static let commonWords = OrdinalSet([
        "the", "and", "for", "with", "this", "that", "these", "those", "from", "into", "onto", "about", "please", "can",
        "you", "your", "my", "me", "its", "it", "on", "in", "at", "to", "of", "a", "an", "is", "are", "be", "do", "go",
        "open", "click", "press", "show", "find", "get", "put", "make", "now", "then", "hey", "jarvis", "some", "one",

        // Generic places: "this window" or "the tab" doesn't name one.
        "window", "tab", "page", "app", "screen", "button", "link", "box", "field",
    ])

    /// How the window sits on its screen: "maximized", "minimized", "left half", "right half", or empty.
    public static func placement(_ window: DesktopWindow) -> String {
        if window.show == .minimized {
            return "minimized"
        }

        if window.show == .maximized {
            return "maximized"
        }

        guard let r = window.rect, let area = window.workArea, !area.isEmpty else { return "" }
        let width = r.width / area.width
        let height = r.height / area.height
        if width >= 0.95 && height >= 0.95 {
            return "maximized"
        }

        if width >= 0.4 && width <= 0.6 && height >= 0.85 {
            return r.centerX < area.centerX ? "left half" : "right half"
        }

        return ""
    }

    /// The windows whose items are listed: the front one, then those the request seems to be about, then the next ones
    /// behind (minimized windows can't be read).
    public static func chooseWindowsToScan(
        _ windows: [DesktopWindow], _ request: String, _ appName: (WindowInfo) -> String
    ) -> [DesktopWindow] {
        let words = requestWords(request)
        let visible = windows.prefix(maxWindows).filter { $0.show != .minimized }
        var chosen = Array(visible.prefix(1))
        chosen += visible.dropFirst().filter { mentions(words, $0.window.title + " " + appName($0.window)) }
        chosen += visible.dropFirst()
        var distinct: [DesktopWindow] = []
        for window in chosen where !distinct.contains(window) {
            distinct.append(window)
        }

        return Array(distinct.prefix(maxScannedWindows))
    }

    /// The screen text, starting with "Windows (front first):". `items` are by window handle.
    public static func format(
        _ windows: [DesktopWindow], _ items: [Int: [UiElement]], _ request: String, _ appName: (WindowInfo) -> String
    ) -> String {
        var lines = ["Windows (front first):"]
        let listed = Array(windows.prefix(maxWindows))
        if listed.isEmpty {
            lines.append("(no windows open)")
        }

        for (i, w) in listed.enumerated() {
            let spot = placement(w)
            let place = i == 0 && w.show != .minimized
                ? (spot.isEmpty ? "in front" : spot + ", in front")
                : (spot.isEmpty ? "behind" : spot)
            lines.append("\(i + 1). \"\(title(w.window))\" (\(BrainSafety.cleanText(appName(w.window), 40))), \(place)")
        }

        var budget = maxItems
        for w in listed {
            guard budget > 0, let found = items[w.window.handle] else { continue }
            let picked = pickItems(found, request, min(maxItemsPerWindow, budget))
            budget -= picked.count
            if picked.isEmpty {
                lines.append("Items in \"\(title(w.window))\": (none found)")
            } else {
                let listing = picked.map { e in
                    let name = BrainSafety.cleanText(NameMatcher.cleanElementName(e.name), maxNameLength)
                    return roleWord(e.role) + " \"" + name + "\""
                }
                lines.append("Items in \"\(title(w.window))\": " + listing.joined(separator: "; "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// At most `max` items, in reading order: those naming words of the request first, then text boxes and
    /// content-like names (three or more words: titles, messages, files), then the rest.
    public static func pickItems(_ elements: [UiElement], _ request: String, _ max: Int) -> [UiElement] {
        if max <= 0 {
            return []
        }

        let words = requestWords(request)
        let wanted = roleWanted(NetText.words(TranscriptText.normalize(request)))
        let ordered = TargetResolver.deduplicate(
            elements.filter { !NameMatcher.cleanElementName($0.name).isEmpty || $0.role == .textBox })
        let scored = ordered.enumerated().map { item in
            (element: item.element, index: item.offset, score: score(item.element, words, wanted))
        }

        let best = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(max)
        return best.sorted { $0.index < $1.index }.map(\.element)
    }

    private static func score(_ element: UiElement, _ words: [String], _ roleWanted: ElementRole?) -> Int {
        let name = TranscriptText.normalize(NameMatcher.cleanElementName(element.name))
        let nameWords = NetText.words(name)
        let named = words.filter { w in
            nameWords.contains { n in
                DotNet.ordinalEquals(n, w) || (w.utf16.count >= 4 && DotNet.startsWith(n, w))
                    || (n.utf16.count >= 4 && DotNet.startsWith(w, n))
            }
        }

        var score = 10 * named.count
        if element.role == .textBox {
            score += 3
        }

        if nameWords.count >= 3 || name.utf16.count >= 24 {
            // Titles, messages and file names rather than menus.
            score += 2
        }

        if roleWanted == element.role {
            score += 5
        }

        return score
    }

    private static func roleWanted(_ words: [String]) -> ElementRole? {
        if NetText.contains(words, "tab") {
            return .tab
        }

        if NetText.contains(words, "button") {
            return .button
        }

        if NetText.contains(words, "link") {
            return .link
        }

        return NetText.contains(words, "box") || NetText.contains(words, "field") ? .textBox : nil
    }

    private static func requestWords(_ request: String) -> [String] {
        NetText.distinct(NetText.words(TranscriptText.normalize(request)).filter {
            $0.utf16.count >= 3 && !commonWords.contains($0)
        })
    }

    private static func mentions(_ words: [String], _ text: String) -> Bool {
        let known = NetText.words(TranscriptText.normalize(text))
        return words.contains { w in
            known.contains { k in DotNet.ordinalEquals(k, w) || (w.utf16.count >= 4 && DotNet.startsWith(k, w)) }
        }
    }

    private static func title(_ window: WindowInfo) -> String {
        BrainSafety.cleanText(DotNet.replace(window.title, "\u{200B}", " "), 100)
    }

    private static func roleWord(_ role: ElementRole) -> String {
        switch role {
        case .button: return "button"
        case .link: return "link"
        case .tab: return "tab"
        case .menuItem: return "menuitem"
        case .treeItem: return "treeitem"
        case .listItem: return "listitem"
        case .checkBox: return "checkbox"
        case .radioButton: return "radio"
        case .comboBox: return "combobox"
        case .textBox: return "edit"
        case .other: return "item"
        }
    }
}
