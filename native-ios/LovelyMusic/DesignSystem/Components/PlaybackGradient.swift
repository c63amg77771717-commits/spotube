import SwiftUI

/// Left-to-right colors of the playback progress bar.
/// Karaoke lyric fill uses `linear`. The bar repeats the same list so its shimmer can travel.
enum PlaybackFillGradient {
    static let paletteHexes = ["#C174FF", "#729EFF", "#84DFFF"]

    static var colors: [Color] { paletteHexes.map { Color(hex: $0) } }

    static var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static var travelingHexes: [String] {
        paletteHexes + paletteHexes + [paletteHexes[0]]
    }

    static func traveling(offset: Double) -> LinearGradient {
        LinearGradient(
            colors: travelingHexes.map { Color(hex: $0) },
            startPoint: UnitPoint(x: -offset, y: 0.5),
            endPoint: UnitPoint(x: 2 - offset, y: 0.5)
        )
    }
}

struct PlaybackGradient: View {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = PlaybackRingPhase()

    private var animating: Bool {
        isPlaying && !reduceMotion && scenePhase == .active && !PlaybackInterfaceGate.shared.suspended
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            let offset = phase.degrees(at: context.date.timeIntervalSinceReferenceDate) / 360
            Rectangle().fill(PlaybackFillGradient.traveling(offset: offset))
        }
        .onAppear { updatePhase() }
        .onChange(of: isPlaying) { _, _ in updatePhase() }
        .onChange(of: reduceMotion) { _, _ in updatePhase() }
        .onChange(of: scenePhase) { _, _ in updatePhase() }
        .onChange(of: PlaybackInterfaceGate.shared.suspended) { _, _ in updatePhase() }
        .onDisappear { phase.setPlaying(false, at: Date.timeIntervalSinceReferenceDate) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func updatePhase() {
        phase.setPlaying(animating, at: Date.timeIntervalSinceReferenceDate)
    }
}
