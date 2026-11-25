import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// Choosing the text box to type in (C#'s `PrepareTextTarget`, `FindTextArea`, `FocusSearchBox`, `EditableCandidates`),
/// and the time limit around such work.
final class TextTargetTests: XCTestCase {
    private static let copilot = AppEntry(
        name: "GitHub Copilot", launch: "com.github.copilot", processNames: ["com.github.copilot"], textArea: "Bottom",
        textAreaName: "Message")

    private func button() -> FakeElement {
        FakeElement(role: kAXButtonRole, title: "New", frame: CGRect(x: 10, y: 10, width: 60, height: 20))
    }

    private func window(_ rig: Rig, _ boxes: [FakeElement], focus: FakeElement? = nil) -> WindowInfo {
        let window = rig.front(focus: focus)
        let pane = FakeElement(role: kAXGroupRole)
        pane.children = boxes
        window.children.append(pane)
        return rig.desktop.foregroundWindow()!
    }

    // MARK: prepareTextTarget

    func testTheFocusedBoxIsReady() async throws {
        let rig = Rig()
        let box = FakeElement.textField()
        box.holds("Hi")
        let front = window(rig, [], focus: box)
        let result = try await rig.desktop.prepareTextTarget(front, profile: nil)
        XCTAssertEqual(
            TextTargetResult(success: true, message: "", hasTrailingText: true, focusIsEditable: true), result)
    }

