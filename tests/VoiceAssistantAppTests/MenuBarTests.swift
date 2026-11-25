import AppKit
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// The menu bar's menu (Windows' tray menu, TrayIcon.cs), read and clicked as `StatusMenu` builds it, with no item in
/// the menu bar; the icon's dot for each mode, and where the balloon goes.
final class MenuBarTests: XCTestCase {
    @MainActor
    func testTheMenuHasWindowsItemsInOrderWithTheMacsKeys() throws {
        let recorder = MenuRecorder()
        let menu = StatusMenu(hotkeys: MenuHotkeys(), actions: recorder.actions)
        let items = menu.menu.items

        XCTAssertEqual(
            Self.shown(menu),
            [
                "Open Voice Assistant", "Idea board", "—", "Starting…", "Start listening", "Paste last dictation",
                "Dictation language (⌃⇧H)", "—", "What you can say", "Settings…", "Always show status pill",
                "Start when I log in", "—", "Quit Voice Assistant",
            ])
        let font = try XCTUnwrap(items[0].attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "Open Voice Assistant is bold")
        XCTAssertFalse(menu.statusLine.isEnabled)
        XCTAssertEqual(
            menu.language.submenu?.items.map(\.title),
            [
                "English", "Hindi + English — fast (typed in Roman letters)",
                "Hindi + English — accurate (slower; 830 MB download)",
            ])

        // The text that couldn't be typed is offered while there's some ("The text is in the menu bar.").
        recorder.state.untypedText = "Call me at 4 PM."
        menu.menuNeedsUpdate(menu.menu)
        XCTAssertEqual(
            Array(Self.shown(menu)[6...7]), ["Dictation language (⌃⇧H)", "Copy text that wasn't typed"])
        recorder.state.untypedText = ""
        menu.prepare()
        XCTAssertTrue(menu.copyUntyped.isHidden)

        // The hotkeys show as macOS shows shortcuts; ⌘, and ⌘Q are the Mac's own.
        let keys = [menu.toggle, menu.pasteLast, menu.settings, menu.quit].map(\.keyEquivalent)
        XCTAssertEqual(keys, [" ", "z", ",", "q"])
        XCTAssertEqual(
            [menu.toggle, menu.pasteLast, menu.settings, menu.quit].map(\.keyEquivalentModifierMask),
            [[.control, .shift], [.control, .shift], [.command], [.command]])
    }

    @MainActor
    func testTheModeShowsInTheStatusLineThePauseItemAndTheIconsDot() {
        let menu = StatusMenu(hotkeys: MenuHotkeys(), actions: MenuRecorder().actions)
        let modes: [(InteractionMode, String, String, UInt32?)] = [
            (.standby, "Waiting for “Hey Jarvis”", "Pause listening", nil),
            (.command, "Listening for commands", "Pause listening", 0x4C8DF6),
            (.dictation, "Typing", "Pause listening", 0xEA4335),
            (.paused, "Paused (microphone off)", "Start listening", 0x9AA0A6),
        ]
        for (mode, status, toggle, dot) in modes {
            menu.showMode(mode)
            XCTAssertEqual(menu.statusLine.title, status)
            XCTAssertEqual(menu.toggle.title, toggle)
            XCTAssertEqual(MenuBar.dot(mode), dot.map { Colour($0) }, status)
        }

        XCTAssertEqual(MenuBar.dot(nil), Colour(0x9AA0A6), "grey while starting, as Windows' first icon")
    }

    @MainActor
    func testEachItemDoesWhatItSaysAndTheTicksFollowTheApp() {
        let recorder = MenuRecorder()
        recorder.state = MenuState(
            hinglish: true, accurate: false, pillAlwaysShown: true, startsAtLogin: false,
            untypedText: "Call me at 4 PM.")
        let menu = StatusMenu(hotkeys: MenuHotkeys(), actions: recorder.actions)
        XCTAssertEqual([menu.english, menu.hinglish, menu.hinglishAccurate].map(\.state), [.off, .on, .off])
        XCTAssertEqual(menu.showPill.state, .on)
        XCTAssertEqual(menu.startAtLogin.state, .off)
        XCTAssertFalse(menu.copyUntyped.isHidden)

        for item in [
            menu.openApp, menu.ideaBoard, menu.toggle, menu.pasteLast, menu.english, menu.hinglish,
            menu.hinglishAccurate, menu.copyUntyped, menu.whatYouCanSay, menu.settings, menu.showPill,
            menu.startAtLogin, menu.quit,
        ] {
            menu.click(item)
        }

        XCTAssertEqual(
            recorder.calls,
            [
                "open home", "open ideas", "toggle listening", "paste last", "language false false",
                "language true false", "language true true", "copy untyped", "open help", "open settings",
                "pill always shown false", "starts at login true", "quit",
            ])

        // Opening the menu again reads it all again: once copied, the text that wasn't typed is gone.
        recorder.state = MenuState(hinglish: true, accurate: true, pillAlwaysShown: false, startsAtLogin: true)
        menu.menuNeedsUpdate(menu.menu)
        XCTAssertEqual([menu.english, menu.hinglish, menu.hinglishAccurate].map(\.state), [.off, .off, .on])
        XCTAssertEqual(menu.showPill.state, .off)
        XCTAssertEqual(menu.startAtLogin.state, .on)
        XCTAssertTrue(menu.copyUntyped.isHidden)
        menu.click(menu.showPill)
        menu.click(menu.startAtLogin)
        XCTAssertEqual(recorder.calls.suffix(2), ["pill always shown true", "starts at login false"])

        recorder.state = MenuState()
        menu.prepare()
        XCTAssertEqual([menu.english, menu.hinglish, menu.hinglishAccurate].map(\.state), [.on, .off, .off])
    }

