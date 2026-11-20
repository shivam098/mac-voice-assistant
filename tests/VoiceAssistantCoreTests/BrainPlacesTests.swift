import ThumbFreeCore
import XCTest
@testable import VoiceAssistantCore

/// A desktop that does nothing but say which platform it is.
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

private final class DefaultDesktop: QuietDesktop {}

private final class MacDesktop: QuietDesktop {
    var brainPlaces: BrainPlaces { .mac }
}

/// Where the brain never types, the browsers and the file managers, per platform: the C# core's lists on Windows, and
/// docs/design.md's on the Mac ("Where it never types").
final class BrainPlacesTests: XCTestCase {
    private func window(_ processName: String) -> WindowInfo {
        WindowInfo(handle: 9, processId: 9, processName: processName, title: "")
    }

    private func isCommand(_ processName: String, _ places: BrainPlaces) -> Bool {
        BrainSafety.isCommandWindow(window(processName), places)
    }

    private func isBrowser(_ processName: String, _ places: BrainPlaces) -> Bool {
        BrainSafety.isBrowser(window(processName), places)
    }

    func testWindowsNeverTypesInTerminalsLaunchersOrFileExplorer() {
        check([
            ("cmd", true), ("pwsh", true), ("WindowsTerminal", true), ("windowsterminal", true), ("wsl", true),
            ("Taskmgr", true), ("SearchHost", true), ("PowerToys.PowerLauncher", true), ("Microsoft.CmdPal.UI", true),
            ("EXPLORER", true), ("chrome", false), ("Notepad", false), ("Terminal", false), ("Finder", false),
        ]) { isCommand($0, .windows) }
    }

    func testTheMacNeverTypesInTerminalsSpotlightOrFinder() {
        check([
            ("Terminal", true), ("com.apple.Terminal", true), ("terminal", true), ("iTerm2", true), ("stable", true),
            ("dev.warp.Warp-Stable", true), ("ghostty", true), ("kitty", true), ("Alacritty", true),
            ("wezterm-gui", true), ("Spotlight", true), ("com.apple.Spotlight", true), ("Raycast", true),
            ("Alfred", true), ("Script Editor", true), ("Finder", true), ("com.apple.finder", true),
            ("Safari", false), ("Notes", false), ("TextEdit", false), ("WindowsTerminal", false), ("explorer", false),
            ("cmd", false),
        ]) { isCommand($0, .mac) }
    }

    func testBrowsersAreTheirOwnOnEachPlatform() {
        check([
            ("chrome", true), ("MSEDGE", true), ("firefox", true), ("arc", true), ("Safari", false),
            ("explorer", false),
        ]) { isBrowser($0, .windows) }
        check([
            ("Safari", true), ("com.apple.Safari", true), ("Google Chrome", true), ("com.google.Chrome", true),
            ("Microsoft Edge", true), ("firefox", true), ("Arc", true), ("Brave Browser", true), ("Finder", false),
            ("Terminal", false), ("msedge", false),
        ]) { isBrowser($0, .mac) }
    }

    func testOpeningAFileInTheFileManagerNeedsAYes() {
        let explorer = window("explorer")
        let finder = window("Finder")
        XCTAssertTrue(BrainSafety.isShellItem(explorer, .listItem))
        XCTAssertFalse(BrainSafety.isShellItem(explorer, .button))
        XCTAssertFalse(BrainSafety.isShellItem(finder, .listItem))
        XCTAssertTrue(BrainSafety.isShellItem(finder, .listItem, .mac))
        XCTAssertTrue(BrainSafety.isShellItem(window("com.apple.finder"), .listItem, .mac))
        XCTAssertFalse(BrainSafety.isShellItem(finder, .link, .mac))
        XCTAssertFalse(BrainSafety.isShellItem(explorer, .listItem, .mac))
    }

    func testTheDesktopSaysWhichPlacesAreItsPlatforms() {
        let pc = DefaultDesktop()
        XCTAssertEqual(.windows, pc.brainPlaces)
        XCTAssertTrue(pc.isCommandWindow(window("WindowsTerminal")))
        XCTAssertFalse(pc.isCommandWindow(window("Terminal")))

        let mac = MacDesktop()
        XCTAssertNotEqual(.windows, mac.brainPlaces)
        XCTAssertTrue(mac.isCommandWindow(window("Terminal")))
        XCTAssertTrue(mac.isCommandWindow(window("Finder")))
        XCTAssertFalse(mac.isCommandWindow(window("WindowsTerminal")))
    }
}
