import AppKit
import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore

/// Opening and activating apps, opening web pages and zooming windows (windows-voice-assistant `WindowsDesktop`:
/// `OpenOrActivateAsync`, `ActivateAsync`, `FindAppWindows`; `WindowsDesktop.Brain`: `OpenUrlAsync`, `BrowserWindows`).
extension MacDesktop {
    /// A window of an app, with its element.
    struct AppWindow {
        let info: WindowInfo
        let element: AnyObject
    }

    // MARK: Apps

    /// Brings the app's front-most window forward, or starts the app and waits 15 s for its window (C#'s
    /// `OpenOrActivateAsync`). With `newWindow`, an app already running with `newWindowKeys` gets a fresh window; an
    /// app just started with `newDocumentKeys` gets a blank document. The app is found by its bundle identifiers
    /// (`processNames`) and started by `launch`, a bundle identifier or an app's path.
    public func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult {
        if !app.processNames.isEmpty, let existing = appWindows(app).first {
            let activated = try await activate(existing, app.name)
            log("open \(app.name): existing window \(activated.success ? "activated" : "activation failed")")
            guard activated.success, newWindow, let newWindowKeys = app.newWindowKeys else { return activated }

            // "Open TextEdit" means a fresh window, not the document that's already open.
            let known = Set(appWindows(app).map { $0.info.handle })
            typer.waitForModifiersReleased()
            if !existing.info.sameWindow(foregroundWindow()) {
                return .fail("Focus moved away from \(app.name), so I didn't open a new window.")
            }

            try presser.press(presser.resolve(newWindowKeys))
            let fresh = try await waitForNewWindow(app, known)
            log("open \(app.name): new window \(fresh == nil ? "did not appear" : "opened")")
            guard let fresh else {
                return .fail("\(app.name) didn't open a new window. Say “switch to \(app.name)” to use the open one.")
            }

            return .ok("Opened a new \(app.name) window.", window: fresh)
        }

        let before = foregroundWindow()
        guard let url = applicationURL(app.launch) else {
            log("launch failed: no app for its bundle identifier")
            return .fail("Couldn't start \(app.name).")
        }

        do {
            _ = try await workspace.launch(url)
        } catch {
            let failure = error as NSError
            log("launch failed: \(failure.domain) \(failure.code)")
            return .fail("Couldn't start \(app.name).")
        }

        let deadline = clock.now() + 15
        while clock.now() < deadline {
            try await clock.pause(0.25)
            if !app.processNames.isEmpty {
                if let started = appWindows(app).first {
                    let activated = try await activate(started, app.name)
                    log("open \(app.name): launched, \(activated.success ? "activated" : "activation failed")")
                    if activated.success, let newDocumentKeys = app.newDocumentKeys {
                        // Apps that reopen their documents, or show an Open dialog, get a blank one to type into.
                        try await clock.pause(0.5)
                        typer.waitForModifiersReleased()
                        if started.info.sameWindow(foregroundWindow()) {
                            try presser.press(presser.resolve(newDocumentKeys))
                            try await clock.pause(0.3)
                        }
                    }

                    return activated
                }
            } else if let now = foregroundWindow(), !now.sameWindow(before) {
                // Some window came to the front, but it can't be proved to be the app's: no window in the result.
                log("open \(app.name): launched (window not identifiable)")
                return .ok("Opened \(app.name).")
            }
        }

        log("open \(app.name): launched, window not seen")
        return app.processNames.isEmpty
            ? .ok("Asked macOS to open \(app.name).")
            : .fail("\(app.name) is starting, but its window didn't appear.")
    }

    /// Where the app is: `launch` is an app's path ("/Applications/…", "~/Applications/…") or a bundle identifier.
    func applicationURL(_ launch: String) -> URL? {
        let trimmed = launch.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }

