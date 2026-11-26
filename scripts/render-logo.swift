// From the repo root, after creating .build/:
// swiftc Sources/VoiceAssistantApp/UI/JarvisArtwork.swift scripts/render-logo.swift -o .build/render-logo
// .build/render-logo assets/logo.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum RenderLogo {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: render-logo <output.png>\n".utf8))
            exit(64)
        }
        let size = 1024
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.coderInvalidValue) }
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: CGFloat(size) / 256, y: -CGFloat(size) / 256)
        JarvisArtwork.badge(in: context)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
