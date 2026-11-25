import XCTest
import ThumbFreeSpeech
import VoiceAssistantBoard
@testable import VoiceAssistantApp

/// Where the files go (Windows' AppPaths) and the flag files (StateFlags).
final class AppPathsTests: XCTestCase {
    func testTheMacsFoldersAreInApplicationSupportAndLogs() {
        let paths = AppPaths.standard
        let home = NSHomeDirectory()

        XCTAssertEqual(paths.data, home + "/Library/Application Support/VoiceAssistant")
        XCTAssertEqual(paths.logs, home + "/Library/Logs/VoiceAssistant")
        XCTAssertEqual(paths.models, paths.data + "/models")
        XCTAssertEqual(paths.brain, paths.data + "/brain")
        XCTAssertEqual(paths.sharedModels, [ModelStore.defaultFolder])
        XCTAssertEqual(paths.sharedModels, [home + "/Library/Application Support/ThumbFree/models"])
        XCTAssertEqual(paths.settingsFile, paths.data + "/settings.json")
        XCTAssertEqual(paths.boardFile, paths.data + "/board.json")
        XCTAssertEqual(paths.learnedFile, paths.data + "/learned.json")
        XCTAssertEqual(paths.overlayMinimizedFlag, paths.data + "/overlay-minimized")
        XCTAssertEqual(paths.hinglishDictationFlag, paths.data + "/dictation-hinglish")
        XCTAssertEqual(paths.hinglishAccurateFlag, paths.data + "/dictation-hinglish-accurate")
    }

    func testEveryFolderCanBeChosen() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let paths = AppPaths(
            data: folder.file("data"), logs: folder.file("logs"), models: folder.file("models"),
            brain: folder.file("brain"), sharedModels: [folder.file("thumbfree")])

        XCTAssertEqual(paths.models, folder.file("models"))
        XCTAssertEqual(paths.brain, folder.file("brain"))
        XCTAssertEqual(paths.sharedModels, [folder.file("thumbfree")])
        XCTAssertEqual(AppPaths(data: folder.path, logs: folder.file("logs")).sharedModels, [])

        // The board is VoiceAssistantBoard's store in board.json.
        let board = try BoardStore(path: paths.boardFile)
        try board.add(.todo, "renew passport")
        XCTAssertTrue(TestFiles.exists(paths.boardFile))
        XCTAssertEqual(try BoardStore(path: paths.boardFile).items.map(\.text), ["Renew passport"])
    }

    func testTheBrainFolderIsTheSettingWhenThereIsOne() {
        let paths = AppPaths(data: "/data", logs: "/logs")

        XCTAssertEqual(paths.brainFolder(nil), "/data/brain")
        XCTAssertEqual(paths.brainFolder(""), "/data/brain")
        XCTAssertEqual(paths.brainFolder(" \t\n"), "/data/brain")
        XCTAssertEqual(paths.brainFolder("  /Volumes/External/Brain  "), "/Volumes/External/Brain")
        XCTAssertEqual(paths.brainFolder("~/Brain"), NSHomeDirectory() + "/Brain")
    }

    /// .NET's ExpandEnvironmentVariables on a Mac: %NAME% for a variable that's set, anything else as it is.
    func testPathsExpandEnvironmentVariablesAsDotNetDoes() {
        let environment = ["HOME": "/Users/ren", "A": "1", "B": "2", "EMPTY": ""]
        let cases = [
            ("%HOME%/Brain", "/Users/ren/Brain"),
            ("%NOPE%/Brain", "%NOPE%/Brain"),
            ("a%b", "a%b"),
            ("%%", "%%"),
            ("%A%%B%", "12"),
            ("x%A%", "x1"),
            ("%A%B%", "1B%"),
            ("%NOPE%A%", "%NOPE1"),
            ("%EMPTY%x", "x"),
            ("50% of %A%", "50% of 1"),
            ("", ""),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(AppPaths.expand(path, environment: environment), expected, path)
        }

        XCTAssertEqual(AppPaths.expand("~/Brain", environment: environment), NSHomeDirectory() + "/Brain")
        XCTAssertEqual(AppPaths.expand("/a~b", environment: environment), "/a~b")
    }

    func testFlagFilesAreSetAndCleared() {
        let folder = TempFolder()
        defer { folder.remove() }
        let flag = AppPaths(data: folder.file("data"), logs: folder.file("logs")).hinglishDictationFlag

        XCTAssertFalse(StateFlags.isSet(flag))
        StateFlags.set(flag, true)
        XCTAssertTrue(StateFlags.isSet(flag))
        XCTAssertEqual(TestFiles.bytes(flag), [])
        StateFlags.set(flag, true)
        StateFlags.set(flag, false)
        XCTAssertFalse(StateFlags.isSet(flag))
        StateFlags.set(flag, false)
        XCTAssertFalse(StateFlags.isSet(flag))
    }
}
