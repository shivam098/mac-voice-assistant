import ApplicationServices
import Carbon.HIToolbox
import ThumbFreeMac
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// The window in front, opening and activating apps (C#'s `OpenOrActivateAsync`, `ActivateAsync`, `FindAppWindows`),
/// opening web pages (`OpenUrlAsync`), the installed apps (`StartMenuApps`), zooming, and the names and places.
final class AppsTests: XCTestCase {
    private static let textEdit = AppEntry(
        name: "TextEdit", launch: "com.apple.TextEdit", processNames: ["com.apple.TextEdit"],
        newWindowKeys: "Cmd+N", newDocumentKeys: "Cmd+N")

    /// Setting AXMain on a window makes it its app's focused window, and AXFrontmost on an app makes it take the keys,
    /// as macOS does.
    private func activates(_ rig: Rig) {
        rig.ax.onSet = { [unowned rig] element, attribute, value in
            guard value else { return }
            if attribute == kAXMainAttribute {
                rig.ax.apps[element.pid]?[kAXFocusedWindowAttribute] = element
            } else if attribute == kAXFrontmostAttribute {
                rig.ax.focusedApp = element
                rig.ax.focused = nil
            }
        }
    }

    /// TextEdit running with a window that isn't in front, Finder taking the keys.
    @discardableResult
    private func textEditBehindFinder(_ rig: Rig) -> FakeElement {
        let textEditWindow = rig.front(42, "com.apple.TextEdit", "TextEdit")
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, title: "Documents", number: 80))
        return textEditWindow
    }

    // MARK: The window in front

    func testTheWindowInFrontIsTheAppTakingTheKeys() {
        let rig = Rig()
        rig.front(42, "com.apple.TextEdit", "TextEdit", window: .window(title: "Notes.txt", number: 7))
        let expected = WindowInfo(
            handle: 7, processId: 42, processName: "com.apple.TextEdit", title: "Notes.txt", appName: "TextEdit")
        XCTAssertEqual(expected, rig.desktop.foregroundWindow())
        XCTAssertEqual("TextEdit", rig.desktop.appName(rig.desktop.foregroundWindow()!))

        // Spotlight's panel takes the keys while the app before it stays in front.
        rig.workspace.front = rig.workspace.app(42)
        rig.front(5, "com.apple.Spotlight", "Spotlight", window: .window(pid: 5, number: 50))
        XCTAssertEqual("com.apple.Spotlight", rig.desktop.foregroundWindow()?.processName)
    }

    func testNoWindowForThisAppOrWithoutAnAnswer() {
        let rig = Rig()
        rig.front(Rig.own, "io.github.shivam098.voiceassistant", "Voice Assistant")
        XCTAssertNil(rig.desktop.foregroundWindow())

        rig.front()
        rig.ax.answers = false
        XCTAssertNil(rig.desktop.foregroundWindow())
    }

    /// An app taking the keys without a window (Finder with none open) is still in front: handle 0, no title.
    func testAnAppWithoutAWindow() {
        let rig = Rig()
        rig.front(8, "com.apple.finder", "Finder")
        rig.ax.focusedApp?[kAXFocusedWindowAttribute] = nil
        XCTAssertEqual(
            WindowInfo(handle: 0, processId: 8, processName: "com.apple.finder", title: "", appName: "Finder"),
            rig.desktop.foregroundWindow())
    }

    /// The core's places by bundle identifier, and by the window's process should its name say otherwise.
    func testCommandWindowsByBundleIdentifier() {
        let rig = Rig()
        rig.workspace.run(3, "com.apple.Terminal", "Terminal")
        func window(_ pid: Int, _ processName: String) -> WindowInfo {
            WindowInfo(handle: 1, processId: pid, processName: processName, title: "")
        }

        XCTAssertTrue(rig.desktop.isCommandWindow(window(3, "com.apple.Terminal")))
        XCTAssertTrue(rig.desktop.isCommandWindow(window(3, "Terminal")))
        XCTAssertTrue(rig.desktop.isCommandWindow(window(99, "com.apple.finder")))
        XCTAssertFalse(rig.desktop.isCommandWindow(window(42, "com.apple.TextEdit")))
        XCTAssertEqual(.mac, rig.desktop.brainPlatform)
    }

    // MARK: Opening apps

    func testActivatesTheAppsWindow() async throws {
        let rig = Rig()
        activates(rig)
        let window = textEditBehindFinder(rig)
        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertEqual("TextEdit is ready.", result.message)
        XCTAssertTrue(result.success)
        XCTAssertEqual(420, result.window?.handle)
        XCTAssertEqual(["AXRaise"], window.actions)
        XCTAssertEqual([42], rig.workspace.activated)
        XCTAssertTrue(rig.workspace.launched.isEmpty)
    }

    /// Five tries, each waiting 0.3 s for the window to take the keys.
    func testSaysWhenMacOSWontBringItForward() async throws {
        let rig = Rig()
        let window = textEditBehindFinder(rig)
        let start = rig.time.now
        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertEqual(
            DesktopResult.fail(
                "macOS didn't let me bring TextEdit to the front. Click it once, then say “start typing”."),
            result)
        XCTAssertEqual(5, window.actions.count)
        XCTAssertEqual(1.5, rig.time.now - start, accuracy: 0.001)
        XCTAssertTrue(rig.log.lines.contains("activation of TextEdit refused by macOS"))
    }

    func testRestoresAMinimizedWindow() async throws {
        let rig = Rig()
        activates(rig)
        let window = textEditBehindFinder(rig)
        window[kAXMinimizedAttribute] = true
        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual("AXMinimized=false", window.changes.first)
    }

    /// "Open TextEdit" with TextEdit open means a fresh window: its new-window keys, then the window that wasn't there.
    func testOpensANewWindow() async throws {
        let rig = Rig()
        activates(rig)
        textEditBehindFinder(rig)
        rig.keys.onPost = { [unowned rig] chord in
            guard chord == PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_N), modifiers: .command) else { return }
            rig.front(42, window: .window(title: "Untitled 2", number: 421))
        }

        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: true)
        XCTAssertEqual(DesktopResult.ok("Opened a new TextEdit window.", window: result.window), result)
        XCTAssertEqual(421, result.window?.handle)
    }

    func testSaysWhenNoNewWindowCame() async throws {
        let rig = Rig()
        activates(rig)
        textEditBehindFinder(rig)
        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: true)
        XCTAssertEqual(
            DesktopResult.fail("TextEdit didn't open a new window. Say “switch to TextEdit” to use the open one."),
            result)
        XCTAssertEqual(1, rig.keys.posted.count)
    }

    /// An app that isn't running is started by bundle identifier; its window is brought forward, and an app with
    /// new-document keys gets a blank document.
    func testStartsTheApp() async throws {
        let rig = Rig()
        activates(rig)
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, number: 80))
        let url = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        rig.workspace.installed["com.apple.TextEdit"] = url
        rig.workspace.onLaunch = { [unowned rig] _ in
            let app = FakeElement.app(pid: 42)
            app[kAXWindowsAttribute] = [FakeElement.window(title: "Untitled", number: 420)]
            rig.ax.apps[42] = app
            rig.workspace.run(42, "com.apple.TextEdit", "TextEdit")
        }

        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertEqual("TextEdit is ready.", result.message)
        XCTAssertEqual(420, result.window?.handle)
        XCTAssertEqual([url], rig.workspace.launched)
        XCTAssertEqual([PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_N), modifiers: .command)], rig.keys.posted)
    }

    func testSaysWhenTheAppCantStart() async throws {
        let rig = Rig()
        var result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertEqual(DesktopResult.fail("Couldn't start TextEdit."), result)
        XCTAssertTrue(rig.workspace.launched.isEmpty)

        rig.workspace.installed["com.apple.TextEdit"] = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        rig.workspace.launchError = NSError(domain: NSCocoaErrorDomain, code: 4)
        result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertEqual(DesktopResult.fail("Couldn't start TextEdit."), result)
        XCTAssertTrue(rig.log.lines.contains("launch failed: NSCocoaErrorDomain 4"))
    }

    /// 15 s for the window, looked for every 0.25 s.
    func testSaysWhenTheWindowNeverCame() async throws {
        let rig = Rig()
        rig.workspace.installed["com.apple.TextEdit"] = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let start = rig.time.now
        let result = try await rig.desktop.openOrActivate(Self.textEdit, newWindow: false)
        XCTAssertEqual(DesktopResult.fail("TextEdit is starting, but its window didn't appear."), result)
        XCTAssertEqual(15, rig.time.now - start, accuracy: 0.3)
    }

    /// An app started by its path, with no bundle identifier to find it by: any new window in front says it opened.
    func testAnAppWithoutABundleIdentifier() async throws {
        let rig = Rig()
        let tool = AppEntry(name: "Tool", launch: "~/Applications/Tool.app")
        rig.front(8, "com.apple.finder", "Finder", window: .window(pid: 8, number: 80))
        var result = try await rig.desktop.openOrActivate(tool, newWindow: false)
        XCTAssertEqual(DesktopResult.ok("Asked macOS to open Tool."), result)
        XCTAssertEqual("/Applications/Tool.app", rig.workspace.launched.first?.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: ""))

        rig.workspace.onLaunch = { [unowned rig] _ in rig.front(77, "", "Tool", window: .window(pid: 77, number: 770)) }
        result = try await rig.desktop.openOrActivate(tool, newWindow: false)
        XCTAssertEqual(DesktopResult.ok("Opened Tool."), result)
    }

    /// The app's standard windows whose title has `windowTitleContains`, front-most first by the window server's
    /// order; panels aren't the app's windows.
    func testFindsTheAppsWindowsFrontMostFirst() {
        let rig = Rig()
        let app = FakeElement.app(pid: 42)
        let panel = FakeElement.window(title: "Fonts", number: 1)
        panel[kAXSubroleAttribute] = kAXFloatingWindowSubrole
        let back = FakeElement.window(title: "Copilot Chat", number: 2)
        let front = FakeElement.window(title: "Copilot Chat 2", number: 3)
        let other = FakeElement.window(title: "Settings", number: 4)
        app[kAXWindowsAttribute] = [panel, back, front, other]
        rig.ax.apps[42] = app
        rig.workspace.run(42, "com.github.copilot", "Copilot")
        rig.workspace.windowOrder = [9, 3, 1, 2]
        let copilot = AppEntry(
            name: "Copilot", launch: "com.github.copilot", processNames: ["COM.GITHUB.COPILOT"],
            windowTitleContains: "copilot chat")
        XCTAssertEqual([3, 2], rig.desktop.appWindows(copilot).map(\.info.handle))
    }

    // MARK: Web pages

    private func link(_ text: String) -> WebLink { BrainSafety.normalizeUrl(text)! }

    /// With a browser taking the keys, the page opens in it; its window's title changing says the page is there.
    func testOpensAPageInTheBrowserInFront() async throws {
        let rig = Rig()
        let window = rig.front(
            9, "com.google.Chrome", "Google Chrome", window: .window(pid: 9, title: "Inbox", number: 90))
        rig.workspace.onOpen = { _, _ in window[kAXTitleAttribute] = "YouTube" }
        let result = try await rig.desktop.openURL(link("youtube.com"))
        XCTAssertEqual("Opened the page.", result.message)
        XCTAssertEqual(90, result.window?.handle)
        XCTAssertEqual(URL(string: "https://youtube.com/"), rig.workspace.opened.first?.url)
        XCTAssertEqual(URL(fileURLWithPath: "/Applications/Google Chrome.app"), rig.workspace.opened.first?.app)
    }

    /// Without a browser in front, the default browser opens it, and its new window is brought forward.
    func testOpensAPageInTheDefaultBrowser() async throws {
        let rig = Rig()
        activates(rig)
        rig.front()
        rig.workspace.onOpen = { [unowned rig] _, _ in
            let safari = FakeElement.app(pid: 11)
            safari[kAXWindowsAttribute] = [FakeElement.window(pid: 11, title: "Example", number: 110)]
            rig.ax.apps[11] = safari
            rig.workspace.run(11, "com.apple.Safari", "Safari")
        }

        let result = try await rig.desktop.openURL(link("example.com"))
        XCTAssertEqual(DesktopResult.ok("Opened the page.", window: result.window), result)
        XCTAssertEqual(110, result.window?.handle)
        XCTAssertNil(rig.workspace.opened.first?.app)
    }

    func testSaysWhatHappenedWhenNoPageShowed() async throws {
        let rig = Rig()
        rig.front()
        rig.workspace.openError = NSError(domain: NSCocoaErrorDomain, code: 1)
        var result = try await rig.desktop.openURL(link("example.com"))
        XCTAssertEqual(DesktopResult.fail("Couldn't open the web browser."), result)

        rig.workspace.openError = nil
        result = try await rig.desktop.openURL(link("example.com"))
        XCTAssertEqual(DesktopResult.ok("Asked the browser to open the page."), result)
    }

    // MARK: Installed apps

    /// The bundles in the three folders and the folders in them, then running apps found nowhere else; named as Finder
    /// shows them, with the file's name too when that differs.
    func testDiscoversTheInstalledApps() {
        let rig = Rig()
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let system = URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        let utilities = system.appendingPathComponent("Utilities", isDirectory: true)
        func bundle(_ folder: URL, _ file: String, _ id: String?, _ name: String) -> FolderItem {
            let url = folder.appendingPathComponent(file + ".app")
            rig.workspace.bundles[url] = AppBundle(url: url, bundleIdentifier: id, displayName: name)
            return FolderItem(url: url, isFolder: false)
        }

        rig.workspace.folders[applications] = [
            bundle(applications, "Safari", "com.apple.Safari", "Safari"),
            bundle(applications, "Google Chrome", "com.google.Chrome", "Google Chrome"),
            FolderItem(url: applications.appendingPathComponent("notes.txt"), isFolder: false),
        ]
        rig.workspace.folders[system] = [
            bundle(system, "Calculator", "com.apple.calculator", "Rechner"),
            bundle(system, "Safari", "com.apple.Safari", "Safari"),
            FolderItem(url: utilities, isFolder: true),
        ]
        rig.workspace.folders[utilities] = [bundle(utilities, "Terminal", "com.apple.Terminal", "Terminal")]
        rig.workspace.run(8, "com.apple.finder", "Finder")
        rig.workspace.running.append(RunningApp(
            processIdentifier: 9, bundleIdentifier: "com.apple.dock", name: "Dock",
            bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app"), isRegular: false))

        let apps = rig.desktop.discoverApps()
        XCTAssertEqual(["Finder", "Google Chrome", "Rechner", "Safari", "Terminal"], apps.map(\.name))
        let calculator = apps.first { $0.name == "Rechner" }
        XCTAssertEqual(["Calculator"], calculator?.aliases)
        XCTAssertEqual("com.apple.calculator", calculator?.launch)
        XCTAssertEqual(["com.apple.calculator"], calculator?.processNames)
        XCTAssertEqual([], apps.first { $0.name == "Safari" }?.aliases)
        XCTAssertTrue(rig.log.lines.contains("installed apps discovered: 5"))
    }

    /// An app without a bundle identifier is started by its path.
    func testAnAppWithoutABundleIdentifierIsStartedByPath() {
        let rig = Rig()
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let url = applications.appendingPathComponent("Old.app")
        rig.workspace.bundles[url] = AppBundle(url: url, bundleIdentifier: nil, displayName: "Old")
        rig.workspace.folders[applications] = [FolderItem(url: url, isFolder: false)]
        let apps = rig.desktop.discoverApps()
        XCTAssertEqual([AppEntry(name: "Old", launch: url.path)], apps)
    }

    // MARK: Zoom and permissions

    /// The window fills the usable part of the screen it's on.
    func testZoomFillsTheScreen() async throws {
        let rig = Rig()
        let frame = CGRect(x: 1600, y: 100, width: 400, height: 300)
        let window = rig.front(window: .window(title: "Notes", number: 5, frame: frame))
        let wide = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        rig.workspace.screenAreas = [
            ScreenArea(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800)),
            ScreenArea(frame: wide, visibleFrame: wide),
        ]
        let result = try await rig.desktop.zoom(rig.desktop.foregroundWindow()!)
        XCTAssertEqual("TextEdit fills the screen.", result.message)
        XCTAssertEqual(wide, window.frame)
    }

    func testListsMissingPermissions() {
        let rig = Rig()
        XCTAssertEqual([], rig.desktop.missingPermissions)
        rig.permissions.mayPost = false
        XCTAssertEqual([.postEvents], rig.desktop.missingPermissions)
        rig.permissions.trusted = false
        XCTAssertEqual([.accessibility, .postEvents], rig.desktop.missingPermissions)
    }
}
