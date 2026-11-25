import Darwin
import Foundation
import ThumbFreeCore
import VoiceAssistantCore

/// windows-voice-assistant's brain bench (tools/BrainSpike, Bench.cs): 25 requests, each with the screen summary it's
/// asked on and a check of the plan, run through the app's own prompt (`BrainPrompt`) and plan reader (`BrainPlan`,
/// tidied as the app runs it). A plan passes when its steps do what a person would expect; small differences in
/// wording don't matter. "Clean" also means no more than 3 steps. The first 21 cases are the ones
/// docs/design/ai-brain.md scores "18/21"; 22–25, opening Instagram with Chrome in front, came with v0.12.1, which
/// scored 22/25.
///
/// The screens are Bench.cs's text exactly, line breaks included: the Windows measurements were built from a checkout
/// with CRLF line ends, which C#'s raw strings keep (as `BrainPrompt` explains), so the screens break lines with CRLF.
enum BrainBench {
    struct Step: Hashable {
        var tool: String
        var target: String
        var text: String
    }

    struct Case {
        var request: String
        var screen: String
        var check: ([Step], String) -> Bool
        var maxSteps = 3
    }

    /// One case's result.
    struct Outcome {
        var request: String
        var passed: Bool
        var clean: Bool
        var milliseconds: Double

        /// The plan as Bench.cs prints it ("focus_window(…) → click(…)  say: …"), or what was wrong with the reply.
        var plan: String
    }

    /// Windows' verdicts in the v0.12.1 run (22/25): the three misses.
    static let windowsMisses: Set<String> = ["open notepad and write buy milk", "close this tab", "do the thing"]

    /// Windows' times in that run, case by case, in milliseconds as it printed them (median 1908; the slowest, 7.0 s,
    /// is the first request, with an empty prompt cache).
    static let windowsMilliseconds: [Double] = [
        7011, 2982, 3496, 4817, 2687, 1748, 3139, 1529, 1778, 1900, 3330, 2322, 1587, 1878, 1605, 2438, 1399, 1526,
        2359, 1506, 1553, 2423, 1749, 1908, 2376,
    ]

    private static let lineBreak = "\r\n"

    private static func lines(_ lines: String...) -> String { lines.joined(separator: lineBreak) }

    /// One long line, written in pieces.
    private static func line(_ pieces: String...) -> String { pieces.joined() }

