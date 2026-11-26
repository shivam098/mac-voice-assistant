import AppKit
import ApplicationServices

/// What the desktop asks the Accessibility API, behind a protocol so the reading can be tested without other apps
/// (`FakeAX` in the tests), as ThumbFreeMac's `FocusedField.Accessibility` is. Elements are AXUIElements (plain
/// objects in tests); they can be used from any thread. A missing attribute is nil; a call that gets no answer
/// (Accessibility is off for this app, the element has gone, or its app didn't answer in time) throws `AXNoAnswer`.
public protocol AXSystem: AnyObject {
    /// The app taking the keys (the system-wide kAXFocusedApplicationAttribute): Spotlight, not the app left in front.
    func focusedApplication() throws -> AnyObject?

    /// The element with the keyboard focus, in whichever app has it (the system-wide kAXFocusedUIElementAttribute).
    func focusedElement() throws -> AnyObject?

    /// The app's own element (AXUIElementCreateApplication).
    func application(_ processIdentifier: pid_t) -> AnyObject

    func processIdentifier(of element: AnyObject) throws -> pid_t

    func string(_ attribute: String, of element: AnyObject) throws -> String?

    /// A number or a true/false attribute (kAXEnabledAttribute, kAXNumberOfCharactersAttribute…), true as 1.
    func number(_ attribute: String, of element: AnyObject) throws -> Int?

    func element(_ attribute: String, of element: AnyObject) throws -> AnyObject?

    /// An attribute that holds elements (kAXChildrenAttribute, kAXWindowsAttribute); empty when there are none.
    func elements(_ attribute: String, of element: AnyObject) throws -> [AnyObject]

    /// An attribute that holds strings (Chromium's AXDOMClassList); empty when there are none.
    func strings(_ attribute: String, of element: AnyObject) throws -> [String]

    /// A range attribute, such as kAXSelectedTextRangeAttribute: in UTF-16 units, as NSString counts.
    func range(_ attribute: String, of element: AnyObject) throws -> CFRange?

    /// A text attribute for `range`, such as kAXStringForRangeParameterizedAttribute, as UTF-16 units: a range can cut
    /// an emoji in two, and a Swift string can't hold its halves.
    func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]?

    /// kAXPositionAttribute and kAXSizeAttribute together: in points, from the top left of the main display, y down.
    func frame(of element: AnyObject) throws -> CGRect?

    /// Whether the attribute can be set (AXUIElementIsAttributeSettable), as an editable box's kAXValueAttribute can;
    /// nil when the element doesn't have it.
    func isSettable(_ attribute: String, of element: AnyObject) throws -> Bool?

    /// Sets a true/false attribute: kAXFocusedAttribute, kAXMainAttribute, kAXMinimizedAttribute,
    /// kAXFrontmostAttribute, an app's kAXHiddenAttribute.
    @discardableResult
    func set(_ attribute: String, _ value: Bool, of element: AnyObject) -> AXOutcome

    /// Performs an action: kAXPressAction, kAXRaiseAction.
    @discardableResult
    func perform(_ action: String, on element: AnyObject) -> AXOutcome

    /// Moves and resizes a window (kAXPositionAttribute, kAXSizeAttribute): its position, its size, then its position
    /// again, as a window too big for where it was is refused its size.
    @discardableResult
    func setFrame(_ frame: CGRect, of element: AnyObject) -> AXOutcome

    /// The window server's number for a window (its CGWindowID): what tells two windows of one app apart, as a window
    /// handle does on Windows. Nil when it can't be told.
    func windowNumber(of window: AnyObject) -> Int?

    /// The same element (CFEqual).
    func isSame(_ element: AnyObject, as other: AnyObject) -> Bool

    /// What one call (AXUIElementCopyMultipleAttributeValues) reads about an element, for walking a window's
    /// elements: its role, subrole and children, title and description, whether it's enabled, and its frame. An element
    /// that has gone from the screen has none of them.
    func node(_ element: AnyObject) throws -> AXNode

    /// The actions the element can do (AXUIElementCopyActionNames): kAXPressAction, AXScrollToVisible…
    func actions(of element: AnyObject) throws -> [String]

    /// The innermost element of the app's windows at a point of the screen (AXUIElementCopyElementAtPosition on the
    /// app's element), as UI Automation's FromPoint finds it; nil when there's none. The point is in Accessibility's
    /// coordinates.
    func element(at point: CGPoint, of application: AnyObject) throws -> AnyObject?

    /// The innermost element at a point of the screen in whichever app's window a click there would land
    /// (AXUIElementCopyElementAtPosition on the system-wide element); nil when there's none.
    func elementAtPoint(_ point: CGPoint) throws -> AnyObject?
}

/// What one call reads about an element (`AXSystem.node`).
public struct AXNode {
    public var role: String?
    public var subrole: String?
    public var children: [AnyObject]

