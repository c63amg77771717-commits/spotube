import SwiftUI

struct ShimmerView: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var cornerRadius: CGFloat = Theme.CornerRadius.small

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active)) { context in
            let cycle = 1.2
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle
            let travel = -1.0 + (2.5 * progress)
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(light: Color(hex: "#C5BEE3"), dark: Color.white.opacity(0.04)))
                .frame(width: width, height: height)
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                Color(light: Color.white.opacity(0.65), dark: Color.white.opacity(0.06)),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: geo.size.width * travel)
                    }
                )
                .drawingGroup()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
