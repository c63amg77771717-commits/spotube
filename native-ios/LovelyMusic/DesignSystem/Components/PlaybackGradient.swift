import SwiftUI

struct PlaybackGradient: View {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = PlaybackRingPhase()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying || reduceMotion)) { context in
            let offset = phase.degrees(at: context.date.timeIntervalSinceReferenceDate) / 360
            Rectangle().fill(LinearGradient(
                colors: [
                    Theme.Colors.brandGradientStart, Color(hex: "#729EFF"), Theme.Colors.brandGradientEnd,
                    Theme.Colors.brandGradientStart, Color(hex: "#729EFF"), Theme.Colors.brandGradientEnd,
                    Theme.Colors.brandGradientStart,
                ],
                startPoint: UnitPoint(x: -offset, y: 0.5),
                endPoint: UnitPoint(x: 2 - offset, y: 0.5)
            ))
        }
        .onAppear { updatePhase() }
        .onChange(of: isPlaying) { _, _ in updatePhase() }
        .onChange(of: reduceMotion) { _, _ in updatePhase() }
        .onDisappear { phase.setPlaying(false, at: Date.timeIntervalSinceReferenceDate) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func updatePhase() {
        phase.setPlaying(isPlaying && !reduceMotion, at: Date.timeIntervalSinceReferenceDate)
    }
}
