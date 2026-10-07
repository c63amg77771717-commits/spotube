import AVFoundation
import Foundation
import SwiftUI
import os

// MARK: - Playback Error Categories

enum PlaybackErrorCategory: Equatable {
    case noInternet
    case regionBlocked
    case songRemoved
    case serverError
    case authRequired
    case verificationRequired
    case sourceNotConfigured
    case unknown

    static func classify(_ message: String) -> Self {
        let lower = message.lowercased()
        if lower.contains("online source is not configured") || lower.contains("尚未設定線上音源") {
            return .sourceNotConfigured
        }
        if ["not a bot", "不是機器人", "不是机器人"].contains(where: lower.contains) {
            return .verificationRequired
        }
        if ["sign in", "login", "authentication required", "unauthorized",
            "confirm your age", "private", "登入", "私人影片"]
            .contains(where: lower.contains) {
            return .authRequired
        }
        if ["network", "internet", "offline", "connection", "網路"]
            .contains(where: lower.contains) {
            return .noInternet
        }
        if ["removed", "deleted", "not found", "已移除", "音源移除", "刪除"]
            .contains(where: lower.contains) {
            return .songRemoved
        }
        // A missing stream or an unspecified unavailable video does not prove a region restriction.
        if ["region", "country", "geoblock", "geo-block", "地區限制", "所在地區", "地區播放"]
            .contains(where: lower.contains) {
            return .regionBlocked
        }
        if ["server", "500", "503", "伺服器"]
            .contains(where: lower.contains) {
            return .serverError
        }
        return .unknown
    }

    var icon: String {
        switch self {
        case .noInternet: return "wifi.slash"
        case .regionBlocked: return "globe.badge.chevron.backward"
        case .songRemoved: return "trash.circle"
        case .serverError: return "exclamationmark.icloud"
        case .authRequired: return "person.crop.circle.badge.exclamationmark"
        case .verificationRequired: return "checkmark.shield"
        case .sourceNotConfigured: return "gearshape"
        case .unknown: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .noInternet: return LocalizationManager.text("No Internet Connection")
        case .regionBlocked: return LocalizationManager.text("Not Available in Your Region")
        case .songRemoved: return LocalizationManager.text("Song No Longer Available")
        case .serverError: return LocalizationManager.text("Server Error")
        case .authRequired: return LocalizationManager.text("Sign In Required")
        case .verificationRequired: return "YouTube 播放驗證"
        case .sourceNotConfigured: return LocalizationManager.text("Online source is not configured")
        case .unknown: return LocalizationManager.text("Playback Error")
        }
    }

    var action: String {
        switch self {
        case .noInternet: return LocalizationManager.text("Check your connection and try again")
        case .regionBlocked: return LocalizationManager.text("This content is restricted in your area")
        case .songRemoved: return LocalizationManager.text("This song has been removed from the catalog")
        case .serverError: return LocalizationManager.text("Please try again later")
        case .authRequired: return LocalizationManager.text("Sign in to YouTube to access this content")
        case .verificationRequired:
            return "YouTube 要求驗證目前的播放連線。可改用 YouTube 網頁播放，或稍後重試。"
        case .sourceNotConfigured: return LocalizationManager.text("This test build needs source configuration for online playback.")
        case .unknown: return LocalizationManager.text("Something went wrong")
        }
    }
}

enum TransferEstimateFormatter {
    static func upperBoundString(bytes: Int64) -> String {
        let byteCount = max(0, bytes)
        guard byteCount >= 1_024 else {
            return LocalizationManager.text("up to \(byteCount) bytes")
        }
        let units: [(threshold: Double, label: String)] = [
            (1_024 * 1_024 * 1_024, "GB"),
            (1_024 * 1_024, "MB"),
            (1_024, "KB"),
        ]
        let selected = units.first { Double(byteCount) >= $0.threshold }!
        let ceilingValue = ceil((Double(byteCount) / selected.threshold) * 10) / 10
        let value = ceilingValue.rounded() == ceilingValue
            ? String(format: "%.0f", ceilingValue)
            : String(format: "%.1f", ceilingValue)
        return LocalizationManager.text("up to \(value) \(selected.label)")
    }
}

