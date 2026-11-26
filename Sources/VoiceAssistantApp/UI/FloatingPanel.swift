import AppKit
import QuartzCore
import SwiftUI

/// Small, quick animations that make the app feel smooth (windows-voice-assistant `Motion`): fades, and colours that
/// ease on hover, with Windows' timings and its easing. All of it is skipped while System Settings › Accessibility ›
/// Display › Reduce motion is on, as Windows skips it while its "Animation effects" setting is off. Windows' eased
/// mouse-wheel scrolling has no counterpart here: macOS scrolls smoothly itself.
@MainActor
public enum Motion {
    /// Whether Reduce motion is on; tests replace it.
    static var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Animations run: Reduce motion is off.
    public static var isEnabled: Bool { !reduceMotion() }

    /// `milliseconds` of Windows' easing, or nil (no animation) while Reduce motion is on.
    public static func animation(_ milliseconds: Int) -> Animation? {
        guard isEnabled else { return nil }
        return .timingCurve(0.33, 1, 0.68, 1, duration: Double(milliseconds) / 1000)
    }

    /// Windows' easing for Core Animation: WPF's CubicEase with EaseOut, 1 − (1 − t)³, as a Bézier curve.
    static var timingFunction: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1) }
}

/// A panel that floats over other windows without ever taking the keyboard focus or activating the app, so it can't
/// take what you're typing (Windows' WS_EX_NOACTIVATE tool windows): the pill, the reminder cards and the balloon. It's
/// borderless and clear around its content, on every Space and over full-screen apps, left out of ⌘` and Mission
/// Control, and it fades in and out as `Motion` says.
@MainActor
final class FloatingPanel: NSPanel {
    /// Counts fades, so a fade-out that a later fade-in replaced doesn't finish (Windows' FadeOut checks the opacity).
    private var fades = 0
    private var afterFade: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A panel showing `content`, whose buttons work on the first click. The panel is sized by its owner (`size(of:)`),
    /// not by the content.
    static func make<Content: View>(_ content: FirstClickHostingView<Content>) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // The app is never active while you use the panels, and AppKit shows tooltips (SwiftUI's `.help`) only in an
        // active app unless the window says otherwise: the pill's badge and minimize button have tooltips.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.appearance = Theme.appearance
        content.sizingOptions = []
        panel.contentView = content
        return panel
    }

    /// The size SwiftUI wants for `view`: its natural size, within its own frames (ThumbFree's pill is measured the
    /// same way).
    static func size<Content: View>(of view: Content) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    /// Fades in from clear over `milliseconds` (Windows' `Motion.FadeIn`); at once while Reduce motion is on.
    func fadeIn(milliseconds: Int) {
        fades += 1
        afterFade = nil
        guard Motion.isEnabled else {
            alphaValue = 1
            return
        }

        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(milliseconds) / 1000
            context.timingFunction = Motion.timingFunction
            self.animator().alphaValue = 1
        }
    }

    /// Fades out over `milliseconds`, then runs `done` and is opaque again for the next time it shows (Windows'
    /// `Motion.FadeOut`); a fade-in before then cancels `done`. At once while Reduce motion is on.
    func fadeOut(milliseconds: Int, then done: @escaping @MainActor () -> Void) {
        fades += 1
        guard Motion.isEnabled else {
            afterFade = nil
            done()
            return
        }

        let fade = fades
        afterFade = done
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Double(milliseconds) / 1000
            context.timingFunction = Motion.timingFunction
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeEnded(fade)
            }
        })
    }

    private func fadeEnded(_ fade: Int) {
        guard fade == fades, let done = afterFade else { return }
        afterFade = nil
        done()
        alphaValue = 1
    }
}

/// SwiftUI in a panel that never becomes the key window: a click goes straight to the button under it, and the app
/// stays inactive.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Tells its view whether the mouse is over it, through a tracking area that works whichever app is active: the
/// floating panels' buttons light up on hover although their app never becomes active.
struct HoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
    }

    /// Follows the mouse, and lets clicks through to the view under it.
    final class TrackingView: NSView {
        var changed: (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }

            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            changed(true)
        }

        override func mouseExited(with event: NSEvent) {
            changed(false)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
