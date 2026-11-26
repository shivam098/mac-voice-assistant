import AppKit
import SwiftUI

/// A SwiftUI view in an NSHostingView in an offscreen window, laid out, so a test can reach the AppKit views SwiftUI
/// made for it (its text areas, buttons and boxes) and use them.
@MainActor
final class Hosted<Content: View> {
    let window: NSWindow
    let view: NSHostingView<Content>

    init(_ content: Content, size: CGSize = CGSize(width: 600, height: 400)) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: content)
        // The view is the size given, as the window's is, whatever its content would like.
        view.sizingOptions = []
        window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// The AppKit views of `type` in it, depth first.
    func views<Found: NSView>(_ type: Found.Type) -> [Found] {
        Self.views(type, in: view)
    }

    func close() {
        window.orderOut(nil)
    }

    private static func views<Found: NSView>(_ type: Found.Type, in root: NSView) -> [Found] {
        var found: [Found] = []
        for subview in root.subviews {
            if let match = subview as? Found {
                found.append(match)
            }

            found += views(type, in: subview)
        }

        return found
    }
}
