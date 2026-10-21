import AVFoundation
import Foundation
import SwiftUI
import UIKit
import os

// MARK: - Playback Error Categories

enum PlaybackErrorCategory: Equatable {
    case noInternet
    case regionBlocked
    case songRemoved
    case serverError
    case requestRejected
    case authRequired
    case verificationRequired
    case sourceNotConfigured
    case unknown

    static func classify(_ message: String) -> Self {
        let lower = message.lowercased()
        if lower.contains("sourcenotconfigured") || lower.contains("online source is not configured")
            || lower.contains("尚未設定線上音源") {
            return .sourceNotConfigured
        }
        if lower.contains("http") && lower.contains("400") {
            return .requestRejected
        }
        if ["verificationrequired", "verification required", "not a bot", "不是機器人", "不是机器人"].contains(where: lower.contains) {
            return .verificationRequired
        }
        if ["login_required", "sign in", "login", "authentication required", "unauthorized",
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
        if ["server", "500", "503", "429", "too many requests", "rate limit", "quota", "限流", "配額", "伺服器"]
            .contains(where: lower.contains) {
            return .serverError
        }
        return .unknown
    }

    var permitsReplacementSearch: Bool {
        self == .regionBlocked || self == .songRemoved || self == .unknown
    }

    var icon: String {
        switch self {
        case .noInternet: return "wifi.slash"
        case .regionBlocked: return "globe.badge.chevron.backward"
        case .songRemoved: return "trash.circle"
        case .serverError: return "exclamationmark.icloud"
        case .requestRejected: return "exclamationmark.triangle"
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
        case .requestRejected: return "原生播放請求遭拒"
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
        case .requestRejected: return "YouTube 回傳 HTTP 400。App 已嘗試 HLS 備援，請檢查登入狀態或匯出播放診斷。"
        case .authRequired: return LocalizationManager.text("Sign in to YouTube to access this content")
        case .verificationRequired:
            return "YouTube 尚未接受目前的原生播放工作階段。請在 EvanTube 確認登入狀態，若持續失敗請匯出播放診斷。"
        case .sourceNotConfigured:
            return "此版本的原生串流來源尚未設定完整。請檢查 EvanTube 的登入與播放來源設定。"
        case .unknown: return LocalizationManager.text("Something went wrong")
        }
    }
}

/// Decide whether an unavailable recording can advance an existing queue.
    /// This never attempts to circumvent a provider restriction: the new song
    /// gets its own independent playability validation.
enum UnavailablePlaybackRecoveryPolicy {
    enum Action: Equatable {
        case offerManualReplacement
        case skipImmediately
        case skipAfterDelay
        case hold
    }

    static func decide(
        isPermanent: Bool,
        category: PlaybackErrorCategory,
        replacementSearchAvailable: Bool,
        isAppInteractive: Bool,
        autoSkipEnabled: Bool,
        queueHasTracks: Bool
    ) -> Action {
        guard isPermanent else { return .hold }
        // Service/auth/network failures do not establish that a different song
        // will work. Never churn through a queue or bypass login verification.
        if [.authRequired, .verificationRequired, .noInternet, .serverError,
            .requestRejected, .sourceNotConfigured].contains(category) {
            return .hold
        }
        if isAppInteractive, replacementSearchAvailable, category.permitsReplacementSearch {
            return .offerManualReplacement
        }
        guard autoSkipEnabled, queueHasTracks else { return .hold }
        // A suspended background audio task cannot rely on a delayed timer
        // to resume the queue: advance synchronously on the actor instead.
        return isAppInteractive ? .skipAfterDelay : .skipImmediately
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
    private let sourceReplacementStore: PlaybackSourceReplacementStore
    private let playlistSourceStore: PlaylistSourceOverrideStore
    private let previewStreamResolver: ((String) async throws -> (url: String, contentLength: Int64?))?
    private let replacementSearcher: ((String) async throws -> [Song])?
    private let isAppInteractive: () -> Bool
    private(set) var sourceReplacementSession: ReplacementSourceSearchModel?

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
    private(set) var isLyricsVisible: Bool = false
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
    var canRetry: Bool {
        guard retryCount < maxRetries, currentSong != nil else { return false }
        // These are global service or client-configuration failures, not a
        // transient broken recording; offer the official web player instead.
        return ![.authRequired, .verificationRequired, .sourceNotConfigured, .serverError, .requestRejected]
            .contains(where: { $0 == streamErrorCategory })
    }

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
        telemetryManager: TelemetryManager = .shared,
        sourceReplacementStore: PlaybackSourceReplacementStore? = nil,
        playlistSourceOverrideStore: PlaylistSourceOverrideStore? = nil,
        previewStreamResolver: ((String) async throws -> (url: String, contentLength: Int64?))? = nil,
        replacementSearcher: ((String) async throws -> [Song])? = nil,
        isAppInteractive: @escaping () -> Bool = {
            UIApplication.shared.applicationState == .active
        }
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
        self.sourceReplacementStore = sourceReplacementStore ?? PlaybackSourceReplacementStore()
        self.playlistSourceStore = playlistSourceOverrideStore ?? PlaylistSourceOverrideStore()
        self.previewStreamResolver = previewStreamResolver
        self.replacementSearcher = replacementSearcher
        self.isAppInteractive = isAppInteractive
        self.isAutoplayEnabled =
            UserDefaults.standard.object(forKey: "isAutoplayEnabled") as? Bool ?? true
        observeAudioEngineErrors()
        observeBufferingState()
        observeTrackChanges()
        observeStreamRecovery()
        setupAutoplay()
        observeSettingsChanges()

        // System lock-screen next/previous commands bypass PlayerViewModel.next().
        // Reset the same user-initiated recovery budget on these commands.
        audioEngine.onRemoteUserNavigation = { [weak self] in
            guard let self else { return }
            self.autoSkipTask?.cancel()
            self.resetConsecutiveFailures()
            self.retryCount = 0
            self.streamError = nil
            self.streamErrorCategory = nil
        }
        // Reset the consecutive-failure budget only on confirmed AVPlayer
        // playback, not on a pending source URL or a merely selected track.
        audioEngine.onPlaybackConfirmed = { [weak self] song in
            guard let self, self.currentSong?.id == song.id else { return }
            self.resetConsecutiveFailures()
        }
    }

