import ApplicationServices
import ThumbFreeCore
import VoiceAssistantCore

/// How the desktop reads elements: what UI Automation's properties and patterns tell on Windows
/// (windows-voice-assistant `WindowsDesktop`: `IsEditable`, `IsClearlyNotText`, `InPage`, names), from the
/// Accessibility API's roles and attributes. Each throws `AXNoAnswer` when the app doesn't answer.
extension AXSystem {
    func role(of element: AnyObject) throws -> String? { try string(kAXRoleAttribute, of: element) }

    func subrole(of element: AnyObject) throws -> String? { try string(kAXSubroleAttribute, of: element) }

    /// A password box (AXSecureTextField, as role or subrole, as ThumbFreeMac reads it): never typed into or read.
    func isSecure(_ element: AnyObject) throws -> Bool {
        let elementRole = try self.role(of: element)
        return try elementRole == kAXSecureTextFieldSubrole || subrole(of: element) == kAXSecureTextFieldSubrole
    }

    /// What the element is called, as UI Automation's Name: its title, else its description (accessibilityLabel and
    /// aria-label), else the text of the label that names it, else its placeholder (which Chromium names an unlabelled
    /// box with on Windows). Empty when it has none.
    func name(of element: AnyObject) throws -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = try string(attribute, of: element), !DotNet.isNullOrWhiteSpace(text) {
                return text
            }
        }

        return try labelName(of: element)
    }

    /// The name of an element that has neither title nor description: the text of the label that names it, else its
    /// placeholder; empty when it has neither.
    func labelName(of element: AnyObject) throws -> String {
        if let label = try self.element(kAXTitleUIElementAttribute, of: element) {
            for attribute in [kAXValueAttribute, kAXTitleAttribute] {
                if let text = try string(attribute, of: label), !DotNet.isNullOrWhiteSpace(text) {
                    return text
                }
            }
        }

        return try string(AXName.placeholder, of: element) ?? ""
    }

    /// Its help text (AXHelp: a tooltip, aria-describedby), as UI Automation's HelpText.
    func helpText(of element: AnyObject) throws -> String { try string(kAXHelpAttribute, of: element) ?? "" }

    /// Its identifier (AppKit's accessibilityIdentifier, a web page's id), as UI Automation's AutomationId.
    func identifier(of element: AnyObject) throws -> String {
        try string(AXName.identifier, of: element) ?? string(AXName.domIdentifier, of: element) ?? ""
    }

    /// It takes typed text (C#'s `IsEditable`). A text field always does (UI Automation's Edit). A text area or a combo
    /// box does when its value can be set, as a Document or ComboBox does when its ValuePattern isn't read-only; a text
    /// area that doesn't say does inside a web page's editor (AXEditableAncestor), as a Document does with a
    /// TextPattern. Terminal's scrollback and a read-only text view don't.
    func isEditable(_ element: AnyObject) throws -> Bool {
        let elementRole = try self.role(of: element)
        if elementRole == kAXTextFieldRole {
            return true
        }

        guard elementRole == kAXTextAreaRole || elementRole == kAXComboBoxRole else { return false }
        if let settable = try isSettable(kAXValueAttribute, of: element), settable {
            return true
        }

        return try elementRole == kAXTextAreaRole && self.element(AXName.editableAncestor, of: element) != nil
    }

    /// Something that positively doesn't take text has the focus (C#'s `IsClearlyNotText`): a list, a table or an
    /// outline (a file, mail or chat list), a row, a button, a link, a menu, a tab, a checkbox, a radio button, an
    /// image or a Dock item. Anything else (documents, panes, custom controls, spreadsheet cells, terminals) still gets
    /// the text, so apps with unusual text boxes are never skipped.
    func isClearlyNotText(_ element: AnyObject) throws -> Bool {
        if try isEditable(element) {
            return false
        }

        return try role(of: element).map { AXRoles.notText.contains($0) } ?? false
    }

    /// Part of a web page: the element or a parent is a web area (C#'s `InPage`: a Document ancestor). A browser's
    /// address, search and find bars aren't, in any language.
    func isInWebPage(_ element: AnyObject) throws -> Bool {
        var node: AnyObject? = element
        for _ in 0..<60 {
            guard let current = node else { return false }
            if try role(of: current) == AXName.webArea {
                return true
            }

            node = try self.element(kAXParentAttribute, of: current)
        }

        return false
    }

    /// Chromium's address bar: its view's class, which Chromium gives as the element's AXDOMClassList, is
    /// OmniboxViewViews (Chrome's, Edge's, Brave's…), as Windows reads it from the class name.
    func isAddressBar(_ element: AnyObject) throws -> Bool {
        try strings(AXName.domClassList, of: element).contains { $0.hasSuffix("OmniboxViewViews") }
    }

    /// The element's frame as the core's `ScreenRect`, in points from the top left of the main display.
    func screenRect(_ element: AnyObject) throws -> ScreenRect? {
        try frame(of: element).map { ScreenRect($0) }
    }
}

extension ScreenRect {
    /// A frame in Accessibility's coordinates (points from the top left of the main display, y down).
    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    /// The part both rectangles cover; empty (no width or height) when they don't meet.
    func intersection(_ other: ScreenRect) -> ScreenRect {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let width = max(0, min(right, other.right) - left)
        let height = max(0, min(bottom, other.bottom) - top)
        return ScreenRect(x: left, y: top, width: width, height: height)
    }
}

/// Roles the desktop sorts elements by.
enum AXRoles {
    /// The roles of C#'s clearly-not-text control types: List (AXList, AXTable, AXBrowser), ListItem and TreeItem
    /// (AXRow), Tree (AXOutline), Button and SplitButton (AXButton, AXMenuButton), Hyperlink, MenuItem, Menu, MenuBar,
    /// Tab (AXTabGroup) and TabItem (tabs are AXRadioButtons), CheckBox, RadioButton, Image, and the taskbar's buttons
    /// (AXDockItem). UI Automation's Header and HeaderItem (a table's column headers) are AXButtons on the Mac.
    static let notText: Set<String> = [
        kAXListRole, kAXTableRole, kAXBrowserRole, kAXRowRole, kAXOutlineRole, kAXButtonRole, kAXMenuButtonRole,
        AXName.link, kAXMenuItemRole, kAXMenuRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXTabGroupRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXImageRole, kAXDockItemRole,
    ]
}
