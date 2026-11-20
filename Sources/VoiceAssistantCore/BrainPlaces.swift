/// The windows the AI brain treats specially, which differ by platform (like `ShortcutKeys`): where it never types or
/// presses keys, the web browsers (where it types only inside the page) and the file managers (where opening a file
/// needs a "yes"). `windows` has the C# core's lists; `mac` follows docs/design.md, "Where it never types". The desktop
/// hands the core its platform's (`JarvisDesktop.brainPlaces`).
///
/// Entries are process names, compared ignoring case. On the Mac, a window's process name is whatever the desktop
/// layer reports for its app (it isn't settled yet), so `mac` lists each app twice: by its executable name, as Activity
/// Monitor shows it, and by its bundle identifier.
public struct BrainPlaces: Equatable, Sendable {
    /// Windows where text or keys can run a command (screen text could steer the model there): terminals, the Run box,
    /// launchers and search, the file manager. Dictating there yourself still works.
    public let commandProcesses: [String]

    /// Web browsers, whether or not the app list has them: their own bars open what is typed, so the brain types only
    /// where the focus is inside the page (`FocusInfo.inPage`: a UI Automation Document on Windows, an `AXWebArea` on
    /// the Mac), never into the address bar.
    public let browserProcesses: [String]

    /// File managers: opening a file or folder there needs a "yes", as known extensions are hidden.
    public let fileManagerProcesses: [String]

    private let commands: IgnoreCaseSet
    private let browsers: IgnoreCaseSet
    private let fileManagers: IgnoreCaseSet

    public init(commandProcesses: [String], browserProcesses: [String], fileManagerProcesses: [String]) {
        self.commandProcesses = commandProcesses
        self.browserProcesses = browserProcesses
        self.fileManagerProcesses = fileManagerProcesses
        commands = IgnoreCaseSet(commandProcesses)
        browsers = IgnoreCaseSet(browserProcesses)
        fileManagers = IgnoreCaseSet(fileManagerProcesses)
    }

    func isCommand(_ processName: String) -> Bool { commands.contains(processName) }

    func isBrowser(_ processName: String) -> Bool { browsers.contains(processName) }

    func isFileManager(_ processName: String) -> Bool { fileManagers.contains(processName) }

    /// The C# core's: terminals, the Run box, Task Manager's "Run new task", launchers, the Start menu's search and
    /// File Explorer (its address bar starts programs, its keys open and delete files, and the Run box is its dialog).
    public static let windows = BrainPlaces(
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
        fileManagerProcesses: ["explorer"])

    /// Terminal and the other terminals, Spotlight and Finder (docs/design.md). Also, as the C# lists PowerToys Run
    /// and PowerShell ISE: the launchers Raycast, Alfred and LaunchBar, and Script Editor, which runs what it holds.
    public static let mac = BrainPlaces(
        commandProcesses: [
            "Terminal", "com.apple.Terminal", "iTerm2", "com.googlecode.iterm2", "stable", "dev.warp.Warp-Stable",
            "ghostty", "com.mitchellh.ghostty", "kitty", "net.kovidgoyal.kitty", "alacritty", "org.alacritty",
            "wezterm-gui", "com.github.wez.wezterm", "Hyper", "co.zeit.hyper", "Tabby", "org.tabby",
            "Spotlight", "com.apple.Spotlight", "Raycast", "com.raycast.macos", "Alfred",
            "com.runningwithcrayons.Alfred", "LaunchBar", "at.obdev.LaunchBar", "Script Editor",
            "com.apple.ScriptEditor2", "Finder", "com.apple.finder",
        ],
        browserProcesses: [
            "Safari", "com.apple.Safari", "Safari Technology Preview", "com.apple.SafariTechnologyPreview",
            "Google Chrome", "com.google.Chrome", "Google Chrome Beta", "com.google.Chrome.beta", "Google Chrome Dev",
            "com.google.Chrome.dev", "Google Chrome Canary", "com.google.Chrome.canary", "Microsoft Edge",
            "com.microsoft.edgemac", "Microsoft Edge Beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Dev",
            "com.microsoft.edgemac.Dev", "Microsoft Edge Canary", "com.microsoft.edgemac.Canary", "firefox",
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "Brave Browser",
            "com.brave.Browser", "Brave Browser Beta", "com.brave.Browser.beta", "Brave Browser Nightly",
            "com.brave.Browser.nightly", "Arc", "company.thebrowser.Browser", "Dia", "company.thebrowser.dia", "Opera",
            "com.operasoftware.Opera", "Opera GX", "com.operasoftware.OperaGX", "Vivaldi", "com.vivaldi.Vivaldi",
            "Chromium", "org.chromium.Chromium", "DuckDuckGo", "com.duckduckgo.macos.browser", "Orion",
            "com.kagi.kagimacOS", "zen", "app.zen-browser.zen", "org.torproject.torbrowser", "Thorium",
            "org.chromium.Thorium", "Whale", "com.naver.Whale", "Yandex", "ru.yandex.desktop.yandex-browser",
        ],
        fileManagerProcesses: ["Finder", "com.apple.finder"])

    public static func == (a: BrainPlaces, b: BrainPlaces) -> Bool {
        a.commandProcesses == b.commandProcesses && a.browserProcesses == b.browserProcesses
            && a.fileManagerProcesses == b.fileManagerProcesses
    }
}
