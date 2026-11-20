import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// A desktop that does nothing; each one names its platform, since `brainPlatform` has no default.
private protocol QuietDesktop: JarvisDesktop {}

extension QuietDesktop {
    func foregroundWindow() -> WindowInfo? { nil }

    func openOrActivate(_ app: AppEntry, newWindow: Bool) async throws -> DesktopResult { .fail("") }

    func prepareTextTarget(_ window: WindowInfo, profile: AppEntry?) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "")
    }

    func focusSearchBox(_ window: WindowInfo) async throws -> TextTargetResult {
        TextTargetResult(success: false, message: "")
    }

    func checkFocusedField() -> AssistantFieldCheck { .unknown }

    func focusedTextEndsWithNonWhitespace() -> Bool? { nil }

    func typeText(_ text: String) throws {}

    func pressKeys(_ chord: String) throws {}

    func backspace(_ count: Int) throws {}
}

private final class WindowsDesktop: QuietDesktop {
    var brainPlatform: BrainPlatform { .windows }
}

private final class MacDesktop: QuietDesktop {
    var brainPlatform: BrainPlatform { .mac }
}

/// What the brain's limits mean on each platform: where it never types, the browsers and the file manager, the button
/// words and the program files. Windows has the C# core's lists; the Mac has docs/design.md's ("Where it never
/// types"), by bundle identifier.
final class BrainPlatformTests: XCTestCase {
    private func window(_ processName: String) -> WindowInfo {
        WindowInfo(handle: 9, processId: 9, processName: processName, title: "")
    }

    private func isCommand(_ processName: String, _ platform: BrainPlatform) -> Bool {
        BrainSafety.isCommandWindow(window(processName), platform)
    }

    private func isBrowser(_ processName: String, _ platform: BrainPlatform) -> Bool {
        BrainSafety.isBrowser(window(processName), platform)
    }

    func testWindowsNeverTypesInTerminalsLaunchersOrFileExplorer() {
        check([
            ("cmd", true), ("pwsh", true), ("WindowsTerminal", true), ("windowsterminal", true), ("wsl", true),
            ("Taskmgr", true), ("SearchHost", true), ("PowerToys.PowerLauncher", true), ("Microsoft.CmdPal.UI", true),
            ("EXPLORER", true), ("chrome", false), ("Notepad", false), ("com.apple.Terminal", false),
            ("com.apple.finder", false),
        ]) { isCommand($0, .windows) }
    }

    func testTheMacNeverTypesInTerminalsLaunchersSettingsOrFinder() {
        // Real bundle identifiers, as the Mac desktop reports the app that has the keyboard focus.
        check([
            ("com.apple.Terminal", true), ("COM.APPLE.TERMINAL", true), ("com.googlecode.iterm2", true),
            ("dev.warp.Warp-Stable", true), ("com.mitchellh.ghostty", true), ("net.kovidgoyal.kitty", true),
            ("org.alacritty", true), ("com.github.wez.wezterm", true), ("co.zeit.hyper", true), ("org.tabby", true),
            ("com.apple.Spotlight", true), ("com.raycast.macos", true), ("com.runningwithcrayons.Alfred", true),
            ("at.obdev.LaunchBar", true), ("com.apple.ScriptEditor2", true), ("com.apple.Automator", true),
            ("com.apple.shortcuts", true), ("com.apple.systempreferences", true), ("com.apple.SecurityAgent", true),
            ("com.apple.loginwindow", true), ("com.apple.ActivityMonitor", true), ("com.apple.DiskUtility", true),
            ("com.apple.keychainaccess", true), ("com.apple.finder", true), ("com.apple.Safari", false),
            ("com.apple.Notes", false), ("com.apple.TextEdit", false), ("com.apple.mail", false),
            ("com.microsoft.VSCode", false), ("com.tinyspeck.slackmacgap", false), ("WindowsTerminal", false),
            ("explorer", false), ("cmd", false),
        ]) { isCommand($0, .mac) }
    }

    func testTheMacMatchesBundleIdentifiersOnly() {
        // Executable and localized names vary: Warp's executable is "stable", WezTerm's "wezterm-gui", and Script
        // Editor is "Skripteditor" in German.
        let names = [
            "Terminal", "iTerm2", "stable", "wezterm-gui", "Spotlight", "Raycast", "Script Editor", "Skripteditor",
            "Automator", "Finder", "Safari", "Google Chrome", "firefox", "zen",
        ]
        for name in names {
            XCTAssertFalse(isCommand(name, .mac), name)
            XCTAssertFalse(isBrowser(name, .mac), name)
            XCTAssertFalse(BrainSafety.isShellItem(window(name), .listItem, .mac), name)
        }

        let mac = BrainPlatform.mac
        for id in mac.commandProcesses + mac.browserProcesses + mac.fileManagerProcesses {
            XCTAssertTrue(id.contains(".") && !id.contains(" "), id)
        }
    }

