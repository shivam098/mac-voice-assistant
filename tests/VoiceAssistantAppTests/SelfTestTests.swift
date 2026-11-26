import Foundation
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantApp

/// The scripted self-test (windows-voice-assistant `SelfTest`) on a fake desktop: what it records, and what it never
/// records.
final class SelfTestTests: XCTestCase {
    func testAScriptRunsThroughTheControllerAndRecordsOnlyChecksAndKinds() async throws {
        let output = try await run(
            """
            # Comments and blank lines are skipped.

            listen
            say: hey jarvis
            fg
            expecttitle: notes
            expectfocus: MESSAGE
            ptt: hello world
            read
            expect: Hello
            expectvalue: Hello world.
            expectboard: Todo Draft a reply
            clipboard
            insert Type
            typing 50 10
            """)

        XCTAssertFalse(output.contains("Comments"))
        XCTAssertTrue(output.contains("> listen\n   [Standby] Info: Say “…” to give a command.\n"))
        XCTAssertTrue(output.contains("> say: hey jarvis\n   [Command] Info: Yes? Say a command.\n"))
        XCTAssertTrue(output.contains("> fg\n   foreground: com.apple.TextEdit\n"))
        XCTAssertTrue(output.contains("   PASS: foreground title contains the expected phrase\n"))
        XCTAssertTrue(output.contains("   PASS: focused control has the expected name\n"))
        XCTAssertTrue(output.contains("> ptt: hello world\n   [Command] Success: Typed.\n"))
        XCTAssertTrue(output.contains("   focused: AXTextArea len=12 hash=\(SelfTest.hash("Hello world."))\n"))
        XCTAssertTrue(output.contains("   PASS: focused text contains the expected phrase (field len=12)\n"))
        XCTAssertTrue(
            output.contains("   PASS: focused text equals the expected text (field len=12, expected len=12)\n"))
        XCTAssertTrue(output.contains("   FAIL: board does not have the expected note (notes=0)\n"))
        XCTAssertTrue(output.contains("   clipboard fingerprint: formats=[(empty)] textHash=E3B0C44298FC len=0\n"))
        XCTAssertTrue(output.hasSuffix("> typing 50 10\n"))
        XCTAssertEqual(insertMethod.value, "Type")

        // The window's title stays out of it.
        XCTAssertFalse(output.contains("Notes.txt"))
    }

    func testStopOnFailStopsAtTheFirstFailedCheck() async throws {
        let output = try await run(
            """
            stoponfail
            expecttitle: Nav Lab
            say: hey jarvis
            listen
            """)

        XCTAssertTrue(
            output.hasSuffix(
                "> expecttitle: Nav Lab\n   FAIL: foreground title does not contain the expected phrase\n"
                    + "> say: hey jarvis\n!! stopped after a failed check\n"))
    }

    func testANumberThatIsntOneEndsTheScriptAsWindowsSays() async throws {
        let output = try await run("wait soon\nlisten\n")

        XCTAssertTrue(
            output.hasSuffix("> wait soon\n!! FormatException: The input string 'soon' was not in a correct format.\n"))
    }

    /// `braindownload` is ok once the AI brain's files are all here, even when its model then can't start: that isn't
    /// a failed download (C#'s `BrainError` is the download's alone). A download that stops with files missing fails.
    func testABrainDownloadIsOkOnceItsFilesAreHereEvenIfTheModelCantStart() async throws {
        let startFails = FakeBrain(missingBytes: 100) { brain in
            brain.missingBytes = 0
            brain.change(to: .installed)
            brain.change(to: .starting)
            brain.change(to: .failed("It couldn't start: llama-server stopped. It tries again when you next ask."))
        }

        let downloadStops = FakeBrain(missingBytes: 100) { brain in
            brain.missingBytes = 40
            brain.change(to: .failed("The download stopped. Check the internet connection and try again."))
        }

        let started = try await run("braindownload\n", brain: startFails)
        let stopped = try await run("braindownload\n", brain: downloadStops)

        XCTAssertTrue(started.contains("> braindownload\n"))
        XCTAssertTrue(started.contains("   brain download: ok\n"))
        XCTAssertTrue(stopped.contains("   brain download: failed\n"))
    }

    func testStatusLinesAreRedacted() {
        XCTAssertEqual(
            SelfTest.redact("Typing into “Notes.txt”. Say “stop typing” when done."),
            "Typing into “…”. Say “…” when done.")
        XCTAssertEqual(SelfTest.choicesLine(nil), "   choices shown: 0")
        XCTAssertEqual(
            SelfTest.choicesLine([
                ChoiceBadge(number: 1, rect: ScreenRect(x: 10.4, y: 20.6, width: 30, height: 40), label: "Save")
            ]),
            "   choices shown: 1 at 10,21 30x40")
    }

    private let insertMethod = Locked("Paste")

    /// The script's output, run with the fake desktop and focus (a text area holding "Hello world."), and `brain`.
    private func run(_ script: String, brain: AssistantBrain? = nil) async throws -> String {
        let folder = TempFolder()
        defer { folder.remove() }
        let path = folder.file("lab.selftest.txt")
        TestFiles.write(path, script)
        let desktop = FakeDesktop()
        desktop.focus = FocusInfo(name: "Message", editable: true, inPage: true)
        let paths = AppPaths(data: folder.path, logs: folder.file("logs"))
        let parts = HostParts(
            desktop: desktop, microphone: FakeMicrophone(), speech: FakeSpeech(),
            models: FakeModels(folder: paths.models, present: []), brain: brain, makeSounds: { FakeCues(enabled: $0) },
            copyText: { _ in })
        let insertMethod = self.insertMethod
        let platform = SelfTestPlatform(
            focusedText: { (kind: "AXTextArea", text: "Hello world.") },
            clipboardFingerprint: { "formats=[(empty)] textHash=\(SelfTest.hash("")) len=0" },
            setInsertMethod: { insertMethod.value = $0 })
        let events = DispatchQueue(label: "VoiceAssistantAppTests.selfTest")
        await SelfTest.run(
            scriptPath: path, outputPath: folder.file("lab.out.txt"), settings: AppSettings(), paths: paths,
            parts: parts, platform: platform, post: { events.async(execute: $0) })
        return TestFiles.text(folder.file("lab.out.txt"))
    }
}
