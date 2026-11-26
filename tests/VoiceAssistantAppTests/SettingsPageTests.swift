import ThumbFreeMac
import VoiceAssistantCore
import VoiceAssistantMac
import XCTest
@testable import VoiceAssistantApp

/// Settings (windows-voice-assistant SettingsPage.cs): Windows' fields with the Mac's dictation key, saving only what
/// was edited into settings.json as it is now, "Start when I log in" at once, and the AI brain's card.
final class SettingsPageTests: XCTestCase {
    @MainActor
    func testTheFieldsAreWindowsInItsOrderWithTheMacsDictationKey() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        var launch = AppSettings()
        launch.dictationKey = .rightOption
        launch.insertMethod = "type"
        launch.awakeSeconds = 45
        launch.replacements = SettingsPairs(
            [(key: "git hub", value: "GitHub"), (key: "sign off", value: "Thanks,\nShivam \\o/")], ignoringCase: true)
        let model = rig.settings(launch, keys: KeyNames(dictation: "Right Option"))
        XCTAssertEqual(
            model.fields.map(\.id),
            [
                "listenOnStartup", "soundFeedback", "learnFromUsage", "pushToTalk", "dictationKey",
                "maxDictationSeconds", "livePreview", "removeFillerWords", "spokenPunctuation", "insertMethod",
                "dictationEndSilenceMs", "dictationVocabulary", "replacements", "snippets", "wakeWordEnabled",
                "awakeSeconds", "hotkey", "pasteLastHotkey", "dictationLanguageHotkey", "brainEnabled",
                "brainKeepLoadedMinutes",
            ])
        let field = { (key: String) in model.fields[model.index(key)] }
        XCTAssertEqual(field("pushToTalk").label, "Tap Right Option to dictate into any app (tap again to finish)")
        XCTAssertEqual(field("pushToTalk").text, "True")
        XCTAssertEqual(field("dictationKey").input, .choice(["Fn (🌐)", "Right Option"]))
        XCTAssertEqual(field("dictationKey").text, "Right Option")
        XCTAssertEqual(field("insertMethod").text, "Type", "chosen case aside, as Windows' combo box")
        XCTAssertEqual(field("awakeSeconds").text, "45")
        XCTAssertEqual(field("hotkey").text, "Ctrl+Shift+Space", "as settings.json writes it")
        XCTAssertEqual(field("replacements").text, "git hub = GitHub\nsign off = Thanks,\\nShivam \\\\o/")
        XCTAssertFalse(model.fields.contains { $0.isChanged })
    }

    @MainActor
    func testSavingChangesOnlyTheFieldsEditedHereSoHandEditsSurvive() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.settings()
        // Edited by hand since the app started.
        TestFiles.write(
            rig.paths.settingsFile,
            """
            {
              // Faster commands.
              "awakeSeconds": 45,
              "threads": 3,
              "commandPrefix": "jarvis",
              "soundFeedback": true,
            }
            """)

        rig.now.update { $0 = PageRig.date("2026-11-26 17:05") }
        model.fields[model.index("soundFeedback")].text = "False"
        model.fields[model.index("pasteLastHotkey")].text = "  Ctrl+Alt+V "
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.message, "Saved at 17:05. Restart to apply dictation and hotkey changes.")
        XCTAssertEqual(model.messageColour, Theme.muted)
        let saved = AppSettings.loadOrCreate(from: rig.paths.settingsFile)
        XCTAssertFalse(saved.soundFeedback)
        XCTAssertEqual(saved.pasteLastHotkey, "Ctrl+Alt+V")
        XCTAssertEqual(saved.awakeSeconds, 45, "the page showed 30, but the file's 45 wasn't edited here")
        XCTAssertEqual(saved.threads, 3)
        XCTAssertEqual(saved.commandPrefix, "jarvis", "a setting the page doesn't have")
        XCTAssertFalse(TestFiles.text(rig.paths.settingsFile).contains("Faster"), "comments go, as the page says")
        XCTAssertFalse(model.fields.contains { $0.isChanged })

        XCTAssertTrue(model.save())
        XCTAssertEqual(model.message, "Nothing to save.")
    }

    @MainActor
    func testAValueThatIsntRightIsntSavedAndTheLineSaysWhy() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.settings()
        TestFiles.write(rig.paths.settingsFile, "{ \"awakeSeconds\": 45 }")
        let file = TestFiles.text(rig.paths.settingsFile)

        model.fields[model.index("awakeSeconds")].text = "500"
        XCTAssertFalse(model.save())
        XCTAssertEqual(
            model.message,
            "Not saved: “Keep listening for commands after “Hey Jarvis” (seconds)” must be a number from 2 to 120.")
        XCTAssertEqual(model.messageColour, Theme.danger)
        model.fields[model.index("awakeSeconds")].text = "thirty"
        XCTAssertFalse(model.save())

        model.fields[model.index("awakeSeconds")].text = " 30 "
        XCTAssertFalse(model.fields[model.index("awakeSeconds")].isChanged, "trimmed, it's what was there")
        model.fields[model.index("replacements")].text = "git hub = GitHub\n= nothing heard"
        XCTAssertFalse(model.save())
        XCTAssertEqual(
            model.message,
            "Not saved: “= nothing heard” in “Personal dictionary (heard = typed, one per line)” needs the form: "
                + "heard = typed.")
        XCTAssertEqual(TestFiles.text(rig.paths.settingsFile), file, "nothing is written while a value is wrong")

        TestFiles.write(rig.paths.settingsFile, "{\n  \"awakeSeconds\": ,\n}")
        model.fields[model.index("replacements")].text = "git hub = GitHub"
        model.fields[model.index("livePreview")].text = "False"
        XCTAssertFalse(model.save())
        XCTAssertEqual(
            model.message,
            "Not saved: settings.json has an error near line 2. Fix it with Open settings file, or delete the file to "
                + "start over.")
        XCTAssertEqual(
            TestFiles.text(rig.paths.settingsFile), "{\n  \"awakeSeconds\": ,\n}",
            "a file with a mistake is never replaced")
    }

    @MainActor
    func testListsAndPairsAreSavedOneALine() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.settings()
        model.fields[model.index("dictationVocabulary")].text = "  GitHub Copilot \n\n Kubernetes\r\n"
        model.fields[model.index("replacements")].text =
            "git hub = GitHub\nGit Hub = GitHub!\nsign off = Thanks,\\nShivam \\\\o/ \\t\n\n"
        model.fields[model.index("snippets")].text = " "
        XCTAssertTrue(model.save())

        let saved = AppSettings.loadOrCreate(from: rig.paths.settingsFile)
        XCTAssertEqual(saved.dictationVocabulary, ["GitHub Copilot", "Kubernetes"])
        XCTAssertEqual(
            saved.replacements.pairs.map { $0.key }, ["git hub", "sign off"],
            "a key given twice keeps its first place, case aside")
        XCTAssertEqual(saved.replacements["git hub"], "GitHub!", "and takes its last value")
        XCTAssertEqual(saved.replacements["sign off"], "Thanks,\nShivam \\o/ \\t")
        XCTAssertTrue(saved.snippets.isEmpty)
        XCTAssertEqual(
            model.fields[model.index("replacements")].saved,
            "git hub = GitHub\nGit Hub = GitHub!\nsign off = Thanks,\\nShivam \\\\o/ \\t")

        XCTAssertEqual(SettingsModel.escape("a\\b\r\nc\nd"), "a\\\\b\\nc\\nd")
        XCTAssertEqual(SettingsModel.unescape("a\\\\b\\nc\\td\\"), "a\\b\nc\\td\\")
    }

    @MainActor
    func testSaveAndRestartRestartsOnceItsSaved() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.settings()
        model.saveAndRestart()
        XCTAssertEqual(rig.restarts, 1, "nothing to save counts as saved, as on Windows")

        TestFiles.write(rig.paths.settingsFile, "{ oops")
        model.fields[model.index("livePreview")].text = "False"
        model.saveAndRestart()
        XCTAssertEqual(rig.restarts, 1)
        XCTAssertEqual(model.messageColour, Theme.danger)

        TestFiles.write(rig.paths.settingsFile, "{}")
        model.saveAndRestart()
        XCTAssertEqual(rig.restarts, 2)
        XCTAssertFalse(AppSettings.loadOrCreate(from: rig.paths.settingsFile).livePreview)
    }

    @MainActor
    func testStartWhenILogInAppliesAtOnceAndSaysWhenMacOSDidntChangeIt() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.settings()
        XCTAssertFalse(model.startsAtLogin)
        model.setStartsAtLogin(true)
        XCTAssertEqual(rig.login.asked, [true])
        XCTAssertTrue(model.startsAtLogin)
        XCTAssertNil(model.loginProblem)
        XCTAssertFalse(TestFiles.exists(rig.paths.settingsFile), "a login item, not a setting")

        rig.login.works = false
        model.setStartsAtLogin(false)
        XCTAssertTrue(model.startsAtLogin, "the box shows what macOS says")
        XCTAssertEqual(
            model.loginProblem, "Still on: remove Voice Assistant in System Settings › General › Login Items.")
        rig.login.enabled = false
        model.refresh()
        XCTAssertFalse(model.startsAtLogin)
        XCTAssertNil(model.loginProblem, "switched off in System Settings")

        model.setStartsAtLogin(true)
        XCTAssertEqual(
            model.loginProblem,
            "Not on yet: allow Voice Assistant in System Settings › General › Login Items, or move it to your "
                + "Applications folder and try again.")
        model.refresh()
        XCTAssertNotNil(model.loginProblem, "still not on")
    }

    @MainActor
    func testTheBrainCardShowsTheBrainsStateWithItsButtons() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        let model = rig.settings()
        let folder = rig.brain.folder
        XCTAssertEqual(
            model.brainCard,
            BrainCard(
                text: "Not downloaded yet: 2.2 GB, one time. It stays on this Mac (\(folder)).", showsDownload: true,
                showsFolder: true))

        rig.brain.status = .downloading(received: 536_870_912, total: 2_392_985_300)
        rig.brain.canDownload = false
        model.brainChanged()
        XCTAssertEqual(
            model.brainCard,
            BrainCard(
                text: "Downloading… 512 MB of 2.2 GB (22%). You can keep using the app.", showsStop: true,
                showsFolder: true))

        let states: [(BrainStatus, String, Bool)] = [
            (.installed, "Ready. Qwen3 4B loads when you next ask for something.", false),
            (.unloaded, "Ready. Qwen3 4B loads when you next ask for something.", false),
            (.starting, "Loading Qwen3 4B…", false),
            (.ready, "Ready: Qwen3 4B, running on this Mac.", false),
            (.failed("The download stopped: the network connection was lost."),
             "The download stopped: the network connection was lost.", true),
            (.failed(""), "It couldn't start. Open logs folder for details; it tries again when you next ask.", false),
            (.unavailable("The AI brain needs a Mac with Apple silicon."),
             "The AI brain needs a Mac with Apple silicon.", false),
        ]
        for (status, text, isError) in states {
            rig.brain.status = status
            model.brainChanged()
            XCTAssertEqual(model.brainCard, BrainCard(text: text, isError: isError, showsFolder: true), text)
        }

        rig.brain.status = .notInstalled
        rig.brain.missingBytes = 0
        model.refresh()
        XCTAssertEqual(
            model.brainCard.text, "Its files aren't where settings.json says (brainServerPath / brainModelPath).")
        XCTAssertEqual(
            rig.settings(brainOn: false).brainCard, BrainCard(text: "Off. Switch it on and restart to use it."),
            "switched off: no buttons")
    }

    @MainActor
    func testTheButtonsOpenTheFilesAndFoldersAndAskTheApp() {
        let rig = PageRig()
        defer { rig.folder.remove() }
        var launch = AppSettings()
        launch.awakeSeconds = 40
        let model = rig.settings(launch)
        model.openSettingsFile()
        XCTAssertEqual(rig.opener.opened, ["TextEdit " + rig.paths.settingsFile])
        XCTAssertEqual(
            AppSettings.loadOrCreate(from: rig.paths.settingsFile).awakeSeconds, 40,
            "written first, from the settings read at launch")
        TestFiles.write(rig.paths.settingsFile, "{ \"awakeSeconds\": 50 }")
        model.openSettingsFile()
        XCTAssertEqual(AppSettings.loadOrCreate(from: rig.paths.settingsFile).awakeSeconds, 50, "a file is kept")

        model.openLogsFolder()
        model.openBrainFolder()
        model.openSoundSettings()
        XCTAssertEqual(
            Array(rig.opener.opened.suffix(3)),
            [rig.paths.logs, rig.brain.folder, "x-apple.systempreferences:com.apple.preference.sound?input"])
        for folder in [rig.paths.logs, rig.brain.folder] {
            var isFolder: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), folder)
            XCTAssertTrue(isFolder.boolValue, "made first: \(folder)")
        }

        model.downloadBrain()
        model.stopBrainDownload()
        model.forgetLearned()
        XCTAssertEqual(rig.brain.calls, ["download", "stop download"])
        XCTAssertEqual(rig.assistant.calls, ["forget learned"])
    }
}