    func testBrowsersAreTheirOwnOnEachPlatform() {
        check([
            ("chrome", true), ("MSEDGE", true), ("firefox", true), ("arc", true), ("librewolf", true),
            ("com.apple.Safari", false), ("explorer", false),
        ]) { isBrowser($0, .windows) }
        check([
            ("com.apple.Safari", true), ("com.google.Chrome", true), ("com.microsoft.edgemac", true),
            ("org.mozilla.firefox", true), ("company.thebrowser.Browser", true), ("com.brave.Browser", true),
            ("com.operasoftware.Opera", true), ("com.vivaldi.Vivaldi", true), ("net.librewolf.librewolf", true),
            ("io.gitlab.librewolf-community.librewolf", true), ("net.waterfox.waterfox", true),
            ("one.ablaze.floorp", true), ("net.mullvad.mullvadbrowser", true), ("com.apple.finder", false),
            ("com.apple.Terminal", false), ("msedge", false),
        ]) { isBrowser($0, .mac) }
    }

    func testOpeningAFileInTheFileManagerNeedsAYes() {
        let explorer = window("explorer")
        let finder = window("com.apple.finder")
        XCTAssertTrue(BrainSafety.isShellItem(explorer, .listItem, .windows))
        XCTAssertFalse(BrainSafety.isShellItem(explorer, .button, .windows))
        XCTAssertFalse(BrainSafety.isShellItem(finder, .listItem, .windows))
        XCTAssertTrue(BrainSafety.isShellItem(finder, .listItem, .mac))
        XCTAssertTrue(BrainSafety.isShellItem(window("COM.APPLE.FINDER"), .listItem, .mac))
        XCTAssertFalse(BrainSafety.isShellItem(finder, .link, .mac))
        XCTAssertFalse(BrainSafety.isShellItem(explorer, .listItem, .mac))
        XCTAssertEqual("File Explorer", BrainPlatform.windows.fileManagerName)
        XCTAssertEqual("Finder", BrainPlatform.mac.fileManagerName)
    }

    func testTheMacAsksBeforeForceQuitAndOpenAnyway() {
        // As "End task" and "Run anyway" ask on Windows.
        check([
            ("Force Quit", true), ("Open Anyway", true), ("End task", true), ("Run anyway", true), ("Send", true),
            ("Open", false), ("Quit", false), ("Force quitting apps", false),
        ]) { BrainSafety.isSendLike($0, .mac) }
        check([("Force Quit", false), ("Open Anyway", false), ("End task", true), ("Run anyway", true)]) {
            BrainSafety.isSendLike($0, .windows)
        }
    }

    func testTheMacsProgramFilesAreItsAppsScriptsPackagesAndLinks() {
        check([
            ("Utilities.app", true), ("Backup.command", true), ("cleanup.tool", true), ("Homebrew.terminal", true),
            ("Install Office.pkg", true), ("Office.mpkg", true), ("Bank login.webloc", true), ("Site.inetloc", true),
            ("Applications.fileloc", true), ("VPN.mobileconfig", true), ("Helper.prefPane", true),
            ("Installer.PKG, 2 MB", true), ("setup.exe", true), ("Notes.txt", false), ("Apple Support", false),
            ("Report.pdf", false), ("Steps to install.md", false), ("App Store", false),
        ]) { BrainSafety.runsProgram($0, .mac) }
        check([("Install Office.pkg", false), ("Utilities.app", false), ("Bank login.webloc", false)]) {
            BrainSafety.runsProgram($0, .windows)
        }
    }

    func testWindowsKeepsTheCSharpPatternForProgramFiles() {
        XCTAssertEqual(
            #"\.(exe|bat|cmd|com|ps1|psm1|vbs|vbe|js|jse|wsf|wsh|msi|msix|msixbundle|appx|appxbundle|scr|hta|jar|"#
                + #"reg|lnk|cpl|inf|url|application)\s*(,|$)"#,
            BrainPlatform.windows.programFilePattern)
    }

    func testEachDesktopNamesItsPlatform() {
        let pc = WindowsDesktop()
        XCTAssertEqual(.windows, pc.brainPlatform)
        XCTAssertTrue(pc.isCommandWindow(window("WindowsTerminal")))
        XCTAssertFalse(pc.isCommandWindow(window("com.apple.Terminal")))

        let mac = MacDesktop()
        XCTAssertEqual(.mac, mac.brainPlatform)
        XCTAssertNotEqual(BrainPlatform.windows, mac.brainPlatform)
        XCTAssertTrue(mac.isCommandWindow(window("com.apple.Terminal")))
        XCTAssertTrue(mac.isCommandWindow(window("com.apple.finder")))
        XCTAssertFalse(mac.isCommandWindow(window("WindowsTerminal")))
    }
}
