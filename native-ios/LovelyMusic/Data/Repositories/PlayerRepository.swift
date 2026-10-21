import Foundation
import os

final class PlayerRepository: PlayerRepositoryProtocol, @unchecked Sendable {
    private let api: PlayerAPIClient
    private let decoder = JSONDecoder()
    private let videoQualityProvider: @Sendable () -> VideoQuality

    /// Single-flight caches: concurrent callers asking for the same `videoId`
    /// share one underlying `InnerTubeAPI` round-trip. Audio is keyed by id and
    /// effective quality, YouTube session and rejected-candidate version;
    /// video remains keyed by id. The separate caches keep a
    /// stuck video resolve from blocking audio for the same id.
    private struct AudioInflightKey: Hashable, Sendable {
        let videoID: String
        let quality: AudioQuality
        let sessionContext: PlayerSessionContext
        let candidateVersion: UInt64
    }

    private enum AudioCandidateClient: CaseIterable, Hashable, Sendable {
        case session, visionOS, ios, webRemix
    }

    private struct ResolvedAudioCandidate: Sendable {
        let descriptor: StreamDescriptor
        let client: AudioCandidateClient
    }

    private struct ObservedAudioCandidate {
        let url: String
        let client: AudioCandidateClient
        let observedAt: Date
    }

    private struct CandidateState {
        var version: UInt64
        var rejected: Set<AudioCandidateClient> = []
        // Keep only the newest descriptor for each quality. Old URLs cannot
        // blacklist a replacement descriptor, and the state stays bounded.
        var observed: [AudioQuality: ObservedAudioCandidate] = [:]
        var expiresAt: Date
        var lastAccess: Date
    }

    private struct CandidateSnapshot: Sendable {
        let version: UInt64
        let rejected: Set<AudioCandidateClient>
    }

    private let candidateLock = NSLock()
    private var candidateStates: [String: CandidateState] = [:]
    private var candidateSessionContext: PlayerSessionContext?
    private var candidateVersion: UInt64 = 0
    private let candidateClock: @Sendable () -> Date
    private static let candidateTTL: TimeInterval = 5 * 60
    private static let maximumCandidateVideos = 64

    private let audioInflight: InflightCache<AudioInflightKey, StreamDescriptor>
    private let videoInflight: InflightCache<
        String,
        (url: String, contentLength: Int64?)?
    >

    private static let maxAttempts = 3
    private static let backoffDelaysMs: [UInt64] = [0, 500, 1500]

    /// Internal sentinel: server explicitly declared the video unplayable
    /// (e.g., region-blocked, removed, private). Retrying the same client is
    /// pointless — caller should skip to next client immediately.
    private struct PlayabilityFailure: Error {
        let reason: String
    }

    init(
        api: PlayerAPIClient,
        videoQualityProvider: @escaping @Sendable () -> VideoQuality = { .auto },
        audioInflightDidJoin: InflightJoinObserver? = nil,
        videoInflightDidJoin: InflightJoinObserver? = nil,
        candidateClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.videoQualityProvider = videoQualityProvider
        self.candidateClock = candidateClock
        audioInflight = InflightCache(didJoin: audioInflightDidJoin)
        videoInflight = InflightCache(didJoin: videoInflightDidJoin)
    }

