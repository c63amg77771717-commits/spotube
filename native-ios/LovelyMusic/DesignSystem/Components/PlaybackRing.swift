import SwiftUI

struct PlaybackRing: View {
    let isPlaying: Bool
    var lineWidth: CGFloat = 1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = PlaybackRingPhase()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying || reduceMotion)) { context in
            Circle()
                .stroke(
                    AngularGradient(colors: [
                        Theme.Colors.brandGradientStart,
                        Color(hex: "#AC70FF"), Color(hex: "#729EFF"),
                        Theme.Colors.brandGradientEnd, Theme.Colors.brandGradientStart,
                    ], center: .center),
                    lineWidth: lineWidth
                )
                .rotationEffect(.degrees(phase.degrees(at: context.date.timeIntervalSinceReferenceDate)))
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