    /// Ends with a line break, so item lists added after it start on their own line.
    private static let desk = lines(
        #"Windows (front first):"#,
        #"1. "Windows PowerShell" (PowerShell), right half, in front"#,
        #"2. "Home - YouTube - Google Chrome" (Chrome), left half"#,
        #"3. "WhatsApp" (WhatsApp), minimized"#) + lineBreak

    private static let chromeTabs = lines(
        #"Windows (front first):"#,
        #"1. "Pull requests · shivam098/thumbfree - Google Chrome" (Google Chrome), maximized, in front"#,
        #"2. "WhatsApp" (WhatsApp), minimized"#,
        #"3. "Inbox - Outlook" (Outlook), minimized"#,
        line(
            #"Items in "Pull requests · shivam098/thumbfree - Google Chrome": tab "WhatsApp"; "#,
            #"tab "Pull requests · shivam098/thumbfree"; tab "Inbox (3) - Gmail"; tab "Home - YouTube"; "#,
            #"tab "Settings"; button "New Tab"; edit "Address and search bar"; button "Bookmark this tab"; "#,
            #"link "Android: History #5 opened 2 days ago"; link "Android: live typing #4 opened 3 days ago"; "#,
            #"button "New pull request"; edit "Search or jump to…""#))

    static let cases: [Case] = [
        Case(
            request: "open the MrBeast video on YouTube",
            screen: desk + lines(
                #"Items in "Home - YouTube - Google Chrome":"#,
                #"link "Home"; link "Shorts"; link "Subscriptions"; button "Search"; edit "Search";"#,
                #"link "I Survived 50 Hours In Antarctica - MrBeast - 98M views";"#,
                #"link "Why Is This Bridge Twisted? - Veritasium - 4.1M views";"#,
                #"link "Lofi hip hop radio - beats to relax/study to - Lofi Girl";"#,
                #"link "How I Made My First App - Fireship - 1.2M views""#,
                #"Items in "Windows PowerShell": edit "Command line""#),
            check: { s, _ in
                let focus = index(s, "focus_window", "YouTube")
                return has(s, "click", "MrBeast") && focus >= 0 && focus < index(s, "click", "MrBeast")
            }),
        Case(
            request: "play the second video",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "lofi - YouTube - Google Chrome" (Chrome), maximized, in front"#,
                #"Items in "lofi - YouTube - Google Chrome":"#,
                #"edit "Search"; button "Search";"#,
                #"link "lofi hip hop radio 📚 - beats to relax/study to - Lofi Girl";"#,
                #"link "Chill Lofi Mix [chill lo-fi hip hop beats] - Chillhop Music";"#,
                #"link "1 A.M Study Session 📚 - [lofi hip hop/chill beats] - Lofi Girl""#),
            check: { s, _ in has(s, "click", "Chill Lofi Mix") }),
        Case(
            request: "search YouTube for lofi music",
            screen: desk + lines(
                #"Items in "Home - YouTube - Google Chrome": edit "Search"; button "Search"; link "Home""#),
            check: { s, _ in
                has(s, "web_search", "lofi") || (has(s, "type_text", "lofi") && has(s, "click", "Search"))
            }),
        Case(
            request: "reply thanks to Rahul on WhatsApp",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Inbox - Outlook" (Outlook), maximized, in front"#,
                #"2. "WhatsApp" (WhatsApp), behind"#,
                #"Items in "WhatsApp":"#,
                #"edit "Search or start a new chat"; listitem "Rahul Sharma, Are we still on for tomorrow?, 10:42";"#,
                line(
                    #"listitem "Mom, Call me, 09:15"; listitem "Project Team, Priya: deck is ready, Yesterday"; "#,
                    #"edit "Type a message""#)),
            check: { s, _ in
                has(s, "focus_window", "WhatsApp") && has(s, "click", "Rahul") && has(s, "type_text", "thank")
            }),
        Case(
            request: "open notepad and write buy milk", screen: desk,
            check: { s, _ in has(s, "open_app", "notepad") && has(s, "type_text", "buy milk") }),
        Case(
            request: "close this tab",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Pull requests · shivam098/thumbfree - Google Chrome" (Chrome), maximized, in front"#,
                line(
                    #"Items in "Pull requests · shivam098/thumbfree - Google Chrome": "#,
                    #"tab "Pull requests · shivam098/thumbfree"; tab "Gmail"; button "Close""#)),
            check: { s, _ in has(s, "press", "ctrl+w") || has(s, "press", "ctrl + w") }),
        Case(
            request: "go to the GitHub tab",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Gmail - Inbox - Google Chrome" (Chrome), maximized, in front"#,
                line(
                    #"Items in "Gmail - Inbox - Google Chrome": tab "Gmail - Inbox"; "#,
                    #"tab "Pull requests · shivam098/thumbfree"; tab "YouTube"; button "Compose""#)),
            check: { s, _ in has(s, "click", "Pull requests") }),
        Case(request: "scroll down", screen: desk, check: { s, _ in has(s, "scroll", "down") }),
        Case(
            request: "what's the weather in Bangalore", screen: desk,
            check: { s, _ in has(s, "web_search", "weather") || has(s, "open_url", "weather") }),
        Case(
            request: "mute the video",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "I Survived 50 Hours In Antarctica - YouTube - Google Chrome" (Chrome), maximized, in front"#,
                #"Items in "I Survived 50 Hours In Antarctica - YouTube - Google Chrome":"#,
                line(
                    #"button "Pause (k)"; button "Mute (m)"; button "Next (SHIFT+n)"; button "Full screen (f)"; "#,
                    #"button "Subscribe"; button "Like""#)),
            check: { s, _ in has(s, "click", "Mute") || (has(s, "press", "m") && s.count == 1) }),

        // Lab 3 (18 Nov 2026): the real screen after "go back", in the app's layout. The first prompt read "clear"
        // as not asked to delete and clicked the browser's bookmark star instead.
        Case(
            request: "clear my watch history",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Home - YouTube - Google Chrome" (Google Chrome), maximized, in front"#,
                #"2. "Windows PowerShell" (Terminal), behind"#,
                line(
                    #"Items in "Home - YouTube - Google Chrome": button "Search tabs"; tab "WhatsApp"; "#,
                    #"tab "Pull requests · shivam098/thumbfree"; button "Close"; tab "Home - YouTube"; "#,
                    #"button "Ask Gemini"; edit "Address and search bar"; button "Bookmark this tab"; "#,
                    #"button "You"; edit "Search"; link "I Survived 50 Hours In Antarctica - MrBeast - 98M views"; "#,
                    #"link "Why Is This Bridge Twisted? - Veritasium - 4.1M views"; "#,
                    #"link "Lofi hip hop radio - beats to relax/study to - Lofi Girl"; button "Delete history""#),
                line(
                    #"Items in "Windows PowerShell": tab "Windows PowerShell"; button "New Tab"; button "Close"; "#,
                    #"edit "Windows PowerShell""#)),
            check: { s, _ in has(s, "click", "Delete history") && s.filter { $0.tool == "click" }.count == 1 }),
        Case(
            request: "open the latest pull request",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Pull requests · shivam098/thumbfree - Google Chrome" (Chrome), maximized, in front"#,
                #"Items in "Pull requests · shivam098/thumbfree - Google Chrome":"#,
                line(
                    #"link "Android: History #5 opened 2 days ago"; "#,
                    #"link "Android: live typing #4 opened 3 days ago"; "#,
                    #"link "Tap to start, tap to finish #3 opened 4 days ago"; button "New pull request""#)),
            check: { s, _ in has(s, "click", "History") }),
        Case(
            request: "switch to PowerShell",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Home - YouTube - Google Chrome" (Chrome), maximized, in front"#,
                #"2. "Windows PowerShell" (PowerShell), behind"#),
            check: { s, _ in has(s, "focus_window", "PowerShell") && !has(s, "open_app") }),
        Case(
            request: "play next",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "I Survived 50 Hours In Antarctica - YouTube - Google Chrome" (Chrome), maximized, in front"#,
                line(
                    #"Items in "I Survived 50 Hours In Antarctica - YouTube - Google Chrome": button "Pause (k)"; "#,
                    #"button "Mute (m)"; button "Next (SHIFT+n)""#)),
            check: { s, _ in has(s, "click", "Next") || has(s, "press", "shift+n") }),
        Case(
            request: "delete this email",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Weekly newsletter - Outlook" (Outlook), maximized, in front"#,
                line(
                    #"Items in "Weekly newsletter - Outlook": button "Reply"; button "Forward"; button "Delete"; "#,
                    #"button "Archive""#)),
            check: { s, _ in has(s, "click", "Delete") }),
        Case(
            request: "open report.docx from downloads",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Downloads - File Explorer" (Explorer), maximized, in front"#,
                line(
                    #"Items in "Downloads - File Explorer": listitem "report.docx"; listitem "invoice-oct.pdf"; "#,
                    #"listitem "photo.jpg"; button "New""#)),
            check: { s, _ in has(s, "click", "report.docx") }),
        Case(request: "tell me a joke", screen: desk, check: { s, say in s.isEmpty && say.utf16.count > 10 }),
        Case(request: "maximize this window", screen: desk, check: { s, _ in has(s, "press", "win+up") }),
        Case(
            request: "open the Veritasium video about black holes",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "Home - YouTube - Google Chrome" (Chrome), maximized, in front"#,
                line(
                    #"Items in "Home - YouTube - Google Chrome": edit "Search"; button "Search"; "#,
                    #"link "I Survived 50 Hours In Antarctica - MrBeast"; link "Lofi hip hop radio - Lofi Girl""#)),
            check: { s, _ in
                has(s, "web_search", "Veritasium")
                    || (has(s, "type_text", "Veritasium")
                        && index(s, "type_text", "Veritasium") < max(index(s, "click", "Veritasium"), 99))
            }),
        Case(
            request: "send it",
            screen: lines(
                #"Windows (front first):"#,
                #"1. "WhatsApp" (WhatsApp), maximized, in front"#,
                line(
                    #"Items in "WhatsApp": listitem "Rahul Sharma, Are we still on for tomorrow?"; "#,
                    #"edit "Type a message"; button "Send""#)),
            check: { s, _ in has(s, "click", "Send") || has(s, "press", "enter") }),
        Case(request: "do the thing", screen: desk, check: { s, _ in has(s, "ask") && s.count == 1 }),

        // 19 Nov 2026: "open Instagram in a new tab" with Chrome in front. The first prompt typed the address into
        // the address bar (refused by the app), clicked Chrome's New Tab button, or looked for an Instagram app.
        Case(request: "open Instagram in a new tab", screen: chromeTabs, check: { s, _ in opensSite(s, "instagram") }),
        Case(
            request: "open Instagram", screen: chromeTabs,
            check: { s, _ in
                opensSite(s, "instagram")
                    || (has(s, "web_search", "instagram") && !has(s, "type_text") && !has(s, "click"))
            }),
        Case(request: "go to instagram.com", screen: chromeTabs, check: { s, _ in opensSite(s, "instagram.com") }),
        Case(
            request: "open a new tab and open Instagram", screen: chromeTabs,
            check: { s, _ in opensSite(s, "instagram") }),
    ]

    /// The site opens through open_url, with nothing typed, clicked, launched or pressed on the way.
    private static func opensSite(_ s: [Step], _ site: String) -> Bool {
        has(s, "open_url", site) && !has(s, "type_text") && !has(s, "click") && !has(s, "open_app")
            && !has(s, "press")
    }

    /// A step with this tool whose target and text, joined by a space, contain `contains` (C#'s
    /// `StringComparison.OrdinalIgnoreCase`).
    static func has(_ steps: [Step], _ tool: String, _ contains: String = "") -> Bool {
        index(steps, tool, contains) >= 0
    }

    /// The first such step, or -1.
    static func index(_ steps: [Step], _ tool: String, _ contains: String = "") -> Int {
        let wanted = DotNet.string(DotNet.ordinalIgnoreCase(contains))
        return steps.firstIndex {
            $0.tool == tool
                && DotNet.contains(DotNet.string(DotNet.ordinalIgnoreCase($0.target + " " + $0.text)), wanted)
        } ?? -1
    }

    /// A reply as the bench judges it (Bench.cs's `RunAsync`): the app's plan reader, then `BrainPlan.tidy`, then the
    /// case's check. "Clean" also means at most `maxSteps` steps.
    static func judge(_ reply: String, _ benchCase: Case) -> (passed: Bool, clean: Bool, plan: String) {
        switch BrainPlan.parse(reply) {
        case .failure(let unusable):
            return (false, false, "BAD REPLY (\(unusable.reason)): \(reply)")
        case .success(let plan):
            let steps = BrainPlan.tidy(plan.steps).map {
                Step(tool: BrainPlan.nameOf($0.tool), target: $0.target, text: $0.text)
            }

            let passed = benchCase.check(steps, plan.say)
            let shown = steps.map { "\($0.tool)(\($0.target)\($0.text.isEmpty ? "" : ", " + $0.text))" }
            let described = steps.isEmpty && plan.say.isEmpty
                ? reply : shown.joined(separator: " → ") + "  say: \(plan.say)"
            return (passed, passed && steps.count <= benchCase.maxSteps, described)
        }
    }

    /// Runs every case through `generate` (the conversation to the model's raw reply) in order, writing each result to
    /// `output` as Bench.cs prints it.
    static func run(
        output: (String) -> Void, _ generate: ([ChatTurn]) async throws -> String
    ) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for benchCase in cases {
            let started = ProcessInfo.processInfo.systemUptime
            let reply: String
            do {
                reply = try await generate(BrainPrompt.messages(benchCase.screen, benchCase.request))
            } catch {
                reply = "ERROR \(error)"
            }

            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let verdict = judge(reply, benchCase)
            let time = String(format: "%6.0f", milliseconds)
            output("  \(verdict.passed ? "PASS" : "FAIL") \(time) ms  \(benchCase.request)")
            output("        \(verdict.plan)")
            outcomes.append(Outcome(
                request: benchCase.request, passed: verdict.passed, clean: verdict.clean, milliseconds: milliseconds,
                plan: verdict.plan))
        }

        return outcomes
    }

    /// The middle and the longest of the times, as Bench.cs takes them (the upper middle of an even count).
    static func medianAndSlowest(_ outcomes: [Outcome]) -> (median: Double, slowest: Double) {
        let times = outcomes.map(\.milliseconds).sorted()
        guard let slowest = times.last else { return (0, 0) }
        return (times[times.count / 2], slowest)
    }
}

/// llama-server's memory while the bench runs: its resident size, sampled, and the largest footprint the system
/// recorded for it (what Activity Monitor's Memory column shows), which also counts memory the graphics chip uses.
final class BrainBenchMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var sampler: Task<Void, Never>?

    /// Samples `process` every `interval` seconds until `stop`.
    init(process: Int32, interval: TimeInterval = 0.2) {
        sampler = Task.detached { [weak self] in
            while !Task.isCancelled {
                if let resident = BrainBenchMemory.resident(process) {
                    self?.record(resident)
                }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// The largest resident size sampled.
    var peakResident: UInt64 { lock.withLock { peak } }

    func stop() {
        sampler?.cancel()
    }

    private func record(_ resident: UInt64) {
        lock.withLock { peak = max(peak, resident) }
    }

    static func resident(_ process: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(process, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    /// The largest physical footprint of the process so far.
    static func peakFootprint(_ process: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process, RUSAGE_INFO_V4, $0)
            }
        }

        return result == 0 ? info.ri_lifetime_max_phys_footprint : nil
    }
}