@MainActor
@Observable
final class PlayerViewModel {
    // MARK: - Dependencies
    private let audioEngine: AudioEngine
    private let resolveStreamUseCase: ResolveStreamUseCase
    private let getLyricsUseCase: GetLyricsUseCase
    private let managePlaylistUseCase: ManagePlaylistUseCase
    private let manageFavoritesUseCase: ManageFavoritesUseCase
    private let premiumManager: PremiumManager
    private let getRelatedSongsUseCase: GetRelatedSongsUseCase
    private weak var adManager: AdManager?
    private let telemetryManager: TelemetryManager

    // MARK: - Lyrics
    private(set) var lyrics: SyncedLyrics?
    private(set) var isLoadingLyrics = false
    private(set) var lyricsError: String?
    private(set) var lyricsLookupReport: LyricsLookupReport?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsGeneration = 0
    private var lyricsTrackID: String?

    // MARK: - Dynamic Theme
    var dominantColor: Color = Theme.Colors.brandGradientStart
    private var colorExtractionTask: Task<Void, Never>?
    private var lastColorExtractedSongId: String?

    // MARK: - Video load gate (ExecPlan T3)
    /// Last `Song.id` for which we requested a video stream load. Used by
    /// `observeTrackChanges` to suppress duplicate `loadVideoStream` calls
    /// caused by `currentTrack` reassignments during the same playback
    /// (initial set, post-resolve, recovery).
    private var lastHandledVideoTrackId: String?
    /// Previous `currentTrack.id` observed by `observeTrackChanges`. Used to
    /// detect a genuine song-change boundary so the gate above resets.
    private var previousObservedTrackId: String?

    // MARK: - Favorites tracking
    private var _favoriteRevision = 0

    // MARK: - State
    private(set) var streamError: String?
    private(set) var streamErrorCategory: PlaybackErrorCategory?
    private(set) var bufferingTooLong = false
    private(set) var isAutoplayEnabled: Bool
    private(set) var isLoadingAutoplay = false
    private(set) var isVideoMode = false

    var isFullPlayerPresented: Bool = false
    var isQueuePresented: Bool = false
    var isLyricsVisible: Bool = UserDefaults.standard.bool(forKey: "playerLyricsVisible") {
        didSet { UserDefaults.standard.set(isLyricsVisible, forKey: "playerLyricsVisible") }
    }
    var showYouTubeLoginPrompt: Bool = false
    var isDockHidden: Bool = false

    /// The AVPlayer for video rendering, observed by the UI layer.
    var videoPlayer: AVPlayer? { audioEngine.videoPlayer }

    /// The current video load state, exposed for UI feedback.
    var videoLoadState: VideoPlaybackManager.VideoLoadState { audioEngine.videoLoadState }


    // MARK: - Retry
    private var retryCount = 0
    private let maxRetries = 3
    /// Tracks how many songs in a row failed via auto-skip-on-error so we can
    /// halt the loop when an entire queue (e.g., region-blocked playlist) is
    /// unavailable. Reset on any user-initiated playback action.
    private var consecutiveAutoSkipFailures = 0
    private let maxConsecutiveAutoSkipFailures = 3
    private var bufferingTimerTask: Task<Void, Never>?
    private var autoSkipTask: Task<Void, Never>?

    // MARK: - Observation Guards (prevent subscription stacking)
    private var isObservingErrors = false
    private var isObservingBuffering = false
    private var isObservingTrackChanges = false
    private var isObservingStreamRecovery = false
    private var settingsObserver: NSObjectProtocol?