        return trimmed.isEmpty ? nil : workspace.applicationURL(bundleIdentifier: trimmed)
    }

    /// C#'s `WaitForNewWindowAsync`: 4 s for a window of the app that wasn't there, brought to the front.
    func waitForNewWindow(_ app: AppEntry, _ known: Set<Int>) async throws -> WindowInfo? {
        for _ in 0..<16 {
            try await clock.pause(0.25)
            guard let fresh = appWindows(app).first(where: { !known.contains($0.info.handle) }) else { continue }
            if !fresh.info.sameWindow(foregroundWindow()) {
                let activated = try await activate(fresh, app.name)
                if !activated.success {
                    return nil
                }
            }

            return fresh.info
        }

        return nil
    }

    /// C#'s `ActivateAsync`: un-minimizes the window (and unhides its app, whose windows don't show while it's hidden),
    /// then up to 5 times brings it forward and waits 0.3 s for it to take the keys. `logName` is what the log calls it
    /// when `appName` could be a title (logs never hold titles).
    func activate(_ window: AppWindow, _ appName: String, logName: String? = nil) async throws -> DesktopResult {
        if let pid = pid_t(exactly: window.info.processId), isHidden(pid) {
            ax.set(kAXHiddenAttribute, false, of: ax.application(pid))
        }

        if (try? ax.number(kAXMinimizedAttribute, of: window.element)) == 1 {
            ax.set(kAXMinimizedAttribute, false, of: window.element)
        }

        for _ in 0..<5 {
            bringForward(window)
            for _ in 0..<6 {
                try await clock.pause(0.05)
                if window.info.sameWindow(foregroundWindow()) {
                    return .ok("\(appName) is ready.", window: window.info)
                }
            }
        }

        log("activation of \(logName ?? appName) refused by macOS")
        return .fail("macOS didn't let me bring \(appName) to the front. Click it once, then say “start typing”.")
    }

    /// C#'s `TrySetForeground`: the window becomes its app's main window and is raised, and its app comes to the front,
    /// through Accessibility (AXFrontmost, which works where NSRunningApplication's activation no longer does from
    /// macOS 14) and NSRunningApplication.
    func bringForward(_ window: AppWindow) {
        ax.set(kAXMainAttribute, true, of: window.element)
        ax.perform(kAXRaiseAction, on: window.element)
        guard let pid = pid_t(exactly: window.info.processId) else { return }
        ax.set(kAXFrontmostAttribute, true, of: ax.application(pid))
        workspace.activate(pid)
    }

    /// C#'s `FindAppWindows`: the windows of the app's running processes (by bundle identifier, ignoring case) whose
    /// title contains `windowTitleContains` (ignoring case), front-most first. Standard windows only, minimized ones
    /// too (they're restored): panels, alerts and Finder's desktop aren't, as Windows skips tool and owned windows.
    /// Untitled windows count, though Windows skips them: a Mac app's only window can have no title.
    func appWindows(_ app: AppEntry) -> [AppWindow] {
        let processes = workspace.runningApps().filter { running in
            running.processIdentifier != ownProcess
                && app.processNames.contains { DotNet.equalsOrdinalIgnoreCase($0, running.processName) }
        }

        var found: [AppWindow] = []
        for process in processes {
            for window in windows(of: process) {
                if let part = app.windowTitleContains, !TextUnits.contains(window.info.title, part) {
                    continue
                }

                found.append(window)
            }
        }

        return frontToBack(found)
    }

    /// The app's standard windows (AXStandardWindow, or windows that don't say what they are), minimized ones too, and
    /// a hidden app's. macOS calls a minimized window a dialog (AXDialog), and every window of a hidden app, as it
    /// calls an alert or a panel. Such a window counts when it's minimized, which an alert or a panel can't be; in a
    /// hidden app, only when it has a minimize button that works (`canMinimize`), as a document window has and an
    /// alert or an About panel hasn't. `stop` is asked before each window, and an app that doesn't answer isn't asked
    /// any more: the windows found until then.
    func windows(of process: RunningApp, until stop: () -> Bool = { false }) -> [AppWindow] {
        searchWindows(of: process, until: stop).windows
    }

    /// What asking an app for its windows (`windows(of:)`) came to.
    struct WindowSearch {
        var windows: [AppWindow] = []

        /// False when the app stopped answering, and wasn't asked any more.
        var answered = true

        /// Whether the app is hidden, when that was asked.
        var hidden: Bool?
    }

    /// `windows(of:)`, with whether the app answered and is hidden.
    func searchWindows(of process: RunningApp, until stop: () -> Bool) -> WindowSearch {
        let pid = process.processIdentifier
        var search = WindowSearch()
        let windows: [AnyObject]
        do {
            windows = try ax.elements(kAXWindowsAttribute, of: ax.application(pid))
        } catch {
            search.answered = false
            return search
        }

        for window in windows {
            if stop() {
                break
            }

            do {
                guard try ax.role(of: window) == kAXWindowRole else { continue }
                let subrole = try ax.subrole(of: window)
                if subrole == kAXDialogSubrole {
                    if try ax.number(kAXMinimizedAttribute, of: window) != 1 {
                        if search.hidden == nil {
                            search.hidden = try ax.number(kAXHiddenAttribute, of: ax.application(pid)) == 1
                        }

                        guard search.hidden == true, try canMinimize(window) else { continue }
                    }
                } else if subrole != nil && subrole != kAXStandardWindowSubrole {
                    continue
                }

                let title = try ax.string(kAXTitleAttribute, of: window) ?? ""
                let info = WindowInfo(
                    handle: ax.windowNumber(of: window) ?? 0, processId: Int(pid), processName: process.processName,
                    title: title, appName: process.name)
                search.windows.append(AppWindow(info: info, element: window))
            } catch {
                search.answered = false
                break
            }
        }

        return search
    }

    /// The window has a minimize button that works (kAXMinimizeButtonAttribute, enabled), as a document window has, and
    /// an alert or an About panel hasn't.
    func canMinimize(_ window: AnyObject) throws -> Bool {
        guard let button = try ax.element(kAXMinimizeButtonAttribute, of: window) else { return false }
        return try ax.number(kAXEnabledAttribute, of: button) != 0
    }

    /// Front-most first, in the window server's order of the windows on screen; the others (minimized, hidden) after,
    /// as they came.
    func frontToBack(_ windows: [AppWindow]) -> [AppWindow] {
        var rank: [Int: Int] = [:]
        for (index, number) in workspace.windowNumbersFrontToBack().enumerated() where rank[number] == nil {
            rank[number] = index
        }

        return DotNet.orderBy(windows) { rank[$0.info.handle] ?? Int.max }
    }

    // MARK: Web pages

    /// Opens an http(s) page (C#'s `OpenUrlAsync`): as a new tab of the browser in front, else in the default browser;
    /// then waits 8 s for a browser window to appear or change its title (the tab's), brings it to the front, and gives
    /// the page half a second to build its first elements. It opens `link.url`, never `absoluteUri`. (Windows first
    /// lets the browser take the front; macOS lets an app NSWorkspace opens take it.)
    public func openURL(_ link: WebLink) async throws -> DesktopResult {
        let url = link.url
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return .fail("I only open web links.")
        }

        var before: [Int: String] = [:]
        for window in browserWindows() where before[window.info.handle] == nil {
            before[window.info.handle] = window.info.title
        }

        let openedInFront = await openInBrowserInFront(url)
        if !openedInFront {
            do {
                try await workspace.open(url, withApplicationAt: nil)
            } catch {
                let failure = error as NSError
                log("open url failed: \(failure.domain) \(failure.code)")
                return .fail("Couldn't open the web browser.")
            }
        }

        let deadline = clock.now() + 8
        while clock.now() < deadline {
            try await clock.pause(0.25)
            guard let changed = browserWindows().first(where: { before[$0.info.handle] != $0.info.title }) else {
                continue
            }

            if !changed.info.sameWindow(foregroundWindow()) {
                let activated = try await activate(changed, "the browser")
                if !activated.success {
                    log("open url: opened, browser not in front")
                    return .ok("Opened the page in the browser.")
                }
            }

            try await clock.pause(0.5)
            log("open url: browser in front")
            return .ok("Opened the page.", window: foregroundWindow() ?? changed.info)
        }

        log("open url: browser window not seen")
        return .ok("Asked the browser to open the page.")
    }

    /// C#'s `OpenInBrowserInFront`: with a browser taking the keys, the page opens in it (a running browser makes it a
    /// new tab of its window). False when no browser is in front or it didn't take the page: the default browser opens
    /// it then.
    func openInBrowserInFront(_ url: URL) async -> Bool {
        guard let front = foregroundWindow(), BrainSafety.isBrowser(front, brainPlatform),
              let pid = pid_t(exactly: front.processId), let browser = workspace.app(pid)?.bundleURL else {
            return false
        }

        do {
            try await workspace.open(url, withApplicationAt: browser)
            log("open url: in the browser in front")
            return true
        } catch {
            let failure = error as NSError
            log("open url in the browser in front failed: \(failure.domain) \(failure.code)")
            return false
        }
    }

    /// C#'s `BrowserWindows`: the titled, unminimized windows of the browsers running (`BrainPlatform.mac`'s),
    /// front-most first.
    func browserWindows() -> [AppWindow] {
        var found: [AppWindow] = []
        for process in workspace.runningApps() where process.processIdentifier != ownProcess {
            guard brainPlatform.browserProcesses.contains(where: {
                DotNet.equalsOrdinalIgnoreCase($0, process.processName)
            }) else { continue }
            found += windows(of: process).filter { window in
                !window.info.title.isEmpty && (try? ax.number(kAXMinimizedAttribute, of: window.element)) != 1
            }
        }

        return frontToBack(found)
    }

    // MARK: Zoom

    /// "Maximize" on the Mac (`ShortcutKeys.mac.maximize` is `.zoomThroughAccessibility`, where Windows presses
    /// Win+Up): the window fills the usable part of its screen, without the menu bar and the Dock, its position and
    /// size set through Accessibility. Not full screen, which gives the window a Space of its own. The AI brain asks for
    /// it (`JarvisDesktop.zoom`) where a plan presses Windows' maximize keys.
    public func zoom(_ window: WindowInfo) async throws -> DesktopResult {
        let screens = await workspace.screens()
        let name = label(window)
        guard let element = windowElement(window), let frame = try? ax.frame(of: element) else {
            return .fail("I couldn't find \(name)'s window.")
        }

        guard let screen = Self.screen(of: frame, screens) else {
            return .fail("I couldn't tell which screen \(name) is on.")
        }

        if (try? ax.number(kAXMinimizedAttribute, of: element)) == 1 {
            ax.set(kAXMinimizedAttribute, false, of: element)
        }

        guard ax.setFrame(screen.visibleFrame, of: element) == .done else {
            log("zoom refused")
            return .fail("macOS didn't let me resize \(name).")
        }

        return .ok("\(name) fills the screen.", window: window)
    }
}
