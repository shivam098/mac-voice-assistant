import AppKit
import SwiftUI

/// Fades a view in when it appears, rising `rise` points as it does (Windows' `Motion.FadeIn`): the fade takes
/// `milliseconds`, the rise 60 more. At once while Reduce motion is on.
struct FadeInOnAppear: ViewModifier {
    let milliseconds: Int
    let rise: CGFloat
    @State private var visible = false
    @State private var risen = false

    init(milliseconds: Int, rise: CGFloat = 0) {
        self.milliseconds = milliseconds
        self.rise = rise
    }

    func body(content: Content) -> some View {
        let opacity: Double = visible ? 1 : 0
        let offset: CGFloat = risen ? 0 : rise
        content
            .opacity(opacity)
            .offset(y: offset)
            .onAppear {
                guard Motion.isEnabled else {
                    visible = true
                    risen = true
                    return
                }

                withAnimation(Motion.animation(milliseconds)) { visible = true }
                withAnimation(Motion.animation(milliseconds + 60)) { risen = true }
            }
    }
}

/// Its views in a row, left to right, a new row starting where the next one doesn't fit (WPF's `WrapPanel`, which
/// Windows' rows of buttons are in): `spacing` between the views of a row, `lineSpacing` between rows, each view at
/// its own size and centred in its row's height.
struct WrapStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in rows {
            width = max(width, row.width)
            height += row.height
        }

        if rows.count > 1 {
            height += lineSpacing * CGFloat(rows.count - 1)
        }

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y: CGFloat = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x: CGFloat = bounds.minX
            for index in row.views {
                let size = subviews[index].sizeThatFits(.unspecified)
                let top: CGFloat = y + (row.height - size.height) / 2
                subviews[index].place(at: CGPoint(x: x, y: top), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }

            y += row.height + lineSpacing
        }
    }

    /// A row: its views' indices, and its width and height.
    private struct Row {
        var views: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// The views in rows no wider than `width`; a view wider than that has a row of its own.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let gap: CGFloat = row.views.isEmpty ? 0 : spacing
            if !row.views.isEmpty && row.width + gap + size.width > width {
                rows.append(row)
                row = Row()
                row.width = size.width
            } else {
                row.width += gap + size.width
            }

            row.height = max(row.height, size.height)
            row.views.append(index)
        }

        if !row.views.isEmpty {
            rows.append(row)
        }

        return rows
    }
}

/// A text area for settings that are typed in later exactly as they're written here (Settings' lists and pairs):
/// plain text, with none of the corrections and substitutions macOS makes as you type when System Settings › Keyboard
/// has them on, as SwiftUI's `TextEditor` does (smart quotes and dashes, text replacements, spelling corrections), and
/// no spelling underlines, as Windows' boxes. VoiceOver calls it `label`.
struct PlainTextBox: NSViewRepresentable {
    @Binding var text: String
    let label: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let box = scroll.documentView as? NSTextView {
            Self.configure(box)
            box.string = text
            box.delegate = context.coordinator
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let box = scroll.documentView as? NSTextView else { return }
        box.setAccessibilityLabel(label)
        if box.string != text {
            box.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Plain 13-point text in the theme's colour on the card, kept as typed.
    static func configure(_ box: NSTextView) {
        box.isRichText = false
        box.importsGraphics = false
        box.allowsUndo = true
        box.isAutomaticQuoteSubstitutionEnabled = false
        box.isAutomaticDashSubstitutionEnabled = false
        box.isAutomaticTextReplacementEnabled = false
        box.isAutomaticSpellingCorrectionEnabled = false
        box.isAutomaticTextCompletionEnabled = false
        box.isAutomaticLinkDetectionEnabled = false
        box.isAutomaticDataDetectionEnabled = false
        box.smartInsertDeleteEnabled = false
        box.isContinuousSpellCheckingEnabled = false
        box.isGrammarCheckingEnabled = false
        box.font = NSFont.systemFont(ofSize: 13)
        box.textColor = NSColor(Color(Theme.text))
        box.drawsBackground = false
    }

    /// Gives what's typed to the binding.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSTextView else { return }
            text.wrappedValue = box.string
        }
    }
}
