import AppKit
import SwiftUI
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore

/// The window's state (windows-voice-assistant `MainWindow`'s): the page that's open, the list the board opened at,
/// and the pages' models.
@MainActor
public final class WindowModel: ObservableObject {
    @Published public private(set) var page = AppPage.home
    /// The list "show my reminders" opened the board at, which the board lights up; nil for the whole board.
    @Published public private(set) var boardList: BoardList?

    public let home: HomeModel
    public let settings: SettingsModel
    public let help: HelpModel
    /// The idea board's page; nil without a board.
    public let board: BoardModel?

    public init(home: HomeModel, settings: SettingsModel, help: HelpModel, board: BoardModel? = nil) {
        self.home = home
        self.settings = settings
        self.help = help
        self.board = board
    }

    /// Opens `page`, as its button in the sidebar does (Windows' `ShowPage`): the board opens whole.
    public func show(_ page: AppPage) {
        boardList = nil
        self.page = page
    }

    /// Opens the board, lighting up `list` for a moment (Windows' `ShowBoard`).
    public func showBoard(_ list: BoardList?) {
        boardList = list
        page = .ideas
        if let list {
            board?.highlight(list)
        }
    }

    /// Reads again what may have changed while the window was away, as it shows or comes forward: what macOS allows,
    /// which reminders are due (on Home and the board), "Start when I log in" and the AI brain.
    public func refresh() {
        home.refreshPermissions()
        home.refreshReminders()
        board?.refresh()
        settings.refresh()
    }
}

/// The app's window (windows-voice-assistant `MainWindow`): Home, the idea board, Settings and "What you can say",
/// with the sidebar to move between them. Light, as on Windows, whatever the Mac's appearance. Closing it hides it and
/// the assistant keeps running in the menu bar, as it says the first time; Quit Voice Assistant (⌘Q) quits. While it's
/// in front, the app's menu gives it the Mac's keys: ⌘, for Settings, ⌘W, ⌘M, ⌘H and ⌘Q, and the Edit menu's for its
/// text boxes (macOS doesn't show the menus of an app that lives in the menu bar, but their keys work).
@MainActor
public final class MainWindow: NSObject, NSWindowDelegate {
    /// What the app says the first time the window is closed (Windows' tray balloon).
    public static let stillRunning =
        "Voice Assistant is still running in the menu bar. Click its icon › Quit Voice Assistant to quit."

    /// Its size when it opens, and the least it can be made (Windows' Width, Height, MinWidth and MinHeight).
    public static let size = CGSize(width: 1180, height: 760)
    public static let minimumSize = CGSize(width: 900, height: 560)

    public let model: WindowModel

    private let window: NSWindow
    private let content: NSHostingView<MainWindowView>
    private let notice: @MainActor (String) -> Void
    private var toldAboutMenuBar = false

