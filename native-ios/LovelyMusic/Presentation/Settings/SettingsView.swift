import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(DIContainer.self) private var container
    @State private var showPlaylistImport = false
    @State private var showDriveSync = false
    @Bindable var themeManager: ThemeManager
    @Environment(SleepTimerManager.self) private var sleepTimerManager
    @Environment(EqualizerManager.self) private var equalizerManager
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    // Haptic feedback triggers (SwiftUI native, replacing UIKit imperative calls)
    @State private var mediumHapticTrigger = false
    @Namespace private var qualityNamespace

    var body: some View {
        ZStack(alignment: .top) {
            // Base background
            Theme.Colors.backgroundPrimary.ignoresSafeArea()

            // Gradient header bleed — brand gradient that fades into content
            settingsGradientHeader

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.xl) {
                    // MARK: - Account Card (Hero Identity)
                    if featureFlags.isYouTubeAuthEnabled {
                        accountCard
                            .padding(.horizontal, Theme.Spacing.lg)
                            .staggeredAppear(index: 0)
                    }

                playlistSettingsSection
                    .padding(.bottom, Theme.Spacing.lg)

                // MARK: - Appearance (elevated visual showcase)
                if featureFlags.isAppearanceSettingsEnabled {
                    appearanceSection
                        .staggeredAppear(index: 2)
                }

                // MARK: - Navigation Cards (Individual floating cards)
                VStack(spacing: Theme.Spacing.md) {
                    // Playback & Audio
                    NavigationLink {
                        PlaybackAudioSettingsView(
                            viewModel: viewModel,
                            equalizerPresetName: equalizerManager.selectedPreset.localizedName,
                            sleepTimerIsActive: sleepTimerManager.isActive,
                            sleepTimerFormatted: sleepTimerManager.formattedRemaining,
                            audioQualityPicker: AnyView(audioQualityPicker),
                            onCancelSleepTimer: {
                                sleepTimerManager.cancel()
                                viewModel.sleepTimer = .off
                            }
                        )
                    } label: {
                        settingsNavCard(
                            icon: "waveform",
                            accentColor: Theme.Colors.brandGradientStart,
                            title: "Playback & Audio",
                            subtitle: playbackSubtitle,
                            badge: viewModel.audioQuality.displayName
                        )
                    }
                    .buttonStyle(.bouncy)

                    // Language & Region
                    NavigationLink {
                        LanguageRegionSettingsView(viewModel: viewModel)
                    } label: {
                        settingsNavCard(
                            icon: "globe",
                            accentColor: .blue,
                            title: "Language & Region",
                            subtitle: languageSubtitle,
                            badge: viewModel.region
                        )
                    }
                    .buttonStyle(.bouncy)

                    // Privacy & Storage
                    NavigationLink {
                        PrivacyStorageSettingsView(viewModel: viewModel)
                    } label: {
                        settingsNavCard(
                            icon: "lock.shield.fill",
                            accentColor: Theme.Colors.error,
                            title: "Privacy & Storage",
                            subtitle: privacySubtitle,
                            badge: viewModel.cacheSize.isEmpty ? nil : viewModel.cacheSize
                        )
                    }
                    .buttonStyle(.bouncy)

                    // About
                    NavigationLink {
                        AboutView()
                    } label: {
                        settingsNavCard(
                            icon: "music.note.house.fill",
                            accentColor: Theme.Colors.brandGradientEnd,
                            title: "About",
                            subtitle: "製作資訊、授權與條款",
                            badge: "v\(appVersion)"
                        )
                    }
                    .buttonStyle(.bouncy)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .staggeredAppear(index: 3)

                // MARK: - Reset
                resetAllButton
                    .staggeredAppear(index: 4)

                // MARK: - Branded Footer
                settingsBrandedFooter
                    .staggeredAppear(index: 5)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("Settings")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .sheet(isPresented: $showPlaylistImport) {
            MB3ImportView(viewModel: container.libraryViewModel)
        }
        .sheet(isPresented: $showDriveSync) {
            GoogleDriveSyncView()
        }
        .sheet(isPresented: $viewModel.showingLogin) {
            YouTubeLoginView(authManager: viewModel.authManager) {
                NotificationCenter.default.post(name: .settingsChanged, object: nil)
            }
        }
        .onChange(of: viewModel.sleepTimer) { _, newValue in
            sleepTimerManager.start(option: newValue)
        }
        .alert("Sign Out?", isPresented: $viewModel.showSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                withAnimation(Theme.AnimationPresets.smooth) {
                    viewModel.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You'll need to sign in again to access your music library, playlists, and personalized recommendations."
            )
        }
        .alert("Reset All Settings?", isPresented: $viewModel.showResetAllAlert) {
            Button("Reset", role: .destructive) {
                viewModel.resetAllSettings()
                container.audioEngine.shuffleEnabled = false
                container.audioEngine.repeatMode = .off
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "All preferences (playback, audio, language, privacy) will return to defaults. Your playlists, history, downloads, and account are not affected."
            )
        }
        .overlay(alignment: .top) {
            resetCompletedToast
        }
        .animation(Theme.AnimationPresets.smooth, value: viewModel.showResetAllCompleted)
        // SwiftUI native haptics (replacing UIKit UIImpactFeedbackGenerator calls)
        .sensoryFeedback(.impact(weight: .medium), trigger: mediumHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.sleepTimer)
    }

    private var playlistSettingsSection: some View {
        SettingsGroup(header: "歌單與同步") {
            Button {
                showPlaylistImport = true
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Label("匯入歌單", systemImage: "square.and.arrow.down")
                        .foregroundStyle(Theme.Colors.brandGradient)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(minHeight: 52)
                .padding(.horizontal, Theme.Spacing.lg)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings_playlist_import")
            SettingsDivider()
            Button {
                showDriveSync = true
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Label("Google Drive 歌單同步", systemImage: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(Theme.Colors.brandGradient)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(minHeight: 52)
                .padding(.horizontal, Theme.Spacing.lg)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings_drive_sync")
        }
    }

    // MARK: - Gradient Header Background

    private var settingsGradientHeader: some View {
        LinearGradient(
            colors: [
                Theme.Colors.brandGradientStart.opacity(0.12),
                Theme.Colors.brandGradientEnd.opacity(0.06),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 220)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Individual Navigation Card

    private func settingsNavCard(
        icon: String,
        accentColor: Color,
        title: LocalizedStringKey,
        subtitle: String,
        badge: String? = nil
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Left accent glowing border indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4, height: 38)
                .shadow(color: accentColor.opacity(0.3), radius: 3, x: 0, y: 0)

            // Icon with rounded squircle and subtle gradient
            ZStack {
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: accentColor.opacity(0.35), radius: 6, x: 0, y: 3)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            // Text stack
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let badge {
                Text(badge)
                    .font(Theme.Typography.captionSecondary)
                    .fontWeight(.semibold)
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, Theme.Spacing.xs + 2)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.12), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
        .shadow(
            color: Theme.Shadows.small.color,
            radius: Theme.Shadows.small.radius,
            x: Theme.Shadows.small.x,
            y: Theme.Shadows.small.y
        )
    }

    // MARK: - Branded Footer

    private var settingsBrandedFooter: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Gradient app name
            Text("EvanTube")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // Version pill
            Text("v\(appVersion)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    Capsule().fill(Theme.Colors.backgroundTertiary)
                )

            // Horizontal legal links
            HStack(spacing: Theme.Spacing.md) {
                if let url = URL(string: "https://www.iletai.qzz.io/policy#privacy-policy") {
                    Link("Privacy Policy", destination: url)
                }

                Circle()
                    .fill(Theme.Colors.textTertiary)
                    .frame(width: 3, height: 3)

                if let url = URL(string: "https://www.iletai.qzz.io/policy#terms-of-use") {
                    Link("Terms of Use", destination: url)
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textTertiary)

            Text("Made with ♪ in Vietnam")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary.opacity(0.6))
                .accessibilityIdentifier("settings_footer_note")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxxl)
        .padding(.top, Theme.Spacing.xl)
    }

    // MARK: - Subtitles for Navigation Rows

    private var resetAllButton: some View {
        Button(role: .destructive) {
            viewModel.showResetAllAlert = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text("Reset All Settings")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var resetCompletedToast: some View {
        if viewModel.showResetAllCompleted {
            Text("Settings reset")
                .font(Theme.Typography.body)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(.green.opacity(0.9), in: Capsule())
                .padding(.top, Theme.Spacing.md)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var playbackSubtitle: String {
        let quality = viewModel.audioQuality.displayName
        let eq = equalizerManager.selectedPreset.localizedName
        return "\(quality)音質 · \(eq)"
    }

    private var languageSubtitle: String {
        let lang = localizationManager.currentLanguage.displayName
        let region = regionName(viewModel.region)
        return "\(lang) · \(region)"
    }

    private var privacySubtitle: String {
        var parts: [String] = []
        if viewModel.pauseListenHistory || viewModel.pauseSearchHistory {
            parts.append("紀錄已暫停")
        }
        if !viewModel.cacheSize.isEmpty {
            parts.append("快取 \(viewModel.cacheSize)")
        }
        return parts.isEmpty ? "管理紀錄、快取與隱私" : parts.joined(separator: " · ")
    }

    private func regionName(_ code: String) -> String {
        switch code {
        case "TW": return "台灣"
        case "VN": return "越南"
        case "US": return "美國"
        case "JP": return "日本"
        case "KR": return "韓國"
        default: return code
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - Account Card (Hero Identity)

    @State private var avatarRingRotation: Double = 0

    private var accountCard: some View {
        VStack(spacing: 0) {
            if viewModel.isLoggedIn {
                HStack(spacing: Theme.Spacing.lg) {
                    // Avatar with animated gradient ring
                    ZStack {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        Theme.Colors.brandGradientStart,
                                        Theme.Colors.brandGradientEnd,
                                        Theme.Colors.brandGradientStart.opacity(0.6),
                                        Theme.Colors.brandGradientStart
                                    ],
                                    center: .center
                                ),
                                lineWidth: 3
                            )
                            .frame(width: 58, height: 58)
                            .rotationEffect(.degrees(avatarRingRotation))

                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(Theme.Colors.brandGradientStart)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(viewModel.accountName ?? LocalizationManager.text("Music Account"))
                            .font(Theme.Typography.title3)
                            .foregroundStyle(Theme.Colors.textPrimary)


                            Text("Signed in")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
                .transition(.scale.combined(with: .opacity))

                Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                    .padding(.leading, 76)

                Button(role: .destructive) {
                    viewModel.showSignOutAlert = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Theme.Colors.error)
                        Text("Sign Out")
                            .foregroundStyle(Theme.Colors.error)
                        Spacer()
                    }
                    .font(Theme.Typography.body)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
                }
            } else {
                Button {
                    viewModel.showingLogin = true
                } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        // Avatar placeholder with subtle gradient ring
                        ZStack {
                            Circle()
                                .stroke(
                                    Theme.Colors.textTertiary.opacity(0.3),
                                    lineWidth: 2
                                )
                                .frame(width: 58, height: 58)

                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 46))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }

                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Sign in")
                                .font(Theme.Typography.title3)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text("Access playlists & recommendations")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.xl)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.AnimationPresets.smooth, value: viewModel.isLoggedIn)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
        .shadow(
            color: Theme.Shadows.small.color,
            radius: Theme.Shadows.small.radius,
            x: Theme.Shadows.small.x,
            y: Theme.Shadows.small.y
        )
        .onAppear {
            guard viewModel.isLoggedIn else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                avatarRingRotation = 360
            }
        }
    }

    // MARK: - Appearance Section (Visual Showcase)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Section header
            Text("Appearance")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, Theme.Spacing.lg)

            // Visual theme cards - larger, more expressive
            HStack(spacing: Theme.Spacing.md) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    let isSelected = themeManager.appearanceMode == mode
                    Button {
                        withAnimation(Theme.AnimationPresets.bouncy) {
                            themeManager.appearanceMode = mode
                        }
                    } label: {
                        VStack(spacing: Theme.Spacing.sm) {
                            // Mini device preview
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(mode == .dark ? Color.black.opacity(0.85) : mode == .light ? Color.white : Color.gray.opacity(0.2))
                                    .frame(height: 72)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .stroke(
                                                isSelected
                                                    ? Theme.Colors.brandGradientStart
                                                    : Theme.Colors.textTertiary.opacity(0.2),
                                                lineWidth: isSelected ? 2 : 1
                                            )
                                    )

                                // Mini content lines inside preview
                                VStack(alignment: .leading, spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(mode == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.15))
                                        .frame(width: 36, height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(mode == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.08))
                                        .frame(width: 28, height: 3)
                                    HStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Theme.Colors.brandGradientStart.opacity(0.5))
                                            .frame(width: 12, height: 12)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(mode == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.06))
                                            .frame(width: 20, height: 3)
                                    }
                                }
                                .padding(Theme.Spacing.sm)
                            }

                            // Label + selection dot
                            VStack(spacing: Theme.Spacing.xs) {
                                Text(mode.displayName)
                                    .font(Theme.Typography.caption)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundStyle(
                                        isSelected
                                            ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)

                                Circle()
                                    .fill(isSelected ? Theme.Colors.brandGradientStart : Color.clear)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .scaleEffect(isSelected ? 1.03 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .animation(Theme.AnimationPresets.smooth, value: themeManager.appearanceMode)
        .sensoryFeedback(.impact(weight: .light), trigger: themeManager.appearanceMode)
    }

    // MARK: - Audio Quality Picker

    private var audioQualityPicker: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(AudioQuality.allCases, id: \.self) { quality in
                let isSelected = viewModel.audioQuality == quality

                Button {

                        withAnimation(Theme.AnimationPresets.bouncy) {
                            viewModel.audioQuality = quality
                        }
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Text(quality.displayName)
                            .font(Theme.Typography.caption)
                            .fontWeight(isSelected ? .semibold : .medium)

                    }
                    .foregroundStyle(
                        isSelected
                            ? .white
                            : Theme.Colors.textSecondary
                    )
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.Colors.brandGradient)
                                .matchedGeometryEffect(id: "qualitySelector", in: qualityNamespace)
                                .shadow(color: Theme.Colors.brandGradientStart.opacity(0.35), radius: 4, x: 0, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.xxxs)
        .fixedSize()
        .background(Theme.Colors.surfaceCard, in: Capsule())
    }

    // MARK: - Helpers

    private func regionDisplayName(_ code: String) -> String {
        switch code {
        case "VN": return LocalizationManager.text("🇻🇳 Vietnam")
        case "US": return LocalizationManager.text("🇺🇸 United States")
        case "JP": return LocalizationManager.text("🇯🇵 Japan")
        case "KR": return LocalizationManager.text("🇰🇷 Korea")
        default: return code
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "vi": return LocalizationManager.text("🇻🇳 Vietnamese")
        case "en": return LocalizationManager.text("🇺🇸 English")
        case "ja": return LocalizationManager.text("🇯🇵 Japanese")
        case "ko": return LocalizationManager.text("🇰🇷 Korean")
        default: return code
        }
    }
}
