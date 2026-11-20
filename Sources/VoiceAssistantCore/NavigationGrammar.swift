import ThumbFreeCore

/// The navigation grammar (windows-voice-assistant docs/specs/navigation.md): tabs, clicking by name, "start typing
/// in X", numbers, and yes or no.
extension CommandParser {
    static let ordinalWords = OrdinalMap<Int>([
        ("first", 1), ("1st", 1), ("second", 2), ("2nd", 2), ("third", 3), ("3rd", 3), ("fourth", 4), ("4th", 4),
        ("fifth", 5), ("5th", 5), ("sixth", 6), ("6th", 6), ("seventh", 7), ("7th", 7), ("eighth", 8), ("8th", 8),
        ("ninth", 9), ("9th", 9), ("tenth", 10), ("10th", 10), ("last", -1),
    ])

    static let numberWords = OrdinalMap<Int>([
        ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6), ("seven", 7), ("eight", 8),
        ("nine", 9), ("ten", 10), ("eleven", 11), ("twelve", 12), ("thirteen", 13), ("fourteen", 14), ("fifteen", 15),
        ("sixteen", 16), ("seventeen", 17), ("eighteen", 18), ("nineteen", 19), ("twenty", 20),
    ])

    private static let showNumbersPhrases = OrdinalSet([
        "show numbers", "show the numbers", "show labels", "show the labels", "number everything", "label everything",
        "show me the numbers", "numbers",
    ])

    private static let hideNumbersPhrases = OrdinalSet([
        "hide numbers", "hide the numbers", "hide labels", "hide the labels", "clear numbers", "remove numbers",
        "no numbers",
    ])

    private static let confirmPhrases =
        OrdinalSet(["yes", "yes do it", "yes please", "confirm", "do it", "go ahead", "yeah", "yep", "sure"])

    private static let cancelPhrases = OrdinalSet(
        ["no", "nope", "cancel", "never mind", "nevermind", "dont", "dont do it", "cancel that", "forget it"])

    private static let tabVerbs = [
        "go to", "go back to", "switch to", "switch over to", "open", "select", "show me", "show", "jump to",
        "take me to", "move to", "bring up", "focus",
    ]

    private static let clickVerbs = [
        "click on", "click", "tap on", "tap", "press on", "press", "hit", "select", "choose", "pick", "expand",
        "collapse", "toggle",
    ]

    private static let typingVerbs = [
        "start typing", "begin typing", "continue typing", "start writing", "start dictating", "let me type", "type",
        "write", "dictate",
    ]

    private static let regionSuffixes: [(phrase: String, region: ScreenRegion)] = [
        ("on the left side", .left), ("on the left hand side", .left), ("in the left pane", .left),
        ("in the left panel", .left), ("in the sidebar", .left), ("in the side bar", .left), ("on the sidebar", .left),
        ("on the left", .left), ("at the left", .left), ("to the left", .left), ("on the right side", .right),
        ("on the right hand side", .right), ("in the right pane", .right), ("in the right panel", .right),
        ("on the right", .right), ("at the right", .right), ("at the top", .top), ("on the top", .top),
        ("on top", .top), ("at the bottom", .bottom), ("on the bottom", .bottom),
    ]

    private static let elementNoise = ["button", "link", "option", "menu item", "menu", "item", "icon", "entry"]

    private static let fieldSuffixes = ["text box", "box", "field", "bar", "area", "input"]

    /// Parses a spoken description of something on screen: "the second Issues on the left" is name "issues", ordinal
    /// 2, region left. Used by the grammar and by the "go to X" fallback.
    public static func parseTarget(_ phrase: String) -> ElementTarget {
        var text = DotNet.trim(phrase)
        var region: ScreenRegion?
        for (suffix, r) in regionSuffixes
        where DotNet.endsWith(text, " " + suffix) || DotNet.ordinalEquals(text, suffix) {
            text = DotNet.trim(NetText.dropSuffix(text, suffix))
            region = r
            break
        }

        text = stripArticles(text)
        var ordinal: Int?
        if let space = text.unicodeScalars.firstIndex(of: " "), space != text.startIndex,
           let o = ordinalWords[String(text[..<space])] {
            ordinal = o
            text = DotNet.trim(String(text[text.unicodeScalars.index(after: space)...]))
        } else if let only = ordinalWords[text] {
            ordinal = only
            text = ""
        }

        for noise in elementNoise {
            if DotNet.ordinalEquals(text, noise) || DotNet.ordinalEquals(text, "one") {
                text = ""
                break
            }

            if DotNet.endsWith(text, " " + noise) {
                text = DotNet.trim(NetText.dropSuffix(text, " " + noise))
                break
            }
        }

        return ElementTarget(name: simplify(stripArticles(text)), region: region, ordinal: ordinal)
    }

    private static func stripArticles(_ text: String) -> String {
        for article in ["on the ", "the ", "a ", "an ", "my "] where DotNet.startsWith(text, article) {
            return DotNet.trim(DotNet.dropPrefix(text, article))
        }

        return text
    }

    static func matchNavigation(_ n: String) -> [VoiceCommand]? {
        if showNumbersPhrases.contains(n) {
            return [VoiceCommand(.showNumbers)]
        }

        if hideNumbersPhrases.contains(n) {
            return [VoiceCommand(.hideNumbers)]
        }

        if confirmPhrases.contains(n) {
            return [VoiceCommand(.confirm)]
        }

        if cancelPhrases.contains(n) {
            return [VoiceCommand(.cancel)]
        }

        if let choice = matchChoice(n) {
            return [VoiceCommand(.choose, String(choice))]
        }

        for suffix in chainedStartTyping where DotNet.endsWith(n, suffix) {
            if let first = matchTabOrClick(DotNet.trim(NetText.dropSuffix(n, suffix))) {
                return [first, VoiceCommand(.startTyping)]
            }
        }

        return matchStartTypingIn(n) ?? matchTabOrClick(n).map { [$0] }
    }

    private static func matchTabOrClick(_ n: String) -> VoiceCommand? { matchTab(n) ?? matchClick(n) }

    // A new tab or window as the place to open something: "in a new tab", "on another tab", "in a new browser
    // window". Never "the other tab" or "the second tab": those are tabs already open. ("tap" is how speech
    // recognition often hears "tab" here.)
    private static let newPlaceWords =
        #"(?:(?:a |the )?(?:new|separate|fresh)|(?:a )?different|another|an other|a second)"#
    private static let newPlace = newPlaceWords + #" (?:browser )?(?<place>tabs?|tap|windows?)"#
    private static let openPlaceVerbs =
        "open up|open|launch|load|pull up|bring up|go to|take me to|show me|show|get me|start|visit|navigate to"

    // Not something to open: things on screen ("it", "this link"), kinds of tab ("a blank page in a new tab",
    // "incognito in a new window") and typing ("open a new tab and start dictating").
    private static let notAPageName = OrdinalSet([
        "it", "this", "that", "them", "this one", "that one", "link", "this link", "that link", "page", "this page",
        "that page", "incognito", "private", "inprivate", "in private", "blank", "empty", "browser",
        "typing", "type", "writing", "write", "dictating", "dictation", "dictate",
    ])

    private static let pageNameTails =
        [" website", " web site", " webpage", " web page", " homepage", " home page", " site", " page"]

    /// "open Instagram in a new tab", "open instagram.com in another tab", "open a new tab and go to GitHub", "open
    /// Notepad in a new window": opening something there, never selecting a tab called "instagram in new". ("Open a new
    /// Instagram tab" stays a tab name, as "the What's New tab" is one; when no tab has it, the AI brain gets the
    /// request.)
    static func matchOpenInNewPlace(_ n: String) -> VoiceCommand? {
        // "start typing in a new tab", "open a new tab and start typing": typing commands, not a page called "typing".
        if typingVerbs.contains(where: { DotNet.startsWith(n, $0 + " ") })
            || chainedStartTyping.contains(where: { DotNet.endsWith(n, $0) }) {
            return nil
        }

        guard let m = inNewPlaceRegex.match(n) ?? newPlaceThenRegex.match(n) else { return nil }
        var name = stripArticles(DotNet.trim(m.group(named: "name")))
        for tail in pageNameTails where DotNet.endsWith(name, tail) && name.utf16.count > tail.utf16.count {
            name = DotNet.trim(NetText.dropSuffix(name, tail))
            break
        }

        // "open it in a new tab" is about something on screen: the AI brain (or the click grammar) works that out.
        // "go to the WhatsApp tab in a different window" names a tab that's open already.
        if name.isEmpty || notAPageName.contains(name) || endsWithWord(name, ["tab", "tabs", "window", "windows"]) {
            return nil
        }

        let kind: CommandKind = DotNet.startsWith(m.group(named: "place"), "window") ? .openInNewWindow : .openInNewTab
        return VoiceCommand(kind, name)
    }

    private static func endsWithWord(_ text: String, _ words: [String]) -> Bool {
        words.contains { DotNet.ordinalEquals(text, $0) || DotNet.endsWith(text, " " + $0) }
    }

    private static let numberedThings = OrdinalSet(["number", "link", "result", "item", "video", "option", "choice"])
    private static let placedThings =
        OrdinalSet(["top", "bottom", "other", "latest", "newest", "oldest", "same", "main", "current", "middle"])
    private static let placedKinds = OrdinalSet(["one", "ones", "result", "results", "video", "videos"])
    private static let pointingWords = OrdinalSet(["this", "that", "these", "those", "next", "previous"])
    private static let screenThings = OrdinalSet([
        "video", "videos", "image", "images", "picture", "pictures", "photo", "photos", "email", "emails", "message",
        "messages", "post", "posts", "article", "articles", "result", "results",
    ])

    /// "first link", "this video", "downloads folder", "number 3", "link 3", "the top result": something on screen
    /// rather than a website or app, so "open … in a new tab" never searches the web for it. Real names are spared:
    /// "Prime Video", "election results", "Formula 1", "Capital One".
    static func namesSomethingOnScreen(_ name: String) -> Bool {
        let words = NetText.words(name)
        guard let last = words.last else { return false }
        let numbered = NetText.parseDigits(last) != nil || numberWords.contains(last)
        return (numbered && (words.count == 1 || (words.count == 2 && numberedThings.contains(words[0]))))
            || (words.count == 2 && placedThings.contains(words[0]) && placedKinds.contains(words[1]))
            || ordinalWords.contains(words[0]) || pointingWords.contains(words[0])
            || endsWithWord(name, ["link", "links", "folder", "folders", "file", "files", "item", "items", "button",
                                   "buttons"])
            || screenThings.contains(name)
    }

    private static let inNewPlaceRegex =
        NetRegex("^(?:" + openPlaceVerbs + ") (?<name>.+?) (?:in|on|into|inside) " + newPlace + "$")

    private static let newPlaceThenRegex = NetRegex(
        "^(?:open up|open|launch|start) " + newPlace + "(?: and then| and| then)? (?:" + openPlaceVerbs
            + "|with|for|to) (?<name>.+)$")

    // The end of "open Instagram in a new" before "tab": a new tab, not a tab's name.
    private static let newPlaceTailRegex =
        NetRegex("(?:^| )(?:in|on|into|inside) " + newPlaceWords + "(?: browser)?$")

    /// The command's words as said: the replacement in "replace X with Y", and web addresses ("instagram.com").
    static func asSaid(_ commands: [VoiceCommand], _ cleaned: String) -> [VoiceCommand] {
        withWebAddresses(withSpokenReplacement(commands, cleaned), cleaned)
    }

    /// "open instagram.com in a new tab": normalizing turned the address into "instagram com", so it is taken back
    /// from the words as said (or "instagram dot com" is joined up).
    private static func withWebAddresses(_ commands: [VoiceCommand], _ cleaned: String) -> [VoiceCommand] {
        func opensSomething(_ c: VoiceCommand) -> Bool {
            c.kind == .openApp || c.kind == .switchToApp || c.kind == .openInNewTab || c.kind == .openInNewWindow
        }

        if !commands.contains(where: opensSomething) {
            return commands
        }

        let said = saidAddressRegex.matches(cleaned).map {
            DotNet.lowerInvariant(DotNet.trimEnd($0.value, [".", ",", "!", "?", ";", ":"]))
        }

        return commands.map { c in
            guard opensSomething(c), let name = c.argument, let address = addressAsSaid(name, said) else { return c }
            var updated = c
            updated.argument = address
            return updated
        }
    }

    private static func addressAsSaid(_ name: String, _ said: [String]) -> String? {
        if let address = said.first(where: { DotNet.ordinalEquals(TranscriptText.normalize($0), name) }) {
            return address
        }

        return spokenDotsRegex.isMatch(name) ? DotNet.replace(name, " dot ", ".") : nil
    }

    private static let saidAddressRegex = NetRegex(
        #"(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?:/\S*)?"#, .ignoreCase)

    private static let spokenDotsRegex = NetRegex(#"^[a-z0-9-]+(?: dot [a-z0-9-]+)+$"#)

    /// "click 3", "number three", "choose two", "3", "the second one".
    private static func matchChoice(_ n: String) -> Int? {
        var text = n
        for prefix in [
            "click on number ", "click number ", "click on ", "click ", "choose number ", "choose ", "pick number ",
            "pick ", "select number ", "select ", "number ", "option ", "go with ", "the ",
        ] where DotNet.startsWith(text, prefix) {
            text = DotNet.trim(DotNet.dropPrefix(text, prefix))
            break
        }

        if DotNet.startsWith(text, "the ") {
            text = DotNet.dropPrefix(text, "the ")
        }

        if let digits = NetText.parseDigits(text) {
            return digits > 0 && digits < 100 ? digits : nil
        }

        if let word = numberWords[text] {
            return word
        }

        // "the second one" picks the second numbered choice.
        if DotNet.endsWith(text, " one"), let ordinal = ordinalWords[NetText.dropSuffix(text, " one")], ordinal > 0 {
            return ordinal
        }

        return nil
    }

    /// "go to the first tab", "tab 3", "last tab", "the YouTube tab", "the tab where YouTube is open".
    private static func matchTab(_ n: String) -> VoiceCommand? {
        func tab(_ name: String, _ ordinal: Int?) -> VoiceCommand {
            VoiceCommand(.selectTab, target: ElementTarget(name: name, ordinal: ordinal))
        }

        var text = n
        for verb in tabVerbs where DotNet.startsWith(text, verb + " ") {
            text = DotNet.trim(DotNet.dropPrefix(text, verb + " "))
            break
        }

        text = stripArticles(text)
        for lead in [
            "tab with ", "tab where ", "tab that has ", "tab that shows ", "tab showing ", "tab containing ",
            "tab for ", "tab of ",
        ] where DotNet.startsWith(text, lead) {
            var name = DotNet.trim(DotNet.dropPrefix(text, lead))
            for tail in [" is open", " is opened", " is playing", " open", " opened", " on it", " is"]
            where DotNet.endsWith(name, tail) {
                name = DotNet.trim(NetText.dropSuffix(name, tail))
                break
            }

            name = simplify(stripArticles(name))
            return name.isEmpty ? nil : tab(name, nil)
        }

        if DotNet.startsWith(text, "tab ") {
            var rest = DotNet.trim(DotNet.dropPrefix(text, "tab "))
            if DotNet.startsWith(rest, "number ") {
                rest = DotNet.trim(DotNet.dropPrefix(rest, "number "))
            }

            if let number = NetText.parseDigits(rest), number > 0 {
                return tab("", number)
            }

            return numberWords[rest].map { tab("", $0) }
        }

        if !DotNet.endsWith(text, " tab") {
            return nil
        }

        let before = stripArticles(DotNet.trim(NetText.dropSuffix(text, " tab")))
        if let ordinal = ordinalWords[before] {
            return tab("", ordinal)
        }

        if newPlaceTailRegex.isMatch(before) {
            // "switch to Instagram in a new tab": a new tab, not one called "instagram in new".
            return nil
        }

        // "new tab", "next tab", "close tab" are shortcuts handled earlier; anything else names the tab.
        if before.isEmpty || NetText.contains(["new", "next", "previous", "this", "that", "other"], before) {
            return nil
        }

        return tab(simplify(before), nil)
    }

    /// "click New on the left", "select Library", "press the Issues button", "expand Sessions".
    private static func matchClick(_ n: String) -> VoiceCommand? {
        for verb in clickVerbs where DotNet.startsWith(n, verb + " ") {
            let target = parseTarget(DotNet.dropPrefix(n, verb + " "))
            return target.name.isEmpty && target.ordinal == nil ? nil : VoiceCommand(.click, verb, target: target)
        }

        return nil
    }

    /// "start typing in YouTube", "type in the message box", "start typing in the first tab".
    private static func matchStartTypingIn(_ n: String) -> [VoiceCommand]? {
        for verb in typingVerbs {
            for preposition in [" in ", " into ", " on "] where DotNet.startsWith(n, verb + preposition) {
                let rest = DotNet.trim(DotNet.dropPrefix(n, verb + preposition))
                let bare = stripArticles(rest)
                if NetText.contains(["it", "here", "this", "there", "this window", "this app"], bare) {
                    return [VoiceCommand(.startTyping)]
                }

                if NetText.contains(searchTargets, bare) {
                    return [VoiceCommand(.focusSearch)]
                }

                if NetText.contains(addressTargets, bare) {
                    return [VoiceCommand(.focusAddressBar)]
                }

                for suffix in fieldSuffixes
                where DotNet.ordinalEquals(bare, suffix) || DotNet.endsWith(bare, " " + suffix) {
                    let field =
                        DotNet.ordinalEquals(bare, suffix) ? "" : DotNet.trim(NetText.dropSuffix(bare, " " + suffix))
                    return field.isEmpty || DotNet.ordinalEquals(field, "text")
                        ? [VoiceCommand(.startTyping)]
                        : [VoiceCommand(.focusField, target: ElementTarget(name: field))]
                }

                if let tab = matchTab(rest) {
                    return [tab, VoiceCommand(.startTyping)]
                }

                let app = cleanAppName(rest)
                return app.isEmpty ? nil : [VoiceCommand(.switchToApp, app), VoiceCommand(.startTyping)]
            }
        }

        return nil
    }
}