    /// kAXTitleAttribute.
    public var title: String?

    /// kAXDescriptionAttribute: accessibilityLabel, a web page's aria-label.
    public var label: String?

    /// kAXEnabledAttribute; nil when the element doesn't say.
    public var enabled: Bool?

    /// kAXPositionAttribute and kAXSizeAttribute: in points, from the top left of the main display, y down.
    public var frame: CGRect?

    public init(
        role: String?, subrole: String? = nil, children: [AnyObject] = [], title: String? = nil, label: String? = nil,
        enabled: Bool? = nil, frame: CGRect? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.children = children
        self.title = title
        self.label = label
        self.enabled = enabled
        self.frame = frame
    }
}

/// Accessibility couldn't answer: it's off for this app, the element has gone, or the app didn't answer in time.
public struct AXNoAnswer: Error, Equatable {
    public init() {}
}

/// How setting an attribute or performing an action went.
public enum AXOutcome: Equatable, Sendable {
    case done

    /// The element doesn't do that (or refused it).
    case unsupported

    /// The element has gone from the screen.
    case gone

    /// The app didn't answer in time, or Accessibility is off for this app.
    case noAnswer
}

/// Attribute, role and action names that HIServices has no constant for, as AppKit, WebKit and Chromium name them.
enum AXName {
    /// A window in full screen, in a Space of its own (AppKit's windows).
    static let fullScreen = "AXFullScreen"
    static let placeholder = "AXPlaceholderValue"
    static let identifier = "AXIdentifier"
    static let domIdentifier = "AXDOMIdentifier"
    static let domClassList = "AXDOMClassList"
    static let editableAncestor = "AXEditableAncestor"
    static let webArea = "AXWebArea"
    static let link = "AXLink"
    static let popover = "AXPopover"
    static let tabButton = "AXTabButton"
    static let scrollToVisible = "AXScrollToVisible"

    /// Safari's address bar's identifier (its smart search field's).
    static let safariAddressBar = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
}

/// The Accessibility API itself. Every call waits at most `timeout` for the app's answer.
public final class SystemAX: AXSystem, @unchecked Sendable {
    /// How long one call waits for an app (AXUIElementSetMessagingTimeout on the system-wide element, which sets it for
    /// every call this app makes; ThumbFreeMac's reader sets the same).
    public static let timeout: Float = 1

    private let systemWide = AXUIElementCreateSystemWide()

    public init() {
        _ = AXUIElementSetMessagingTimeout(systemWide, Self.timeout)
    }

    public func focusedApplication() throws -> AnyObject? {
        try element(kAXFocusedApplicationAttribute, of: systemWide)
    }

    public func focusedElement() throws -> AnyObject? {
        try element(kAXFocusedUIElementAttribute, of: systemWide)
    }

    public func application(_ processIdentifier: pid_t) -> AnyObject {
        AXUIElementCreateApplication(processIdentifier)
    }

    public func processIdentifier(of element: AnyObject) throws -> pid_t {
        var pid: pid_t = 0
        guard AXUIElementGetPid(Self.ax(element), &pid) == .success else { throw AXNoAnswer() }
        return pid
    }

    public func string(_ attribute: String, of element: AnyObject) throws -> String? {
        try copy(attribute, of: element) as? String
    }

    public func number(_ attribute: String, of element: AnyObject) throws -> Int? {
        (try copy(attribute, of: element) as? NSNumber)?.intValue
    }

    public func element(_ attribute: String, of element: AnyObject) throws -> AnyObject? {
        guard let value = try copy(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return value
    }

    public func elements(_ attribute: String, of element: AnyObject) throws -> [AnyObject] {
        guard let values = try copy(attribute, of: element) as? [AnyObject] else { return [] }
        return values.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
    }

    public func strings(_ attribute: String, of element: AnyObject) throws -> [String] {
        guard let values = try copy(attribute, of: element) as? [AnyObject] else { return [] }
        return values.compactMap { $0 as? String }
    }

    public func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
        guard let value = try axValue(attribute, of: element, .cfRange) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    public func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            Self.ax(element), attribute as CFString, parameter, &value)
        guard try Self.answered(error), let text = value as? NSString else { return nil }
        var units = [UInt16](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        return units
    }

    public func frame(of element: AnyObject) throws -> CGRect? {
        guard let position = try axValue(kAXPositionAttribute, of: element, .cgPoint),
              let size = try axValue(kAXSizeAttribute, of: element, .cgSize) else { return nil }
        var frame = CGRect.zero
        guard AXValueGetValue(position, .cgPoint, &frame.origin), AXValueGetValue(size, .cgSize, &frame.size) else {
            return nil
        }

        return frame
    }

    public func isSettable(_ attribute: String, of element: AnyObject) throws -> Bool? {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(Self.ax(element), attribute as CFString, &settable)
        return try Self.answered(error) ? settable.boolValue : nil
    }

