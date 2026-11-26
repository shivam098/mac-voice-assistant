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

    /// The windows of the other apps, front-most first and the one taking the keys first of all, at most 12 (C#'s
    /// `ListWindows`), each with how it's shown, its frame and the usable part of its screen (`describe`). Windows
    /// lists the visible top-level windows that no other window owns; here they're the standard windows
    /// (`windows(of:)`) of the apps in the Dock, and of the app taking the keys when it isn't one: panels, alerts,
    /// sheets and Finder's desktop aren't, as Windows skips tool and owned windows and the desktop. Minimized windows
    /// count, as on Windows, and so do a hidden app's, shown as minimized. A window without a title counts too, though
    /// Windows skips those: a Mac app's only window can have none, and the brain also knows a window by its app's name.
    /// Off the caller's thread with the scans' 4-second limit; an app slow to answer ends the list with what was found
    /// by then.
    public func listWindows() async throws -> [DesktopWindow] {
        let screens = await workspace.screens()
        return try await scanned("window list") { [self] token in scanWindows(screens, token) }
    }

    /// C#'s `ListWindows`, in `token`'s time.
    func scanWindows(_ screens: [ScreenArea], _ token: WorkToken) -> [DesktopWindow] {
        let start = clock.now()
        let front = foregroundWindow()
        var found: [AppWindow] = []
        var hidden: Set<Int> = []
        for process in workspace.runningApps() where process.processIdentifier != ownProcess {
            guard process.isRegular || front?.processId == Int(process.processIdentifier) else { continue }
            if token.isCancelled || clock.now() > start + Self.scanTime {
                break
            }

            let processWindows = windows(of: process)
            if !processWindows.isEmpty, isHidden(process.processIdentifier) {
                hidden.insert(Int(process.processIdentifier))
            }

            found += processWindows
        }

        var listed = Array(frontToBack(found).prefix(Self.maxListedWindows))
        if let front, let index = listed.firstIndex(where: { $0.info.sameWindow(front) }), index > 0 {
            listed.insert(listed.remove(at: index), at: 0)
        }

        let described = listed.map { window in
            describe(window, hidden: hidden.contains(window.info.processId), screens)
        }
        log("window list: \(described.count) windows, \(milliseconds(since: start)) ms")
        return described
    }

    /// C#'s `Describe`: minimized (also when its app is hidden: nothing of it shows), maximized in full screen, else
    /// normal (the core calls a window that fills its screen's usable part maximized, as zooming makes it); its frame,
    /// and the usable part of the screen it's on (`screen(of:)`).
    func describe(_ window: AppWindow, hidden: Bool, _ screens: [ScreenArea]) -> DesktopWindow {
        var show = WindowShow.normal
        if hidden || (try? ax.number(kAXMinimizedAttribute, of: window.element)) == 1 {
            show = .minimized
        } else if (try? ax.number(AXName.fullScreen, of: window.element)) == 1 {
            show = .maximized
        }

        let frame: CGRect? = try? ax.frame(of: window.element)
        let workArea: ScreenRect? = frame.flatMap { Self.screen(of: $0, screens) }.map { ScreenRect($0.visibleFrame) }
        return DesktopWindow(window: window.info, show: show, rect: frame.map { ScreenRect($0) }, workArea: workArea)
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