    /// - Parameters:
    ///   - settings: The settings as read at launch.
    ///   - paths: Where settings.json and the logs are.
    ///   - board: The idea board: its page, and Home's "Coming up".
    ///   - assistant: The assistant host.
    ///   - brain: The AI brain; nil while it's switched off.
    ///   - keys: The keys the texts name.
    ///   - startAtLogin: "Start when I log in".
    ///   - restart: Starts a fresh copy of the app, with its window open when `windowVisible` ("Save and restart").
    ///   - notice: Says something by the menu bar icon (Windows' tray balloon), as when the board can't save a change.
    ///   - permissions: What macOS allows, for Home's "Permissions needed".
    ///   - opener: Finder, TextEdit and System Settings.
    public init(
        settings: AppSettings, paths: AppPaths, board: BoardStore?, assistant: AssistantControls,
        brain: BrainControls?, keys: KeyNames, startAtLogin: StartAtLogin,
        restart: @escaping @MainActor (_ windowVisible: Bool) -> Void, notice: @escaping @MainActor (String) -> Void,
        permissions: Permissions = Permissions(), opener: FileOpener = WorkspaceOpener()
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        let ideas: BoardModel? = board.map { (store: BoardStore) -> BoardModel in
            BoardModel(board: store, keys: keys, report: notice)
        }
        let model = WindowModel(
            home: HomeModel(
                assistant: assistant, board: board, keys: keys, permissions: permissions,
                dictationKeyOn: settings.pushToTalk),
            settings: SettingsModel(
                settings: settings, paths: paths, assistant: assistant, brain: brain, keys: keys,
                startAtLogin: startAtLogin, restart: { [weak window] in restart(window?.isVisible ?? false) },
                opener: opener),
            help: HelpModel(keys: keys), board: ideas)
        let content = NSHostingView(rootView: MainWindowView(model: model))
        content.sizingOptions = [.minSize]
        self.model = model
        self.window = window
        self.content = content
        self.notice = notice
        super.init()
        model.home.openBoard = { [weak self] list in self?.showBoard(list) }
        window.title = "Voice Assistant"
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = Theme.appearance
        window.backgroundColor = NSColor(Color(Theme.background))
        window.contentView = content
        window.delegate = self
        window.center()
        NSApplication.shared.mainMenu = mainMenu()
    }

    /// The window is on the screen (so a restart opens it again).
    public var isVisible: Bool { window.isVisible }

    /// macOS hasn't given a permission the assistant needs: Home's card lists it, so the app opens the window at Home.
    public var permissionsNeeded: Bool { !model.home.permissions.isEmpty }

    /// Shows the window and brings it forward, out of the Dock if it was minimized (Windows' `Bring`); its contents
    /// fade in when it wasn't showing. A voice command or a second launch isn't a click in the app, so macOS may keep
    /// another app active (and the window may not become key): the window still comes to the front, with its pages
    /// read again.
    public func bring() {
        let wasVisible = window.isVisible
        model.refresh()
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if !wasVisible {
            fadeIn()
        }
    }

    /// A page from the menu bar (App's `OpenPage`): the board as "show my board" opens it, another page brought
    /// forward.
    public func open(_ page: AppPage) {
        if page == .ideas {
            showBoard(nil)
            return
        }

        bring()
        model.show(page)
    }

    /// Opens the window at the board, highlighting `list` (Windows' `ShowBoard`; the host's `showBoardRequested`).
    public func showBoard(_ list: BoardList?) {
        bring()
        model.showBoard(list)
    }

    /// A status from the assistant: Home's mode and recent activity.
    public func showStatus(_ update: AssistantStatus) {
        model.home.showStatus(update)
    }

    /// The dictation language changed (the hotkey, the menu): Home's choice follows.
    public func setDictationLanguage(hinglish: Bool, accurate: Bool) {
        model.home.setDictationLanguage(hinglish: hinglish, accurate: accurate)
    }

    /// The AI brain's status changed: Settings' card follows.
    public func brainChanged() {
        model.settings.brainChanged()
    }

    /// Closing hides the window (Windows' `OnClosing`).
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Back in front, perhaps from System Settings: what macOS allows, the login item and the times may have changed.
    public func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }

    /// Hides the window and gives the keyboard back to the app before (the floating panels stay: they can't hide);
    /// the first time, says the app is still running.
    func hide() {
        window.orderOut(nil)
        if NSApp.isActive {
            NSApp.hide(nil)
        }

        if !toldAboutMenuBar {
            toldAboutMenuBar = true
            notice(Self.stillRunning)
        }
    }

    /// Windows' fade of the window's contents each time it opens: 200 ms, unless Reduce motion is on.
    private func fadeIn() {
        guard Motion.isEnabled else {
            content.alphaValue = 1
            return
        }

        content.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = Motion.timingFunction
            self.content.animator().alphaValue = 1
        }
    }

    /// The app's menu, for its keys: Settings… (⌘,), Hide (⌘H) and Quit (⌘Q); the Edit menu's for text boxes; Close
    /// (⌘W) and Minimize (⌘M).
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Voice Assistant")
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Voice Assistant", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(
            withTitle: "Quit Voice Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for menu in [app, edit, windows] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }

        return main
    }

    @objc private func openSettings(_ sender: Any?) {
        open(.settings)
    }
}

