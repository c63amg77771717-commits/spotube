import SwiftUI

struct FloatingDockView: View {
    @Binding var selectedTab: AppTab
    var onReselect: ((AppTab) -> Void)?
    @Environment(PlayerViewModel.self) private var playerVM

    private var hasSong: Bool { playerVM.currentSong != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar at the top edge of the dock (isolated sub-view)
            if hasSong {
                DockProgressBar()
            }

            // Mini player row
            if hasSong {
                DockMiniPlayer()
                    .transition(
                        .asymmetric(
                            insertion: .push(from: .bottom).combined(with: .opacity),
                            removal: .push(from: .top).combined(with: .opacity)
                        ))

                // Divider between mini player and tabs — Round 2 Q3: 1px hairline.
                Rectangle()
                    .fill(Theme.Colors.divider)
                    .frame(height: Theme.SizeTokens.dividerThick)
                    .padding(.horizontal, 12)
            }

            // Tab bar (always visible)
            DockTabBar(selectedTab: $selectedTab, onReselect: onReselect)
        }
        // Round 2 Q3: depth via solid surface + hairline + shadow, NOT material.
        .background(Theme.Colors.miniPlayerBackground)
        .clipShape(
            RoundedRectangle(
                cornerRadius: hasSong ? Theme.CornerRadius.extraLarge : 28,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: hasSong ? Theme.CornerRadius.extraLarge : 28,
                style: .continuous
            )
            .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
        .shadow(
            color: Theme.Shadows.medium.color,
            radius: Theme.Shadows.medium.radius,
            x: Theme.Shadows.medium.x,
            y: Theme.Shadows.medium.y
        )
        .padding(.horizontal, hasSong ? Theme.Spacing.lg : Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.sm)
        .animation(Theme.AnimationPresets.smooth, value: hasSong)
    }
}

/// Progress updates and scrubbing stay isolated from the rest of the dock.
private struct DockProgressBar: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackProgress.self) private var playbackProgress
    @State private var sliderValue = 0.0
    @State private var isSeeking = false

    var body: some View {
        ProgressSlider(
            value: Binding(
                get: { isSeeking ? sliderValue : playbackProgress.progress },
                set: { sliderValue = $0; isSeeking = true }
            ),
            isPlaying: playerVM.isPlaying,
            onEditingChanged: { editing in
                if !editing { playerVM.seekToProgress(sliderValue) }
            },
            duration: playbackProgress.duration
        )
        .padding(.horizontal, Theme.Spacing.lg)
        .disabled(playbackProgress.duration <= 0)
        .accessibilityIdentifier("dock_progress_slider")
        .onChange(of: playbackProgress.progress) { _, progress in
            if isSeeking, abs(progress - sliderValue) < 0.005 { isSeeking = false }
        }
        .onChange(of: playerVM.currentSong?.id) {
            isSeeking = false
            sliderValue = 0
        }
    }
}
