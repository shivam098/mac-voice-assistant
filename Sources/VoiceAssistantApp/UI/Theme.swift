import AppKit
import SwiftUI
import ThumbFreeMac
import VoiceAssistantBoard

/// A colour as the Windows app writes it: #RRGGBB and an opacity (ThumbFree's pill colour, ThumbFreeMac `Pill.Colour`).
public typealias Colour = Pill.Colour

/// The look of the window, the reminder cards and the balloon (windows-voice-assistant `Theme`): light and Windows
/// 11-like, with the same colours, cards, headings and buttons. Light only, as on Windows: each window and panel of the
/// app has the Aqua appearance whatever the Mac's (`Theme.appearance`). Sizes are Windows' numbers in points, which
/// draw as many pixels on a Mac as Windows' device-independent pixels do on a PC at 100%.
public enum Theme {
    public static let background = Colour(0xF3F3F3)
    public static let sidebar = Colour(0xEBEBEB)
    public static let card = Colour(0xFFFFFF)
    public static let border = Colour(0xE0E0E0)
    public static let text = Colour(0x1B1B1B)
    public static let muted = Colour(0x5F6368)
    public static let accent = Colour(0x5B4BDB)
    public static let accentSoft = Colour(0xECEAFD)
    public static let danger = Colour(0xC42B1C)

    /// The light appearance every window and panel of the app has.
    @MainActor
    public static var appearance: NSAppearance? { NSAppearance(named: .aqua) }

    /// The colour of each list's sticky notes on the idea board (Windows' `ListColours`).
    public static func listColour(_ list: BoardList) -> Colour {
        switch list {
        case .ideas: return Colour(0xFFF4B8)
        case .brainstorm: return Colour(0xD9F2FF)
        case .todo: return Colour(0xDDF5E3)
        case .reminders: return Colour(0xFFE1E1)
        }
    }

    /// A list's name as the board shows it.
    public static func listName(_ list: BoardList) -> String {
        switch list {
        case .ideas: return "Ideas"
        case .brainstorm: return "Brainstorm"
        case .todo: return "To-do"
        case .reminders: return "Reminders"
        }
    }

    /// A heading: semibold, 24 points unless `size` says, with 12 below it.
    @MainActor
    public static func heading(_ text: String, size: CGFloat = 24) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(Theme.text))
            .padding(.bottom, 12)
    }

    /// A line of text, 13 points in the text colour unless `size` and `colour` say. It wraps; with `wrap` false it stays
    /// on one line, cut short with "…".
    @MainActor
    public static func label(_ text: String, size: CGFloat = 13, colour: Colour = Theme.text, wrap: Bool = true)
        -> some View
    {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(Color(colour))
            .lineLimit(wrap ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: wrap)
    }
}

extension View {
    /// A card (Windows' `Theme.CardOf`): white unless `background` says, a 1-point border, corners rounded 8, the
    /// contents 16 in from the border (`padding`), and 12 below the card.
    public func themeCard(_ background: Colour = Theme.card, padding: CGFloat = 16) -> some View {
        // Windows' border is outside its padding; SwiftUI's is drawn inside, so the padding is a point more.
        self.padding(padding + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(background)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(Theme.border), lineWidth: 1))
            .padding(.bottom, 12)
    }
}

/// The theme's button (Windows' `Theme.Button` and `Theme.Animate`): flat, rounded 6, 13-point text, its background
/// easing to the hover colour while the mouse is over it (140 ms) and to the pressed colour while it's held (60 ms,
/// and 120 ms back). Half transparent when disabled. The window's sidebar items are the same button without a border,
/// larger and as wide as the sidebar, whose resting colour eases to show the page that's open (`SetRestColor`).
public struct ThemeButtonStyle: ButtonStyle {
    public var normal: Colour
    public var hover: Colour
    public var pressed: Colour
    public var foreground: Colour
    /// Nil: no border.
    public var border: Colour?
    public var fontSize: CGFloat = 13
    public var weight: Font.Weight = .regular
    /// Inside the border, as Windows' Padding.
    public var padding = EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
    /// As wide as it may be, its text on the left.
    public var fillsWidth = false

    public init(normal: Colour, hover: Colour, pressed: Colour, foreground: Colour, border: Colour?) {
        self.normal = normal
        self.hover = hover
        self.pressed = pressed
        self.foreground = foreground
        self.border = border
    }

    /// The main action: white on the accent colour.
    public static let primary = ThemeButtonStyle(
        normal: Colour(0x5B4BDB), hover: Colour(0x4C3DC7), pressed: Colour(0x3F31B0), foreground: .white,
        border: Theme.accent)

    /// Any other action: dark text on white.
    public static let standard = ThemeButtonStyle(
        normal: Colour(0xFFFFFF), hover: Colour(0xF3F3F3), pressed: Colour(0xE6E6E6), foreground: Theme.text,
        border: Theme.border)

    public func makeBody(configuration: Configuration) -> some View {
        ThemeButton(style: self, configuration: configuration)
    }
}

/// A themed button's look, which follows the mouse.
private struct ThemeButton: View {
    let style: ThemeButtonStyle
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // Each value on its own, so the chain below stays quick to type-check.
        let fill: Colour = configuration.isPressed ? style.pressed : hovering ? style.hover : style.normal
        // Windows' border is outside its padding; SwiftUI draws the border inside the padding.
        let edge: CGFloat = style.border == nil ? 0 : 1
        let border: Colour = style.border ?? Colour(0xFFFFFF, alpha: 0)
        let padding = EdgeInsets(
            top: style.padding.top + edge, leading: style.padding.leading + edge, bottom: style.padding.bottom + edge,
            trailing: style.padding.trailing + edge)
        let width: CGFloat? = style.fillsWidth ? CGFloat.infinity : nil
        let press: Int = configuration.isPressed ? 60 : 120
        let opacity: Double = isEnabled ? 1 : 0.5
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.system(size: style.fontSize, weight: style.weight))
            .foregroundStyle(Color(style.foreground))
            .padding(padding)
            .frame(maxWidth: width, alignment: .leading)
            .background(shape.fill(Color(fill)))
            .overlay(shape.strokeBorder(Color(border), lineWidth: edge))
            .contentShape(shape)
            .background(HoverTracker { hovering = $0 })
            .animation(Motion.animation(press), value: configuration.isPressed)
            .animation(Motion.animation(140), value: hovering)
            .animation(Motion.animation(140), value: style.normal)
            .opacity(opacity)
    }
}

extension Color {
    /// A theme or pill colour.
    public init(_ colour: Colour) {
        self.init(
            .sRGB,
            red: Double((colour.rgb >> 16) & 0xFF) / 255,
            green: Double((colour.rgb >> 8) & 0xFF) / 255,
            blue: Double(colour.rgb & 0xFF) / 255,
            opacity: colour.alpha)
    }
}

extension Pill.Colour {
    /// The colour for Core Graphics.
    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}