/// The window's contents (MainWindow.cs): the sidebar, with the logo, the pages and where everything stays, and the
/// open page.
struct MainWindowView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 230)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(Theme.sidebar))
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(Theme.background))
        }
        .frame(minWidth: MainWindow.minimumSize.width, minHeight: MainWindow.minimumSize.height)
    }

    /// The open page, which fades in and rises 10 points each time another opens (Windows' `ShowPage`).
    @ViewBuilder private var page: some View {
        switch model.page {
        case .home:
            HomePage(model: model.home).modifier(FadeInOnAppear(milliseconds: 180, rise: 10))
        case .ideas:
            if let board = model.board {
                IdeasPage(model: board).modifier(FadeInOnAppear(milliseconds: 180, rise: 10))
            } else {
                IdeasPlaceholderPage().modifier(FadeInOnAppear(milliseconds: 180, rise: 10))
            }
        case .settings:
            SettingsPage(model: model.settings).modifier(FadeInOnAppear(milliseconds: 180, rise: 10))
        case .help:
            HelpPage(model: model.help).modifier(FadeInOnAppear(milliseconds: 180, rise: 10))
        }
    }
}

/// The sidebar (MainWindow.cs): the logo and the name, a button for each page (the open one tinted and in semibold),
/// and where everything stays.
struct Sidebar: View {
    /// A page's button: Windows' label, whose emoji WPF draws in the text's colour, as the symbol is here.
    struct Item {
        let page: AppPage
        let symbol: String
        let label: String
    }

    static let items = [
        Item(page: .home, symbol: "house", label: "Home"),
        Item(page: .ideas, symbol: "lightbulb", label: "Idea board"),
        Item(page: .settings, symbol: "gearshape", label: "Settings"),
        Item(page: .help, symbol: "questionmark.circle", label: "What you can say"),
    ]

    static let privacy = "Runs on this Mac. Speech, notes and settings never leave it."

    @ObservedObject var model: WindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                AppLogo.Mark(size: 28).padding(.trailing, 10)
                Text(verbatim: "Voice Assistant")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(Theme.text))
            }
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 20, trailing: 0))
            ForEach(Self.items, id: \.page) { (item: Item) in
                let selected: Bool = model.page == item.page
                let traits: AccessibilityTraits = selected ? .isSelected : []
                Button {
                    model.show(item.page)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).frame(width: 18).accessibilityHidden(true)
                        Text(verbatim: item.label)
                    }
                }
                .buttonStyle(Self.style(selected: selected))
                .accessibilityAddTraits(traits)
                .padding(.bottom, 4)
            }

            Theme.label(Self.privacy, size: 11, colour: Theme.muted)
                .padding(EdgeInsets(top: 24, leading: 8, bottom: 0, trailing: 8))
        }
        .padding(EdgeInsets(top: 16, leading: 12, bottom: 12, trailing: 12))
    }

    /// A page's button (Windows' nav buttons): clear at rest, or the soft accent while its page is open.
    static func style(selected: Bool) -> ThemeButtonStyle {
        var style = ThemeButtonStyle(
            normal: selected ? Theme.accentSoft : Colour(0xEBEBEB, alpha: 0), hover: Colour(0xE0E0E0),
            pressed: Colour(0xD6D6D6), foreground: Theme.text, border: nil)
        style.fontSize = 14
        style.weight = selected ? .semibold : .regular
        style.padding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        style.fillsWidth = true
        return style
    }
}

/// The idea board's place in a window without a board (the app always has one: it doesn't start without board.json).
struct IdeasPlaceholderPage: View {
    static let text = "The idea board isn't open."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.heading("Idea board")
            Theme.label(Self.text, colour: Theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
