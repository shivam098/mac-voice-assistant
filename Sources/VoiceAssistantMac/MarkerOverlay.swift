import AppKit
import QuartzCore
import VoiceAssistantCore

/// Where the overlay's panel goes and what it draws there (windows-voice-assistant `MarkerOverlay.Render`), worked out
/// without AppKit: the badges' numbers and corners, and the click outline, in the panel with y down.
struct OverlayLayout: Equatable {
    struct Badge: Equatable {
        let number: Int

        /// Its top left corner, in the panel.
        let origin: CGPoint
    }

    /// The room around everything shown, for badges that sit above and left of their elements.
    static let margin = 40.0

    /// The area the panel covers, in Accessibility's coordinates.
    let area: ScreenRect
    let badges: [Badge]

    /// The outline around what was just clicked, in the panel.
    let outline: CGRect?

    /// Nil when there's nothing to show. A badge without a place (an empty rectangle: a Safari tab whose button
    /// Accessibility doesn't show) isn't shown.
    init?(badges: [ChoiceBadge]?, flash: ScreenRect?) {
        let placed = (badges ?? []).filter { !$0.rect.isEmpty }
        let rects = placed.map(\.rect) + (flash.map { [$0] } ?? [])
        guard let first = rects.first else { return nil }
        var left = first.x
        var top = first.y
        var right = first.right
        var bottom = first.bottom
        for rect in rects.dropFirst() {
            left = min(left, rect.x)
            top = min(top, rect.y)
            right = max(right, rect.right)
            bottom = max(bottom, rect.bottom)
        }

        left -= Self.margin
        top -= Self.margin
        area = ScreenRect(x: left, y: top, width: right + Self.margin - left, height: bottom + Self.margin - top)
        self.badges = placed.map { badge in
            Badge(number: badge.number, origin: CGPoint(x: badge.rect.x - left - 6, y: badge.rect.y - top - 6))
        }

        outline = flash.map { rect in
            CGRect(x: rect.x - left - 4, y: rect.y - top - 4, width: rect.width + 8, height: rect.height + 8)
        }
    }

    /// The panel's frame in AppKit's screen coordinates, which start at the bottom left of the main display:
    /// `mainTop` is the main display's height.
    func panelFrame(mainTop: CGFloat) -> CGRect {
        CGRect(x: area.x, y: Double(mainTop) - area.bottom, width: area.width, height: area.height)
    }
}

/// The windows of this app that clicks go through, by window number: the number badges' panel (`MarkerOverlay`) while
/// it shows. A real click aimed past one of them still lands where it was aimed, while any other window of this app's
/// over the point (the pill, a reminder card, a balloon) covers it (`MacDesktop.landing`). Several threads share it.
public final class ClickThroughWindows: @unchecked Sendable {
    /// This app's.
    public static let shared = ClickThroughWindows()

    private let lock = NSLock()
    private var numbers: Set<Int> = []

    public init() {}

    func insert(_ number: Int) {
        lock.withLock { _ = numbers.insert(number) }
    }

    func remove(_ number: Int) {
        lock.withLock { _ = numbers.remove(number) }
    }

    func contains(_ number: Int) -> Bool {
        lock.withLock { numbers.contains(number) }
    }
}

/// The numbers and the click outline over other apps (windows-voice-assistant `MarkerOverlay`): numbered badges for
/// "show numbers" and ambiguous names (`InteractionController.onChoicesChanged`), and for under a second an outline on
/// what was just clicked, selected or focused (`onHighlight`). A borderless, non-activating panel above other apps'
/// windows, on every Space and over full-screen apps, that clicks go through and that never takes the focus; its window
/// number is in `ClickThroughWindows` while it shows. Its rectangles are the desktop's, in Accessibility's coordinates.
/// Main thread only.
@MainActor
public final class MarkerOverlay {
    private let panel: NSPanel
    private let canvas: OverlayCanvas
    private let clickThrough: ClickThroughWindows
    private var badges: [ChoiceBadge]?
    private var flashed: ScreenRect?
    private var flashTimer: Timer?

