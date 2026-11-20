import XCTest
@testable import VoiceAssistantCore

/// The shortcut commands press the keys of the parser's `ShortcutKeys`: Windows chords by default (the C# core's, so
/// the ported tests are unchanged), the Mac's with `.mac` (docs/design.md, "Mac shortcuts").
final class ShortcutKeysTests: XCTestCase {
    private func keys(_ phrase: String, _ map: ShortcutKeys) -> String? {
        let commands = CommandParser(keys: map).parse(phrase, .command).commands
        guard commands.count == 1, commands[0].kind == .pressKeys else { return nil }
        return commands[0].argument
    }

    func testMacShortcutsUseCommandWhereWindowsUsesCtrl() {
        let cases: [(String, String?)] = [
            ("copy", "Cmd+C"), ("paste that", "Cmd+V"), ("cut", "Cmd+X"), ("undo", "Cmd+Z"), ("redo", "Shift+Cmd+Z"),
            ("select all", "Cmd+A"), ("save the file", "Cmd+S"), ("new tab", "Cmd+T"), ("open a new tab", "Cmd+T"),
            ("close this tab", "Cmd+W"), ("refresh", "Cmd+R"), ("reload the page", "Cmd+R"),
        ]
        check(cases) { keys($0, .mac) }
    }

    func testMacBackForwardAndParentFolder() {
        let cases: [(String, String?)] = [
            ("go back", "Cmd+["), ("take me back", "Cmd+["), ("go to the previous page", "Cmd+["),
            ("go forward", "Cmd+]"), ("go to the next page", "Cmd+]"), ("parent folder", "Cmd+Up"),
            ("go up one level", "Cmd+Up"),
        ]
        check(cases) { keys($0, .mac) }
    }

    func testKeysThePlatformsShareAreTheSame() {
        let cases: [(String, String?)] = [
            ("next tab", "Ctrl+Tab"), ("previous tab", "Ctrl+Shift+Tab"), ("scroll down", "PageDown"),
            ("page up", "PageUp"), ("press enter", "Enter"), ("press shift tab", "Shift+Tab"),
        ]
        check(cases) { keys($0, .mac) }
        check(cases) { keys($0, .windows) }
    }

    func testWindowsKeepsTheCSharpChords() {
        let cases: [(String, String?)] = [
            ("copy", "Ctrl+C"), ("redo", "Ctrl+Y"), ("go back", "Alt+Left"), ("go forward", "Alt+Right"),
            ("parent folder", "Alt+Up"), ("refresh", "F5"), ("new tab", "Ctrl+T"), ("close tab", "Ctrl+W"),
        ]
        check(cases) { keys($0, .windows) }
        check(cases) { keys($0, CommandParser().keys) }
    }

    func testEveryShortcutHasDifferentKeysOnTheMacUnlessShared() {
        let shared: Set<String> = ["Ctrl+Tab", "Ctrl+Shift+Tab", "PageDown", "PageUp"]
        for shortcut in Shortcut.allCases {
            let windows = ShortcutKeys.windows.keys(for: shortcut)
            let mac = ShortcutKeys.mac.keys(for: shortcut)
            XCTAssertEqual(shared.contains(windows), windows == mac, "\(shortcut)")
            XCTAssertFalse(mac.contains("Win"), "\(shortcut)")
        }
    }
}
