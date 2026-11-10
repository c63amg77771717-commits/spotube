import SwiftUI

/// Lyric fill and the playback progress bar share one palette.
enum LyricFillStyle {
    static var gradient: LinearGradient { PlaybackFillGradient.linear }
    static var paletteHexes: [String] { PlaybackFillGradient.paletteHexes }
}

/// Reveals `PlaybackFillGradient` from the left of each visual line.
/// The edge is a fractional glyph, with the clock's feather in front of it.
struct LyricFillRenderer: TextRenderer {
    var sweep: LyricPlaybackClock.LyricSweep

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let counts = layout.map { line -> Int in
            line.reduce(0) { partial, run in partial + run.count }
        }
        let reveals = LyricPlaybackClock.lineReveals(glyphCounts: counts, sweep: sweep)
        for (line, reveal) in zip(layout, reveals) where reveal.edge > 0 {
            draw(line, reveal: reveal, in: &context)
        }
    }

    private func draw(
        _ line: Text.Layout.Line,
        reveal: LyricPlaybackClock.LineReveal,
        in context: inout GraphicsContext
    ) {
        let slices = slices(in: line)
        guard !slices.isEmpty else { return }
        if reveal.edge >= Double(slices.count) - 0.000_1, reveal.feather <= 0.000_1 {
            for slice in slices {
                context.draw(slice)
            }
            return
        }
        let minXs = slices.map { Double($0.typographicBounds.rect.minX) }
        let maxXs = slices.map { Double($0.typographicBounds.rect.maxX) }
        let minX = minXs.min() ?? 0
        let maxX = maxXs.max() ?? minX
        let edgeX = LyricPlaybackClock.absoluteEdge(
            minXs: minXs, maxXs: maxXs, glyphPosition: reveal.edge)
        let solidPosition = max(0, reveal.edge - reveal.feather)
        let solidX = LyricPlaybackClock.absoluteEdge(
            minXs: minXs, maxXs: maxXs, glyphPosition: solidPosition)
        let lineRect = line.typographicBounds.rect
        var masked = context
        if edgeX < maxX - 0.5 {
            let clipRect = CGRect(
                x: minX - 6,
                y: lineRect.minY - 10,
                width: (edgeX + 1) - (minX - 6),
                height: lineRect.height + 20
            )
            masked.clip(to: Path(clipRect))
        }
        let span = max(maxX - minX, 1)
        if edgeX - solidX > 0.4 {
            let edgeUnit = Double((edgeX - minX) / span)
            let featherUnit = Double((edgeX - solidX) / span)
            let stops = LyricPlaybackClock.sweepMaskStops(edge: edgeUnit, feather: featherUnit).map {
                Gradient.Stop(color: Color.white.opacity($0.opacity), location: CGFloat($0.location))
            }
            masked.clipToLayer { mask in
                mask.fill(
                    Path(lineRect.insetBy(dx: -6, dy: -10)),
                    with: .linearGradient(
                        Gradient(stops: stops),
                        startPoint: CGPoint(x: minX, y: lineRect.midY),
                        endPoint: CGPoint(x: maxX, y: lineRect.midY)
                    )
                )
            }
        }
        for slice in slices where slice.typographicBounds.rect.minX < edgeX + 0.5 {
            masked.draw(slice)
        }
    }

    private func slices(in line: Text.Layout.Line) -> [Text.Layout.RunSlice] {
        var result: [Text.Layout.RunSlice] = []
        for run in line {
            for slice in run {
                result.append(slice)
            }
        }
        return result
    }
}

struct LyricSweepLabel: View {
    let text: String
    let role: LyricPlaybackClock.LineRole
    let sweep: LyricPlaybackClock.LyricSweep

    var body: some View {
        switch role {
        case .sung:
            Text(text)
                .foregroundStyle(LyricFillStyle.gradient)
        case .current:
            Text(text)
                .foregroundStyle(unfilled)
                .overlay {
                    Text(text)
                        .foregroundStyle(LyricFillStyle.gradient)
                        .textRenderer(LyricFillRenderer(sweep: sweep))
                        .accessibilityHidden(true)
                }
        case .plain:
            Text(text)
                .foregroundStyle(Theme.Colors.textTertiary)
        case .upcoming:
            Text(text)
                .foregroundStyle(unfilled)
        }
    }

    private var unfilled: Color { Theme.Colors.textTertiary.opacity(0.6) }
}
