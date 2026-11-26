import AppKit
import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore

/// The open windows for the AI brain (windows-voice-assistant `WindowsDesktop.Brain`: `ListWindows`, `Describe`,
/// `ActivateWindowAsync`): the apps' windows front to back, each with how it's shown and where, and bringing one to the
/// front. Logs hold counts and outcomes, never titles.
extension MacDesktop {
    /// The most windows listed (C#'s `MaxListedWindows`).
    static let maxListedWindows = 12

    /// How long the window list asks apps for their windows, then describes them, inside the 4-second limit. Both are
    /// checked before each window, and an app that doesn't answer is asked nothing more, so about one question, which
    /// waits `SystemAX.timeout` (1 s) at most, goes past either: the list comes back in time with what was found.
    static let windowSearchTime: TimeInterval = 1.5
    static let windowListTime: TimeInterval = 3

    /// The windows of the other apps, front-most first and the one taking the keys first of all, at most 12 (C#'s
    /// `ListWindows`), each with how it's shown, its frame and the usable part of its screen (`describe`). Windows
    /// lists the visible top-level windows that no other window owns; here they're the standard windows
    /// (`windows(of:)`) of the apps in the Dock, and of the app in front when it isn't one: panels, alerts, sheets and
    /// Finder's desktop aren't, as Windows skips tool and owned windows and the desktop. Minimized windows count, as on
    /// Windows, and so do a hidden app's, shown as minimized. A window without a title counts too, though Windows skips
    /// those: a Mac app's only window can have none, and the brain also knows a window by its app's name.
    ///
    /// Off the caller's thread with the scans' 4-second limit (Windows' list doesn't wait on apps, so it has none). It
    /// asks the apps for their windows for 1.5 s, the app in front first, then the others in the order of their
    /// front-most window on screen (`searchOrder`), so what's cut when time runs out is at the back, as Windows cuts
    /// its list in that order. It describes the windows found, front-most first, until 3 s (`windowSearchTime`,
    /// `windowListTime`); an app that doesn't answer isn't asked again, and a window not described by then is listed
    /// with what's known: its app, its number and title, no frame. The window taking the keys is asked for last.
    /// Should the limit pass all the same (an app in front that doesn't answer), the windows found by then are the
    /// list.
    public func listWindows() async throws -> [DesktopWindow] {
        let screens = await workspace.screens()
        let listed = Background.Answer<[DesktopWindow]>()
        switch try await Background.run(Self.accessibilityTimeout, { [self] token in
            scanWindows(screens, token, listed)
        }) {
        case .finished(let windows):
            return windows
        case .timedOut:
            let partial = listed.value ?? []
            log("window list timed out with \(partial.count) windows")
            return partial
        }
    }

    /// C#'s `ListWindows`, in `token`'s time: the list as it grows goes to `listed`, in case the time runs out.
    func scanWindows(
        _ screens: [ScreenArea], _ token: WorkToken, _ listed: Background.Answer<[DesktopWindow]>
    ) -> [DesktopWindow] {
        let start = clock.now()
        let searchEnd = start + Self.windowSearchTime
        let listEnd = start + Self.windowListTime
        var found: [AppWindow] = []
        var hidden: Set<Int> = []
        var unanswered: Set<Int> = []
        for process in searchOrder(workspace.serverWindowsFrontToBack()) {
            if token.isCancelled || clock.now() > searchEnd {
                break
            }

            let pid = Int(process.processIdentifier)
            let search = searchWindows(of: process) { token.isCancelled || self.clock.now() > searchEnd }
            if search.hidden == true {
                hidden.insert(pid)
            } else if search.answered, search.hidden == nil, !search.windows.isEmpty,
                      isHidden(process.processIdentifier) {
                hidden.insert(pid)
            }

            if !search.answered {
                unanswered.insert(pid)
            }

            found += search.windows
        }

        let ordered = Array(frontToBack(found).prefix(Self.maxListedWindows))
        var described: [DesktopWindow] = ordered.map { (window: AppWindow) -> DesktopWindow in
            Self.known(window, hidden: hidden.contains(window.info.processId))
        }
        listed.set(described)
        var reached = 0
        for window in ordered {
            if token.isCancelled || clock.now() > listEnd {
                break
            }

            let pid = window.info.processId
            described[reached] = describe(window, hidden: hidden.contains(pid), &unanswered, screens)
            reached += 1
            listed.set(described)
        }

        if let keys = foregroundWindow(), let index = described.firstIndex(where: { $0.window.sameWindow(keys) }),
           index > 0 {
            described.insert(described.remove(at: index), at: 0)
        }

        let notDescribed = described.count - reached
        let note = notDescribed > 0 ? " (\(notDescribed) not described)" : ""
        log("window list: \(described.count) windows\(note), \(milliseconds(since: start)) ms")
        return described
    }

