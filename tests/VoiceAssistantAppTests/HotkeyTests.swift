import Carbon
import ThumbFreeMac
import XCTest
@testable import VoiceAssistantApp

/// The pause, paste-last and language hotkeys: read as Windows' `GlobalHotkey.Parse` reads them, with Windows' defaults
/// meaning the Mac's.
final class HotkeyTests: XCTestCase {
    func testAChordIsReadAsWindowsReadsIt() throws {
        let space = HotkeyChord(modifiers: [.control, .shift], key: .code(UInt16(kVK_Space)))
        XCTAssertEqual(try HotkeyChord.parse("Ctrl+Shift+Space"), space)
        XCTAssertEqual(try HotkeyChord.parse(" shift + CONTROL ++ space "), space)
        XCTAssertEqual(
            try HotkeyChord.parse("Alt+Shift+Z"), HotkeyChord(modifiers: [.option, .shift], key: .character("z")))
        XCTAssertEqual(
            try HotkeyChord.parse("Win+F12"), HotkeyChord(modifiers: [.command], key: .code(UInt16(kVK_F12))))
        XCTAssertEqual(
            try HotkeyChord.parse("Cmd+Option+Enter"),
            HotkeyChord(modifiers: [.command, .option], key: .code(UInt16(kVK_Return))))
        XCTAssertEqual(try HotkeyChord.parse("Ctrl+7"), HotkeyChord(modifiers: [.control], key: .character("7")))
    }

    func testAChordItCantUseIsRefusedInWindowsWords() {
        for (chord, message) in [
            ("Space", "Hotkey 'Space' needs a modifier and a key."),
            ("Ctrl+Shift", "Hotkey 'Ctrl+Shift' needs a modifier and a key."),
            ("Ctrl+Hyper", "Unknown key 'Hyper'."),
            ("Ctrl+F21", "Unknown key 'F21'."),
        ] {
            XCTAssertThrowsError(try HotkeyChord.parse(chord), chord) { error in
                XCTAssertEqual((error as? HotkeyChord.Problem)?.message, message)
            }
        }
    }

    /// A settings.json copied from Windows: its default hotkeys mean the Mac's, anything else is used as written, and
    /// the file keeps what it says.
    func testWindowsDefaultHotkeysMeanTheMacsOnes() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.macHotkey, "Ctrl+Shift+Space")
        XCTAssertEqual(settings.macPasteLastHotkey, "Ctrl+Shift+Z")
        XCTAssertEqual(settings.macDictationLanguageHotkey, "Ctrl+Shift+H")

        settings.hotkey = "Ctrl+Alt+Space"
        settings.pasteLastHotkey = "Alt+Shift+Z"
        settings.dictationLanguageHotkey = "shift+alt+h"
        XCTAssertEqual(settings.macHotkey, "Ctrl+Shift+Space")
        XCTAssertEqual(settings.macPasteLastHotkey, "Ctrl+Shift+Z")
        XCTAssertEqual(settings.macDictationLanguageHotkey, "Ctrl+Shift+H")
        let file = try XCTUnwrap(AppSettings.parse(settings.fileText()))
        XCTAssertEqual(file.hotkey, "Ctrl+Alt+Space")
        XCTAssertEqual(file.pasteLastHotkey, "Alt+Shift+Z")

        settings.hotkey = "Ctrl+Alt+K"
        settings.pasteLastHotkey = "Win+Shift+V"
        settings.dictationLanguageHotkey = "Alt+Shift+H+Ctrl"
        XCTAssertEqual(settings.macHotkey, "Ctrl+Alt+K")
        XCTAssertEqual(settings.macPasteLastHotkey, "Win+Shift+V")
        XCTAssertEqual(settings.macDictationLanguageHotkey, "Alt+Shift+H+Ctrl")
    }

    func testChordsShowAsMacShortcuts() {
        XCTAssertEqual(AppSettings.hotkeyLabel("Ctrl+Shift+Space"), "⌃⇧Space")
        XCTAssertEqual(AppSettings.hotkeyLabel("win+alt+shift+ctrl+k"), "⌃⌥⇧⌘K")
        XCTAssertEqual(AppSettings.hotkeyLabel("Ctrl+PageDown"), "⌃Page Down")
        XCTAssertEqual(AppSettings.hotkeyLabel("Alt+F5"), "⌥F5")
        XCTAssertEqual(AppSettings.hotkeyLabel("not a chord"), "not a chord")
    }

    /// The key that types a letter in the layout in use (the runner's is US), and the number row's for a digit.
    @MainActor
    func testTheKeysRegisteredAreTheLayoutsForLettersAndTheNumberRowsForDigits() throws {
        XCTAssertEqual(try HotkeyChord.parse("Ctrl+Shift+Space").keyCode, UInt16(kVK_Space))
        XCTAssertEqual(try HotkeyChord.parse("Ctrl+Shift+Z").keyCode, UInt16(kVK_ANSI_Z))
        XCTAssertEqual(try HotkeyChord.parse("Win+Shift+H").keyCode, UInt16(kVK_ANSI_H))
        XCTAssertEqual(try HotkeyChord.parse("Ctrl+1").keyCode, UInt16(kVK_ANSI_1))
    }
}
