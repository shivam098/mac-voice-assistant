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
