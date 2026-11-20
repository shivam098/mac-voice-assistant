import ThumbFreeCore

/// What the AI brain's limits mean on one platform, as `ShortcutKeys` is for the voice commands: where it never types
/// or presses keys, the web browsers (where it types only inside the page) and the file manager (where opening a file
/// needs a "yes"); which button words send or run something; which files start a program; and how the keys a plan names
/// are pressed and judged (`BrainSafety`). `windows` has the C# core's lists and rules unchanged; `mac` follows
/// docs/design.md ("Where it never types", "Mac shortcuts"). There are only these two, and the desktop must name its
/// own (`JarvisDesktop.brainPlatform` has no default), so no check can fall back to another platform's lists.
///
/// Apps are named by process, compared ignoring case: on Windows by the executable's name, on the Mac by bundle
/// identifier only, since executable and localized names vary (Warp's executable is "stable", WezTerm's
/// "wezterm-gui", and Script Editor is "Skripteditor" in German). The app checked is the one that has the keyboard
/// focus (`JarvisDesktop.foregroundWindow`).
public struct BrainPlatform: Equatable, Sendable {
    public enum Kind: Sendable {
        /// Plans' keys are pressed as named, by the C# core's rules.
        case windows

        /// Plans still name Windows keys (the prompt is Windows'): each chord is pressed as its Mac chord, and refused
        /// or asked about if either Windows' rules or the Mac's say so (`BrainSafety.pressedChord`).
        case mac
    }

    public let kind: Kind

    /// Apps where text or keys can run a command (screen text could steer the model there): terminals, the Run box,
    /// launchers and search, the file manager, and apps that run scripts or change the system. Dictating there yourself
    /// still works.
    public let commandProcesses: [String]

    /// Web browsers, whether or not the app list has them: their own bars open what is typed, so the brain types only
    /// where the focus is inside the page (`FocusInfo.inPage`: a UI Automation Document on Windows, an `AXWebArea` on
    /// the Mac), never into the address bar.
    public let browserProcesses: [String]

    /// File managers: opening a file or folder there needs a "yes", as known extensions are hidden.
    public let fileManagerProcesses: [String]

    /// What the messages call the file manager ("I don't type in File Explorer…").
    public let fileManagerName: String

    /// Words on buttons that send, publish, install, run or agree to something: clicking one needs a "yes" (on top of
    /// `TargetResolver.isDestructive`).
    public let sendWords: [String]

    /// The extensions of files that start a program or a script, or open a link, when they are opened: opening one
    /// needs a "yes".
    public let programFileTypes: [String]

    private let commands: IgnoreCaseSet
    private let browsers: IgnoreCaseSet
    private let fileManagers: IgnoreCaseSet

    /// The extension ends the name (or comes before a comma, as Explorer adds details): "Node.js tutorial" isn't a
    /// file. With `windows`'s types this is the C#'s pattern exactly.
    let programFilePattern: String
    let programFile: NetRegex

    private init(
        kind: Kind, commandProcesses: [String], browserProcesses: [String], fileManagerProcesses: [String],
        fileManagerName: String, sendWords: [String], programFileTypes: [String]
    ) {
        self.kind = kind
        self.commandProcesses = commandProcesses
        self.browserProcesses = browserProcesses
        self.fileManagerProcesses = fileManagerProcesses
        self.fileManagerName = fileManagerName
        self.sendWords = sendWords
        self.programFileTypes = programFileTypes
        commands = IgnoreCaseSet(commandProcesses)
        browsers = IgnoreCaseSet(browserProcesses)
        fileManagers = IgnoreCaseSet(fileManagerProcesses)
        let pattern = #"\.("# + programFileTypes.joined(separator: "|") + #")\s*(,|$)"#
        programFilePattern = pattern
        programFile = NetRegex(pattern, .ignoreCase)
    }

    func isCommand(_ processName: String) -> Bool { commands.contains(processName) }

    func isBrowser(_ processName: String) -> Bool { browsers.contains(processName) }

    func isFileManager(_ processName: String) -> Bool { fileManagers.contains(processName) }

    private static let windowsSendWords = [
        "send", "post", "submit", "publish", "tweet", "share", "comment", "reply all", "forward", "install", "allow",
        "accept", "agree", "approve", "confirm", "run", "end task", "end process", "run anyway", "keep anyway",
        "repost", "retweet",
    ]