    var currentSong: Song? { audioEngine.currentTrack }
    var isPlaying: Bool { audioEngine.isPlaying }
    var currentTime: TimeInterval { audioEngine.currentTime }
    var duration: TimeInterval { audioEngine.duration }
    var queue: [Song] { audioEngine.queue }
    var autoplayQueue: [Song] { audioEngine.autoplayQueue }
    var isPlayingFromAutoplay: Bool { audioEngine.isPlayingFromAutoplay }
    var isBuffering: Bool { audioEngine.isBuffering }
    var playbackError: String? { audioEngine.lastError }
    var transferConsentViewState: TransferConsentViewState? {
        audioEngine.transferConsentViewState
    }
    var guardedPlaybackError: GuardedPlaybackError? {
        audioEngine.guardedPlaybackError
    }
    var playbackSpeed: Float {
        get { audioEngine.playbackSpeed }
        set { audioEngine.playbackSpeed = newValue }
    }
    var playbackSpeedLabel: String {
        let speed = audioEngine.playbackSpeed
        if speed == Float(Int(speed)) {
            return "\(Int(speed))x"
        }
        return "\(String(format: "%.2g", speed))x"
    }
    var shuffleEnabled: Bool {
        get { audioEngine.shuffleEnabled }
        set { audioEngine.shuffleEnabled = newValue }
    }
    var repeatMode: AudioEngine.RepeatMode {
        get { audioEngine.repeatMode }
        set { audioEngine.repeatMode = newValue }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var hasTrack: Bool { currentSong != nil }
    var canRetry: Bool { retryCount < maxRetries && currentSong != nil }

    // MARK: - Init

    init(
        audioEngine: AudioEngine,
        resolveStreamUseCase: ResolveStreamUseCase,
        getLyricsUseCase: GetLyricsUseCase,
        managePlaylistUseCase: ManagePlaylistUseCase,
        manageFavoritesUseCase: ManageFavoritesUseCase,
        premiumManager: PremiumManager,
        getRelatedSongsUseCase: GetRelatedSongsUseCase,
        adManager: AdManager? = nil,
        telemetryManager: TelemetryManager = .shared
    ) {
        self.audioEngine = audioEngine
        self.resolveStreamUseCase = resolveStreamUseCase
        self.getLyricsUseCase = getLyricsUseCase
        self.managePlaylistUseCase = managePlaylistUseCase
        self.manageFavoritesUseCase = manageFavoritesUseCase
        self.premiumManager = premiumManager
        self.getRelatedSongsUseCase = getRelatedSongsUseCase
        self.adManager = adManager
        self.telemetryManager = telemetryManager
        self.isAutoplayEnabled =
            UserDefaults.standard.object(forKey: "isAutoplayEnabled") as? Bool ?? true
        observeAudioEngineErrors()
        observeBufferingState()
        observeTrackChanges()
        if let song = currentSong { requestLyrics(for: song) }
        observeStreamRecovery()
        setupAutoplay()
        observeSettingsChanges()
    }

    // MARK: - Actions

    func play(song: Song, fromQueue: [Song] = []) {
        autoSkipTask?.cancel()
        telemetryManager.trackEvent("song_play", parameters: ["song_id": song.id, "title": song.title])
        retryCount = 0
        consecutiveAutoSkipFailures = 0
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        // Reset video-load gate so this play session is treated as fresh.
        // Covers re-tap of same song (F2) and ensures the gate cannot suppress
        // the upcoming initial-set / post-resolve observer fires.
        lastHandledVideoTrackId = nil
        previousObservedTrackId = nil
        audioEngine.play(song: song, fromQueue: fromQueue)

        // Auto-detect video mode based on song metadata
        if song.isVideo {
            isVideoMode = true
            audioEngine.setVideoMode(true)
            // Video stream is loaded by observeTrackChanges (T3 gate)
        } else if isVideoMode {
            isVideoMode = false
            audioEngine.setVideoMode(false)
        }

        requestLyrics(for: song)
    }

    // Track observation can repeat after stream resolution; do not reset a
    // listener's manual cover/video choice for the same recording.
    private func requestLyrics(for song: Song) {
        guard currentSong?.id == song.id, lyricsTrackID != song.id else { return }
        Task { [weak self] in
            guard let self, self.currentSong?.id == song.id, self.lyricsTrackID != song.id else { return }
            await self.loadLyrics(for: song)
        }
    }

    func retryInterruptedLyrics() {
        guard !isLoadingLyrics, lyrics == nil,
              lyricsTrackID == nil || lyricsError != nil || lyricsLookupReport?.canRetryAvailability == true,
              let song = currentSong else { return }
        requestLyricsAfterFailure(for: song)
    }

    private func requestLyricsAfterFailure(for song: Song) {
        lyricsTrackID = nil
        requestLyrics(for: song)
    }

    func retryLyrics() {
        guard let song = currentSong else { return }
        Task { [weak self] in await self?.loadLyrics(for: song) }
    }

    private func cancelLyricsRequest() {
        lyricsTask?.cancel()
        lyricsGeneration += 1
        lyricsTrackID = nil
        lyrics = nil
        lyricsError = nil
        lyricsLookupReport = nil
        isLoadingLyrics = false
    }

    /// Settings changes stop in-flight requests before replacing the lookup.
    func lyricsSourceSettingsChanged() {
        cancelLyricsRequest()
        guard let song = currentSong else { return }
        requestLyrics(for: song)
    }

    func loadLyrics(for song: Song) async {
        guard currentSong?.id == song.id else { return }
        lyricsTask?.cancel()
        lyricsGeneration += 1
        let generation = lyricsGeneration
        lyricsTrackID = song.id
        isLoadingLyrics = true
        lyricsError = nil
        lyricsLookupReport = nil
        lyrics = nil
        let task = Task { [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let report = try await self.getLyricsUseCase.executeReport(song: song)
                guard !Task.isCancelled, self.lyricsGeneration == generation,
                      self.currentSong?.id == song.id else { return }
                let applyStarted = ProcessInfo.processInfo.systemUptime
                defer {
                    if let context = report.diagnosticContext {
                        let now = ProcessInfo.processInfo.systemUptime
                        LyricsLookupDiagnostics.shared.record(.init(context: context, phase: .stageTiming,
                            stage: "playerStateApply", stageElapsedMilliseconds: max(0, now - applyStarted) * 1000))
                        LyricsLookupDiagnostics.shared.record(.init(context: context, phase: .stageTiming,
                            stage: "playerLookupThroughStateApply", stageElapsedMilliseconds: max(0, now - started) * 1000))
                    }
                }
                self.lyricsLookupReport = report
                if report.state == .sourceUnavailable { self.lyricsError = report.state.message }
                if let result = report.lyrics, !result.lines.isEmpty || !result.candidates.isEmpty {
                    // Candidate-only results must reach the player's selection UI.
                    self.lyrics = result
                } else {
                    self.lyrics = nil
                }
            } catch {
                guard self.lyricsGeneration == generation,
                      self.currentSong?.id == song.id else { return }
                if Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    self.lyricsTrackID = nil
                } else {
                    self.lyricsError = "歌詞取得失敗（\(error.localizedDescription)），請重試"
                }
            }
            guard self.lyricsGeneration == generation else { return }
            self.isLoadingLyrics = false
        }
        lyricsTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if lyricsGeneration == generation {
            isLoadingLyrics = false
            if task.isCancelled { lyricsTrackID = nil }
        }
    }