    // MARK: - Actions

    func play(song: Song, fromQueue: [Song] = []) {
        cancelSourceReplacement()
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

    }

    // Lyrics have been retired. Keep these compatibility entry points inert so
    // legacy view observers cannot start a provider request or show a retry UI.
    private func requestLyrics(for song: Song) {}
    func retryInterruptedLyrics() {}
    func retryLyrics() {}
    private func cancelLyricsRequest() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsGeneration += 1
        lyricsTrackID = nil
        lyrics = nil
        lyricsError = nil
        lyricsLookupReport = nil
        isLoadingLyrics = false
    }
    func lyricsSourceSettingsChanged() { cancelLyricsRequest() }
    func loadLyrics(for song: Song) async { cancelLyricsRequest() }

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


    // MARK: - Playlist-only alternative sources

    func hasPlaylistSourceReplacement(song: Song, playlistID: String) -> Bool {
        playlistSourceStore.hasReplacement(playlistID: playlistID, originalID: song.id,
            legacy: { sourceReplacementStore.sourceID(for: $0) })
    }

    func makePlaylistSourceEditor(song: Song, playlistID: String,
                                  stillAvailable: @escaping () -> Bool) -> PlaylistSourceEditorModel? {
        guard let searcher = replacementSearcher, let previewStreamResolver,
              PlaybackSourceReplacementPolicy.isVideoID(song.id),
              !playlistID.isEmpty, stillAvailable() else { return nil }
        return PlaylistSourceEditorModel(
            original: song.inPlaylist(playlistID), store: playlistSourceStore,
            legacySource: { [sourceReplacementStore] in sourceReplacementStore.sourceID(for: $0) },
            searcher: searcher, streamResolver: previewStreamResolver,
            audioEngine: audioEngine, stillAvailable: stillAvailable
        )
    }

    @discardableResult
    func restorePlaylistSource(song: Song, playlistID: String) -> Bool {
        guard !playlistID.isEmpty, PlaybackSourceReplacementPolicy.isVideoID(song.id) else { return false }
        do {
            try playlistSourceStore.restore(playlistID: playlistID, originalID: song.id,
                expectedRevision: playlistSourceStore.revision(playlistID: playlistID, originalID: song.id))
            audioEngine.invalidatePlaylistSource(playlistID: playlistID, originalID: song.id)
            // The current audio keeps playing until the next explicit playback.
            return true
        } catch { return false }
    }

    // MARK: - Per-song alternative playback sources

    var playbackSelectionGeneration: UInt64 { audioEngine.playbackSelectionGeneration }

    var currentPlaybackSourceID: String? {
        currentSong.map { sourceReplacementStore.sourceID(for: $0.id) }
    }

    var hasCurrentSourceReplacement: Bool {
        currentSong.map { sourceReplacementStore.hasReplacement(for: $0.id) } ?? false
    }

    var canSearchReplacement: Bool {
        guard replacementSearcher != nil, let song = currentSong, streamError != nil,
              streamErrorCategory?.permitsReplacementSearch == true else { return false }
        return audioEngine.lastFailedSongId == nil || audioEngine.lastFailedSongId == song.id
    }

