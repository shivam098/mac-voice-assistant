import ApplicationServices
import VoiceAssistantCore
import XCTest
@testable import VoiceAssistantMac

/// What has the focus (C#'s `CheckFocusedField`, `DescribeFocus`), the text before the cursor, the end of the box's
/// text, and the default button, read from fake apps.
final class FocusTests: XCTestCase {
    private func element(_ role: String, subrole: String? = nil) -> FakeElement {
        FakeElement(role: role, subrole: subrole, frame: CGRect(x: 10, y: 10, width: 100, height: 20))
    }

    // MARK: checkFocusedField

    func testATextBoxIsSafeAndAPasswordBoxIsnt() {
        let rig = Rig()
        rig.front(focus: .textField())
        XCTAssertEqual(.safe, rig.desktop.checkFocusedField())

        let password = FakeElement.textField()
        password[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        rig.front(focus: password)
        XCTAssertEqual(.password, rig.desktop.checkFocusedField())
    }

    func testUnknownWithoutAFocusOrAnAnswer() {
        let rig = Rig()
        rig.front()
        XCTAssertEqual(.unknown, rig.desktop.checkFocusedField())

        rig.front(focus: .textField())
        rig.ax.answers = false
        XCTAssertEqual(.unknown, rig.desktop.checkFocusedField())
    }

    func testWhatPositivelyTakesNoTextIsNotText() {
        let rig = Rig()
        for role in [kAXButtonRole, kAXListRole, kAXTableRole, kAXOutlineRole, kAXRowRole, "AXLink", kAXMenuItemRole,
                     kAXRadioButtonRole, kAXCheckBoxRole, kAXImageRole, kAXTabGroupRole] {
            rig.front(focus: element(role))
            XCTAssertEqual(.notText, rig.desktop.checkFocusedField(), role)
        }
    }

    /// Documents, panes, custom controls, spreadsheet cells and terminals still get the text.
    func testAnythingElseIsSafe() {
        let rig = Rig()
        let terminal = FakeElement.textArea(editable: false)
        for focused in [element("AXWebArea"), element(kAXGroupRole), element(kAXCellRole), terminal] {
            rig.front(focus: focused)
            XCTAssertEqual(.safe, rig.desktop.checkFocusedField())
        }
    }

    func testTheDockTakesNoText() {
        let rig = Rig()
        rig.front(7, "com.apple.dock", "Dock", window: nil, focus: element(kAXDockItemRole))
        XCTAssertEqual(.notText, rig.desktop.checkFocusedField())
        rig.ax.focused = nil
        XCTAssertEqual(.notText, rig.desktop.checkFocusedField())
    }

    /// Finder's desktop is a "window" whose role is AXScrollArea: its icons take no text, renaming one does.
    func testFindersDesktopTakesNoTextButARenameDoes() {
        let rig = Rig()
        let desktop = FakeElement(pid: 8, role: kAXScrollAreaRole)
        let icons = FakeElement(pid: 8, role: kAXGroupRole)
        desktop.children = [icons]
        rig.front(8, "com.apple.finder", "Finder", window: desktop, focus: nil)
        rig.ax.focused = icons
        XCTAssertEqual(.notText, rig.desktop.checkFocusedField())

        let rename = FakeElement.textField(pid: 8)
        icons.children = [rename]
        rig.ax.focused = rename
        XCTAssertEqual(.safe, rig.desktop.checkFocusedField())

        // A Finder window is no desktop: there only what positively takes no text is.
        let window = FakeElement.window(pid: 8, title: "Documents", number: 81)
        rig.front(8, "com.apple.finder", "Finder", window: window, focus: element(kAXGroupRole))
        XCTAssertEqual(.safe, rig.desktop.checkFocusedField())
    }

    // MARK: describeFocus

    func testDescribesTheFocusedBox() {
        let rig = Rig()
        let page = FakeElement(role: "AXWebArea")
        let group = FakeElement(role: kAXGroupRole)
        let box = FakeElement.textField(name: "Search")
        page.children = [group]
        group.children = [box]
        let window = rig.front()
        window.children = [page]
        rig.ax.focused = box
        XCTAssertEqual(
            FocusInfo(name: "Search", editable: true, inPage: true, addressBar: false), rig.desktop.describeFocus())
    }

    /// Chromium's address bar says so in AXDOMClassList, in any language, and isn't in the page.
    func testRecognisesChromiumsAddressBar() {
        let rig = Rig()
        let omnibox = FakeElement.textField(name: "Adress- und Suchleiste")
        omnibox["AXDOMClassList"] = ["OmniboxViewViews"]
        rig.front(9, "com.google.Chrome", "Google Chrome", focus: omnibox)
        XCTAssertEqual(
            FocusInfo(name: "Adress- und Suchleiste", editable: true, inPage: false, addressBar: true),
            rig.desktop.describeFocus())
    }

    /// A name is the title, else the description, else the label's text, else the placeholder.
    func testNamesComeFromTitleDescriptionLabelOrPlaceholder() {
        let rig = Rig()
        let box = FakeElement.textField()
        rig.front(focus: box)
        box["AXPlaceholderValue"] = "Type a message"
        XCTAssertEqual("Type a message", rig.desktop.describeFocus()?.name)

        let label = FakeElement(role: kAXStaticTextRole)
        label[kAXValueAttribute] = "To:"
        box[kAXTitleUIElementAttribute] = label
        XCTAssertEqual("To:", rig.desktop.describeFocus()?.name)

        box[kAXDescriptionAttribute] = "Recipients"
        XCTAssertEqual("Recipients", rig.desktop.describeFocus()?.name)

        box[kAXTitleAttribute] = "To"
        XCTAssertEqual("To", rig.desktop.describeFocus()?.name)
    }

    func testNoFocusIsNoDescription() {
        let rig = Rig()
        rig.front()
        XCTAssertNil(rig.desktop.describeFocus())
        rig.front(focus: .textField())
        rig.ax.answers = false
        XCTAssertNil(rig.desktop.describeFocus())
    }

    // MARK: readTextBeforeCaret

    func testReadsTheTextBeforeTheCursor() {
        let rig = Rig()
        let box = FakeElement.textArea()
        box.holds("Hello world", cursor: 5)
        rig.front(focus: box)
        XCTAssertEqual(CaretText(before: "Hello", caretKnown: true), rig.desktop.readTextBeforeCaret())

        box.holds("Hello world", cursor: 5, selected: 3)
        XCTAssertEqual(
            CaretText(before: "Hello", caretKnown: true, hasSelection: true), rig.desktop.readTextBeforeCaret())
    }

    /// Without a cursor the whole text is read, the cursor taken to be at the end; without ranges, the value's start.
    func testWithoutACursorOrRangesTheValueIsRead() {
        let rig = Rig()
        let box = FakeElement.textArea()
        box.holds("Hello world", cursor: 5)
        box.givesRanges = false
        rig.front(focus: box)
        XCTAssertEqual(CaretText(before: "Hello", caretKnown: true), rig.desktop.readTextBeforeCaret())

        box.selection = nil
        XCTAssertEqual(CaretText(before: "Hello world", caretKnown: false), rig.desktop.readTextBeforeCaret())
    }

    /// At most the last 20,000 UTF-16 units (C#'s MaxChars), fetched on their own with one more; half an emoji cut at
    /// the start goes, where C# keeps it.
    func testReadsAtMostTheLast20000Units() {
        let rig = Rig()
        let box = FakeElement.textArea()
        box.holds(String(repeating: "a", count: 25_000))
        rig.front(focus: box)
        XCTAssertEqual(20_000, rig.desktop.readTextBeforeCaret()?.before.utf16.count)
        XCTAssertEqual(4_999, rig.ax.rangesRead.last?.location)
        XCTAssertEqual(20_001, rig.ax.rangesRead.last?.length)

        box.holds("x😀" + String(repeating: "b", count: 19_999))
        XCTAssertEqual(String(repeating: "b", count: 19_999), rig.desktop.readTextBeforeCaret()?.before)
    }

    func testPasswordsAndReadOnlyText() {
        let rig = Rig()
        let password = FakeElement.textField()
        password[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        password.holds("secret")
        rig.front(focus: password)
        XCTAssertNil(rig.desktop.readTextBeforeCaret())

        let output = FakeElement.textArea(editable: false)
        output.holds("$ ls")
        rig.front(focus: output)
        XCTAssertEqual(CaretText(before: "$ ls", caretKnown: true, editable: false), rig.desktop.readTextBeforeCaret())

        rig.ax.focused = nil
        XCTAssertNil(rig.desktop.readTextBeforeCaret())
    }

    /// A web page's editor whose value can't be set takes text all the same (AXEditableAncestor).
    func testAWebEditorIsEditable() {
        let rig = Rig()
        let editor = FakeElement.textArea(editable: false)
        editor["AXEditableAncestor"] = editor
        editor.holds("Dear Sam")
        rig.front(focus: editor)
        XCTAssertEqual(true, rig.readTextEditable())
    }

    // MARK: focusedTextEndsWithNonWhitespace

    /// The end of the box's whole text (C#'s `HasTrailingText` reads the ValuePattern's value), wherever the cursor is,
    /// read on its own.
    func testTellsWhetherTheTextEndsInAWord() {
        let rig = Rig()
        let box = FakeElement.textField()
        rig.front(focus: box)
        for (text, ends) in [("Hello", true), ("Hello ", false), ("", false), ("Hi 😀", true), ("a\n", false)] {
            box.holds(text, cursor: 0)
            XCTAssertEqual(ends, rig.desktop.focusedTextEndsWithNonWhitespace(), text)
        }

        box.holds("Hello world")
        rig.ax.rangesRead.removeAll()
        _ = rig.desktop.focusedTextEndsWithNonWhitespace()
        XCTAssertEqual([9], rig.ax.rangesRead.map(\.location))
        XCTAssertEqual([2], rig.ax.rangesRead.map(\.length))

        box.givesRanges = false
        XCTAssertEqual(true, rig.desktop.focusedTextEndsWithNonWhitespace())
    }

    func testUnknownForPasswordsAndControlsWithoutText() {
        let rig = Rig()
        let password = FakeElement.textField()
        password[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        password.holds("secret")
        rig.front(focus: password)
        XCTAssertNil(rig.desktop.focusedTextEndsWithNonWhitespace())

        rig.front(focus: element(kAXButtonRole))
        XCTAssertNil(rig.desktop.focusedTextEndsWithNonWhitespace())
    }

    // MARK: describeDefaultButton

    func testReadsTheWindowsDefaultButton() {
        let rig = Rig()
        let window = rig.front(focus: .textField())
        XCTAssertEqual(.noButton, rig.desktop.describeDefaultButton())

        let erase = element(kAXButtonRole)
        erase[kAXTitleAttribute] = "Erase"
        window[kAXDefaultButtonAttribute] = erase
        XCTAssertEqual(.named("Erase"), rig.desktop.describeDefaultButton())

        // A button that says nothing: its name couldn't be read, which counts as unknown.
        erase[kAXTitleAttribute] = nil
        XCTAssertEqual(.named(""), rig.desktop.describeDefaultButton())
    }

    /// Return goes to a sheet while it's open: the focus's sheet, or the sheet on the focus's window, or with nothing
    /// focused the sheet on the app's window. A sheet whose default button can't be read (the save panel's buttons are
    /// another process's) is unknown.
    func testASheetsDefaultButtonIsTheOneReturnPresses() {
        let rig = Rig()
        let window = rig.front()
        let send = element(kAXButtonRole)
        send[kAXTitleAttribute] = "Send"
        window[kAXDefaultButtonAttribute] = send
        let sheet = FakeElement(role: kAXSheetRole)
        let delete = element(kAXButtonRole)
        delete[kAXTitleAttribute] = "Delete"
        sheet[kAXDefaultButtonAttribute] = delete
        let field = FakeElement.textField()
        let behind = FakeElement.textField()
        sheet.children = [field, delete]
        window.children = [behind, sheet]
        XCTAssertEqual(.named("Delete"), rig.desktop.describeDefaultButton())

        rig.ax.focused = field
        XCTAssertEqual(.named("Delete"), rig.desktop.describeDefaultButton())

        rig.ax.focused = behind
        XCTAssertEqual(.named("Delete"), rig.desktop.describeDefaultButton())

        sheet[kAXDefaultButtonAttribute] = nil
        XCTAssertEqual(.unknown, rig.desktop.describeDefaultButton())
    }

    func testUnknownWhenTheWindowCantBeTold() {
        let rig = Rig()
        rig.front(focus: .textField())
        rig.ax.answers = false
        XCTAssertEqual(.unknown, rig.desktop.describeDefaultButton())

        rig.ax.answers = true
        rig.ax.focusedApp = nil
        rig.ax.focused = nil
        XCTAssertEqual(.unknown, rig.desktop.describeDefaultButton())
    }

    func testAnAppWithoutAWindowHasNoDefaultButton() {
        let rig = Rig()
        rig.front()
        rig.ax.focusedApp?[kAXFocusedWindowAttribute] = nil
        XCTAssertEqual(.noButton, rig.desktop.describeDefaultButton())
    }
}

extension Rig {
    /// Whether the text before the cursor counts as editable.
    func readTextEditable() -> Bool? { desktop.readTextBeforeCaret()?.editable }
}
