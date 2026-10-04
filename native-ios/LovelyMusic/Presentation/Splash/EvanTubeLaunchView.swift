import SwiftUI

/// Branded loading page while local library metadata is being prepared.
struct EvanTubeLaunchView: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color("LaunchBackground")
                    .ignoresSafeArea()

                VStack(spacing: 30) {
                    Image("EvanTubeLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(geometry.size.width * 0.66, geometry.size.height * 0.36))
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Image("EvanTubeLaunchWordmark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 40)
                            .accessibilityLabel("EvanTube")
                        Text("More Than Music")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    }
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.42)

                VStack(spacing: 18) {
                    Text("正在開啟你的音樂世界…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 154 / 255, green: 166 / 255, blue: 184 / 255))
                    EvanTubeLoadingBar()
                        .frame(width: min(geometry.size.width * 0.6, 280), height: 4)
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.73)

                VStack(spacing: 8) {
                    Text("Evan Liao")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text("© 2026 Evan Liao · EvanTube")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 154 / 255, green: 166 / 255, blue: 184 / 255))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("evantube.launch.preview")
    }
}

private struct EvanTubeLoadingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var isStatic: Bool { reduceMotion || scenePhase != .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isStatic)) { timeline in
            GeometryReader { geometry in
                let segmentWidth = geometry.size.width * 0.4
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                let offset = isStatic
                    ? (geometry.size.width - segmentWidth) / 2
                    : (geometry.size.width + segmentWidth) * phase - segmentWidth
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(Theme.Colors.brandGradient)
                        .frame(width: segmentWidth)
                        .offset(x: offset)
                }
                .clipShape(Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在載入")
        .accessibilityIdentifier("evantube.launch.progress")
    }
}

#Preview {
    EvanTubeLaunchView()
}
