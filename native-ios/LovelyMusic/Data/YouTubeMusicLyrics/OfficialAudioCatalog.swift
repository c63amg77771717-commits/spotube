import Foundation

/// In audio mode a fan upload or music video is played as YouTube Music's official
/// audio of the same song (an "ATV" track), whose timed lyrics fit the recording.
/// Playback and lyrics ask this one catalog, so both always use the same version.
/// Video mode, downloads and user-chosen sources keep the original video.
final class OfficialAudioCatalog: @unchecked Sendable {
    struct Match: Codable, Equatable, Sendable {
        let videoID: String
        let title: String
        let artist: String
        let duration: Int?
    }

    typealias Search = @Sendable (_ query: String) async throws -> [Match]

    static let shared = OfficialAudioCatalog(search: { try await YouTubeMusicLyricsService().searchSongs($0) })

    private enum Decision: Sendable { case match(Match), none }

    private let lock = NSLock()
    private let search: Search
    private let defaults: UserDefaults
    private let timeout: Duration
    private static let storeKey = "evantube_official_audio_matches_v1"
    private var enabled = true
    private var decisions: [String: Decision] = [:]
    private var saved: [String: Match]
    private var lookups: [String: Task<Void, Never>] = [:]
    /// Original IDs whose own file must play (a download or a legacy source choice).
    var keepsOriginal: @MainActor (_ songID: String) -> Bool = { _ in false }

    init(search: @escaping Search, defaults: UserDefaults = .standard, timeout: Duration = .seconds(3)) {
        self.search = search
        self.defaults = defaults
        self.timeout = timeout
        saved = defaults.data(forKey: Self.storeKey)
            .flatMap { try? JSONDecoder().decode([String: Match].self, from: $0) } ?? [:]
        decisions = saved.mapValues { .match($0) }
    }

    /// Off in video mode: the picture and the sound must be the same recording.
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    static func isEligible(_ song: Song) -> Bool {
        song.hasYouTubeOrigin && !song.isEpisode && song.musicVideoType != "MUSIC_VIDEO_TYPE_ATV"
            && !song.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The ID whose audio plays for `songID` right now (itself unless substituted).
    @MainActor
    func sourceID(for songID: String) -> String {
        guard !keepsOriginal(songID), let match = playingMatch(songID) else { return songID }
        return match.videoID
    }

    /// True while playback should wait for `prepare` before choosing a source.
    @MainActor
    func needsLookup(_ song: Song) -> Bool {
        guard Self.isEligible(song), !keepsOriginal(song.id) else { return false }
        return lock.withLock { enabled && decisions[song.id] == nil }
    }

    /// Finds the official audio once per song; gives up after `timeout` for this
    /// run of the app (a late answer is saved for next time).
    func prepare(_ song: Song) async {
        guard Self.isEligible(song) else { return }
        await lookup(id: song.id, title: song.title, duration: song.duration).value
    }

    /// The version lyrics must follow for `context`, waiting for a running lookup.
    func lyricsMatch(for context: LyricsLookupContext) async -> Match? {
        guard context.hasYouTubeOrigin, context.musicVideoType != "MUSIC_VIDEO_TYPE_ATV",
              let id = context.songID, isEnabled else { return nil }
        let keepsOriginal = self.keepsOriginal
        let keep = await MainActor.run { keepsOriginal(id) }
        guard !keep else { return nil }
        await lookup(id: id, title: context.title, duration: context.duration).value
        return playingMatch(id)
    }

    /// Playback of the official audio failed: use the original from now on.
    func reject(_ songID: String) {
        lock.withLock {
            decisions[songID] = Decision.none
            save(nil, for: songID)
        }
    }

    private func playingMatch(_ songID: String) -> Match? {
        lock.withLock {
            guard enabled, case .match(let match)? = decisions[songID], match.videoID != songID else { return nil }
            return match
        }
    }

    private func lookup(id: String, title: String, duration: Int?) -> Task<Void, Never> {
        lock.withLock {
            if let running = lookups[id] { return running }
            if decisions[id] != nil { return Task {} }
            let search = self.search
            let finder = Task { await Self.find(title: title, duration: duration, search: search) }
            let timeout = self.timeout
            let task = Task { [weak self] in
                // Whichever ends first: the search, or the timeout (nil). A task group
                // would wait for the search either way.
                let found: Decision? = await withCheckedContinuation { continuation in
                    let once = Once()
                    Task {
                        let match = await finder.value
                        if once.claim() { continuation.resume(returning: match.map(Decision.match) ?? Decision.none) }
                    }
                    Task {
                        try? await Task.sleep(for: timeout)
                        if once.claim() { continuation.resume(returning: nil) }
                    }
                }
                self?.finish(id: id, decision: found, finder: finder)
            }
            lookups[id] = task
            return task
        }
    }

    private func finish(id: String, decision: Decision?, finder: Task<Match?, Never>) {
        lock.withLock {
            lookups[id] = nil
            decisions[id] = decision ?? Decision.none
            if case .match(let match)? = decision { save(match, for: id) }
        }
        guard decision == nil else { return }
        // Timed out: this run keeps the original; a late match serves the next launch.
        Task { [weak self] in
            guard let match = await finder.value, let self else { return }
            self.lock.withLock { self.save(match, for: id) }
        }
    }

    /// Caller holds `lock`.
    private func save(_ match: Match?, for id: String) {
        saved[id] = match
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.storeKey)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    /// First YouTube Music song result that is this song (same title and artist,
    /// not a cover, live take or other version), trying up to three title guesses.
    static func find(title: String, duration: Int?, search: Search) async -> Match? {
        let titleHasArtist = !(YouTubeTitleParser.guesses(title).first?.artist.isEmpty ?? true)
        for query in YouTubeTitleParser.queries(title, limit: 3) {
            guard !Task.isCancelled else { return nil }
            let text = (query.song + " " + query.artist).trimmingCharacters(in: .whitespaces)
            guard let results = try? await search(text) else { continue }
            for result in results.prefix(5) {
                let record = YouTubeTitleParser.Record(title: result.title, artist: result.artist,
                                                       duration: result.duration.map(Double.init))
                if YouTubeTitleParser.isSameSong(record, guess: query, videoTitle: title, videoDuration: duration,
                                                 titleHasArtist: titleHasArtist) {
                    return result
                }
            }
        }
        return nil
    }
}