    func testRefusesPasswordsAndWhatCantBeChecked() async throws {
        let rig = Rig()
        let password = FakeElement.textField()
        password[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        var front = window(rig, [], focus: password)
        var result = try await rig.desktop.prepareTextTarget(front, profile: nil)
        XCTAssertEqual(
            TextTargetResult(success: false, message: "That's a password field — I won't type there."), result)

        front = window(rig, [])
        result = try await rig.desktop.prepareTextTarget(front, profile: nil)
        XCTAssertEqual(
            TextTargetResult(
                success: false,
                message: "I couldn't check the focused field. Click into the text box, then say “start typing”."),
            result)
    }

    /// Nothing editable has the focus in a window without a profile: it's ready, and says so for the core to choose.
    func testWithoutAProfileTheFocusIsChecked() async throws {
        let rig = Rig()
        let front = window(rig, [FakeElement.textArea()], focus: button())
        let result = try await rig.desktop.prepareTextTarget(front, profile: nil)
        XCTAssertEqual(
            TextTargetResult(success: true, message: "", hasTrailingText: nil, focusIsEditable: false), result)
    }

    /// "Bottom": the lowest box at least 120 points wide, named as the profile says, is focused.
    func testFocusesTheProfilesTextAreaAtTheBottom() async throws {
        let rig = Rig()
        let editor = FakeElement.textArea(name: "Message", frame: CGRect(x: 300, y: 100, width: 600, height: 300))
        let message = FakeElement.textArea(name: "Message", frame: CGRect(x: 10, y: 600, width: 500, height: 60))
        let narrow = FakeElement.textArea(name: "Message", frame: CGRect(x: 10, y: 700, width: 100, height: 40))
        let search = FakeElement.textField(name: "Search", frame: CGRect(x: 10, y: 750, width: 300, height: 24))
        let front = window(rig, [editor, message, narrow, search], focus: button())
        let result = try await rig.desktop.prepareTextTarget(front, profile: Self.copilot)
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(true, result.focusIsEditable)
        XCTAssertTrue(rig.ax.focused === message)
        XCTAssertEqual(["AXFocused=true"], message.changes)
    }

    /// The focus in another box than the one named moves to it.
    func testMovesTheFocusToTheNamedBox() async throws {
        let rig = Rig()
        let editor = FakeElement.textArea(name: "Editor", frame: CGRect(x: 10, y: 100, width: 600, height: 300))
        let message = FakeElement.textArea(frame: CGRect(x: 10, y: 50, width: 400, height: 40))
        message[kAXHelpAttribute] = "Message Copilot"
        let front = window(rig, [editor, message], focus: editor)
        let result = try await rig.desktop.prepareTextTarget(front, profile: Self.copilot)
        XCTAssertTrue(result.success, result.message)
        XCTAssertTrue(rig.ax.focused === message)
    }

    /// "Largest": the biggest box, for a document editor.
    func testFocusesTheLargestTextArea() async throws {
        let rig = Rig()
        let small = FakeElement.textArea(frame: CGRect(x: 10, y: 600, width: 300, height: 60))
        let page = FakeElement.textArea(frame: CGRect(x: 10, y: 50, width: 800, height: 500))
        let front = window(rig, [small, page], focus: button())
        let notes = AppEntry(
            name: "Notes", launch: "com.apple.Notes", processNames: ["com.apple.Notes"], textArea: "Largest")
        let result = try await rig.desktop.prepareTextTarget(front, profile: notes)
        XCTAssertTrue(result.success, result.message)
        XCTAssertTrue(rig.ax.focused === page)
    }

    /// Disabled, password, read-only, unfocusable and hidden boxes aren't candidates; none left is said so, after a
    /// second look 0.4 s later (Chromium describes its page once asked).
    func testSaysWhenThereIsNowhereToType() async throws {
        let rig = Rig()
        let disabled = FakeElement.textArea(name: "Message")
        disabled[kAXEnabledAttribute] = false
        let password = FakeElement.textField(name: "Message")
        password[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        let readOnly = FakeElement.textArea(name: "Message", editable: false)
        let unfocusable = FakeElement.textArea(name: "Message")
        unfocusable.settable[kAXFocusedAttribute] = false
        let hidden = FakeElement.textArea(name: "Message", frame: CGRect(x: 5_000, y: 5_000, width: 300, height: 60))
        let front = window(rig, [disabled, password, readOnly, unfocusable, hidden], focus: button())
        let start = rig.time.now
        let result = try await rig.desktop.prepareTextTarget(front, profile: Self.copilot)
        XCTAssertEqual(
            TextTargetResult(
                success: false,
                message: "I couldn't find where to type in GitHub Copilot. Click it once, then say “start typing”."),
            result)
        XCTAssertEqual(0.4, rig.time.now - start, accuracy: 0.001)
    }

    func testSaysWhenTheFocusWontMove() async throws {
        let rig = Rig()
        let message = FakeElement.textArea(name: "Message")
        message.takesFocus = false
        let front = window(rig, [message], focus: button())
        let result = try await rig.desktop.prepareTextTarget(front, profile: Self.copilot)
        XCTAssertEqual(
            TextTargetResult(
                success: false,
                message: "I couldn't focus the text area in GitHub Copilot. Click it once, then say “start typing”."),
            result)
    }

    // MARK: focusSearchBox

    /// A box whose name, identifier or help text says "search", or a search field in any language; the top-most wins.
    func testFocusesTheTopMostSearchBox() async throws {
        let rig = Rig()
        let lower = FakeElement.textField(name: "Search mail", frame: CGRect(x: 10, y: 300, width: 300, height: 24))
        let upper = FakeElement.textField(frame: CGRect(x: 10, y: 40, width: 300, height: 24))
        upper["AXDOMIdentifier"] = "site-search"
        let other = FakeElement.textField(name: "To", frame: CGRect(x: 10, y: 10, width: 300, height: 24))
        let front = window(rig, [lower, upper, other], focus: button())
        let result = try await rig.desktop.focusSearchBox(front)
        XCTAssertEqual(TextTargetResult(success: true, message: ""), result)
        XCTAssertTrue(rig.ax.focused === upper)
    }

    func testASearchFieldSaysItInAnyLanguage() async throws {
        let rig = Rig()
        let field = FakeElement.textField(name: "Suchen")
        field[kAXSubroleAttribute] = kAXSearchFieldSubrole
        let help = FakeElement.textField(frame: CGRect(x: 10, y: 5, width: 300, height: 24))
        help[kAXHelpAttribute] = "Type to SEARCH"
        let front = window(rig, [field, help], focus: button())
        _ = try await rig.desktop.focusSearchBox(front)
        XCTAssertTrue(rig.ax.focused === help)

        help[kAXHelpAttribute] = nil
        rig.ax.focused = nil
        _ = try await rig.desktop.focusSearchBox(front)
        XCTAssertTrue(rig.ax.focused === field)
    }

    /// Messages name the app as macOS does (Windows names the window by its title, which names the app there).
    func testSaysWhenThereIsNoSearchBox() async throws {
        let rig = Rig()
        var front = window(rig, [FakeElement.textField(name: "To")], focus: button())
        var result = try await rig.desktop.focusSearchBox(front)
        XCTAssertEqual(TextTargetResult(success: false, message: "I couldn't find a search box in TextEdit."), result)

        let search = FakeElement.textField(name: "Search")
        search.takesFocus = false
        front = window(rig, [search], focus: button())
        result = try await rig.desktop.focusSearchBox(front)
        XCTAssertEqual(
            TextTargetResult(
                success: false,
                message: "I couldn't focus the search box in TextEdit. Click it once, then say “start typing”."),
            result)
    }

    // MARK: Time limits

    /// Work that takes too long comes back as timed out, its token cancelled so it never acts afterwards.
    func testWorkThatTakesTooLongTimesOut() async throws {
        let token = Background.Answer<WorkToken>()
        let outcome = try await Background.run(0.05) { work -> Int in
            token.set(work)
            Thread.sleep(forTimeInterval: 0.5)
            return 1
        }

        guard case .timedOut = outcome else { return XCTFail("finished") }
        try await Self.waitFor(token)
        XCTAssertEqual(true, token.value?.isCancelled)

        let quick = try await Background.run(5) { _ in 2 }
        guard case .finished(let value) = quick else { return XCTFail("timed out") }
        XCTAssertEqual(2, value)

        let waited = Background.wait(0.05) { () -> Int in
            Thread.sleep(forTimeInterval: 0.5)
            return 3
        }

        guard case .timedOut = waited else { return XCTFail("finished") }
    }

    /// Cancelling the caller's task cancels the work's token and throws, as C#'s WaitAsync does with a token.
    func testCancellingTheTaskCancelsTheWork() async throws {
        let token = Background.Answer<WorkToken>()
        let task = Task {
            try await Background.run(5) { work -> Int in
                token.set(work)
                Thread.sleep(forTimeInterval: 0.3)
                return 1
            }
        }

        try await Self.waitFor(token)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(true, token.value?.isCancelled)
    }

    /// Waits up to 5 s for the work to have started.
    private static func waitFor(_ token: Background.Answer<WorkToken>) async throws {
        for _ in 0..<500 where token.value == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
