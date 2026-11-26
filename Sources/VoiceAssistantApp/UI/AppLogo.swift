import AppKit
import SwiftUI

/// Voice Assistant's logo, drawn as windows-voice-assistant assets/make-logo.ps1 draws it (the app's icon comes from that
/// script's assets/logo.png): a white microphone with sound waves on a rounded indigo-to-violet tile. It's drawn rather
/// than loaded, so the app carries no image files and the logo is sharp at every size. Lengths are the script's, in
/// 256ths of the logo's size, y down.
public enum AppLogo {
    /// The logo's width and height in its own units.
    static let units: CGFloat = 256

    /// The tile's gradient, from its top-left corner to its bottom-right one.
    static let tileTop = Colour(0x4F46E5)
    static let tileBottom = Colour(0xA855F7)

    /// The waves are a little see-through.
    static let wave = Colour(0xFFFFFF, alpha: 230.0 / 255)

    /// The stand's and the waves' line widths, in units.
    static let standWidth: CGFloat = 14
    static let waveWidth: CGFloat = 10

    /// The tile: 244 units square, 6 in from the edges, its corners rounded 56.
    static func tile(_ scale: CGFloat) -> CGPath {
        rounded(CGRect(x: 6, y: 6, width: 244, height: 244), radius: 56, scale)
    }

    /// The microphone's capsule, filled: 56 by 104 units, round at both ends.
    static func capsule(_ scale: CGFloat) -> CGPath {
        rounded(CGRect(x: 100, y: 48, width: 56, height: 104), radius: 28, scale)
    }

    /// The microphone's stand, stroked: the lower half of an ellipse around the capsule's foot, a stem and a base.
    static func stand(_ scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        arc(path, CGRect(x: 76, y: 92, width: 104, height: 88), from: 0, sweep: 180, scale)
        path.move(to: CGPoint(x: 128 * scale, y: 180 * scale))
        path.addLine(to: CGPoint(x: 128 * scale, y: 204 * scale))
        path.move(to: CGPoint(x: 100 * scale, y: 206 * scale))
        path.addLine(to: CGPoint(x: 156 * scale, y: 206 * scale))
        return path
    }

    /// The sound waves either side of the microphone, stroked.
    static func waves(_ scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        arc(path, CGRect(x: 34, y: 66, width: 60, height: 92), from: 120, sweep: 120, scale)
        arc(path, CGRect(x: 162, y: 66, width: 60, height: 92), from: -60, sweep: 120, scale)
        return path
    }

    /// The logo at `size` points: the pill's 22 and the window's 28. Its lines are in proportion, as when Windows
    /// shows the script's 64-pixel image at those sizes.
    public struct Mark: View {
        let size: CGFloat

        public init(size: CGFloat) {
            self.size = size
        }

        public var body: some View {
            let scale = size / AppLogo.units
            ZStack {
                Path(AppLogo.tile(scale))
                    .fill(
                        LinearGradient(
                            colors: [Color(AppLogo.tileTop), Color(AppLogo.tileBottom)], startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                Path(AppLogo.capsule(scale)).fill(Color.white)
                Path(AppLogo.stand(scale))
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: AppLogo.standWidth * scale, lineCap: .round, lineJoin: .round))
                Path(AppLogo.waves(scale))
                    .stroke(
                        Color(AppLogo.wave),
                        style: StrokeStyle(lineWidth: AppLogo.waveWidth * scale, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
        }
    }

    /// The menu bar's picture, 20 by 18 points: the logo's microphone and waves without the tile, so it shows on a
    /// light or a dark menu bar. A `dot` goes in its bottom-right corner, with a gap around it, as on Windows' tray
    /// icon. Without a dot it's a template image, which macOS colours as it colours other menu bar items; with one it's
    /// drawn each time it's shown, in the text colour of the menu bar's appearance then.
    public static func menuBarImage(dot: Colour?) -> NSImage {
        let size = CGSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            AppLogo.drawGlyph(context, size: size, colour: NSColor.labelColor.cgColor, dot: dot)
            return true
        }

        image.isTemplate = dot == nil
        image.accessibilityDescription = "Voice Assistant"
        return image
    }

    /// Draws the menu bar's glyph into `context` (y down) at `size`: the microphone and waves, as large as fit with a
    /// point above and below, with lines at least 1.5 points wide (the script's least width), and the dot.
    static func drawGlyph(_ context: CGContext, size: CGSize, colour: CGColor, dot: Colour?) {
        // The glyph's own box, in units: from the left wave's outer edge to the right one's, and from the capsule's
        // top to the base's bottom.
        let box = CGRect(x: 29, y: 48, width: 198, height: 165)
        let scale: CGFloat = min(size.width / box.width, (size.height - 2) / box.height)
        // Windows' tray icon: a ring 15/32 of the icon across, with the dot, 11/32, in it.
        let ringSize: CGFloat = size.height * 15 / 32
        let ring = CGRect(x: size.width - ringSize, y: size.height * 17 / 32, width: ringSize, height: ringSize)

        context.saveGState()
        if dot != nil {
            // Leave the ring's circle clear; the background shows through, whatever it is.
            context.addRect(CGRect(origin: .zero, size: size))
            context.addEllipse(in: ring)
            context.clip(using: .evenOdd)
        }

        let left: CGFloat = (size.width - box.width * scale) / 2 - box.minX * scale
        let top: CGFloat = (size.height - box.height * scale) / 2 - box.minY * scale
        context.translateBy(x: left, y: top)
        context.setFillColor(colour)
        context.addPath(capsule(scale))
        context.fillPath()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(colour)
        context.setLineWidth(max(1.5, standWidth * scale))
        context.addPath(stand(scale))
        context.strokePath()
        let waveAlpha: CGFloat = colour.alpha * CGFloat(wave.alpha)
        context.setStrokeColor(colour.copy(alpha: waveAlpha) ?? colour)
        context.setLineWidth(max(1.5, waveWidth * scale))
        context.addPath(waves(scale))
        context.strokePath()
        context.restoreGState()

        if let dot {
            let inset: CGFloat = (ringSize - size.height * 11 / 32) / 2
            context.setFillColor(dot.cgColor)
            context.fillEllipse(in: ring.insetBy(dx: inset, dy: inset))
        }
    }

    /// A rectangle in units with rounded corners, scaled (the script's `New-RoundedPath`).
    private static func rounded(_ rect: CGRect, radius: CGFloat, _ scale: CGFloat) -> CGPath {
        let scaled = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let corner = min(radius * scale, scaled.width / 2, scaled.height / 2)
        return CGPath(roundedRect: scaled, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    /// GDI+'s DrawArc, which the script draws with: the part of the ellipse in `box` (in units) from `start` degrees
    /// for `sweep` degrees clockwise, y down, where an angle is a direction from the ellipse's centre.
    private static func arc(_ path: CGMutablePath, _ box: CGRect, from start: CGFloat, sweep: CGFloat, _ scale: CGFloat) {
        let a: CGFloat = box.width / 2
        let b: CGFloat = box.height / 2
        let steps = 48
        for step in 0...steps {
            let degrees: CGFloat = start + sweep * CGFloat(step) / CGFloat(steps)
            let angle: CGFloat = degrees * CGFloat.pi / 180
            let along: CGFloat = b * cos(angle)
            let across: CGFloat = a * sin(angle)
            let radius: CGFloat = a * b / (along * along + across * across).squareRoot()
            let x: CGFloat = (box.midX + radius * cos(angle)) * scale
            let y: CGFloat = (box.midY + radius * sin(angle)) * scale
            let point = CGPoint(x: x, y: y)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
    }
}