    @discardableResult
    public func set(_ attribute: String, _ value: Bool, of element: AnyObject) -> AXOutcome {
        Self.outcome(AXUIElementSetAttributeValue(Self.ax(element), attribute as CFString, NSNumber(value: value)))
    }

    @discardableResult
    public func perform(_ action: String, on element: AnyObject) -> AXOutcome {
        Self.outcome(AXUIElementPerformAction(Self.ax(element), action as CFString))
    }

    @discardableResult
    public func setFrame(_ frame: CGRect, of element: AnyObject) -> AXOutcome {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else {
            return .unsupported
        }

        let window = Self.ax(element)
        let moved = Self.outcome(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position))
        guard moved == .done else { return moved }
        let sized = Self.outcome(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent))
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        return sized
    }

    public func windowNumber(of window: AnyObject) -> Int? {
        guard let getWindow = Self.getWindow else { return nil }
        var number: CGWindowID = 0
        return getWindow(Self.ax(window), &number) == .success && number != 0 ? Int(number) : nil
    }

    public func isSame(_ element: AnyObject, as other: AnyObject) -> Bool {
        CFEqual(element, other)
    }

    public func node(_ element: AnyObject) throws -> AXNode {
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(Self.ax(element), names, [], &values)
        if error == .invalidUIElement {
            // Gone from the screen: nothing to read or walk into.
            return AXNode(role: nil)
        }

        guard try Self.answered(error), let list = values as? [AnyObject], list.count == 8 else {
            return AXNode(role: nil)
        }

        // An attribute the element doesn't have comes back as an AXValue holding its error.
        let found = list.map { value -> AnyObject? in
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return value }
            return AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .axError ? nil : value
        }

        let children = (found[2] as? [AnyObject])?.filter { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? []
        var frame: CGRect?
        if let position = Self.asAXValue(found[6], .cgPoint), let size = Self.asAXValue(found[7], .cgSize) {
            var rect = CGRect.zero
            if AXValueGetValue(position, .cgPoint, &rect.origin), AXValueGetValue(size, .cgSize, &rect.size) {
                frame = rect
            }
        }

        return AXNode(
            role: found[0] as? String, subrole: found[1] as? String, children: children, title: found[3] as? String,
            label: found[4] as? String, enabled: (found[5] as? NSNumber)?.boolValue, frame: frame)
    }

    public func actions(of element: AnyObject) throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(Self.ax(element), &names)
        guard try Self.answered(error), let list = names as? [String] else { return [] }
        return list
    }

    public func element(at point: CGPoint, of application: AnyObject) throws -> AnyObject? {
        var found: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(Self.ax(application), Float(point.x), Float(point.y), &found)
        guard try Self.answered(error), let found else { return nil }
        return found
    }

    public func elementAtPoint(_ point: CGPoint) throws -> AnyObject? {
        try element(at: point, of: systemWide)
    }

    /// `_AXUIElementGetWindow`: HIServices' own way from a window's element to its CGWindowID, which window managers
    /// (Rectangle, Hammerspoon, AltTab) use, as Apple offers no public one. It's looked up when first needed, so a
    /// macOS without it still runs: windows are then told apart by app only.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindow? = {
        // RTLD_DEFAULT: every image loaded in the process.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    /// The attribute's value: nil when the element doesn't have it, `AXNoAnswer` when Accessibility is off for this
    /// app, the element has gone or the app didn't answer in time.
    private func copy(_ attribute: String, of element: AnyObject) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(Self.ax(element), attribute as CFString, &value)
        return try Self.answered(error) ? value : nil
    }

    /// True for an answer, false for "the element doesn't have that"; throws when there was no answer (as ThumbFreeMac
    /// reads the errors).
    private static func answered(_ error: AXError) throws -> Bool {
        switch error {
        case .success:
            return true
        case .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .failure, .illegalArgument,
             .notImplemented:
            return false
        default:
            throw AXNoAnswer()
        }
    }

    private static func outcome(_ error: AXError) -> AXOutcome {
        switch error {
        case .success:
            return .done
        case .invalidUIElement:
            return .gone
        case .cannotComplete, .apiDisabled, .notEnoughPrecision:
            return .noAnswer
        default:
            return .unsupported
        }
    }

    /// A point, size or range attribute: an AXValue of `type`.
    private func axValue(_ attribute: String, of element: AnyObject, _ type: AXValueType) throws -> AXValue? {
        try Self.asAXValue(copy(attribute, of: element), type)
    }

    /// `value` as an AXValue of `type`; nil when it's something else.
    private static func asAXValue(_ value: AnyObject?, _ type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private static func ax(_ element: AnyObject) -> AXUIElement {
        precondition(CFGetTypeID(element) == AXUIElementGetTypeID(), "not an AXUIElement")
        return unsafeBitCast(element, to: AXUIElement.self)
    }
}
