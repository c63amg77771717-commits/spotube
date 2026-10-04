import GoogleSignIn
import Nuke
import SwiftUI

@main
struct LovelyMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Cached/default configuration is ready synchronously; remote refresh is background work.
    @State private var flagManager: FeatureFlagManager

    /// Built synchronously so offline library, CarPlay and background playback can open immediately.
    @State private var diContainer: DIContainer?
    @State private var isLocalLibraryReady = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
    @AppStorage("disableScreenshots") private var disableScreenshots = false
    @Environment(\.scenePhase) private var scenePhase

    private var isLaunchPreview: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("-evantubeLaunchPreview")
        #else
        return false
        #endif
    }

    init() {
        // XCUITest snapshot seeding: process launch args before @AppStorage reads.
        if CommandLine.arguments.contains("-hasCompletedOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }

        let manager = MainActor.assumeIsolated { FeatureFlagManager() }
        _flagManager = State(initialValue: manager)

        #if DEBUG
        if CommandLine.arguments.contains("-evantubeLaunchPreview") {
            _diContainer = State(initialValue: nil)
            return
        }
        #endif

        // Configure Nuke's shared pipeline for smooth launch experience:
        // - DataCache: persistent disk cache → images load instantly on relaunch
        // - dataCachePolicy: .storeEncodedImages → cache already-resized images (no re-process)
        // - isProgressiveDecodingEnabled → show low-res preview while downloading
        // - isStoringPreviewsInMemoryCache → previews available instantly in memory
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.lovelymusic.images",
            sizeLimit: 150 * 1024 * 1024
        )
        config.dataCachePolicy = .storeEncodedImages
        config.isProgressiveDecodingEnabled = true
        config.isStoringPreviewsInMemoryCache = true
        ImagePipeline.shared = ImagePipeline(configuration: config)

        // Install the UNUserNotificationCenter delegate before any DI work so a
        // cold-start tap (notification received while app not running) is
        // delivered to APNsManager as soon as the system invokes it.
        APNsManager.shared.configureDelegate()

        let container = MainActor.assumeIsolated {
            DIContainer(featureFlagManager: manager)
        }
        _diContainer = State(initialValue: container)
    }

    var body: some Scene {
        WindowGroup {
            if isLaunchPreview {
                EvanTubeLaunchView()
            } else {
                appContent
            }
        }
    }

    private var appContent: some View {
        ZStack {
            if let diContainer, isLocalLibraryReady {
                if hasCompletedOnboarding {
                    ContentView()
                        .environment(diContainer)
                        .environment(diContainer.themeManager)
                        .environment(diContainer.playerViewModel)
                        .environment(diContainer.playbackProgress)
                        .environment(diContainer.audioEngine)
                        .environment(diContainer.sleepTimerManager)
                        .environment(diContainer.premiumManager)
                        .environment(diContainer.equalizerManager)
                        .environment(diContainer.downloadManager)
                        .environment(diContainer.localizationManager)
                        .environment(diContainer.featureFlagManager)
                        .environment(diContainer.scrollDirectionTracker)
                        .environment(\.locale, diContainer.localizationManager.locale)
                        .id("\(ObjectIdentifier(diContainer))-\(diContainer.localizationManager.refreshToken)")
                        .screenshotProtected(disableScreenshots)
                        .transition(.opacity)
                } else {
                    OnboardingView {
                        withAnimation(Theme.AnimationPresets.smooth) {
                            hasCompletedOnboarding = true
                        }
                    }
                    .transition(.opacity)
                }
            } else {
                EvanTubeLaunchView()
            }
        }
        .task {
            // Warm the actual local library before presenting it. DI remains
            // available to CarPlay/background scenes; remote requests never gate launch.
            if !isLocalLibraryReady, let diContainer {
                await diContainer.libraryViewModel.loadLibrary()
                guard !Task.isCancelled else { return }
                isLocalLibraryReady = true
            }
            if scenePhase != .background {
                GoogleDrivePlaylistSync.shared.startForeground()
            }
            await flagManager.fetchFlags()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                GoogleDrivePlaylistSync.shared.stopForeground()
                diContainer?.audioEngine.savePlaybackState()

                // S2: Reclaim disk on background. Trim the LRU cache to
                // its size budget and remove orphans / entries superseded
                // by a downloaded copy.
                if let di = diContainer {
                    di.audioCacheManager.trimToFit()
                    let downloadIds = Set(di.downloadManager.downloadedSongs.map { $0.song.id })
                    di.audioCacheManager.removeOrphans(knownDownloadIds: downloadIds)
                }
            } else if newPhase == .active {
                if isLocalLibraryReady {
                    GoogleDrivePlaylistSync.shared.startForeground()
                }
                // polish-B4: invalidate home cache when returning from a
                // long background pause (>15 min) so users see fresh
                // recommendations. On first launch the cache is not stale
                // (lastForegroundedAt == nil) — we only record the
                // timestamp.
                Task {
                    guard let diContainer else { return }
                    if await diContainer.isHomeCacheStale() {
                        await diContainer.invalidateHomeCache()
                    }
                    await diContainer.touchForegroundCache()
                }
            }
        }
        .onOpenURL { url in
            _ = GIDSignIn.sharedInstance.handle(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistsChanged)) { _ in
            GoogleDrivePlaylistSync.shared.scheduleSync()
        }
    }

    /// Races `fetchFlags()` against a deadline. Returns when whichever finishes
    /// first. The fetch task is allowed to continue in the background after
    /// the deadline (URLSession will honor its own 5s timeout); we just stop
    /// blocking the UI on it. Pure helper — testable without SwiftUI.
    @MainActor
    @discardableResult
    static func fetchWithDeadline(
        _ manager: FeatureFlagManager,
        seconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await manager.fetchFlags()
                return true
            }
            group.addTask {
                let nanos = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return false
            }
            let success = await group.next() ?? false
            group.cancelAll()
            return success
        }
    }
}
