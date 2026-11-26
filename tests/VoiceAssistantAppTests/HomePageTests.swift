import AVFoundation
import ThumbFreeCore
import ThumbFreeMac
import VoiceAssistantBoard
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// Home (windows-voice-assistant HomePage.cs): the mode, the dictation language, what's coming up and this session's
/// activity, and the Mac's card of permissions macOS hasn't given yet.
final class HomePageTests: XCTestCase {
    @MainActor
    func testTheStatusCardShowsTheModeAndNamesTheDictationKey() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let lines = [InteractionMode.standby, .command, .dictation, .paused].map { HomeModel.modeLine($0, key: "Fn") }
        XCTAssertEqual(
            lines.map(\.title), ["Listening for “Hey Jarvis”", "Listening for a command", "Typing", "Paused"])
        XCTAssertEqual(
            lines.map(\.hint),
            [
                "Tap Fn any time to dictate; tap it again to finish.", "Say a command now, e.g. “open TextEdit”.",
                "Speaking types into the chosen text box. Say “stop typing” when done.",
                "The microphone is off. Tapping Fn still dictates.",
            ])
        XCTAssertEqual(
            lines.map(\.colour), [Colour(0x34A853), Colour(0x4C8DF6), Colour(0xEA4335), Colour(0x9AA0A6)])
        XCTAssertEqual(
            lines.map(\.toggle), ["Pause listening", "Pause listening", "Pause listening", "Start listening"])
        XCTAssertEqual(
            HomeModel.modeLine(.standby, key: "Right Option").hint,
            "Tap Right Option any time to dictate; tap it again to finish.")

