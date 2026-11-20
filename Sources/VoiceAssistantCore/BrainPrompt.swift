import ThumbFreeCore

/// What the brain is told: the tools, the rules and four worked examples, then the screen and the request. This is the
/// prompt measured in windows-voice-assistant docs/design/ai-brain.md (its tools/BrainSpike runs it): change it only
/// with a new measurement. It is the C#'s text exactly, Windows' own words included ("You control a Windows PC",
/// "win+up"), and so are its line breaks: C#'s raw strings keep the line ends of the file they are compiled from, and
/// the Windows release and the measurements were built from checkouts with CRLF line ends (core.autocrlf, as on
/// GitHub's Windows runners), so the system prompt and the examples' screens break lines with CRLF.
public enum BrainPrompt {
    /// The line break inside the system prompt and the examples' screens (see above).
    static let lineBreak = "\r\n"

    public static let system = [
        #"You control a Windows PC. Turn the request into the FEWEST steps, using only these tools:"#,
        #"focus_window(target: a window title from the screen) · open_app(target: app name, only if no such "#
            + #"window is open) · open_url(target: a site's address like "instagram.com"; opens it in a new tab) ·"#,
        #"web_search(target: "youtube" or "google", text: query) · click(target: exact item name from the "#
            + #"screen, without the role word) ·"#,
        #"type_text(text) · press(target: keys like "ctrl+w", "win+up", "m") · scroll(target: "up" or "#
            + #""down") · ask(text: question)"#,
        #"Rules: act on the window the request is about (focus it first if it isn't in front). If the item "#
            + #"isn't on screen, web_search then click it."#,
        #"To open a website or go to an address, use open_url (it opens a new tab by itself): never type an "#
            + #"address, press ctrl+t or click New Tab."#,
        #"Only press enter or click Send when the user asked to send. To delete, clear or remove, click the "#
            + #"item that does it (the PC asks the user first)."#,
        #"Never click anything unrelated to the request. Questions and chat need no steps: just answer in "#
            + #""say"."#,
        #"If the request is unclear, use one ask step. "text" is "" when not used. "say" is one short "#
            + #"sentence."#,
    ].joined(separator: lineBreak)

    public static let examples: [(screen: String, request: String, plan: String)] = [
        (
            [
                #"Windows (front first):"#,
                #"1. "Inbox - Outlook" (Outlook), maximized, in front"#,
                #"2. "Spotify Premium" (Spotify), behind"#,
                #"Items in "Spotify Premium": button "Play"; button "Next"; link "Daily Mix 1"; link "Liked "#
                    + #"Songs""#,
            ].joined(separator: lineBreak),
            #"play daily mix 1 on spotify"#,
            #"{"steps":[{"tool":"focus_window","target":"Spotify Premium","text":""},{"tool":"click","target":"#
                + #""Daily Mix 1","text":""}],"say":"Playing Daily Mix 1."}"#
        ),
        (
            [
                #"Windows (front first):"#,
                #"1. "Inbox (3) - Gmail - Google Chrome" (Chrome), maximized, in front"#,
                #"Items in "Inbox (3) - Gmail - Google Chrome": tab "Inbox (3) - Gmail"; button "New Tab"; "#
                    + #"edit "Address and search bar"; button "Compose""#,
            ].joined(separator: lineBreak),
            #"open github in a new tab"#,
            #"{"steps":[{"tool":"open_url","target":"github.com","text":""}],"say":"Opening GitHub in a new tab."}"#
        ),
        (
            [
                #"Windows (front first):"#,
                #"1. "Untitled - Notepad" (Notepad), left half, in front"#,
            ].joined(separator: lineBreak),
            #"find a pasta recipe on youtube"#,
            #"{"steps":[{"tool":"web_search","target":"youtube","text":"pasta recipe"}],"say":"Searching YouTube "#
                + #"for pasta recipes."}"#
        ),
        (
            [
                #"Windows (front first):"#,
                #"1. "Untitled - Notepad" (Notepad), left half, in front"#,
            ].joined(separator: lineBreak),
            #"how are you doing"#,
            #"{"steps":[],"say":"All good, ready when you are."}"#
        ),
    ]

    /// The plan's exact shape as a llama.cpp grammar: no whitespace and a fixed key order (measured faster than a JSON
    /// schema, which lets some models indent), at most 6 steps and 100 characters per field. As it is sent: with LF
    /// line breaks (the Windows app takes the CRs out of the C#'s).
    public static let grammar = [
        #"root ::= "{\"steps\":[" (step ("," step){0,5})? "],\"say\":" str "}""#,
        #"step ::= "{\"tool\":\"" tool "\",\"target\":" str ",\"text\":" str "}""#,
        #"tool ::= "focus_window" | "open_app" | "open_url" | "web_search" | "click" | "type_text" | "press" "#
            + #"| "scroll" | "ask""#,
        #"str ::= "\"" char{0,100} "\"""#,
        #"char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})"#,
    ].joined(separator: "\n")

    /// One request: `screen` starts with "Windows (front first):".
    public static func userMessage(_ screen: String, _ request: String) -> String {
        "Screen:\n\(DotNet.trimEnd(screen))\nRequest: \"\(BrainSafety.cleanText(request, 300))\""
    }

    /// The system prompt, the examples as earlier turns (their prefix stays in the model's cache), then the request.
    public static func messages(_ screen: String, _ request: String) -> [ChatTurn] {
        var messages = [ChatTurn(role: "system", content: system)]
        for example in examples {
            messages.append(ChatTurn(role: "user", content: userMessage(example.screen, example.request)))
            messages.append(ChatTurn(role: "assistant", content: example.plan))
        }

        messages.append(ChatTurn(role: "user", content: userMessage(screen, request)))
        return messages
    }
}