    func playPause() {
        audioEngine.playPause()
    }

    func respondToTransferConsent(_ disposition: TransferConsentUserDisposition) {
        audioEngine.respondToTransferConsent(disposition)
    }

    func updateTransferConsentPresentation(
        applicationIsActive: Bool,
        phoneUIAvailable: Bool
    ) {
        audioEngine.updateTransferConsentPresentation(
            applicationIsActive: applicationIsActive,
            phoneUIAvailable: phoneUIAvailable
        )
    }

    func retryGuardedPlayback() {
        audioEngine.retryGuardedPlayback()
    }

    func guardedPlaybackErrorMessage(_ error: GuardedPlaybackError) -> String {
        switch error {
        case .continueOnPhone:
            return LocalizationManager.text("Continue on your phone to review the network and temporary storage estimate.")
        case .transferConsentDeclined:
            return LocalizationManager.text("The full-song transfer was not started. You can retry when you are ready.")
        case .policyDenied(.cannotEstablishConservativeUpperBound):
            return LocalizationManager.text("Temporary playback preparation cannot be safely sized on this device.")
        case .policyDenied:
            return LocalizationManager.text("Playback is unavailable under the current network or storage policy.")
        case .descriptorQualificationFailed:
            return LocalizationManager.text("The song source could not be verified for a safe full transfer.")
        case .legacyTransportFailed:
            return LocalizationManager.text("The song transfer did not complete. Retry to check the current policy again.")
        case .legacyRemuxFailed:
            return LocalizationManager.text("The temporary song file could not be prepared for playback.")
        case .rangePathUnavailable:
            return LocalizationManager.text("This streaming path is unavailable in the current app version.")
        }
    }

