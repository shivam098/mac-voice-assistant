import XCTest
import ThumbFreeMac
import VoiceAssistantCore
@testable import VoiceAssistantApp

/// settings.json as Windows reads and writes it. Windows has no tests of AppSettings; these hold the Mac to what the C#
/// code does (AppVectors.swift, generated from it), and pin the Mac's own defaults.
final class SettingsTests: XCTestCase {
    /// The Mac's defaults, as a new settings.json lists them (threads: 4, since the default depends on the Mac):
    /// Windows' keys, values and order, with Mac hotkeys and apps, then the Mac's dictation key.
    static let macDefaultSettings = #"""
    {
      "modelFile": "ggml-small.en-q8_0.bin",
      "vadModelFile": "ggml-silero-v6.2.0.bin",
      "hinglishModelFile": "ggml-hinglish-swift-q8_0.bin",
      "hinglishAccurateModelFile": "ggml-hinglish-apex-q8_0.bin",
      "dictationLanguageHotkey": "Ctrl\u002BShift\u002BH",
      "threads": 4,
      "audioContextSize": 768,
      "microphoneDevice": -1,
      "endSilenceMs": 600,
      "dictationEndSilenceMs": 1100,
      "dictationVocabulary": [
        "GitHub Copilot",
        "vibe coding",
        "iterate",
        "pull request",
        "commit"
      ],
      "maxCommandUtteranceMs": 6000,
      "listenOnStartup": true,
      "hotkey": "Ctrl\u002BShift\u002BSpace",
      "commandPrefix": "computer",
      "requireCommandPrefixWhileTyping": false,
      "returnToCommandModeAfterSend": true,
      "minCommandConfidence": 0.3,
      "insertMethod": "Paste",
      "discoverStartMenuApps": true,
      "wakeWordEnabled": true,
      "wakeWords": [
        "hey jarvis",
        "hi jarvis",
        "hello jarvis",
        "ok jarvis",
        "okay jarvis",
        "a jarvis",
        "hey jervis",
        "hey javis",
        "jarvis"
      ],
      "awakeSeconds": 30,
      "soundFeedback": true,
      "learnFromUsage": true,
      "brainEnabled": true,
      "brainKeepLoadedMinutes": 60,
      "pushToTalk": true,
      "livePreview": true,
      "maxDictationSeconds": 600,
      "pasteLastHotkey": "Ctrl\u002BShift\u002BZ",
      "removeFillerWords": true,
      "spokenPunctuation": true,
      "replacements": {
        "git hub": "GitHub",
        "co-pilot": "Copilot",
        "co pilot": "Copilot"
      },
      "snippets": {},
      "apps": [
        {
          "name": "GitHub Copilot",
          "aliases": [
            "github copilot",
            "copilot app"
          ],
          "launch": "com.github.githubapp",
          "processNames": [
            "com.github.githubapp"
          ],
          "submitKeys": "Enter",
          "newLineKeys": "Shift\u002BEnter",
          "textArea": "Bottom",
          "textAreaName": "Message"
        },
        {
          "name": "TextEdit",
          "aliases": [],
          "launch": "com.apple.TextEdit",
          "processNames": [
            "com.apple.TextEdit"
          ],
          "submitKeys": "",
          "newLineKeys": "Enter",
          "textArea": "Largest",
          "newWindowKeys": "Cmd\u002BN",
          "newDocumentKeys": "Cmd\u002BN"
        },
        {
          "name": "Notes",
          "aliases": [],
          "launch": "com.apple.Notes",
          "processNames": [
            "com.apple.Notes"
          ],
          "submitKeys": "",
          "newLineKeys": "Enter",
          "textArea": "Largest",
          "newWindowKeys": "Cmd\u002BN",
          "newDocumentKeys": "Cmd\u002BN"
        },
        {
          "name": "Google Chrome",
          "aliases": [
            "chrome",
            "google chrome"
          ],
          "launch": "com.google.Chrome",
          "processNames": [
            "com.google.Chrome"
          ],
          "submitKeys": "Enter",
          "newLineKeys": "Shift\u002BEnter",
          "searchKeys": "Cmd\u002BL",
          "addressBarKeys": "Cmd\u002BL"
        },
        {
          "name": "Microsoft Edge",
          "aliases": [
            "edge",
            "microsoft edge"
          ],
          "launch": "com.microsoft.edgemac",
          "processNames": [
            "com.microsoft.edgemac"
          ],
          "submitKeys": "Enter",
          "newLineKeys": "Shift\u002BEnter",
          "searchKeys": "Cmd\u002BL",
          "addressBarKeys": "Cmd\u002BL"
        },
        {
          "name": "Firefox",
          "aliases": [
            "firefox",
            "mozilla firefox"
          ],
          "launch": "org.mozilla.firefox",
          "processNames": [
            "org.mozilla.firefox"
          ],
          "submitKeys": "Enter",
          "newLineKeys": "Shift\u002BEnter",
          "searchKeys": "Cmd\u002BL",
          "addressBarKeys": "Cmd\u002BL"
        },
        {
          "name": "Safari",
          "aliases": [
            "safari"
          ],
          "launch": "com.apple.Safari",
          "processNames": [
            "com.apple.Safari"
          ],
          "submitKeys": "Enter",
          "newLineKeys": "Shift\u002BEnter",
          "searchKeys": "Cmd\u002BL",
          "addressBarKeys": "Cmd\u002BL"
        }
      ],
      "dictationKey": "Fn"
    }
    """#

    /// Windows' file as the Mac writes it back: the same, with the Mac's dictation key added at the end.
    static func withDictationKey(_ windowsFile: String, _ key: String = "Fn") -> String {
        XCTAssertTrue(windowsFile.hasSuffix("\n}"))
        return String(windowsFile.dropLast(2)) + ",\n  \"dictationKey\": \"\(key)\"\n}"
    }

    func testTheMacsDefaultsAreWindowsWithMacHotkeysAppsAndTheDictationKey() throws {
        var settings = AppSettings()
        settings.threads = 4

        XCTAssertEqual(try settings.fileText(), Self.macDefaultSettings)
        XCTAssertEqual(AppSettings.defaultThreads, min(max(ProcessInfo.processInfo.activeProcessorCount * 2 / 3, 2), 8))
        XCTAssertEqual(settings.dictationKey, .fn)
        XCTAssertEqual(try AppSettings.parse(Self.macDefaultSettings), settings)
    }

    func testWindowsDefaultFileReadsAsWindowsWroteItAndWritesBackTheSame() throws {
        let settings = try XCTUnwrap(try AppSettings.parse(windowsDefaultSettings))

        XCTAssertEqual(settings.hotkey, "Ctrl+Alt+Space")
        XCTAssertEqual(settings.pasteLastHotkey, "Alt+Shift+Z")
        XCTAssertEqual(settings.dictationLanguageHotkey, "Alt+Shift+H")
        XCTAssertEqual(settings.threads, 4)
        XCTAssertEqual(settings.minCommandConfidence, 0.3)
        XCTAssertEqual(settings.wakeWords, CommandParser.defaultWakeWords)
        XCTAssertEqual(
            settings.apps.map(\.name), ["GitHub Copilot", "Notepad", "Google Chrome", "Microsoft Edge", "Firefox"])
        XCTAssertEqual(settings.apps[0].launch, #"shell:AppsFolder\com.github.githubapp"#)
        XCTAssertEqual(settings.apps[0].windowTitleContains, "GitHub Copilot")
        XCTAssertEqual(settings.apps[1].newWindowKeys, "Ctrl+Shift+N")
        XCTAssertEqual(settings.apps[1].submitKeys, "")
        XCTAssertEqual(settings.dictationKey, .fn)
        XCTAssertEqual(try settings.fileText(), Self.withDictationKey(windowsDefaultSettings))

        // Windows writes "\r\n".
        let crlf = windowsDefaultSettings.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try AppSettings.parse(crlf), settings)
    }

    func testEverySettingChangedOnWindowsReadsAndWritesBackTheSame() throws {
        let settings = try XCTUnwrap(try AppSettings.parse(windowsCustomSettings))

        XCTAssertEqual(settings.vocabularyPrompt, #"Jarvis, "Copilot" & <GitHub> isn't 'it'"#)
        XCTAssertEqual(settings.hinglishAccurateModelFile, "my model ✓.bin")
        XCTAssertEqual(settings.dictationVocabulary.suffix(2), [#"C:\temp"#, "tab\there"])
        XCTAssertEqual(settings.minCommandConfidence, 0.45)
        XCTAssertEqual(settings.brainModelPath, "/Users/ren/Models/Qwen3 4B.gguf")
        XCTAssertEqual(settings.replacements.pairs.map { $0.key }, ["zebra crossing", "git hub", "Git Hub", "a"])
        XCTAssertEqual(settings.snippets["my signature"], "Thanks,\nShivam")
        XCTAssertEqual(settings.snippets["my address"], "221B Baker Street\tLondon 😀")
        XCTAssertEqual(settings.apps.count, 2)
        XCTAssertEqual(
            settings.apps[0],
            AppEntry(
                name: "Xcode", aliases: ["x code", "apple xcode"], launch: "com.apple.dt.Xcode",
                processNames: ["com.apple.dt.Xcode"], windowTitleContains: "— Edited", submitKeys: "",
                newLineKeys: "Enter", textArea: "Largest", textAreaName: "Source Editor", searchKeys: "Shift+Cmd+O",
                addressBarKeys: "Cmd+L", newWindowKeys: "Shift+Cmd+N", newDocumentKeys: "Cmd+N"))
        XCTAssertEqual(settings.apps[1], AppEntry(name: "Slack", launch: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(try settings.fileText(), Self.withDictationKey(windowsCustomSettings))

        // The order is what the dictation formatter gets.
        XCTAssertEqual(settings.dictationOptions.replacements.map { $0.value }, ["Zebra", "GitHub", "GITHUB", "b"])
        XCTAssertFalse(settings.dictationOptions.removeFillerWords)
    }

    /// Where .NET reads a null that the Mac can't hold (Windows then stops with an error where it uses the value): what
    /// the Mac reads instead, as compact JSON.
    static let macWhereWindowsReadsNull: [String: String] = [
        #"{"apps": [{"name": "X", "launch": "x", "windowTitleContains": null, "submitKeys": null, "#
            + #""newLineKeys": null, "aliases": null, "processNames": null}]}"#:
            #"[{"name":"X","aliases":[],"launch":"x","processNames":[],"submitKeys":"","#
            + #""newLineKeys":"Shift\u002BEnter"}]"#,
        #"{"apps": [null]}"#: "[]",
        #"{"apps": [{"name": "X", "launch": "x", "aliases": ["a", null]}]}"#:
            #"[{"name":"X","aliases":["a"],"launch":"x","processNames":[],"submitKeys":"Enter","#
            + #""newLineKeys":"Shift\u002BEnter"}]"#,
        #"{"apps": [{"name": null, "launch": "x"}]}"#: "[]",
        #"{"wakeWords": ["a", null]}"#: #"["a"]"#,
        #"{"replacements": {"a": null}}"#: "{}",
    ]

    /// Every input Windows' `LoadForEdit` was given (settingsReadingVectors), read from a file as Windows reads it:
    /// what it read, key by key, as Windows writes it on one line; the line of a mistake; or a confidence it reads but
    /// can't write back.
    func testSettingsReadAsWindowsReadsThem() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let path = folder.file("settings.json")
        let defaults = AppSettings()
        var counts: [String: Int] = [:]
        for line in Escaped.lines(settingsReadingVectors) {
            let fields = Escaped.fields(line)
            let (kind, input) = (fields[0], fields[1])
            let text = NetJSON.text(Array(input.utf8))
            counts[kind, default: 0] += 1
            switch kind {
            case "O":
                let settings = try XCTUnwrap(AppSettings.parse(text) ?? (input == "null" ? defaults : nil), input)
                let expected: [(key: String, json: String)] = fields[2].isEmpty ? [] : fields[2]
                    .split(separator: "\u{2}")
                    .map { entry in
                        let parts = entry.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
                        return (key: String(parts[0]), json: String(parts[1]))
                    }
                for (key, windows) in expected {
                    let field = try XCTUnwrap(AppSettings.fields.first { $0.key == key }, key)
                    let mac = try field.value(settings).map { try NetJSON.write($0, indented: false) }
                    if windows == "~" {
                        // Windows read null: the Mac clears an optional setting, empties the vocabulary (as Windows
                        // then does) and keeps every other default.
                        let defaultJSON = try field.value(defaults).map { try NetJSON.write($0, indented: false) }
                        let macNull: String? = key == "dictationVocabulary" ? "[]" : defaultJSON
                        XCTAssertEqual(mac, macNull, "\(input): \(key)")
                    } else {
                        XCTAssertEqual(mac, Self.macWhereWindowsReadsNull[input] ?? windows, "\(input): \(key)")
                    }
                }
            case "E":
                XCTAssertThrowsError(try AppSettings.parse(text), input)
                TestFiles.write(path, input)
                XCTAssertThrowsError(try AppSettings.loadForEdit(from: path), input) { error in
                    XCTAssertEqual((error as? AppSettings.ReadError)?.message, fields[2], input)
                }
            case "I":
                let settings = try XCTUnwrap(AppSettings.parse(text), input)
                XCTAssertEqual(settings.minCommandConfidence.bitPattern, UInt32(fields[2], radix: 16), input)
                XCTAssertThrowsError(try settings.fileText(), input)
                XCTAssertThrowsError(try settings.save(to: path), input)
            default:
                XCTFail("Windows threw \(fields[2]) for \(input)")
            }
        }

        XCTAssertEqual(counts, ["O": 51, "E": 72, "I": 3])
    }

    func testAMissingFileGetsTheDefaultsWhichAreSaved() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let path = folder.file("VoiceAssistant/settings.json")

        let settings = AppSettings.loadOrCreate(from: path)

        XCTAssertEqual(settings, AppSettings())
        XCTAssertEqual(TestFiles.text(path), try AppSettings().fileText())
        XCTAssertFalse(TestFiles.exists(path + ".tmp"))
    }

    func testAFileHoldingNullIsReplacedWithTheDefaultsAsOnWindows() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let path = folder.file("settings.json")
        TestFiles.write(path, "null")

        XCTAssertEqual(try AppSettings.loadForEdit(from: path), AppSettings())
        XCTAssertEqual(TestFiles.text(path), "null")
        XCTAssertEqual(AppSettings.loadOrCreate(from: path), AppSettings())
        XCTAssertEqual(TestFiles.text(path), try AppSettings().fileText())
    }

    func testAFileThatCantBeReadGivesTheDefaultsAndIsLeftAlone() throws {
        let folder = TempFolder()
        defer {
            Log.stop()
            folder.remove()
        }

        Log.start(in: folder.file("logs"))
        let path = folder.file("settings.json")
        let file = "{\n  \"threads\": 4,\n  \"hotkey\": Ctrl+Alt+Space\n}"
        TestFiles.write(path, file)

        XCTAssertEqual(AppSettings.loadOrCreate(from: path), AppSettings())
        XCTAssertEqual(TestFiles.text(path), file)
        let warning = "WARN settings unreadable, using defaults: JSON mistake near line 3"
        XCTAssertEqual(TestFiles.lastLogLine(folder.file("logs")), warning)
        XCTAssertThrowsError(try AppSettings.loadForEdit(from: path)) { error in
            XCTAssertEqual(error.localizedDescription, "settings.json has an error near line 3")
        }
    }

    func testLoadForEditWithoutAFileGivesTheDefaultsAndWritesNothing() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let path = folder.file("settings.json")

        XCTAssertEqual(try AppSettings.loadForEdit(from: path), AppSettings())
        XCTAssertFalse(TestFiles.exists(path))

        // A folder in its place counts as no file, as File.Exists says.
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        XCTAssertEqual(try AppSettings.loadForEdit(from: path), AppSettings())
    }

    func testAChangedSettingIsSavedAndReadBack() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let path = folder.file("settings.json")
        TestFiles.write(path, windowsCustomSettings)

        var settings = try AppSettings.loadForEdit(from: path)
        settings.endSilenceMs = 1500
        settings.dictationKey = .rightOption
        settings.snippets["my signature"] = "Cheers,\nShivam"
        try settings.save(to: path)

        XCTAssertEqual(try AppSettings.loadForEdit(from: path), settings)
        XCTAssertEqual(AppSettings.loadOrCreate(from: path).dictationKey, .rightOption)
        XCTAssertTrue(TestFiles.text(path).hasSuffix(",\n  \"dictationKey\": \"RightOption\"\n}"))
        XCTAssertFalse(TestFiles.exists(path + ".tmp"))
    }

    /// What the Windows harness printed for the same files (its probe): .NET's File.ReadAllText picks the encoding from
    /// a byte order mark, and reads anything else as UTF-8, a byte that isn't UTF-8 becoming U+FFFD.
    func testEncodingsReadAsWindowsReadsThem() throws {
        let json = #"{"threads": 3, "modelFile": "café.bin"}"#
        let utf16 = Array(json.utf16)
        let littleEndian = utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let bigEndian = utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let utf32 = json.unicodeScalars.flatMap { scalar in (0..<4).map { UInt8((scalar.value >> (8 * $0)) & 0xFF) } }
        let files: [(String, [UInt8])] = [
            ("UTF-8", Array(json.utf8)),
            ("UTF-8 with a byte order mark", [0xEF, 0xBB, 0xBF] + Array(json.utf8)),
            ("UTF-16 little-endian", [0xFF, 0xFE] + littleEndian),
            ("UTF-16 big-endian", [0xFE, 0xFF] + bigEndian),
            ("UTF-32 little-endian", [0xFF, 0xFE, 0x00, 0x00] + utf32),
        ]
        for (name, bytes) in files {
            let settings = try XCTUnwrap(try AppSettings.parse(NetJSON.text(bytes)), name)
            XCTAssertEqual(settings.threads, 3, name)
            XCTAssertEqual(settings.modelFile, "café.bin", name)
        }

        let broken = Array(#"{"threads": 3, "modelFile": "a"#.utf8) + [0xFF, 0xC3] + Array(#"b.bin"}"#.utf8)
        XCTAssertEqual(try AppSettings.parse(NetJSON.text(broken))?.modelFile, "a\u{FFFD}\u{FFFD}b.bin")
        let withoutMark = Array(#"{"threads": 3}"#.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertThrowsError(try AppSettings.parse(NetJSON.text(withoutMark)))
    }

    func testTheDictationKeyIsFnOrRightOptionInAnyCase() throws {
        let cases: [(String, FnTapKeys.TapKey?)] = [
            (#"{"dictationKey": "Fn"}"#, .fn),
            (#"{"dictationKey": " rightoption "}"#, .rightOption),
            (#"{"dictationKey": "FN"}"#, .fn),
            (#"{"dictationKey": null}"#, .fn),
            (#"{}"#, .fn),
            (#"{"dictationKey": "Right Option"}"#, nil),
            (#"{"dictationKey": "Fn,RightOption"}"#, nil),
            (#"{"dictationKey": 1}"#, nil),
        ]
        for (file, expected) in cases {
            if let expected {
                XCTAssertEqual(try AppSettings.parse(file)?.dictationKey, expected, file)
            } else {
                XCTAssertThrowsError(try AppSettings.parse(file), file)
            }
        }
    }

    /// Windows' default replacements ignore case (StringComparer.OrdinalIgnoreCase); a file's don't, as .NET reads it.
    func testOnlyTheDefaultPairsIgnoreCase() throws {
        var defaults = AppSettings().replacements
        defaults["Git Hub"] = "GITHUB"
        XCTAssertEqual(defaults.pairs.map { $0.key }, ["git hub", "co-pilot", "co pilot"])
        XCTAssertEqual(defaults["GIT HUB"], "GITHUB")

        var read = try XCTUnwrap(try AppSettings.parse(windowsDefaultSettings)).replacements
        read["Git Hub"] = "GITHUB"
        XCTAssertEqual(read.pairs.map { $0.key }, ["git hub", "co-pilot", "co pilot", "Git Hub"])
        XCTAssertNil(read["GIT HUB"])
        read["co-pilot"] = nil
        XCTAssertEqual(read.pairs.map { $0.key }, ["git hub", "co pilot", "Git Hub"])
    }

    /// The Mac's apps are found by bundle identifier, with Mac keys; the core's app catalog finds them by name.
    func testTheMacsAppsAreFoundByNameAndBundleIdentifier() {
        let catalog = AppCatalog(AppSettings.defaultApps)
        for (spoken, name) in [
            ("text edit", "TextEdit"), ("notes", "Notes"), ("safari", "Safari"), ("chrome", "Google Chrome"),
            ("edge", "Microsoft Edge"), ("firefox", "Firefox"), ("copilot app", "GitHub Copilot"),
        ] {
            guard case .found(let app) = catalog.resolve(spoken) else {
                XCTFail("\(spoken) isn't found")
                continue
            }

            XCTAssertEqual(app.name, name, spoken)
        }

        XCTAssertEqual(catalog.resolve("notepad"), .notFound)
        XCTAssertEqual(catalog.findProfileForProcess("com.apple.Safari", "Apple")?.addressBarKeys, "Cmd+L")
        XCTAssertEqual(catalog.findProfileForProcess("com.github.githubapp", "Untitled")?.textAreaName, "Message")
        XCTAssertEqual(catalog.findProfileForProcess("com.apple.Notes", nil)?.newDocumentKeys, "Cmd+N")
        for app in AppSettings.defaultApps {
            XCTAssertEqual(app.processNames, [app.launch], app.name)
            for keys in [app.submitKeys, app.newLineKeys] + [app.searchKeys, app.newWindowKeys].compactMap({ $0 }) {
                XCTAssertFalse(keys.contains("Ctrl") || keys.contains("Alt"), "\(app.name): \(keys)")
            }
        }
    }

    func testTheMacHotkeysAreControlShiftWithWindowsKeys() {
        let settings = AppSettings()

        XCTAssertEqual(settings.hotkey, "Ctrl+Shift+Space")
        XCTAssertEqual(settings.pasteLastHotkey, "Ctrl+Shift+Z")
        XCTAssertEqual(settings.dictationLanguageHotkey, "Ctrl+Shift+H")
    }
}