        rig.assistant.mode = .paused
        let home = rig.home(board: nil)
        XCTAssertEqual(home.modeLine.title, "Paused", "the host's mode at the start")
        home.showStatus(AssistantStatus(mode: .standby, kind: .info, message: ""))
        XCTAssertEqual(home.modeLine.title, "Listening for “Hey Jarvis”")
        home.toggleListening()
        XCTAssertEqual(rig.assistant.calls, ["toggle listening"])
        XCTAssertEqual(
            home.tips.first, "Tap Fn, speak, tap Fn again: your words are typed where the cursor is.")
    }

    @MainActor
    func testStatusesBecomeRecentActivityNewestFirstInTheirKindsColour() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let home = rig.home(board: nil)
        XCTAssertEqual(home.activity, [], "“Nothing yet this session.”")

        rig.now.update { $0 = PageRig.date("2026-11-26 17:05") }
        home.showStatus(AssistantStatus(mode: .command, kind: .success, message: "Opened TextEdit."))
        home.showStatus(AssistantStatus(mode: .standby, kind: .info, message: "   "))
        home.showStatus(AssistantStatus(mode: .standby, kind: .warning, message: "Sorry, I didn't catch that."))
        home.showStatus(AssistantStatus(mode: .standby, kind: .error, message: "The microphone isn't working."))
        XCTAssertEqual(
            home.activity.map(\.text),
            [
                "17:05   The microphone isn't working.", "17:05   Sorry, I didn't catch that.",
                "17:05   Opened TextEdit.",
            ],
            "a blank message is no activity")
        XCTAssertEqual(home.activity.map(\.colour), [Theme.danger, Colour(0x8A5A00), Theme.text])
        XCTAssertEqual(home.mode, .standby)

        for number in 1...40 {
            home.showStatus(AssistantStatus(mode: .standby, kind: .info, message: "Line \(number)"))
        }

        XCTAssertEqual(home.activity.count, HomeModel.maxActivity)
        XCTAssertEqual(home.activity.first?.text, "17:05   Line 40")
        XCTAssertEqual(home.activity.last?.text, "17:05   Line 11")
        XCTAssertEqual(Set(home.activity.map(\.id)).count, HomeModel.maxActivity)
    }

    @MainActor
    func testTheLanguageFollowsTheHostAndAChoiceHereGoesToIt() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        rig.assistant.hinglishDictation = true
        let home = rig.home(board: nil)
        XCTAssertEqual(home.languageIndex, 1, "Hindi + English, fast")

        home.chooseLanguage(2)
        XCTAssertEqual(rig.assistant.calls, ["language hinglish: true accurate: true"])
        home.chooseLanguage(2)
        home.chooseLanguage(3)
        XCTAssertEqual(rig.assistant.calls.count, 1, "the same choice, or none, isn't sent")

        home.setDictationLanguage(hinglish: false, accurate: true)
        XCTAssertEqual(home.languageIndex, 0)
        XCTAssertEqual(rig.assistant.calls.count, 1, "a change from the host isn't sent back to it")
        home.chooseLanguage(1)
        XCTAssertEqual(rig.assistant.calls.last, "language hinglish: true accurate: false")

        XCTAssertEqual(
            home.languageHint,
            "⌃⇧H switches between English and Hindi + English. Voice commands are always English.")
        let noHotkey = rig.home(board: nil, keys: KeyNames(hotkeys: MenuHotkeys(language: "")))
        XCTAssertEqual(noHotkey.languageHint, "Voice commands are always English.")
    }

    @MainActor
    func testComingUpListsTheNextFourOpenRemindersByTimeInRedOnceDue() throws {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let board = try rig.board()
        let now = rig.now.value
        try board.add(.reminders, "Water the plants", due: nil)
        try board.add(.reminders, "Book the dentist", due: PageRig.date("2026-11-27 09:00"))
        try board.add(.reminders, "Call mom", due: now.addingTimeInterval(25 * 60))
        try board.add(.reminders, "Pay the rent", due: now.addingTimeInterval(-10 * 60))
        try board.add(.todo, "Buy milk", due: now.addingTimeInterval(5 * 60))
        try board.setDone(try board.add(.reminders, "Renew passport", due: now).id, true)

        let home = rig.home(board: board)
        XCTAssertEqual(
            home.upcoming.map(\.text),
            [
                "⏰ today 3:50 PM   Pay the rent", "⏰ in 25 min   Call mom", "⏰ tomorrow 9:00 AM   Book the dentist",
                "⏰ no time   Water the plants",
            ],
            "open reminders by time, those without one last; done ones and other lists left out")
        XCTAssertEqual(home.upcoming.map(\.colour), [Theme.danger, Theme.text, Theme.text, Theme.text])

        // The board tells on its own thread; the page follows on the main one.
        try board.add(.reminders, "Stretch", due: PageRig.date("2026-11-26 18:00"))
        PageRig.waitForMain { home.upcoming.count == 4 && home.upcoming[2].text.hasSuffix("Stretch") }
        XCTAssertEqual(
            home.upcoming.map(\.text),
            [
                "⏰ today 3:50 PM   Pay the rent", "⏰ in 25 min   Call mom", "⏰ today 6:00 PM   Stretch",
                "⏰ tomorrow 9:00 AM   Book the dentist",
            ],
            "four at most")
        XCTAssertEqual(rig.home(board: nil).upcoming, [], "no board, nothing coming up")
    }

    @MainActor
    func testThePermissionsCardNamesWhatMacOSHasntAllowed() {
        let system = PagePermissionSystem()
        let checks = Permissions(system: system)
        XCTAssertEqual(HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true), [], "all allowed: no card")

        system.microphone = .notDetermined
        system.accessibility = false
        system.postEvents = false
        system.listen = false
        let rows = HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true)
        XCTAssertEqual(rows.map(\.name), ["Microphone", "Accessibility", "Input Monitoring"])
        XCTAssertEqual(rows.map(\.button), ["Allow…", "Allow…", "Allow…"])
        XCTAssertEqual(
            rows.map(\.buttonLabel), ["Allow Microphone", "Allow Accessibility", "Allow Input Monitoring"],
            "what VoiceOver says: each button names its permission")
        XCTAssertEqual(
            rows.map(\.reason),
            [
                "To hear “Hey Jarvis”, your commands and your dictation.",
                "To read and use other apps' windows, and to type what you dictate.",
                "So tapping Fn can start dictation while Accessibility isn't allowed.",
            ])

        system.microphone = .denied
        XCTAssertEqual(
            HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true).first?.button, "Open System Settings",
            "macOS asks once")
        XCTAssertEqual(
            HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true, asked: [.accessibility, .inputMonitoring])
                .map(\.button),
            ["Open System Settings", "Open System Settings", "Open System Settings"])
        let asked = HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true, asked: [.accessibility])
        XCTAssertEqual(
            asked.map(\.buttonLabel),
            [
                "Open System Settings for Microphone", "Open System Settings for Accessibility",
                "Allow Input Monitoring",
            ])
        XCTAssertEqual(
            HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: false).map(\.name),
            ["Microphone", "Accessibility"], "Input Monitoring is only for the dictation key")
        system.listen = true
        XCTAssertEqual(
            HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true).map(\.name),
            ["Microphone", "Accessibility"])

        system.microphone = .authorized
        system.accessibility = true
        system.listen = false
        XCTAssertEqual(
            HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true).map(\.name),
            ["Accessibility", "Input Monitoring"], "typing (posting keys) is Accessibility's too")
        system.postEvents = true
        XCTAssertEqual(
            HomeModel.permissionRows(checks, key: "Fn", dictationKeyOn: true), [],
            "with Accessibility the key needs no Input Monitoring")
    }

    @MainActor
    func testThePermissionButtonsAskMacOSOrOpenSystemSettings() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        rig.system.microphone = .notDetermined
        rig.system.accessibility = false
        rig.system.postEvents = false
        rig.system.listen = false
        let home = rig.home(board: nil)
        XCTAssertEqual(home.permissions.map(\.kind), [.microphone, .accessibility, .inputMonitoring])

        home.allow(.microphone)
        PageRig.waitForMain { home.permissions.count == 2 }
        XCTAssertEqual(rig.system.calls, ["ask for the microphone"], "macOS's prompt, the first time")
        XCTAssertEqual(home.permissions.map(\.kind), [.accessibility, .inputMonitoring])

        home.allow(.accessibility)
        PageRig.waitForMain { rig.system.calls.count == 3 }
        XCTAssertEqual(
            rig.system.calls.suffix(2),
            [
                "ask for Accessibility",
                "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ],
            "macOS's prompt lists the app in System Settings, switched off; the pane opens to switch it on")
        XCTAssertEqual(home.permissions.first?.button, "Open System Settings", "macOS asks once")
        home.allow(.accessibility)
        XCTAssertEqual(
            rig.system.calls.suffix(2),
            [
                "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ],
            "then the button opens System Settings")

        rig.system.grantsListen = true
        home.allow(.inputMonitoring)
        PageRig.waitForMain { home.permissions.count == 1 }
        XCTAssertEqual(rig.system.calls.last, "ask to listen to events", "allowed at once: nothing to open")
        XCTAssertEqual(home.permissions.map(\.kind), [.accessibility])

        rig.system.microphone = .denied
        home.refreshPermissions()
        XCTAssertEqual(home.permissions.first?.button, "Open System Settings")
        home.allow(.microphone)
        XCTAssertEqual(
            rig.system.calls.last, "open x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @MainActor
    func testOpenBoardOpensTheWholeBoard() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let home = rig.home(board: nil)
        var opened: [BoardList?] = []
        home.openBoard = { opened.append($0) }
        home.showBoard()
        XCTAssertEqual(opened, [nil])
    }
}