    func beginSourceReplacementSearch() {
        guard canSearchReplacement, let song = currentSong, let searcher = replacementSearcher,
              sourceReplacementSession == nil else { return }
        autoSkipTask?.cancel()
        audioEngine.pause()
        let sessionID = UUID()
        let selectionGeneration = audioEngine.playbackSelectionGeneration
        sourceReplacementSession = ReplacementSourceSearchModel(
            id: sessionID, original: song,
            excludedIDs: [sourceReplacementStore.sourceID(for: song.id)],
            contextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.currentSong?.id == song.id
                    && self.audioEngine.playbackSelectionGeneration == selectionGeneration
                    && self.sourceReplacementSession?.id == sessionID
            },
            searcher: searcher)
    }

    func cancelSourceReplacement() {
        sourceReplacementSession?.cancel()
        sourceReplacementSession = nil
    }

    func applySourceReplacement(_ candidate: PlaybackSourceCandidate, sessionID: UUID) {
        guard let session = sourceReplacementSession, session.id == sessionID,
              currentSong?.id == session.original.id, session.contains(candidate) else { return }
        do {
            try sourceReplacementStore.save(sourceID: candidate.id, for: session.original.id)
        } catch { session.reportSaveFailure(); return }
        cancelSourceReplacement()
        reloadCurrentSource()
    }

    func restoreCurrentSource() {
        guard let song = currentSong, sourceReplacementStore.hasReplacement(for: song.id) else { return }
        cancelSourceReplacement()
        do { try sourceReplacementStore.restore(originalID: song.id) }
        catch { streamError = "無法恢復來源，請再試一次。"; return }
        reloadCurrentSource()
    }

    private func reloadCurrentSource() {
        guard var song = currentSong else { return }
        autoSkipTask?.cancel()
        retryCount = 0
        streamError = nil
        streamErrorCategory = nil
        bufferingTooLong = false
        lastHandledVideoTrackId = nil
        song.streamURL = nil
        song.streamContentLength = nil
        song.resolvedSourceID = nil
        // Preserve queue position and original identity; explicitly restart the selected source.
        audioEngine.play(song: song, seekTo: 0)
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
                && category != .authRequired && category != .noInternet && category != .serverError
                && category != .requestRejected
            // One bounded automatic retry is still resolving this attempt.
            // Preserve the engine diagnostic, but do not render it as a final UI failure.
            streamError = retryIsPending ? nil : userReadableError(from: error)
            streamErrorCategory = retryIsPending ? nil : category
            if audioEngine.requiresManualPlaybackRecovery {
                autoSkipTask?.cancel()
                return
            }
            // Service-wide failures are not evidence that this song or queue is invalid.
            if category == .noInternet || category == .serverError || category == .requestRejected {
                autoSkipTask?.cancel()
                return
            }
            if sourceReplacementSession != nil {
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

            if isPermanent {
                let action = UnavailablePlaybackRecoveryPolicy.decide(
                    isPermanent: true,
                    category: category,
                    replacementSearchAvailable: replacementSearcher != nil,
                    isAppInteractive: isAppInteractive(),
                    autoSkipEnabled: autoSkipEnabled,
                    queueHasTracks: !queue.isEmpty
                )
                // Foreground: allow the user to search for another version.
                // Background/lock screen: the replacement UI is inaccessible,
                // so honor autoSkipOnError and advance to a new recording.
                guard action == .skipImmediately || action == .skipAfterDelay else {
                    autoSkipTask?.cancel()
                    return
                }
                consecutiveAutoSkipFailures += 1
                if consecutiveAutoSkipFailures >= maxConsecutiveAutoSkipFailures {
                    PlaybackDiagnostics.shared.record(.init(
                        phase: .autoSkipLimitReached, videoID: videoId,
                        reason: .unavailable, queueCount: queue.count,
                        currentIndex: audioEngine.currentIndex))
                    Log.player.error(
                        "Halting auto-skip after \(self.consecutiveAutoSkipFailures) consecutive unavailable songs"
                    )
                    streamError = "佇列中的多首歌曲無法播放，請選擇其他歌曲。"
                    autoSkipTask?.cancel()
                    return
                }
                PlaybackDiagnostics.shared.record(.init(
                    phase: .autoSkipUnavailable, videoID: videoId,
                    reason: .unavailable, queueCount: queue.count,
                    currentIndex: audioEngine.currentIndex))
                autoSkipTask?.cancel()
                if action == .skipImmediately {
                    // No Task.sleep: iOS can suspend a background app once
                    // playback stops, before its delayed timer can execute.
                    autoNext()
                } else {
                    autoSkipTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(500)) }
                        catch { return }
                        guard let self, !Task.isCancelled, self.streamError != nil,
                              self.currentSong?.id == videoId,
                              self.audioEngine.lastError == error else { return }
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

                // Auto-detect video mode on track change
                if let song = self.currentSong {
                    // Reset the video-load gate when crossing a real song-change
                    // boundary (different `song.id` than last observed). This
                    // keeps duplicate observer fires for the SAME song from
                    // re-triggering `loadVideoStream`, while allowing a genuine
                    // next/previous to load video again. (ExecPlan T3.)
                    if self.previousObservedTrackId != song.id {
                        self.cancelLyricsRequest()
                        self.cancelSourceReplacement()
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

                } else {
                    self.cancelLyricsRequest()
                    self.cancelSourceReplacement()
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
        case .requestRejected:
            return PlaybackErrorCategory.requestRejected.action
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
