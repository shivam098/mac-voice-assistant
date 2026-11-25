import AppKit
import SwiftUI
import XCTest

/// Draws views into PNG files for people to look at: into UI_RENDER_DIR when it's set (CI keeps that folder as the run's
/// ui-renders artifact), and otherwise only checks that they draw. A SwiftUI view is drawn in an NSHostingView in an
/// offscreen window and copied with `cacheDisplay(in:to:)`, which also draws the AppKit views SwiftUI's `ImageRenderer`
/// can't.
@MainActor
enum Renderer {
    /// Where the pictures go; nil when they aren't kept.
    static var folder: String? {
        guard let folder = ProcessInfo.processInfo.environment["UI_RENDER_DIR"], !folder.isEmpty else { return nil }
        return folder
    }

    /// Draws `view` at the size it wants into `name`.png.
    static func render<Content: View>(_ view: Content, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        guard var bitmap = draw(NSHostingView(rootView: view), size: size, name, file: file, line: line) else { return }
        if isBlank(bitmap) {
            // Only in case: ImageRenderer draws SwiftUI's own views.
            print("\(name): cacheDisplay drew nothing; trying ImageRenderer")
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.cgImage {
                bitmap = NSBitmapImageRep(cgImage: image)
            }
        }

        save(bitmap, name, file: file, line: line)
    }

    /// Draws an AppKit `view` at `size` into `name`.png.
    static func render(_ view: NSView, size: CGSize, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let bitmap = draw(view, size: size, name, file: file, line: line) else { return }
        save(bitmap, name, file: file, line: line)
    }

    private static func draw(
        _ view: NSView, size: CGSize, _ name: String, file: StaticString, line: UInt
    ) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        guard size.width >= 1, size.height >= 1 else {
            XCTFail("\(name) has no size: \(size)", file: file, line: line)
            return nil
        }

        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("\(name): no bitmap to draw into", file: file, line: line)
            return nil
        }

        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func save(_ bitmap: NSBitmapImageRep, _ name: String, file: StaticString, line: UInt) {
        guard let folder else { return }
        XCTAssertFalse(isBlank(bitmap), "\(name) drew nothing", file: file, line: line)
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        } catch {
            XCTFail("couldn't save \(name).png: \(error)", file: file, line: line)
        }
    }

    /// Every pixel looked at is the same: nothing was drawn.
    static func isBlank(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let first = bitmap.colorAt(x: 0, y: 0) else { return true }
        let across = max(1, bitmap.pixelsWide / 80)
        let down = max(1, bitmap.pixelsHigh / 80)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: down) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: across) where bitmap.colorAt(x: x, y: y) != first {
                return false
            }
        }

        return true
    }
}

/// A menu bar item's menu, drawn about as macOS draws one, from the real menu's items: a picture to look at, since a
/// menu can't be drawn while it isn't open.
struct MenuPicture: View {
    struct Row: Hashable {
        var title = ""
        var bold = false
        var checked = false
        var shortcut = ""
        var submenu = false
        var enabled = true
        var separator = false
    }

    let rows: [Row]

    @MainActor
    init(_ menu: NSMenu) {
        rows = menu.items.filter { !$0.isHidden }.map { item in
            guard !item.isSeparatorItem else { return Row(separator: true) }
            let font = item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            return Row(
                title: item.title, bold: font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
                checked: item.state == .on, shortcut: Self.shortcut(item), submenu: item.submenu != nil,
                enabled: item.isEnabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                if row.separator {
                    Rectangle()
                        .fill(Color.black.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                } else {
                    HStack(spacing: 0) {
                        Text(verbatim: row.checked ? "✓" : "").frame(width: 22)
                        Text(verbatim: row.title).fontWeight(row.bold ? .bold : .regular)
                        Spacer(minLength: 28)
                        Text(verbatim: row.shortcut).foregroundStyle(Color.black.opacity(0.45))
                        if row.submenu {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.55))
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(row.enabled ? 0.85 : 0.3))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 300)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.965)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        .padding(16)
        .background(Color(white: 0.82))
    }

    /// A key equivalent as a menu shows it: ⌃⌥⇧⌘, then the key.
    @MainActor
    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        for (flag, glyph) in [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        where flags.contains(flag) {
            text += glyph
        }

        return text + (item.keyEquivalent == " " ? "Space" : item.keyEquivalent.uppercased())
    }
}
