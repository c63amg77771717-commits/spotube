import Foundation

/// Finds lyrics by parsing the YouTube title (YouTubeTitleParser) and searching
/// NetEase Cloud Music and LRCLIB, both public and login-free. A timeline is used
/// when the recording is within 2 s of the video; otherwise its text is plain.
/// On 120 random playlist songs: 40% aligned timelines, 91% with lyrics, when
/// combined with YouTube Music (2026-10-26).
final class TitleMatchedLyricsService: LyricsRepositoryProtocol {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let fetch: Fetch
    // Bounds network use per song. Each guess is one NetEase search (two when
    // traditional and simplified differ) and the same for LRCLIB, plus at most
    // one lyric download once a record matches.
    private static let maxQueries = 5

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    convenience init(session: URLSession? = nil) {
        let session = session ?? LyricsTransportPolicy.makeSession()
        self.init(fetch: { request in
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw PublicSourceError.http(request.url?.host ?? "lyrics", status) }
            guard data.count <= 2 * 1024 * 1024 else { throw PublicSourceError.invalidResponse(request.url?.host ?? "lyrics") }
            return data
        })
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try await lookup(context: context).legacyValue()
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(context: .init(title: title, artist: artist, duration: duration))
    }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        let guesses = context.hasYouTubeOrigin
            ? YouTubeTitleParser.queries(title: context.title, artist: context.artist, limit: Self.maxQueries)
            : [.init(artist: context.artist, song: context.title)]
        guard let first = guesses.first else { return .metadataRejected(provider: .netease) }
        let queries = guesses
        var plain: SyncedLyrics?
        var failures: [LyricsSourceFailure] = []
        var responses = 0
        // Metadata artist is an extra guess. It must not disable the duration
        // check used when the YouTube title itself names no performer.
        let titleHasArtist = context.hasYouTubeOrigin
            ? !(YouTubeTitleParser.guesses(context.title).first?.artist.isEmpty ?? true)
            : !first.artist.isEmpty
        for guess in queries.prefix(Self.maxQueries) {
            try Task.checkCancellation()
            // NetEase and LRCLIB are queried at the same time; NetEase wins ties.
            async let netease = attempt(.netease, guess: guess, context: context, titleHasArtist: titleHasArtist)
            async let lrclib = attempt(.lrclib, guess: guess, context: context, titleHasArtist: titleHasArtist)
            for (provider, result) in [(LyricsProviderID.netease, await netease), (.lrclib, await lrclib)] {
                switch result {
                case .success(let lyrics):
                    responses += 1
                    guard let lyrics else { continue }
                    if lyrics.isTimeSynced {
                        return .provider(provider, lyrics: lyrics, received: 1, successfulResponses: responses, failures: failures)
                    }
                    plain = plain ?? lyrics
                case .failure(let error):
                    try LyricsMatchingPolicy.checkCancellation(error)
                    failures += LyricsSourceFailure.from(error, providerID: provider)
                }
            }
            // A plain hit must not skip later guesses that still have a timeline.
        }
        return .provider(plain?.providerID ?? .netease, lyrics: plain, received: plain == nil ? 0 : 1,
                         successfulResponses: responses, failures: failures)
    }

    private func attempt(_ provider: LyricsProviderID, guess: YouTubeTitleParser.Guess,
                         context: LyricsLookupContext, titleHasArtist: Bool) async -> Result<SyncedLyrics?, Error> {
        do { return .success(try await lyrics(provider, guess: guess, context: context, titleHasArtist: titleHasArtist)) }
        catch { return .failure(error) }
    }

    private func lyrics(_ provider: LyricsProviderID, guess: YouTubeTitleParser.Guess,
                        context: LyricsLookupContext, titleHasArtist: Bool) async throws -> SyncedLyrics? {
        switch provider {
        case .netease:
            let raw = [guess.song, guess.artist].filter { !$0.isEmpty }.joined(separator: " ")
            var songs: [NetEaseSong] = []
            for form in YouTubeTitleParser.searchForms(raw).prefix(2) {
                songs.append(contentsOf: try Self.neteaseSongs(from: try await fetch(Self.neteaseSearch(query: form))))
                if YouTubeTitleParser.bestMatch(songs.map(\.record), guess: guess, videoTitle: context.title,
                                                videoDuration: context.duration, titleHasArtist: titleHasArtist) != nil {
                    break
                }
            }
            guard let match = YouTubeTitleParser.bestMatch(songs.map(\.record), guess: guess, videoTitle: context.title,
                                                           videoDuration: context.duration, titleHasArtist: titleHasArtist),
                  let song = songs.first(where: { $0.record.title == match.title && $0.record.artist == match.artist
                                                  && $0.record.duration == match.duration }),
                  let lrc = try Self.neteaseLRC(from: try await fetch(Self.neteaseLyric(song.id)))
            else { return Self.recordMiss(context, .netease, guess) }
            return Self.recorded(Self.lyrics(lrc: lrc, plain: nil, recording: match.duration, context: context, provider: .netease),
                                 context, .netease, match)
        default:
            var records = try Self.lrclibRecords(from: try await fetch(Self.lrclibSearch(guess)))
            let simplifiedGuess = YouTubeTitleParser.Guess(artist: YouTubeTitleParser.simplified(guess.artist),
                                                           song: YouTubeTitleParser.simplified(guess.song))
            if records.isEmpty || YouTubeTitleParser.bestMatch(records.map(\.record), guess: guess, videoTitle: context.title,
                                                               videoDuration: context.duration, titleHasArtist: titleHasArtist) == nil,
               simplifiedGuess != guess {
                records.append(contentsOf: try Self.lrclibRecords(from: try await fetch(Self.lrclibSearch(simplifiedGuess))))
            }
            guard let match = YouTubeTitleParser.bestMatch(records.map(\.record), guess: guess, videoTitle: context.title,
                                                           videoDuration: context.duration, titleHasArtist: titleHasArtist),
                  let record = records.first(where: { $0.record.title == match.title && $0.record.artist == match.artist
                                                      && $0.record.duration == match.duration })
            else { return Self.recordMiss(context, .lrclib, guess) }
            return Self.recorded(Self.lyrics(lrc: record.synced ?? "", plain: record.plain, recording: match.duration,
                                             context: context, provider: .lrclib), context, .lrclib, match)
        }
    }

    /// Diagnostics export: which record matched, its length, and whether its timeline was used.
    private static func recorded(_ lyrics: SyncedLyrics?, _ context: LyricsLookupContext, _ provider: LyricsProviderID,
                                 _ match: YouTubeTitleParser.Record) -> SyncedLyrics? {
        let reason: LyricsLookupDiagnostics.Reason
        switch lyrics?.timingState {
        case .structurallyCompatible?: reason = .timingCompatible
        case .durationMismatch?: reason = .durationMismatch
        case .timingUnknown?: reason = .timingUnknown
        case .plainOnly?: reason = .plainOnly
        case .invalidTimestamp?: reason = .invalidTimestamp
        case .unsupportedTiming?: reason = .unsupportedTiming
        case nil: reason = .emptyContent
        }
        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: provider, phase: .candidateAccepted,
            reason: reason, title: match.title, artist: match.artist, duration: match.duration))
        return lyrics
    }

    private static func recordMiss(_ context: LyricsLookupContext, _ provider: LyricsProviderID,
                                   _ guess: YouTubeTitleParser.Guess) -> SyncedLyrics? {
        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: provider, phase: .providerEmpty,
            reason: .providerEmpty, title: guess.song, artist: guess.artist))
        return nil
    }

    /// Timelines within 8 s of the video stay timed and start-aligned. YouTube
    /// lengths are whole seconds; rewriting the recording length onto the video
    /// used to mark a 2 s-different take as compatible without moving cues.
    /// Larger gaps stay plain so a different recording is not presented as synced.
    static func lyrics(lrc: String, plain: String?, recording: Double?, context: LyricsLookupContext,
                       provider: LyricsProviderID) -> SyncedLyrics? {
        let cleaned = withoutCredits(lrc)
        let parsed = LyricsMatchingPolicy.parseLRCResult(cleaned)
        let video = context.duration
        let delta = recording.flatMap { rec in video.map { abs(rec - Double($0)) } }
        let cuesFit = parsed.lines.allSatisfy { line in
            guard let video else { return line.time.isFinite && line.time >= 0 }
            let slack = (delta ?? 0) + 1
            return line.time.isFinite && line.time >= 0 && line.time <= Double(video) + slack
        }
        if parsed.invalidTimestampCount == 0, parsed.untimedContentCount == 0, !parsed.unsupportedOffset,
           !parsed.lines.isEmpty, cuesFit, delta.map({ $0 <= 8 }) == true {
            return SyncedLyrics(lines: parsed.lines, source: provider.displayName, providerID: provider,
                                timelineDuration: recording)
        }
        return LyricsMatchingPolicy.lyrics(syncedLRC: cleaned, plainText: plain.map(withoutCredits),
                                           recordingDuration: recording, videoDuration: video, provider: provider)
    }

    /// NetEase LRC opens with timed credit lines such as `[00:02.03] 制作人 : 梁翘柏`.
    static func withoutCredits(_ lrc: String) -> String {
        let credit = #"^\s*(?:\[[0-9:.]+\]\s*)*(?:作词|作詞|作曲|编曲|編曲|制作人|製作人|监制|監製|和声|和聲|混音|母带|母帶|录音|錄音|吉他|贝斯|貝斯|鼓|弦乐|弦樂|出品|发行|發行|OP|SP|词|詞|曲)\s*[:：]"#
        return lrc.components(separatedBy: .newlines)
            .filter { $0.range(of: credit, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    // MARK: NetEase

    struct NetEaseSong {
        let id: Int
        let record: YouTubeTitleParser.Record
    }

    static func neteaseSearch(_ guess: YouTubeTitleParser.Guess) -> URLRequest {
        let raw = [guess.song, guess.artist].filter { !$0.isEmpty }.joined(separator: " ")
        return neteaseSearch(query: YouTubeTitleParser.searchForms(raw).first ?? raw)
    }

    static func neteaseSearch(query: String) -> URLRequest {
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [.init(name: "s", value: query), .init(name: "type", value: "1"),
                                 .init(name: "limit", value: "10")]
        return request(components.url!, referer: "https://music.163.com/")
    }

    static func neteaseLyric(_ id: Int) -> URLRequest {
        request(URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1")!, referer: "https://music.163.com/")
    }

    static func neteaseSongs(from data: Data) throws -> [NetEaseSong] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let songs = ((object as? [String: Any])?["result"] as? [String: Any])?["songs"] as? [[String: Any]] else {
            return []
        }
        return songs.prefix(10).compactMap { song in
            guard let id = song["id"] as? Int, let title = song["name"] as? String else { return nil }
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard !artists.isEmpty else { return nil }
            let milliseconds = (song["duration"] as? Double) ?? (song["duration"] as? Int).map(Double.init)
            return NetEaseSong(id: id, record: .init(title: title, artist: artists.joined(separator: "/"),
                                                     duration: milliseconds.map { $0 / 1000 }))
        }
    }

    static func neteaseLRC(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (object?["lrc"] as? [String: Any])?["lyric"] as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    // MARK: LRCLIB

    struct LrcLibRecord {
        let record: YouTubeTitleParser.Record
        let synced: String?
        let plain: String?
    }

    static func lrclibSearch(_ guess: YouTubeTitleParser.Guess) -> URLRequest {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [.init(name: "track_name", value: guess.song)]
            + (guess.artist.isEmpty ? [] : [.init(name: "artist_name", value: guess.artist)])
        return request(components.url!, referer: nil)
    }

    static func lrclibRecords(from data: Data) throws -> [LrcLibRecord] {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return records.prefix(20).compactMap { record in
            guard let title = record["trackName"] as? String, let artist = record["artistName"] as? String,
                  (record["instrumental"] as? Bool) != true else { return nil }
            let synced = (record["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let plain = (record["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard synced != nil || plain != nil else { return nil }
            return LrcLibRecord(record: .init(title: title, artist: artist, duration: record["duration"] as? Double),
                                synced: synced, plain: plain)
        }
    }

    private static func request(_ url: URL, referer: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpShouldHandleCookies = false
        // NetEase expects a browser; LRCLIB asks clients to identify themselves.
        request.setValue(referer != nil ? YouTubeClient.userAgentWeb
                         : "EvanTube/1.0 (https://github.com/c63amg77771717-commits/spotube)",
                         forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return request
    }
}