    /// The apps to ask for their windows: those in the Dock, and the app in front when it isn't one, never this app.
    /// The app in front first, then the others in the order of their front-most window on screen (`onScreen`, the
    /// window server's, front-most first), then the apps with no window on screen, as they run.
    func searchOrder(_ onScreen: [ServerWindow]) -> [RunningApp] {
        let front = workspace.frontmostApp()?.processIdentifier
        var rank: [pid_t: Int] = [:]
        for (index, window) in onScreen.enumerated() where rank[window.owner] == nil {
            rank[window.owner] = index
        }

        if let front {
            rank[front] = -1
        }

        let apps = workspace.runningApps().filter { (app: RunningApp) -> Bool in
            app.processIdentifier != ownProcess && (app.isRegular || app.processIdentifier == front)
        }
        return DotNet.orderBy(apps) { rank[$0.processIdentifier] ?? Int.max }
    }

    /// A window as it's known without asking its app: minimized when its app is hidden, else normal; no frame.
    static func known(_ window: AppWindow, hidden: Bool) -> DesktopWindow {
        DesktopWindow(window: window.info, show: hidden ? .minimized : .normal)
    }

    /// C#'s `Describe`: minimized (also when its app is hidden: nothing of it shows), maximized in full screen, else
    /// normal (the core calls a window that fills its screen's usable part maximized, as zooming makes it); its frame,
    /// and the usable part of the screen it's on (`screen(of:)`). An app that doesn't answer goes in `unanswered`, and
    /// its windows are described by what's known without asking it (`known`).
    func describe(
        _ window: AppWindow, hidden: Bool, _ unanswered: inout Set<Int>, _ screens: [ScreenArea]
    ) -> DesktopWindow {
        let pid = window.info.processId
        if unanswered.contains(pid) {
            return Self.known(window, hidden: hidden)
        }

        do {
            var show: WindowShow = hidden ? .minimized : .normal
            if !hidden, try ax.number(kAXMinimizedAttribute, of: window.element) == 1 {
                show = .minimized
            } else if !hidden, try ax.number(AXName.fullScreen, of: window.element) == 1 {
                show = .maximized
            }

            let frame: CGRect? = try ax.frame(of: window.element)
            let area: ScreenArea? = frame.flatMap { Self.screen(of: $0, screens) }
            let workArea: ScreenRect? = area.map { ScreenRect($0.visibleFrame) }
            let rect: ScreenRect? = frame.map { ScreenRect($0) }
            return DesktopWindow(window: window.info, show: show, rect: rect, workArea: workArea)
        } catch {
            unanswered.insert(pid)
            return Self.known(window, hidden: hidden)
        }
    }

    /// The screen a window is on (C#'s `MonitorFromWindow`, the nearest): the one with the window's centre, else the
    /// one it covers most, else the main one.
    static func screen(of frame: CGRect, _ screens: [ScreenArea]) -> ScreenArea? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }

        var best: ScreenArea?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(frame)
            let area: CGFloat = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }

        return best ?? screens.first
    }

    /// The app is hidden (AXHidden): its windows don't show, minimized or not.
    func isHidden(_ pid: pid_t) -> Bool {
        (try? ax.number(kAXHiddenAttribute, of: ax.application(pid))) == 1
    }

    // MARK: Bringing a window forward

    /// Brings the window to the front (C#'s `ActivateWindowAsync`): `activate` unhides its app, un-minimizes it, then
    /// brings it forward up to 5 times and checks it takes the keys. Messages name it by its title when that's 1 to 40
    /// characters long, else "that window"; the log never does. A window that has closed fails at once.
    public func activateWindow(_ window: WindowInfo) async throws -> DesktopResult {
        let length = window.title.utf16.count
        let name = length > 0 && length <= 40 ? "“\(window.title)”" : "that window"
        guard window.processId != Int(ownProcess), let element = windowElement(window) else {
            log("activation of a window: not found")
            return .fail("I couldn't find \(name) any more.")
        }

        return try await activate(AppWindow(info: window, element: element), name, logName: "a window")
    }
}
