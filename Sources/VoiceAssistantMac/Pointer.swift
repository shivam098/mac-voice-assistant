import CoreGraphics
import Foundation

/// The pointer: which window a click at a point would land in, and real clicks (windows-voice-assistant
/// `WindowsDesktop.ClickAt`: `WindowFromPoint`, `SetCursorPos` and `SendInput`'s mouse input), behind a protocol so
/// clicking can be tested without moving the pointer (`FakePointer` in the tests). Points are in Accessibility's
/// coordinates: from the top left of the main display, y down.
public protocol PointerSystem: AnyObject {
    /// The number of the front-most window under `below` (0: of all of them) that a click at `point` would land in;
    /// nil when there's none.
    func windowNumber(at point: CGPoint, below: Int) -> Int?

    /// A left click at `point`, then the pointer back where it was: the pointer moves there, 30 ms later the button
    /// goes down and up, and 60 ms later the pointer goes back, as the C# clicks. False when the events couldn't be
    /// made. It needs the permission to post events.
    func click(at point: CGPoint) -> Bool
}

/// The window server and CGEvent themselves.
public final class SystemPointer: PointerSystem, @unchecked Sendable {
    /// Windows from this level up (dragged images, the screen saver, VoiceOver's cursor, the pointer) are passing
    /// visuals, never what a click is for.
    static let passingLevel = Int(CGWindowLevelForKey(.draggingWindow))

    public init() {}

    /// The window server's windows on screen, front-most first (CGWindowListCopyWindowInfo): the first under `below`
    /// whose frame holds the point and that shows. This list can't tell a window that lets clicks through (the Dock's
    /// spans the screen), so the desktop asks Accessibility's system-wide hit test first and walks this list only when
    /// that can't tell (`MacDesktop.landing`). (AppKit's `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
    /// answered for no other app's window on GitHub's runner.)
    public func windowNumber(at point: CGPoint, below: Int) -> Int? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var passed = below == 0
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            if !passed {
                passed = number == below
                continue
            }

            if Self.takesClick(info, at: point) {
                return number
            }
        }

        return nil
    }

    /// Whether the window CGWindowListCopyWindowInfo describes with `info` takes a click at `point`: its frame holds
    /// it, it isn't fully transparent, and it isn't a passing visual.
    static func takesClick(_ info: [String: Any], at point: CGPoint) -> Bool {
        let layer: Int = info[kCGWindowLayer as String] as? Int ?? 0
        let alpha: Double = info[kCGWindowAlpha as String] as? Double ?? 1
        guard layer < passingLevel, alpha > 0, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return frame.contains(point)
    }

    public func click(at point: CGPoint) -> Bool {
        let back = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        guard let move = Self.mouse(.mouseMoved, at: point, source),
              let down = Self.mouse(.leftMouseDown, at: point, source),
              let up = Self.mouse(.leftMouseUp, at: point, source) else { return false }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        if let back {
            _ = CGWarpMouseCursorPosition(back)
        }

        return true
    }

    /// A left-button event at `point`: one click, no modifier keys, and marked as this process's
    /// (eventSourceUnixProcessID), as ThumbFreeMac's keys are.
    private static func mouse(_ type: CGEventType, at point: CGPoint, _ source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else { return nil }
        event.flags = []
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}
