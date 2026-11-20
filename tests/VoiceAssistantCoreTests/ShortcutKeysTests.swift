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

    /// Every chord the interaction controller presses on the Mac is in the grammar `ShortcutKeys` documents for the
    /// desktop: the shortcut and "press …" commands', the keys an exact edit moves and selects with, and the default
    /// send and new line keys of an app. (`BrainKeysTests` checks the brain's, and `BrainControllerMacTests`' desktop
    /// every chord it is asked to press.)
    func testEveryChordTheControllerPressesOnTheMacParses() {
        let phrases = [
            "press enter", "press return", "press tab", "press escape", "press backspace", "press delete",
            "press space", "press up", "press down", "press left", "press right", "press the up arrow key",
            "press down arrow", "press left arrow", "press right arrow", "press page up", "press page down",
            "press home", "press end", "press shift tab", "select all", "copy", "paste", "cut", "undo", "redo", "save",
            "new tab", "close tab", "next tab", "previous tab", "go back", "go forward", "parent folder", "refresh",
            "scroll down", "scroll up",
        ]
        for phrase in phrases {
            guard let chord = keys(phrase, .mac) else {
                XCTFail("\(phrase): no keys")
                continue
            }

            XCTAssertTrue(ChordGrammar.parses(chord, mac: true), "\(phrase): \(chord)")
        }

        let app = AppEntry(name: "App", launch: "app")
        let edits = ["Left", "Shift+Left", "Right", ShortcutKeys.mac.deleteWordBefore]
        for chord in edits + [app.submitKeys, app.newLineKeys] {
            XCTAssertTrue(ChordGrammar.parses(chord, mac: true), chord)
        }
    }
}