    private static let windowsProgramFileTypes = [
        "exe", "bat", "cmd", "com", "ps1", "psm1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "msi", "msix", "msixbundle",
        "appx", "appxbundle", "scr", "hta", "jar", "reg", "lnk", "cpl", "inf", "url", "application",
    ]

    /// The C# core's: terminals, the Run box, Task Manager's "Run new task", launchers, the Start menu's search and
    /// File Explorer (its address bar starts programs, its keys open and delete files, and the Run box is its dialog).
    public static let windows = BrainPlatform(
        kind: .windows,
        commandProcesses: [
            "cmd", "powershell", "pwsh", "powershell_ise", "WindowsTerminal", "OpenConsole", "conhost", "wt", "wsl",
            "wslhost", "bash", "mintty", "putty", "ssh", "regedit", "mmc", "Taskmgr", "SearchHost", "SearchApp",
            "StartMenuExperienceHost", "ShellExperienceHost", "PowerToys.PowerLauncher", "Microsoft.CmdPal.UI",
            "explorer",
        ],
        browserProcesses: [
            "chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "arc", "chromium", "thorium", "librewolf",
            "waterfox", "floorp", "zen", "iexplore", "browser", "DuckDuckGo", "AvastBrowser", "AVGBrowser",
            "CCleanerBrowser", "whale", "maxthon", "slimjet", "iron", "seamonkey", "palemoon", "basilisk",
            "mullvadbrowser",
        ],
        fileManagerProcesses: ["explorer"], fileManagerName: "File Explorer", sendWords: windowsSendWords,
        programFileTypes: windowsProgramFileTypes)

    /// Terminal and the other terminals, Spotlight and Finder (docs/design.md); as the C# lists PowerToys Run and
    /// PowerShell ISE, Task Manager, regedit and mmc, also the launchers Raycast, Alfred and LaunchBar, the apps that
    /// run scripts (Script Editor, Automator, Shortcuts), and System Settings, the password and login prompts, Activity
    /// Monitor (it quits processes), Disk Utility (it erases disks) and Keychain Access (it holds passwords). "Force
    /// Quit" and Gatekeeper's "Open Anyway" need a "yes", as "End task" and "Run anyway" do; so do apps, scripts
    /// Terminal runs (.command, .tool, .terminal), installer packages, links (.webloc and .inetloc are the Mac's .url,
    /// and .fileloc's file can be an app), configuration profiles (as .reg) and settings panes (as .cpl).
    public static let mac = BrainPlatform(
        kind: .mac,
        commandProcesses: [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
            "org.tabby", "com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred",
            "at.obdev.LaunchBar", "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts",
            "com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.loginwindow",
            "com.apple.ActivityMonitor", "com.apple.DiskUtility", "com.apple.keychainaccess", "com.apple.finder",
        ],
        browserProcesses: [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
            "com.google.Chrome.dev", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
            "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary", "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.brave.Browser", "com.brave.Browser.beta",
            "com.brave.Browser.nightly", "company.thebrowser.Browser", "company.thebrowser.dia",
            "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
            "com.duckduckgo.macos.browser", "com.kagi.kagimacOS", "app.zen-browser.zen", "org.torproject.torbrowser",
            "org.chromium.Thorium", "com.naver.Whale", "ru.yandex.desktop.yandex-browser",
            "io.gitlab.librewolf-community.librewolf", "net.librewolf.librewolf", "net.waterfox.waterfox",
            "org.waterfoxproject.waterfox", "one.ablaze.floorp", "net.mullvad.mullvadbrowser",
        ],
        fileManagerProcesses: ["com.apple.finder"], fileManagerName: "Finder",
        sendWords: windowsSendWords + ["force quit", "open anyway"],
        programFileTypes: windowsProgramFileTypes + [
            "app", "command", "tool", "terminal", "pkg", "mpkg", "webloc", "inetloc", "fileloc", "mobileconfig",
            "prefpane",
        ])

    public static func == (a: BrainPlatform, b: BrainPlatform) -> Bool {
        a.kind == b.kind && a.commandProcesses == b.commandProcesses && a.browserProcesses == b.browserProcesses
            && a.fileManagerProcesses == b.fileManagerProcesses && a.fileManagerName == b.fileManagerName
            && a.sendWords == b.sendWords && a.programFileTypes == b.programFileTypes
    }
}
