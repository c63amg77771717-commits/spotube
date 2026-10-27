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
        await lookup(id: song.id, title: song.title, artist: song.artistName, duration: song.duration).value
    }

    /// The version lyrics must follow for `context`, waiting for a running lookup.
    func lyricsMatch(for context: LyricsLookupContext) async -> Match? {
        guard context.hasYouTubeOrigin, context.musicVideoType != "MUSIC_VIDEO_TYPE_ATV",
              let id = context.songID, isEnabled else { return nil }
        let keepsOriginal = self.keepsOriginal
        let keep = await MainActor.run { keepsOriginal(id) }
        guard !keep else { return nil }
        await lookup(id: id, title: context.title, artist: context.artist, duration: context.duration).value
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

    private func lookup(id: String, title: String, artist: String, duration: Int?) -> Task<Void, Never> {
        lock.withLock {
            if let running = lookups[id] { return running }
            if decisions[id] != nil { return Task {} }
            let search = self.search
            let finder = Task { await Self.findOutcome(title: title, artist: artist, duration: duration, search: search) }
            let timeout = self.timeout
            let task = Task { [weak self] in
                // Whichever ends first: the search, or the timeout (nil). A task group
                // would wait for the search either way.
                let found: Immediate? = await withCheckedContinuation { continuation in
                    let once = Once()
                    Task {
                        let outcome = await finder.value
                        let immediate: Immediate
                        switch outcome.kind {
                        case .match:
                            immediate = outcome.match.map(Immediate.match) ?? .none
                        case .none:
                            immediate = .none
                        case .unavailable:
                            immediate = .unavailable
                        }
                        if once.claim() { continuation.resume(returning: immediate) }
                    }
                    Task {
                        try? await Task.sleep(for: timeout)
                        if once.claim() { continuation.resume(returning: nil) }
                    }
                }
                self?.finish(id: id, immediate: found, finder: finder)
            }
            lookups[id] = task
            return task
        }
    }

    /// What the search finished with before the playback timeout.
    /// Nil means the timeout won: this run keeps the original video.
    private enum Immediate: Sendable {
        case match(Match)
        case none
        case unavailable
    }

    private func finish(id: String, immediate: Immediate?, finder: Task<FindOutcome, Never>) {
        lock.withLock {
            lookups[id] = nil
            switch immediate {
            case .some(.match(let match)):
                decisions[id] = .match(match)
                save(match, for: id)
            case .some(.none), .none:
                // A real miss, or a timeout, stays a miss for this run.
                decisions[id] = .none
            case .some(.unavailable):
                // The search never answered. Leave the song unset so the next play retries.
                decisions[id] = nil
            }
        }
        guard immediate == nil else { return }
        // Timed out: this run keeps the original. A late match is saved for next
        // launch. A transport failure is not remembered, so the next play retries.
        Task { [weak self] in
            let outcome = await finder.value
            guard let self else { return }
            self.lock.withLock {
                if let match = outcome.match { self.save(match, for: id) }
                if outcome.kind == .unavailable, case .none? = self.decisions[id] {
                    self.decisions[id] = nil
                }
            }
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

    private struct FindOutcome: Sendable {
        enum Kind: Sendable { case match, none, unavailable }
        var kind: Kind
        var match: Match?
    }

    /// First YouTube Music song result that is this song (same title and artist,
    /// not a cover, live take or other version), trying up to three title guesses.
    static func find(title: String, duration: Int?, search: Search) async -> Match? {
        await findOutcome(title: title, artist: "", duration: duration, search: search).match
    }

    private static func findOutcome(title: String, artist: String, duration: Int?, search: Search) async -> FindOutcome {
        let titleHasArtist = !(YouTubeTitleParser.guesses(title).first?.artist.isEmpty ?? true)
            || YouTubeTitleParser.isUsableArtist(artist)
        var sawResponse = false
        for query in YouTubeTitleParser.queries(title: title, artist: artist, limit: 4) {
            guard !Task.isCancelled else { return FindOutcome(kind: sawResponse ? .none : .unavailable, match: nil) }
            let text = (query.song + " " + query.artist).trimmingCharacters(in: .whitespaces)
            let results: [Match]
            do { results = try await search(text) }
            catch { continue }
            sawResponse = true
            for result in results.prefix(5) {
                let record = YouTubeTitleParser.Record(title: result.title, artist: result.artist,
                                                       duration: result.duration.map(Double.init))
                if YouTubeTitleParser.isSameSong(record, guess: query, videoTitle: title, videoDuration: duration,
                                                 titleHasArtist: titleHasArtist) {
                    return FindOutcome(kind: .match, match: result)
                }
            }
        }
        return FindOutcome(kind: sawResponse ? .none : .unavailable, match: nil)
    }
}