    func next() {
        adManager?.recordSkipAndShowIfNeeded()
        // User-initiated skip — clear the auto-skip failure budget.
        resetConsecutiveFailures()
        performNext()
    }

    /// Auto-skip on error — does NOT consume skip quota
    func autoNext() {
        performNext(userInitiated: false)
    }

    private func performNext(userInitiated: Bool = true) {
        autoSkipTask?.cancel()
        retryCount = 0
        // Only reset the consecutive-failure counter on *user-initiated* skips.
        // Auto-skip due to error must keep accumulating so we can break out of
        // an unavailable queue.
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        audioEngine.next(userInitiated: userInitiated)
    }

    /// Reset the consecutive-failure counter when the user explicitly
    /// navigates — they are taking control of the queue.
    private func resetConsecutiveFailures() {
        consecutiveAutoSkipFailures = 0
    }

    func previous() {
        autoSkipTask?.cancel()
        retryCount = 0
        consecutiveAutoSkipFailures = 0
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        audioEngine.previous()
    }

    func seek(to time: TimeInterval) {
        audioEngine.seek(to: time)
    }

    func seekToProgress(_ progress: Double) {
        let time = progress * duration
        seek(to: time)
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private static let availableSpeeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    func cyclePlaybackSpeed() {
        let speeds = Self.availableSpeeds
        if let index = speeds.firstIndex(of: playbackSpeed) {
            playbackSpeed = speeds[(index + 1) % speeds.count]
        } else {
            playbackSpeed = 1.0
        }
    }

    func addToQueue(_ song: Song) {
        audioEngine.addToQueue(song)
    }

    /// Insert a song to play immediately after the current track without
    /// interrupting playback. If the queue is empty, starts playback with this
    /// song. If the song is already in the queue, it is moved (not duplicated).
    func playNext(_ song: Song) {
        if queue.isEmpty {
            play(song: song)
            return
        }
        audioEngine.insertInQueue(song, at: currentIndex + 1)
    }

    func removeFromQueue(at index: Int) {
        audioEngine.removeFromQueue(at: index)
    }

    func moveToTop(song: Song) {
        guard let songIndex = queue.firstIndex(where: { $0.id == song.id }),
            songIndex > currentIndex + 1
        else { return }
        audioEngine.moveInQueue(
            from: IndexSet(integer: songIndex),
            to: currentIndex + 1
        )
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        audioEngine.moveInQueue(from: source, to: destination)
    }

    // MARK: - Video Mode

    func toggleVideoMode() {
        isLyricsVisible = false
        isVideoMode.toggle()
        audioEngine.setVideoMode(isVideoMode)
        if isVideoMode, let song = currentSong {
            audioEngine.loadVideoStream(for: song)
        }
    }

    func syncVideoPlayback() {
        guard isVideoMode, let vp = videoPlayer else { return }
        let currentTime = audioEngine.currentTime
        let target = CMTime(seconds: currentTime, preferredTimescale: 600)
        vp.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Autoplay

    func toggleAutoplay() {
        isAutoplayEnabled.toggle()
        UserDefaults.standard.set(isAutoplayEnabled, forKey: "isAutoplayEnabled")
        if isAutoplayEnabled {
            setupAutoplay()
        } else {
            audioEngine.onQueueExhausted = nil
        }
    }

    private func setupAutoplay() {
        guard isAutoplayEnabled else { return }
        audioEngine.onQueueExhausted = { [weak self] in
            self?.handleQueueExhausted()
        }
    }

    private func handleQueueExhausted() {
        guard isAutoplayEnabled, let currentSong = audioEngine.currentTrack else {
            return
        }
        isLoadingAutoplay = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let relatedSongs = try await getRelatedSongsUseCase.execute(videoId: currentSong.id)
                let existingIds = Set(
                    audioEngine.queue.map(\.id)
                        + audioEngine.autoplayQueue.map(\.id)
                        + [currentSong.id]
                )
                let newSongs = relatedSongs.filter { !existingIds.contains($0.id) }
                guard !newSongs.isEmpty else {
                    isLoadingAutoplay = false
                    return
                }
                audioEngine.appendToAutoplayQueue(newSongs)

                // If playback stopped because autoplay was empty, resume
                if !audioEngine.isPlaying && !audioEngine.isBuffering {
                    audioEngine.playNextFromAutoplay()
                }

                isLoadingAutoplay = false
            } catch {
                isLoadingAutoplay = false
                Log.player.error(
                    "Autoplay failed to fetch related songs: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Favorites

    func isFavorite(songId: String) -> Bool {
        _ = _favoriteRevision
        return manageFavoritesUseCase.isFavorite(songId: songId)
    }

    var isCurrentSongFavorite: Bool {
        _ = _favoriteRevision
        guard let songId = currentSong?.id else { return false }
        return manageFavoritesUseCase.isFavorite(songId: songId)
    }

    func toggleFavorite(song: Song) async {
        do {
            try await manageFavoritesUseCase.toggleFavorite(song: song)
            _favoriteRevision += 1
        } catch {
            Log.player.error(
                "Failed to toggle favorite: \(error.localizedDescription, privacy: .public)")
        }
    }

    var currentIndex: Int { audioEngine.currentIndex }

    func playFromQueue(at index: Int) {
        autoSkipTask?.cancel()
        guard index < queue.count else { return }
        retryCount = 0
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        let song = queue[index]
        audioEngine.play(song: song, fromQueue: queue)
        Task { [weak self] in await self?.loadLyrics(for: song) }
    }

    func playFromAutoplayQueue(at index: Int) {
        autoSkipTask?.cancel()
        retryCount = 0
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        audioEngine.skipAutoplayTo(index: index)
    }

    // MARK: - Playback Restoration

    /// Restore playback from persisted state on app launch
    func restorePersistedPlayback() {
        guard let state = audioEngine.playbackStatePersistence?.restore() else { return }
        audioEngine.restorePlaybackState(state)

        // Set current song in ViewModel without triggering playback
        if state.currentIndex >= 0, state.currentIndex < state.queue.count {
            // Don't auto-play — user will tap play when ready
        }
    }

    // MARK: - Error Handling

    func prepareForWebPlayback() {
        autoSkipTask?.cancel()
        retryCount = 0
        audioEngine.pause()
    }

    func retryCurrentSong(resetRetryCount: Bool = false) {
        autoSkipTask?.cancel()
        if resetRetryCount { retryCount = 0 }
        guard retryCount < maxRetries, var song = currentSong else { return }
        let position = currentTime
        song.streamURL = nil
        song.streamContentLength = nil
        retryCount += 1
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        audioEngine.play(song: song, seekTo: position)
    }

    func dismissError() {
        streamError = nil
        streamErrorCategory = nil
    }

    // MARK: - Observation

    private func observeAudioEngineErrors() {
        guard !isObservingErrors else { return }
        isObservingErrors = true
        withObservationTracking {
            _ = self.audioEngine.lastError
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingErrors = false
                self.handleErrorChange()
                self.observeAudioEngineErrors()
            }
        }
    }

    private func handleErrorChange() {
        if let error = audioEngine.lastError {
            let videoId = audioEngine.lastFailedSongId ?? currentSong?.id ?? ""
            telemetryManager.recordError(
                NSError(domain: "LovelyMusic.Playback", code: -1, userInfo: [NSLocalizedDescriptionKey: error]),
                additionalInfo: ["video_id": videoId]
            )
            if let failedID = audioEngine.lastFailedSongId, failedID != currentSong?.id {
                streamError = nil
                streamErrorCategory = nil
                autoSkipTask?.cancel()
                return
            }
            let category = PlaybackErrorCategory.classify(error)
            let retryIsPending = !audioEngine.requiresManualPlaybackRecovery
                && audioEngine.lastErrorKind != .permanent && retryCount == 0
                && currentSong != nil
                && category != .sourceNotConfigured && category != .verificationRequired
                && category != .authRequired
            // One bounded automatic retry is still resolving this attempt.
            // Preserve the engine diagnostic, but do not render it as a final UI failure.
            streamError = retryIsPending ? nil : userReadableError(from: error)
            streamErrorCategory = retryIsPending ? nil : category
            if audioEngine.requiresManualPlaybackRecovery {
                autoSkipTask?.cancel()
                return
            }
            let isPermanent = audioEngine.lastErrorKind == .permanent
            let autoSkipEnabled =
                UserDefaults.standard.object(forKey: "autoSkipOnError") as? Bool ?? true

            if streamErrorCategory == .sourceNotConfigured || streamErrorCategory == .verificationRequired {
                autoSkipTask?.cancel()
                return
            }

            // Auth required: halt auto-skip and trigger login prompt so the user
            // can authenticate rather than skipping the remainder of the queue.
            if streamErrorCategory == .authRequired {
                showYouTubeLoginPrompt = true
                autoSkipTask?.cancel()
                return
            }

            // Permanent failure (region-blocked, removed, no stream): retrying
            // the same song is pointless. Count it against the consecutive
            // failure budget and either auto-skip immediately or halt the loop.
            if isPermanent {
                self.consecutiveAutoSkipFailures += 1
                if self.consecutiveAutoSkipFailures >= maxConsecutiveAutoSkipFailures {
                    Log.player.error(
                        "Halting auto-skip after \(self.consecutiveAutoSkipFailures) consecutive unavailable songs"
                    )
                    streamError =
                        "佇列中的多首歌曲無法播放，請選擇其他歌曲。"
                    autoSkipTask?.cancel()
                    return
                }
                if autoSkipEnabled, !queue.isEmpty {
                    autoSkipTask?.cancel()
                    autoSkipTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let self, !Task.isCancelled, self.streamError != nil,
                              self.currentSong?.id == videoId, self.audioEngine.lastError == error else { return }
                        self.autoNext()
                    }
                }
                return
            }

            // Transient failure: try once more before giving up on this song.
            if retryCount == 0 {
                autoSkipTask?.cancel()
                autoSkipTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled, self.currentSong?.id == videoId,
                          self.audioEngine.lastError == error,
                          !self.audioEngine.requiresManualPlaybackRecovery else { return }
                    self.retryCurrentSong()
                }
            } else if autoSkipEnabled {
                self.consecutiveAutoSkipFailures += 1
                if self.consecutiveAutoSkipFailures >= maxConsecutiveAutoSkipFailures {
                    Log.player.error(
                        "Halting auto-skip after \(self.consecutiveAutoSkipFailures) consecutive failures"
                    )
                    streamError =
                        "最近幾首歌曲播放失敗，請檢查網路連線或選擇其他歌曲。"
                    autoSkipTask?.cancel()
                    return
                }
                autoSkipTask?.cancel()
                autoSkipTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled, self.streamError != nil, !self.queue.isEmpty,
                          self.currentSong?.id == videoId, self.audioEngine.lastError == error
                    else { return }
                    self.autoNext()
                }
            }
        } else {
            streamError = nil
            streamErrorCategory = nil
            autoSkipTask?.cancel()
        }
    }

