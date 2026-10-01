import SwiftUI

/// Static launch artwork. Normal startup finishes local setup before presenting the app.
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

#Preview {
    EvanTubeLaunchView()
}
