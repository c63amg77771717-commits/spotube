import AVFoundation
import Foundation
import Observation

/// Explicit, playlist-scoped source editing. A search never mutates playback.
@MainActor @Observable
final class PlaylistSourceEditorModel: Identifiable {
    let id = UUID()
    let original: Song
    private let store: PlaylistSourceOverrideStore
    private let legacySource: (String) -> String
    private let searcher: (String) async throws -> [Song]
    private let streamResolver: (String) async throws -> (url: String, contentLength: Int64?)
    private let audioEngine: AudioEngine
    private let stillAvailable: () -> Bool
    private let startingRevision: UInt64

    var query: String {
        didSet {
            guard query != oldValue else { return }
            invalidateSearch()
            endPreview(resumeOriginal: true)
            approvedCandidateID = nil
            approvedAsset = nil
        }
    }
    private(set) var candidates: [PlaybackSourceCandidate] = []
    private(set) var isSearching = false
    private(set) var isPreviewing = false
    private(set) var isCommitting = false
    private(set) var previewedCandidateID: String?
    private(set) var errorMessage: String?
    private(set) var didFinish = false
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var searchTask: Task<[Song], Error>?
    @ObservationIgnored private var auditionPlayer: AVPlayer?
    @ObservationIgnored private var previewToken: AudioEngine.SourcePreviewToken?
    @ObservationIgnored private var previewStopTask: Task<Void, Never>?
    @ObservationIgnored private var approvedCandidateID: String?
    @ObservationIgnored private var approvedAsset: AVURLAsset?

    init(original: Song, store: PlaylistSourceOverrideStore,
         legacySource: @escaping (String) -> String,
         searcher: @escaping (String) async throws -> [Song],
         streamResolver: @escaping (String) async throws -> (url: String, contentLength: Int64?),
         audioEngine: AudioEngine, stillAvailable: @escaping () -> Bool) {
        self.original = original
        self.store = store
        self.legacySource = legacySource
        self.searcher = searcher
        self.streamResolver = streamResolver
        self.audioEngine = audioEngine
        self.stillAvailable = stillAvailable
        self.query = PlaybackSourceReplacementPolicy.query(for: original)
        self.startingRevision = store.revision(
            playlistID: original.playbackPlaylistID ?? "", originalID: original.id)
    }

    private var playlistID: String { original.playbackPlaylistID ?? "" }
    private var contextValid: Bool {
        isActive && stillAvailable()
        && store.revision(playlistID: playlistID, originalID: original.id) == startingRevision
    }

    private func invalidateSearch() {
        generation &+= 1
        searchTask?.cancel()
        searchTask = nil
        candidates = []
        isSearching = false
        errorMessage = nil
    }

    func search() async {
        invalidateSearch()
        endPreview(resumeOriginal: true)
        approvedCandidateID = nil
        approvedAsset = nil
        guard contextValid else { errorMessage = "歌單已變更，請重新開啟來源選擇。"; return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { errorMessage = "請輸入歌名或歌手。"; return }
        let requestGeneration = generation
        isSearching = true
        let task = Task { try await searcher(text) }
        searchTask = task
        do {
            let found = try await task.value
            try Task.checkCancellation()
            guard contextValid, generation == requestGeneration else { return }
            candidates = PlaylistSourceIdentityPolicy.candidates(
                found, original: original,
                excluding: [store.sourceID(for: original, legacy: legacySource)])
        } catch {
            guard contextValid, generation == requestGeneration else { return }
            errorMessage = "來源搜尋失敗，請稍後重試。"
        }
        if generation == requestGeneration {
            searchTask = nil
            isSearching = false
        }
    }

    func wasPreviewed(_ candidate: PlaybackSourceCandidate) -> Bool {
        previewedCandidateID == candidate.id && approvedAsset != nil
    }

    func preview(_ candidate: PlaybackSourceCandidate) async {
        guard contextValid, !isCommitting,
              candidates.contains(where: { $0.id == candidate.id && $0.song == candidate.song })
        else { return }
        endPreview(resumeOriginal: true)
        approvedCandidateID = nil
        approvedAsset = nil
        previewedCandidateID = nil
        errorMessage = nil
        isPreviewing = true
        let requestGeneration = generation
        let token = audioEngine.beginSourcePreview()
        previewToken = token
        audioEngine.sourcePreviewCancellation = { [weak self] in
            self?.endPreview(resumeOriginal: false)
            self?.approvedCandidateID = nil
            self?.approvedAsset = nil
        }
        do {
            let resolved = try await streamResolver(candidate.id)
            guard contextValid, generation == requestGeneration,
                  audioEngine.sourcePreviewIsCurrent(token), !Task.isCancelled,
                  let url = URL(string: resolved.url), url.scheme == "https",
                  let host = url.host, !host.isEmpty else { throw CancellationError() }
            var headers = audioEngine.streamHeaders
            // The user's cookies must never be sent to arbitrary hosts.
            if host == "youtube.com" || host.hasSuffix(".youtube.com")
                || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") {
                if let cookie = audioEngine.authCookieProvider?(), !cookie.isEmpty {
                    headers["Cookie"] = cookie
                }
            }
            let asset = AVURLAsset(url: url, options:
                headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
            guard try await asset.load(.isPlayable) else { throw CancellationError() }
            guard contextValid, generation == requestGeneration,
                  audioEngine.sourcePreviewIsCurrent(token), !Task.isCancelled else {
                throw CancellationError()
            }
            let audition = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            audition.automaticallyWaitsToMinimizeStalling = false
            auditionPlayer = audition
            audition.play()
            // Ready alone is insufficient; at least one second of actual
            // playback progression proves that audition can be heard.
            var advancing = false
            for _ in 0..<52 {
                try await Task.sleep(for: .milliseconds(250))
                guard contextValid, generation == requestGeneration,
                      audioEngine.sourcePreviewIsCurrent(token) else { throw CancellationError() }
                if audition.currentItem?.status == .failed { throw CancellationError() }
                if audition.currentTime().seconds.isFinite && audition.currentTime().seconds >= 1.0 {
                    advancing = true
                    break
                }
            }
            guard advancing else { throw CancellationError() }
            approvedCandidateID = candidate.id
            approvedAsset = asset
            previewedCandidateID = candidate.id
            isPreviewing = false
            previewStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.endPreview(resumeOriginal: true)
            }
        } catch {
            guard generation == requestGeneration, isActive else { return }
            endPreview(resumeOriginal: true)
            approvedCandidateID = nil
            approvedAsset = nil
            previewedCandidateID = nil
            errorMessage = "試聽無法播放，原來源保持不變。"
        }
    }