    private func observeBufferingState() {
        guard !isObservingBuffering else { return }
        isObservingBuffering = true
        withObservationTracking {
            _ = self.audioEngine.isBuffering
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingBuffering = false
                self.handleBufferingChange()
                self.observeBufferingState()
            }
        }
    }

    private func handleBufferingChange() {
        bufferingTimerTask?.cancel()
        if audioEngine.isBuffering {
            bufferingTimerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                self.bufferingTooLong = true
            }
        } else {
            bufferingTooLong = false
        }
    }

    // MARK: - Track Change Observation

    private func observeTrackChanges() {
        guard !isObservingTrackChanges else { return }
        isObservingTrackChanges = true
        withObservationTracking {
            _ = self.audioEngine.currentTrack
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingTrackChanges = false
                self.extractDominantColor()

                // Persist playback state on track change
                self.audioEngine.savePlaybackState()

                // Auto-detect video mode and reload lyrics on track change
                if let song = self.currentSong {
                    // Reset the video-load gate when crossing a real song-change
                    // boundary (different `song.id` than last observed). This
                    // keeps duplicate observer fires for the SAME song from
                    // re-triggering `loadVideoStream`, while allowing a genuine
                    // next/previous to load video again. (ExecPlan T3.)
                    if self.previousObservedTrackId != song.id {
                        self.cancelLyricsRequest()
                        self.autoSkipTask?.cancel()
                        self.retryCount = 0
                        self.streamError = nil
                        self.streamErrorCategory = nil
                        self.previousObservedTrackId = song.id
                        self.lastHandledVideoTrackId = nil
                    }

                    if song.isVideo {
                        self.isVideoMode = true
                        self.audioEngine.setVideoMode(true)
                        if self.lastHandledVideoTrackId != song.id {
                            self.lastHandledVideoTrackId = song.id
                            self.audioEngine.loadVideoStream(for: song)
                        }
                    } else if self.isVideoMode {
                        self.isVideoMode = false
                        self.audioEngine.setVideoMode(false)
                    }

                    // Reload lyrics for the new track
                    self.requestLyrics(for: song)
                } else {
                    self.cancelLyricsRequest()
                }

                self.observeTrackChanges()
            }
        }
    }

    /// Reset the video-load gate when AudioEngine begins a stream-recovery
    /// pass. Recovery reassigns `currentTrack` to a fresh `Song` with the
    /// SAME `id` but a new `streamURL`; without this hook the gate would
    /// suppress the resulting `loadVideoStream` and the video layer would
    /// keep its stale googlevideo URL while audio recovers (F1).
    private func observeStreamRecovery() {
        guard !isObservingStreamRecovery else { return }
        isObservingStreamRecovery = true
        withObservationTracking {
            _ = self.audioEngine.isReconnecting
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingStreamRecovery = false
                // Any transition (entering OR leaving recovery) invalidates
                // the gate — the next `currentTrack` reassignment must be
                // allowed through to reload the video stream.
                self.lastHandledVideoTrackId = nil
                self.observeStreamRecovery()
            }
        }
    }

    private func extractDominantColor() {
        let songId = currentSong?.id
        guard songId != lastColorExtractedSongId else { return }
        lastColorExtractedSongId = songId

        colorExtractionTask?.cancel()

        guard let urlString = currentSong?.thumbnailURL,
            let url = URL(string: urlString)
        else {
            withAnimation(.easeOut(duration: 0.3)) {
                dominantColor = Theme.Colors.brandGradientStart
            }
            return
        }

        colorExtractionTask = Task { [weak self] in
            if let color = await DominantColorExtractor.extractColor(from: url) {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    self.dominantColor = color
                }
            } else {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    self.dominantColor = Theme.Colors.brandGradientStart
                }
            }
        }
    }

    private func userReadableError(from error: String) -> String {
        switch PlaybackErrorCategory.classify(error) {
        case .authRequired:
            return LocalizationManager.text("Sign in to YouTube is required to play this track.")
        case .verificationRequired:
            return PlaybackErrorCategory.verificationRequired.action
        case .noInternet:
            return LocalizationManager.text("Network error. Check your connection and try again.")
        case .regionBlocked:
            return LocalizationManager.text("This song is unavailable in your region.")
        case .songRemoved:
            return PlaybackErrorCategory.songRemoved.action
        case .serverError:
            return PlaybackErrorCategory.serverError.action
        case .sourceNotConfigured:
            return PlaybackErrorCategory.sourceNotConfigured.action
        case .unknown:
            return LocalizationManager.text("Unable to load this song. The stream may be unavailable.")
        }
    }

    // MARK: - Settings Observation

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newValue =
                    UserDefaults.standard.object(forKey: "isAutoplayEnabled") as? Bool ?? true
                if self.isAutoplayEnabled != newValue {
                    self.isAutoplayEnabled = newValue
                    if newValue {
                        self.setupAutoplay()
                    } else {
                        self.audioEngine.onQueueExhausted = nil
                    }
                }
            }
        }
    }
}