    /// - Parameter clickThrough: Where the panel's window number goes while it shows, for the desktop's clicks to go
    ///   past it.
    public init(clickThrough: ClickThroughWindows = .shared) {
        self.clickThrough = clickThrough
        // A panel needs the app object; the app has it already, a test process may not.
        _ = NSApplication.shared
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        canvas = OverlayCanvas(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // Closing Jarvis's window hides the app (`NSApp.hide`): the numbers stay, as the pill and the reminder cards do.
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas
    }

    /// Shows numbers on the candidates; nil, or none, hides them (C#'s `ShowBadges`).
    public func showBadges(_ badges: [ChoiceBadge]?) {
        self.badges = badges?.isEmpty == false ? badges : nil
        render(newFlash: false)
    }

    /// Outlines a rectangle for under a second (C#'s `Flash`): it fades out from 150 ms, and goes at 900 ms.
    public func flash(_ rect: ScreenRect) {
        guard !rect.isEmpty else { return }
        flashed = rect
        flashTimer?.invalidate()
        let timer = Timer(timeInterval: 0.9, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let overlay = self else { return }
                overlay.flashTimer = nil
                overlay.flashed = nil
                overlay.render(newFlash: false)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
        render(newFlash: true)
    }

    /// The panel's window number while it shows; nil while it's hidden.
    var windowNumber: Int? { panel.isVisible ? panel.windowNumber : nil }

    /// Whether the panel goes when the app hides (NSWindow.canHide): never.
    var hidesWithTheApp: Bool { panel.canHide }

    /// What the panel shows now; nil when it's hidden.
    var layout: OverlayLayout? { canvas.layout }

    /// Places the panel over what's shown, or hides it when there's nothing.
    private func render(newFlash: Bool) {
        guard let layout = OverlayLayout(badges: badges, flash: flashed) else {
            canvas.show(nil, newFlash: false)
            if panel.isVisible {
                panel.orderOut(nil)
                clickThrough.remove(panel.windowNumber)
            }

            return
        }

        let frame = layout.panelFrame(mainTop: NSScreen.screens.first?.frame.maxY ?? 0)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }

        canvas.show(layout, newFlash: newFlash)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            if panel.windowNumber > 0 {
                clickThrough.insert(panel.windowNumber)
            }
        }
    }
}

/// What the overlay draws: the badges (bold numbers in rounded yellow boxes), and the outline in a layer of its own,
/// which fades. The Windows overlay's colours.
final class OverlayCanvas: NSView {
    static let font = NSFont.boldSystemFont(ofSize: 13)
    static let badgeFill = color(0xFDD663)
    static let badgeInk = color(0x202124)
    static let flashStroke = color(0x8AB4F8)

    private(set) var layout: OverlayLayout?
    private let outline = NSView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.wantsLayer = true
        outline.isHidden = true
        addSubview(outline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not made from a nib")
    }

    override var isFlipped: Bool { true }

    /// Draws `layout`; a new flash fades from the start again.
    func show(_ layout: OverlayLayout?, newFlash: Bool) {
        self.layout = layout
        if let rect = layout?.outline {
            outline.frame = rect
            outline.isHidden = false
            if newFlash {
                fade()
            }
        } else {
            outline.isHidden = true
            outline.layer?.removeAllAnimations()
        }

        needsDisplay = true
    }

    /// The outline: 3 points wide, rounded, fully there for 150 ms, then fading over 850 ms.
    private func fade() {
        guard let layer = outline.layer else { return }
        layer.borderWidth = 3
        layer.borderColor = Self.flashStroke.cgColor
        layer.cornerRadius = 6
        layer.removeAllAnimations()
        let fading = CABasicAnimation(keyPath: "opacity")
        fading.fromValue = 1
        fading.toValue = 0
        fading.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.15
        fading.duration = 0.85
        fading.fillMode = .both
        fading.isRemovedOnCompletion = false
        layer.add(fading, forKey: "fade")
    }

    /// Each badge: its number centred in a box at least 20 points wide, with 5 points on each side, a 1-point border
    /// and corners of 5, as the Windows badges.
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Self.badgeInk]
        for badge in layout?.badges ?? [] {
            let text = String(badge.number) as NSString
            let size = text.size(withAttributes: attributes)
            let width: CGFloat = max(20, ceil(size.width) + 12)
            let height: CGFloat = ceil(size.height) + 3
            let box = CGRect(x: badge.origin.x, y: badge.origin.y, width: width, height: height)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            Self.badgeFill.setFill()
            path.fill()
            path.lineWidth = 1
            Self.badgeInk.setStroke()
            path.stroke()
            text.draw(at: CGPoint(x: box.midX - (size.width / 2), y: box.minY + 1), withAttributes: attributes)
        }
    }

    nonisolated private static func color(_ rgb: UInt32) -> NSColor {
        let red: CGFloat = CGFloat((rgb >> 16) & 0xFF) / 255
        let green: CGFloat = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue: CGFloat = CGFloat(rgb & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