    @discardableResult
    func confirm(_ candidate: PlaybackSourceCandidate) async -> Bool {
        guard contextValid, !isCommitting,
              candidates.contains(where: { $0.id == candidate.id && $0.song == candidate.song }),
              approvedCandidateID == candidate.id, let asset = approvedAsset else {
            errorMessage = "請先試聽，確認歌曲可播放。"
            return false
        }
        isCommitting = true
        defer { isCommitting = false }
        previewStopTask?.cancel()
        previewStopTask = nil
        auditionPlayer?.pause()
        auditionPlayer = nil
        // A new selection token is used if playback was resumed when preview
        // reached its time limit. Never use a stale preview callback to commit.
        let currentIsTarget = audioEngine.currentTrack?.id == original.id
            && audioEngine.currentTrack?.playbackPlaylistID == playlistID
        let token: AudioEngine.SourcePreviewToken? = currentIsTarget
            ? (previewToken ?? audioEngine.beginSourcePreview()) : nil
        if !contextValid {
            errorMessage = "歌單來源已變更，請重新開啟。"
            endPreview(resumeOriginal: true)
            return false
        }
        let previous = store.record(playlistID: playlistID, originalID: original.id)
        do {
            let saved = try store.save(candidate: candidate.song, playlistID: playlistID,
                                       originalID: original.id, expectedRevision: startingRevision)
            audioEngine.invalidatePlaylistSource(playlistID: playlistID, originalID: original.id)
            if currentIsTarget, let token {
                let applied = await audioEngine.handoffPlaylistSource(
                    asset: asset, original: original, sourceID: candidate.id, token: token)
                if !applied {
                    try? store.rollback(previous: previous, playlistID: playlistID, originalID: original.id,
                                        fallbackSourceID: legacySource(original.id),
                                        expectedRevision: saved.revision)
                    audioEngine.invalidatePlaylistSource(playlistID: playlistID, originalID: original.id)
                    errorMessage = "切換播放器失敗，已嘗試恢復原來源。"
                    endPreview(resumeOriginal: true)
                    return false
                }
                previewToken = nil
                audioEngine.sourcePreviewCancellation = nil
            } else {
                endPreview(resumeOriginal: true)
            }
            didFinish = true
            isActive = false
            invalidateSearch()
            return true
        } catch {
            errorMessage = "來源保存失敗，原歌曲保持不變。"
            endPreview(resumeOriginal: true)
            return false
        }
    }

    private func endPreview(resumeOriginal: Bool) {
        previewStopTask?.cancel()
        previewStopTask = nil
        auditionPlayer?.pause()
        auditionPlayer = nil
        if let token = previewToken {
            previewToken = nil
            audioEngine.finishSourcePreview(token, resume: resumeOriginal)
        }
        isPreviewing = false
    }

    func cancel() {
        isActive = false
        invalidateSearch()
        endPreview(resumeOriginal: true)
    }
}
