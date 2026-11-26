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

    /// Without Accessibility the desktop can neither read nor type: the run says so and runs nothing.
    func testWithoutAccessibilityNothingRuns() async throws {
        let output = try await run("listen\nsay: hey jarvis\n", missingPermissions: ["accessibility", "postEvents"])

        XCTAssertEqual(
            output,
            "!! missing permissions: accessibility, postEvents. Allow the app, or the terminal that starts it, in "
                + "System Settings › Privacy & Security › Accessibility. Nothing was run.\n")
    }

    /// Each line reaches the output file as it comes, so a run that hangs or is stopped leaves what it did.
    func testTheOutputIsWrittenAsTheRunGoes() async throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let output = folder.file("lab.out.txt")
        let running = start("listen\nwait 3000\nfg\n", in: folder, output: output)

        let waiting = await eventually(2.5) { TestFiles.text(output).hasSuffix("> wait 3000\n") }
        XCTAssertTrue(waiting)
        XCTAssertTrue(TestFiles.text(output).contains("> listen\n   [Standby] Info: Say “…” to give a command.\n"))
        await running.value
        XCTAssertTrue(TestFiles.text(output).hasSuffix("> wait 3000\n> fg\n   foreground: com.apple.TextEdit\n"))
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

    /// "show numbers" numbers what can be clicked: `expectchoices` checks how many show and `expectchoice` that one is
    /// on something with a name, never writing the names; the platform draws them as the app does, then hides them.
    func testChecksTheNumbersShownAndDrawsThem() async throws {
        let drawn = Locked<[Int]>([])
        let clickable = [
            UiElement(id: 1, name: "New", role: .button, rect: ScreenRect(x: 10, y: 10, width: 80, height: 30)),
            UiElement(id: 2, name: "Library", role: .link, rect: ScreenRect(x: 10, y: 60, width: 80, height: 30)),
        ]
        let output = try await run(
            """
            listen
            say: hey jarvis
            say: show numbers
            expectchoices: 2
            expectchoice: library
            expectchoice: Delete account
            say: hide numbers
            expectchoices: 0
            """,
            clickable: clickable, drawn: drawn)

        XCTAssertTrue(output.contains("   choices shown: 2 at 10,10 80x30; 10,60 80x30\n"))
        XCTAssertTrue(output.contains("> expectchoices: 2\n   PASS: 2 numbers shown, 2 expected\n"))
        XCTAssertTrue(
            output.contains(
                "> expectchoice: library\n   PASS: a number is on something with the expected name (numbers=2)\n"))
        XCTAssertTrue(
            output.contains(
                "> expectchoice: Delete account\n   FAIL: a number is not on something with the expected name "
                    + "(numbers=2)\n"))
        XCTAssertTrue(output.contains("> expectchoices: 0\n   PASS: 0 numbers shown, 0 expected\n"))
        XCTAssertFalse(output.contains("Library"))
        XCTAssertEqual([2, 0], drawn.value)
    }

    private let insertMethod = Locked("Paste")

    /// The script's output, run with the fake desktop and focus (a text area holding "Hello world."), `brain`, the
    /// permissions the desktop is missing, what the window in front has that can be clicked, and where the numbers
    /// drawn go (how many each time).
    private func run(
        _ script: String, brain: AssistantBrain? = nil, missingPermissions: [String] = [],
        clickable: [UiElement] = [], drawn: Locked<[Int]>? = nil
    ) async throws -> String {
        let folder = TempFolder()
        defer { folder.remove() }
        let output = folder.file("lab.out.txt")
        let running = start(
            script, in: folder, output: output, brain: brain, missingPermissions: missingPermissions,
            clickable: clickable, drawn: drawn)
        await running.value
        return TestFiles.text(output)
    }

    /// The self-test running `script` in `folder`, writing to `output`.
    private func start(
        _ script: String, in folder: TempFolder, output: String, brain: AssistantBrain? = nil,
        missingPermissions: [String] = [], clickable: [UiElement] = [], drawn: Locked<[Int]>? = nil
    ) -> Task<Void, Never> {
        let path = folder.file("lab.selftest.txt")
        TestFiles.write(path, script)
        let desktop = FakeDesktop()
        desktop.focus = FocusInfo(name: "Message", editable: true, inPage: true)
        desktop.clickable = clickable
        let paths = AppPaths(data: folder.path, logs: folder.file("logs"))
        let parts = HostParts(
            desktop: desktop, microphone: FakeMicrophone(), speech: FakeSpeech(),
            models: FakeModels(folder: paths.models, present: []), brain: brain, makeSounds: { FakeCues(enabled: $0) },
            copyText: { _ in })
        let insertMethod = self.insertMethod
        var showBadges: (@Sendable ([ChoiceBadge]?) -> Void)?
        if let drawn {
            showBadges = { badges in drawn.update { $0.append(badges?.count ?? 0) } }
        }

        let platform = SelfTestPlatform(
            focusedText: { (kind: "AXTextArea", text: "Hello world.") },
            clipboardFingerprint: { "formats=[(empty)] textHash=\(SelfTest.hash("")) len=0" },
            setInsertMethod: { insertMethod.value = $0 },
            missingPermissions: { missingPermissions },
            showBadges: showBadges)
        let events = DispatchQueue(label: "VoiceAssistantAppTests.selfTest")
        return Task {
            await SelfTest.run(
                scriptPath: path, outputPath: output, settings: AppSettings(), paths: paths, parts: parts,
                platform: platform, post: { events.async(execute: $0) })
        }
    }
}