    @available(
        *,
        deprecated,
        message: "Use resolveStreamDescriptor(videoId:quality:requestHeaders:)"
    )
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        do {
            let descriptor = try await resolveStreamDescriptor(
                videoId: videoId,
                quality: .medium,
                requestHeaders: [:]
            )
            return (descriptor.remoteURL.absoluteString, descriptor.contentLength)
        } catch is StreamDescriptorError {
            // Preserve the legacy tuple contract for DownloadManager callers.
            // Typed validation errors remain available through the descriptor API.
            throw InnerTubeError.noStreamAvailable
        }
    }

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        let sessionContext = await api.playerSessionContext()
        guard let candidates = candidateSnapshot(videoId: videoId, sessionContext: sessionContext) else {
            throw CancellationError()
        }
        let key = AudioInflightKey(
            videoID: videoId, quality: quality, sessionContext: sessionContext,
            candidateVersion: candidates.version
        )
        let base = try await audioInflight.run(key) { [self] in
            let result = try await resolveStreamDescriptorUncached(
                videoId: videoId, quality: quality, rejected: candidates.rejected,
                sessionContext: sessionContext
            )
            guard await api.playerSessionContext() == sessionContext else { throw CancellationError() }
            recordPlaybackCandidate(
                result, videoId: videoId, quality: quality, version: candidates.version,
                sessionContext: sessionContext
            )
            return result.descriptor
        }
        // A shared task can complete just before logout. Never hand its old
        // authenticated URL to a caller after the session has changed.
        guard await api.playerSessionContext() == sessionContext else { throw CancellationError() }
        return base.withRequestHeaders(requestHeaders)
    }

    func reportPlaybackCandidateFailure(videoId: String, streamURL: String) {
        let now = candidateClock()
        candidateLock.lock()
        defer { candidateLock.unlock() }
        pruneCandidateStates(now: now)
        guard var state = candidateStates[videoId] else { return }
        let matchingClients = Set(state.observed.values.compactMap { candidate in
            candidate.url == streamURL && now.timeIntervalSince(candidate.observedAt) < Self.candidateTTL
                ? candidate.client : nil
        })
        guard matchingClients.count == 1, let client = matchingClients.first,
              state.rejected.insert(client).inserted else { return }
        state.version = nextCandidateVersion()
        // Late callbacks from the previous resolution generation are ignored.
        state.observed.removeAll()
        state.expiresAt = now.addingTimeInterval(Self.candidateTTL)
        state.lastAccess = now
        candidateStates[videoId] = state
    }

    func reportPlaybackCandidateSuccess(videoId: String, streamURL: String) {
        let now = candidateClock()
        candidateLock.lock()
        defer { candidateLock.unlock() }
        pruneCandidateStates(now: now)
        guard var state = candidateStates[videoId], !state.rejected.isEmpty else { return }
        let matching = state.observed.filter { _, candidate in
            candidate.url == streamURL && now.timeIntervalSince(candidate.observedAt) < Self.candidateTTL
        }
        guard !matching.isEmpty else { return }
        state.rejected.removeAll()
        state.version = nextCandidateVersion()
        state.observed = matching
        state.expiresAt = now.addingTimeInterval(Self.candidateTTL)
        state.lastAccess = now
        candidateStates[videoId] = state
    }

    private func candidateSnapshot(
        videoId: String, sessionContext: PlayerSessionContext
    ) -> CandidateSnapshot? {
        let now = candidateClock()
        candidateLock.lock()
        defer { candidateLock.unlock() }
        if candidateSessionContext != sessionContext {
            // An older suspended caller must not restore exclusions belonging
            // to the session it observed before another caller saw logout.
            if let current = candidateSessionContext,
               sessionContext.generation < current.generation { return nil }
            candidateSessionContext = sessionContext
            candidateStates.removeAll()
        }
        pruneCandidateStates(now: now)
        if var state = candidateStates[videoId] {
            state.lastAccess = now
            candidateStates[videoId] = state
            return CandidateSnapshot(version: state.version, rejected: state.rejected)
        }
        if candidateStates.count >= Self.maximumCandidateVideos,
           let oldest = candidateStates.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            candidateStates.removeValue(forKey: oldest)
        }
        let state = CandidateState(
            version: nextCandidateVersion(),
            expiresAt: now.addingTimeInterval(Self.candidateTTL), lastAccess: now
        )
        candidateStates[videoId] = state
        return CandidateSnapshot(version: state.version, rejected: [])
    }

    private func recordPlaybackCandidate(
        _ result: ResolvedAudioCandidate, videoId: String, quality: AudioQuality, version: UInt64,
        sessionContext: PlayerSessionContext
    ) {
        let now = candidateClock()
        candidateLock.lock()
        defer { candidateLock.unlock() }
        pruneCandidateStates(now: now)
        guard candidateSessionContext == sessionContext,
              var state = candidateStates[videoId], state.version == version else { return }
        state.observed[quality] = ObservedAudioCandidate(
            url: result.descriptor.remoteURL.absoluteString,
            client: result.client, observedAt: now
        )
        state.expiresAt = now.addingTimeInterval(Self.candidateTTL)
        state.lastAccess = now
        candidateStates[videoId] = state
    }

    // These helpers run only while candidateLock is held. URL provenance never
    // leaves this in-memory state and is not included in diagnostics or logs.
    private func nextCandidateVersion() -> UInt64 {
        candidateVersion &+= 1
        return candidateVersion
    }

    private func pruneCandidateStates(now: Date) {
        candidateStates = candidateStates.filter { $0.value.expiresAt > now }
    }

    private func resolveStreamDescriptorUncached(
        videoId: String,
        quality: AudioQuality,
        rejected: Set<AudioCandidateClient>,
        sessionContext: PlayerSessionContext
    ) async throws -> ResolvedAudioCandidate {
        guard rejected.count < AudioCandidateClient.allCases.count else {
            throw InnerTubeError.noStreamAvailable
        }
        // The user's own session may work without optional fallback client keys.
        // Do not block the signed-in native playback request before it can run.
        let cpn = generateCPN()
        return try await withTimeout(seconds: 45) { [self] in
            // Preserve the user's authenticated iOS source. Guests start with
            // public sources: an iOS 200 descriptor alone does not prove its
            // media is usable and must not hide an available full AAC source.
            let isAnonymous = !sessionContext.isAuthenticated
            var lastPlayabilityReason: String?
            var lastDescriptorError: StreamDescriptorError?
            var lastSessionFailure: InnerTubeError?
            // A clean unsigned install ships no private player API keys.
            // Google Drive OAuth is independent of the YouTube session and
            // must not disable public, anonymous music playback attempts.
            let needsPublicWebFallback = isAnonymous || (api is InnerTubeAPI
                && !SecretsProvider.hasPlayerSourceConfiguration)
            var pendingHLS: StreamDescriptor?

            // Start with this user's own iOS session. Preserve the exact HTTP
            // failure; a missing optional alternate-client key is not the cause.
            if !isAnonymous && !rejected.contains(.session) {
                do {
                    if let result = try await attemptClientWithRetries(
                        label: "IOS(session)", videoId: videoId, cpn: cpn, useSession: true,
                        quality: quality,
                        playabilityReason: &lastPlayabilityReason,
                        descriptorError: &lastDescriptorError
                    ) {
                        return ResolvedAudioCandidate(descriptor: result, client: .session)
                    }
                } catch let error as InnerTubeError {
                    switch error {
                    case .httpError, .sourceNotConfigured:
                        lastSessionFailure = error
                    default:
                        // Respect YouTube's explicit sign-in/verification rejection.
                        throw error
                    }
                }
            }

            // The VisionOS HLS DVR playlist can advertise only a ~69-second
            // live window for a much longer song. Prefer its full AAC adaptive
            // resource (if available) before considering HLS playback.
            if !rejected.contains(.visionOS) {
                do {
                    if let descriptor = try await extractHLSDescriptor(
                        videoId: videoId,
                        quality: quality
                    ) {
                        PlaybackDiagnostics.shared.record(.init(
                            phase: .streamResolved, client: .visionOS,
                            videoID: videoId,
                            hlsAvailable: descriptor.mimeType == "application/x-mpegURL"
                        ))
                        if needsPublicWebFallback &&
                            descriptor.mimeType == "application/x-mpegURL" {
                            // This may be a 69-second live DVR window. Keep it only
                            // as a last resort while we try the full public AAC source.
                            pendingHLS = descriptor
                        } else {
                            return ResolvedAudioCandidate(descriptor: descriptor, client: .visionOS)
                        }
                    }
                } catch let failure as PlayabilityFailure {
                    if Self.isExplicitAuthenticationFailure(failure.reason) {
                        throw InnerTubeError.videoUnavailable(reason: failure.reason)
                    }
                    // A definitive VisionOS content result beats an earlier
                    // transport-level IOS HTTP 400.
                    lastPlayabilityReason = failure.reason
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One unavailable client must not prevent the public web
                    // fallback from being attempted on a signed-out device.
                    Log.player.warning("VisionOS source unavailable; trying other public sources")
                }
            }

            if needsPublicWebFallback {
                // Use the same runtime public WEB_REMIX configuration as
                // anonymous search. No Google Drive OAuth credentials or
                // hardcoded private keys are used for this player request.
                if !rejected.contains(.webRemix), let result = try await attemptClientWithRetries(
                    label: "WEB_REMIX(public)", videoId: videoId,
                    cpn: cpn, client: .webRemix, quality: quality,
                    playabilityReason: &lastPlayabilityReason,
                    descriptorError: &lastDescriptorError
                ) {
                    return ResolvedAudioCandidate(descriptor: result, client: .webRemix)
                }
                // Keep guest iOS only as a final compatibility candidate after
                // both public sources have been tried. It shares the same
                // bounded rejection history and never supersedes their AAC.
                if isAnonymous && !rejected.contains(.session) {
                    do {
                        if let result = try await attemptClientWithRetries(
                            label: "IOS(guest)", videoId: videoId, cpn: cpn, useSession: true,
                            quality: quality,
                            playabilityReason: &lastPlayabilityReason,
                            descriptorError: &lastDescriptorError
                        ) {
                            return ResolvedAudioCandidate(descriptor: result, client: .session)
                        }
                    } catch let error as InnerTubeError {
                        switch error {
                        case .httpError, .sourceNotConfigured:
                            lastSessionFailure = error
                        default:
                            throw error
                        }
                    }
                }
                // Preserve the Build31-34 HLS duration check if no complete
                // source is available: never claim a short DVR window is full.
                if let pendingHLS {
                    return ResolvedAudioCandidate(descriptor: pendingHLS, client: .visionOS)
                }
                if let reason = lastPlayabilityReason {
                    throw InnerTubeError.videoUnavailable(reason: reason)
                }
                if let lastDescriptorError { throw lastDescriptorError }
                if let lastSessionFailure { throw lastSessionFailure }
                throw InnerTubeError.noStreamAvailable
            }

            // Reset session before trying fallback clients
            if !rejected.contains(.ios) || !rejected.contains(.webRemix) {
                Log.player.info("Primary client failed, resetting session for fallback chain")
                await api.resetSession()
            }

            // Fallback 1: IOS client
            if !rejected.contains(.ios), let result = try await attemptClientWithRetries(
                label: "IOS", videoId: videoId, cpn: cpn, client: .ios,
                quality: quality,
                playabilityReason: &lastPlayabilityReason,
                descriptorError: &lastDescriptorError
            ) {
                return ResolvedAudioCandidate(descriptor: result, client: .ios)
            }

            // Fallback 2: WEB_REMIX client
            if !rejected.contains(.webRemix), let result = try await attemptClientWithRetries(
                label: "WEB_REMIX", videoId: videoId, cpn: cpn, client: .webRemix,
                quality: quality,
                playabilityReason: &lastPlayabilityReason,
                descriptorError: &lastDescriptorError
            ) {
                return ResolvedAudioCandidate(descriptor: result, client: .webRemix)
            }

            Log.player.error("All player clients exhausted")
            #if DEBUG
            print("🔴 [PlayerRepo] All clients exhausted — playabilityReason=\(lastPlayabilityReason ?? "nil") descriptorError=\(String(describing: lastDescriptorError))")
            #endif
            // If at least one client gave us a definitive playability failure,
            // treat the video as permanently unavailable. Otherwise it was a
            // transient network failure and a future retry might succeed.
            if let reason = lastPlayabilityReason {
                throw InnerTubeError.videoUnavailable(reason: reason)
            }
            if let lastDescriptorError {
                throw lastDescriptorError
            }
            if let lastSessionFailure { throw lastSessionFailure }
            throw InnerTubeError.noStreamAvailable
        }
    }

    /// Attempts to resolve a stream URL using a specific client with retry logic.
    /// Returns the result on success, or `nil` if this client should be skipped
    /// (allowing the caller to try the next client in the fallback chain).
    /// `playabilityReason` is set when the server explicitly declared the
    /// video unplayable — this short-circuits same-client retries (the result
    /// will not change) and lets the top-level resolver throw a permanent error.
    private func attemptClientWithRetries(
        label: String,
        videoId: String,
        cpn: String,
        useSession: Bool = false,
        client: YouTubeClient? = nil,
        quality: AudioQuality,
        playabilityReason: inout String?,
        descriptorError: inout StreamDescriptorError?
    ) async throws -> StreamDescriptor? {
        for attempt in 0..<(useSession ? 1 : Self.maxAttempts) {
            if attempt > 0 {
                let delayMs = Self.backoffDelaysMs[attempt]
                Log.player.debug(
                    "[\(label, privacy: .public)] Backoff: waiting \(delayMs)ms before attempt \(attempt + 1)"
                )
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }

            do {
                let result: StreamDescriptor?
                if useSession {
                    result = try await attemptPlayerWithSession(
                        videoId: videoId,
                        cpn: cpn,
                        quality: quality
                    )
                } else if let client {
                    result = try await attemptPlayer(
                        client: client,
                        videoId: videoId,
                        cpn: cpn,
                        quality: quality
                    )
                } else {
                    return nil
                }
                if let result {
                    PlaybackDiagnostics.shared.record(.init(phase: .streamResolved,
                        client: useSession ? .iosSession : client?.clientName == "WEB_REMIX" ? .webRemix : .ios,
                        videoID: videoId, hlsAvailable: result.mimeType == "application/x-mpegURL"))
                    Log.player.info(
                        "[\(label, privacy: .public)] Stream resolved on attempt \(attempt + 1)")
                    return result
                }
            } catch let failure as PlayabilityFailure {
                // YouTube is explicitly asking for sign-in or human verification.
                // Switching client identities cannot complete that verification;
                // do not retry it on multiple unofficial client endpoints.
                if Self.isExplicitAuthenticationFailure(failure.reason) {
                    throw InnerTubeError.videoUnavailable(reason: failure.reason)
                }
                // Other video-specific failures can still fall through the
                // existing bounded candidate handling.
                playabilityReason = failure.reason
                Log.player.warning(
                    "[\(label, privacy: .public)] Playability not OK: \(failure.reason, privacy: .public) — skipping to next client"
                )
                return nil
            } catch let error as StreamDescriptorError {
                descriptorError = error
                Log.player.warning(
                    "[\(label, privacy: .public)] Descriptor validation failed on attempt \(attempt + 1)"
                )
            } catch let error as InnerTubeError {
                if case .sourceNotConfigured = error {
                    if !SecretsProvider.hasPlayerSourceConfiguration, playabilityReason == nil { throw error }
                    return nil
                }
                if case .httpError(let code) = error {
                    // Preserve the authenticated native response for the
                    // resolver to decide whether a legitimate HLS stream works.
                    if useSession { throw error }
                    if code == 429 {
                        Log.player.warning(
                            "[\(label, privacy: .public)] Rate limited (429), retrying with backoff"
                        )
                        continue
                    }
                    if code == 403 {
                        Log.player.warning(
                            "[\(label, privacy: .public)] Forbidden (403), skipping to next client")
                        return nil
                    }
                }
                Log.player.warning(
                    "[\(label, privacy: .public)] Attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)"
                )
                #if DEBUG
                print("⚠️ [PlayerRepo] [\(label)] attempt \(attempt+1) InnerTubeError: \(error)")
                #endif
            } catch {
                Log.player.warning(
                    "[\(label, privacy: .public)] Attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)"
                )
                #if DEBUG
                print("⚠️ [PlayerRepo] [\(label)] attempt \(attempt+1) error \(type(of: error)): \(error)")
                #endif
            }
        }

        Log.player.warning(
            "[\(label, privacy: .public)] All \(Self.maxAttempts) attempts exhausted")
        return nil
    }

    private static func isExplicitAuthenticationFailure(_ reason: String) -> Bool {
        let lowerReason = reason.lowercased()
        return lowerReason.contains("login_required") || lowerReason.contains("not a bot")
            || lowerReason.contains("不是機器人") || lowerReason.contains("不是机器人")
            || lowerReason.contains("verificationrequired")
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T)
        async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw InnerTubeError.timeout
            }
            let result = try await group.next() ?? { throw InnerTubeError.timeout }()
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private

    private func attemptPlayerWithSession(
        videoId: String,
        cpn: String,
        quality: AudioQuality
    ) async throws -> StreamDescriptor? {
        let data = try await api.playerWithSession(videoId: videoId)
        return try extractStreamDescriptor(
            from: data,
            label: "ANDROID_VR(session)",
            videoId: videoId,
            quality: quality
        )
    }

    private func attemptPlayer(
        client: YouTubeClient,
        videoId: String,
        cpn: String,
        quality: AudioQuality
    ) async throws -> StreamDescriptor? {
        Log.player.info("Trying fallback client: \(client.clientName, privacy: .public)")
        let data = try await api.player(client: client, videoId: videoId)
        return try extractStreamDescriptor(
            from: data,
            label: client.clientName,
            videoId: videoId,
            quality: quality
        )
    }

    func resolveVideoStreamURL(videoId: String) async throws -> (
        url: String, contentLength: Int64?
    )? {
        try await videoInflight.run(videoId) { [self] in
            // ANDROID_VR blocked since Aug 2026. Use VISIONOS hlsManifestUrl —
            // the HLS variant manifest contains both audio and video tracks;
            // VideoPlaybackManager mutes via isMuted=true so no double-audio.
            let data = try await api.playerWithVisionOS(videoId: videoId)
            guard let response = try? decoder.decode(PlayerResponse.self, from: data),
                  response.playabilityStatus?.status == "OK",
                  let hlsURL = response.streamingData?.hlsManifestUrl
            else {
                return nil
            }
            Log.player.info("[VISIONOS] Video HLS resolved for \(videoId, privacy: .public)")
            return (url: hlsURL, contentLength: nil)
        }
    }

    /// Decodes player response and extracts the best audio URL.
    /// Returns `nil` if no compatible audio format was found (transient — try next client).
    /// Throws `PlayabilityFailure` if the server marked the video unplayable
    /// (permanent — caller skips remaining attempts on the same client).
    /// Throws on decode/HTTP errors.
    private func extractStreamDescriptor(
        from data: Data,
        label: String,
        videoId: String,
        quality: AudioQuality
    ) throws -> StreamDescriptor? {
        let response = try decoder.decode(PlayerResponse.self, from: data)

        guard response.playabilityStatus?.status == "OK" else {
            let status = response.playabilityStatus?.status ?? "UNKNOWN"
            let reason = response.playabilityStatus?.reason ?? ""
            // Retain the machine-readable status when YouTube omits or localizes its reason.
            // This prevents service-wide LOGIN_REQUIRED from being treated as an unknown song error.
            throw PlayabilityFailure(reason: reason.isEmpty ? status : "\(status): \(reason)")
        }

        let streamingData = StreamingDataMapper.map(response.streamingData)
        guard let bestFormat = streamingData.bestAudioFormat(
            quality: quality,
            candidateIsPlayable: { format in
                (try? StreamDescriptorResolver.resolve(
                    videoID: videoId,
                    format: format,
                    expiresAt: streamingData.expiresAt,
                    requestHeaders: [:]
                )) != nil
            }
        ) else {
            let availableMimes =
                (response.streamingData?.adaptiveFormats?.compactMap { $0.mimeType } ?? [])
                .description
            Log.player.warning(
                "[\(label, privacy: .public)] No compatible audio format. Available: \(availableMimes, privacy: .public)"
            )
            return nil
        }

        Log.player.info(
            "[\(label, privacy: .public)] Selected: itag=\(bestFormat.itag) mime=\(bestFormat.mimeType, privacy: .public) bitrate=\(bestFormat.bitrate ?? 0)"
        )
        return try StreamDescriptorResolver.resolve(
            videoID: videoId,
            format: bestFormat,
            expiresAt: streamingData.expiresAt,
            requestHeaders: [:]
        )
    }

    private func extractVideoStreamURL(from data: Data, label: String, videoId: String) throws -> (
        url: String, contentLength: Int64?
    )? {
        let response = try decoder.decode(PlayerResponse.self, from: data)
        guard response.playabilityStatus?.status == "OK" else { return nil }
        let streamingData = StreamingDataMapper.map(response.streamingData)
        let quality = videoQualityProvider()
        guard let videoFormat = streamingData.bestVideoFormat(quality: quality), let url = videoFormat.url else {
            let formatsCount = response.streamingData?.formats?.count ?? 0
            let adaptiveVideoCount =
                response.streamingData?.adaptiveFormats?.compactMap { $0.mimeType }.filter {
                    $0.hasPrefix("video/")
                }.count ?? 0
            Log.player.warning(
                "[\(label, privacy: .public)] No video format available. Formats: \(formatsCount), Adaptive: \(adaptiveVideoCount)"
            )
            return nil
        }
        let contentLength = videoFormat.contentLength.flatMap { Int64($0) }
        Log.player.info(
            "[\(label, privacy: .public)] Video selected: itag=\(videoFormat.itag) mime=\(videoFormat.mimeType, privacy: .public) \(videoFormat.width ?? 0)x\(videoFormat.height ?? 0)"
        )
        return (url, contentLength)
    }

    private func generateCPN() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        return String((0..<16).compactMap { _ in chars.randomElement() }.prefix(16))
    }

    /// Prefer the full adaptive AAC asset. Only fall back to HLS when no
    /// validated AAC URL exists; HLS durations are checked by AudioEngine.
    private func extractHLSDescriptor(
        videoId: String,
        quality: AudioQuality
    ) async throws -> StreamDescriptor? {
        let data = try await api.playerWithVisionOS(videoId: videoId)
        let response = try decoder.decode(PlayerResponse.self, from: data)
        let status = response.playabilityStatus?.status ?? "UNKNOWN"
        if status != "OK" {
            let reason = response.playabilityStatus?.reason ?? ""
            throw PlayabilityFailure(reason: reason.isEmpty ? status : "\(status): \(reason)")
        }

        let mapped = StreamingDataMapper.map(response.streamingData)
        let format = mapped.bestAudioFormat(
            quality: quality,
            candidateIsPlayable: { candidate in
                StreamMIMEBaseSyntax.normalizedBase(candidate.mimeType) == "audio/mp4"
                && (try? StreamDescriptorResolver.resolve(
                    videoID: videoId, format: candidate,
                    expiresAt: mapped.expiresAt, requestHeaders: [:]
                )) != nil
            }
        )
        if let format,
           StreamMIMEBaseSyntax.normalizedBase(format.mimeType) == "audio/mp4",
           let fullAudio = try? StreamDescriptorResolver.resolve(
               videoID: videoId, format: format,
               expiresAt: mapped.expiresAt, requestHeaders: [:]
           ) {
            Log.player.info(
                "[VISIONOS] Full AAC selected, itag=\(fullAudio.itag) totalBytes=\(fullAudio.contentLength ?? 0)"
            )
            return fullAudio
        }

        guard let hlsString = response.streamingData?.hlsManifestUrl,
              let hlsURL = URL(string: hlsString),
              hlsURL.scheme?.lowercased() == "https",
              hlsURL.host?.isEmpty == false else {
            return nil
        }
        return StreamDescriptor(
            videoID: videoId,
            remoteURL: hlsURL,
            itag: 0,
            mimeType: "application/x-mpegURL",
            codec: "hls",
            bitrate: 0,
            contentLength: nil,
            duration: nil,
            initializationRange: nil,
            indexRange: nil,
            expiresAt: nil,
            requestHeaders: [:],
            provisionalResourceKey: ProvisionalResourceKey(
                videoID: videoId, itag: 0, codec: "hls", declaredTotalLength: nil)
        )
    }
}