    @MainActor
    func testHotkeysShowAsMacShortcutsOrAfterTheTitle() throws {
        let shortcuts: [(String, String, NSEvent.ModifierFlags)] = [
            ("⌃⇧Space", " ", [.control, .shift]),
            ("⌃⇧Z", "z", [.control, .shift]),
            ("⌥⌘F5", Self.functionKey(NSF5FunctionKey), [.option, .command]),
            ("⌃⌥→", Self.functionKey(NSRightArrowFunctionKey), [.control, .option]),
            ("⌘;", ";", [.command]),
        ]
        for (shortcut, key, modifiers) in shortcuts {
            let equivalent = try XCTUnwrap(StatusMenu.keyEquivalent(shortcut), shortcut)
            XCTAssertEqual(equivalent.key, key, shortcut)
            XCTAssertEqual(equivalent.modifiers, modifiers, shortcut)
        }

        XCTAssertNil(StatusMenu.keyEquivalent("Z"), "no modifier")
        XCTAssertNil(StatusMenu.keyEquivalent("⌃⇧"), "no key")
        XCTAssertNil(StatusMenu.keyEquivalent("⌃⇧Key 105"), "a key a menu can't show")

        // One the menu can't show is written after the title; one that isn't set shows nothing.
        let menu = StatusMenu(
            hotkeys: MenuHotkeys(pause: "⌃⇧Key 105", pasteLast: "", language: ""), actions: MenuRecorder().actions)
        XCTAssertEqual(menu.toggle.title, "Start listening (⌃⇧Key 105)")
        XCTAssertEqual(menu.toggle.keyEquivalent, "")
        menu.showMode(.standby)
        XCTAssertEqual(menu.toggle.title, "Pause listening (⌃⇧Key 105)")
        XCTAssertEqual(menu.pasteLast.title, "Paste last dictation")
        XCTAssertEqual(menu.pasteLast.keyEquivalent, "")
        XCTAssertEqual(menu.language.title, "Dictation language")
    }

    @MainActor
    func testTheBalloonSitsUnderTheIconInsideTheScreen() {
        // A 1440 × 900 screen: the menu bar above 875, the Dock below 70.
        let area = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let size = CGSize(width: 332, height: 80)
        let icon = CGRect(x: 1200, y: 875, width: 24, height: 25)

        XCTAssertEqual(
            Balloon.frame(size: size, anchor: icon, area: area), CGRect(x: 1046, y: 787, width: 332, height: 80))
        let nearTheEdge = CGRect(x: 1400, y: 875, width: 24, height: 25)
        XCTAssertEqual(Balloon.frame(size: size, anchor: nearTheEdge, area: area).maxX, 1432)
        XCTAssertEqual(
            Balloon.frame(size: size, anchor: nil, area: area), CGRect(x: 1100, y: 787, width: 332, height: 80),
            "without an icon on screen: the top right")
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(Unicode.Scalar(UInt32(code))!))
    }

    /// The menu as a person sees it: the items that aren't hidden, "—" for a line.
    @MainActor
    private static func shown(_ menu: StatusMenu) -> [String] {
        menu.menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
    }
}

/// The app as the menu sees it: records what the menu asks, and answers with `state`.
@MainActor
final class MenuRecorder {
    var calls: [String] = []
    var state = MenuState()

    var actions: MenuActions {
        MenuActions(
            open: { page in self.calls.append("open \(page)") },
            toggleListening: { self.calls.append("toggle listening") },
            pasteLast: { self.calls.append("paste last") },
            setDictationLanguage: { hinglish, accurate in self.calls.append("language \(hinglish) \(accurate)") },
            copyUntyped: { self.calls.append("copy untyped") },
            setPillAlwaysShown: { shown in self.calls.append("pill always shown \(shown)") },
            setStartsAtLogin: { on in self.calls.append("starts at login \(on)") },
            quit: { self.calls.append("quit") },
            state: { self.state })
    }
}
