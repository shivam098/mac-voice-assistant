import AppKit
import SwiftUI

public enum AppLogo {
    public struct Mark: View {
        let size: CGFloat

        public init(size: CGFloat) {
            self.size = size
        }

        public var body: some View {
            Canvas { graphics, size in
                graphics.withCGContext { context in
                    context.scaleBy(x: size.width / 256, y: size.height / 256)
                    JarvisArtwork.badge(in: context)
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// Without a status dot the menu bar colours the template itself. The gap around a dot stays transparent.
    public static func menuBarImage(dot: Colour?) -> NSImage {
        let size = CGSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let ringSize = size.height * 15 / 32
            let ring = CGRect(x: size.width - ringSize, y: size.height - ringSize, width: ringSize, height: ringSize)
            let bounds = JarvisArtwork.glyphBounds
            let scale = min(size.width / bounds.width, (size.height - 2) / bounds.height)

            context.saveGState()
            if dot != nil {
                context.addRect(CGRect(origin: .zero, size: size))
                context.addEllipse(in: ring)
                context.clip(using: .evenOdd)
            }
            context.translateBy(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            context.scaleBy(x: scale, y: scale)
            let ink = NSColor.labelColor.cgColor
            JarvisArtwork.emblem(in: context, orbit: ink, beacon: ink)
            context.restoreGState()

            if let dot {
                let inset = size.height * 2 / 32
                context.setFillColor(dot.cgColor)
                context.fillEllipse(in: ring.insetBy(dx: inset, dy: inset))
            }
            return true
        }
        image.isTemplate = dot == nil
        image.accessibilityDescription = "Voice Assistant"
        return image
    }
}
