import CoreGraphics

/// The Mac's beacon: one drawing for the app icon, window, pill and menu bar. Coordinates are 256 units, y down.
enum JarvisArtwork {
    static let glyphBounds = CGRect(x: 46, y: 48, width: 162, height: 159)

    static func badge(in context: CGContext) {
        let tile = CGPath(roundedRect: CGRect(x: 14, y: 13, width: 228, height: 228),
                          cornerWidth: 53, cornerHeight: 53, transform: nil)
        context.saveGState()
        context.addPath(tile)
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(0x267d77), color(0x154d56), color(0x122637)] as CFArray,
            locations: [0, 0.52, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 24, y: 14), end: CGPoint(x: 228, y: 233),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.addPath(tile)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(5)
        context.strokePath()
        context.restoreGState()

        emblem(in: context, orbit: color(0xa6e7d8), beacon: color(0xffd17c))
        context.setFillColor(color(0xffe6a8))
        context.fillEllipse(in: CGRect(x: 184, y: 66, width: 20, height: 20))
    }

    static func emblem(in c: CGContext, orbit: CGColor, beacon: CGColor) {
        c.setStrokeColor(orbit)
        c.setLineWidth(12)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: 153, y: 58))
        c.addCurve(to: CGPoint(x: 54, y: 131), control1: CGPoint(x: 99, y: 39), control2: CGPoint(x: 53, y: 79))
        c.addCurve(to: CGPoint(x: 126, y: 201), control1: CGPoint(x: 54, y: 172), control2: CGPoint(x: 87, y: 202))
        c.addCurve(to: CGPoint(x: 201, y: 116), control1: CGPoint(x: 176, y: 201), control2: CGPoint(x: 207, y: 159))
        c.strokePath()

        c.setFillColor(beacon)
        c.move(to: CGPoint(x: 135, y: 72))
        c.addQuadCurve(to: CGPoint(x: 180, y: 126), control: CGPoint(x: 136, y: 115))
        c.addQuadCurve(to: CGPoint(x: 121, y: 185), control: CGPoint(x: 139, y: 136))
        c.addQuadCurve(to: CGPoint(x: 77, y: 132), control: CGPoint(x: 119, y: 143))
        c.addQuadCurve(to: CGPoint(x: 135, y: 72), control: CGPoint(x: 117, y: 122))
        c.closePath()
        c.fillPath()
    }

    private static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
