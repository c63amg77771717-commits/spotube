import Foundation

/// The official lyrics YouTube Music shows for one exact video (LyricFind or
/// Musixmatch), found by video ID rather than guessed from a YouTube title.
/// Timed lines come from the Android Music client and are aligned to that video;
/// many music videos only have untimed text.
struct YouTubeMusicLyricsService: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let webRemixUserAgent = YouTubeClient.userAgentWeb
    private static let androidMusicVersion = "7.27.52"
    private static let androidMusicUserAgent =
        "com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip"

    func lyrics(videoID: String) async throws -> SyncedLyrics? {
        let next = try await request("next", body: ["videoId": videoID], android: false)
        guard let browseID = Self.strings(forKey: "browseId", in: next).first(where: { $0.hasPrefix("MPLY") })
        else { return nil }
        let timed = try? await request("browse", body: ["browseId": browseID], android: true)
        if let timed, let lines = Self.timedLines(timed), !lines.isEmpty {
            return SyncedLyrics(lines: lines, source: "YouTube Music", providerID: .youtubeMusic)
        }
        let plain = try await request("browse", body: ["browseId": browseID], android: false)
        guard let text = Self.plainText(plain) else { return nil }
        let lines = text.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let source = text.attribution.map { "YouTube Music · " + $0 } ?? "YouTube Music"
        return SyncedLyrics(lines: lines.map { LyricLine(time: 0, text: $0) }, source: source,
                            isTimeSynced: false, providerID: .youtubeMusic, timingState: .plainOnly)
    }

    /// Lines only count as timed when every one carries a cue; otherwise nil.
    static func timedLines(_ response: Any) -> [LyricLine]? {
        guard let cues = values(forKey: "timedLyricsData", in: response).first as? [[String: Any]],
              !cues.isEmpty else { return nil }
        var lines: [LyricLine] = []
        for cue in cues {
            guard let text = cue["lyricLine"] as? String,
                  let range = cue["cueRange"] as? [String: Any],
                  let start = (range["startTimeMilliseconds"] as? String).flatMap(Double.init)
                    ?? (range["startTimeMilliseconds"] as? Double),
                  start.isFinite, start >= 0
            else { return nil }
            lines.append(LyricLine(time: start / 1000, text: text))
        }
        return lines
    }

    static func plainText(_ response: Any) -> (text: String, attribution: String?)? {
        guard let shelf = values(forKey: "musicDescriptionShelfRenderer", in: response).first as? [String: Any],
              let runs = (shelf["description"] as? [String: Any])?["runs"] as? [[String: Any]]
        else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let footer = ((shelf["footer"] as? [String: Any])?["runs"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined()
        // "來源：LyricFind" / "Source: Musixmatch" → the provider name.
        let attribution = footer?.components(separatedBy: CharacterSet(charactersIn: ":：")).last?
            .trimmingCharacters(in: .whitespaces)
        return (text, attribution?.isEmpty == false ? attribution : nil)
    }

    private func request(_ endpoint: String, body: [String: Any], android: Bool) async throws -> Any {
        let client: [String: Any] = android
            ? ["clientName": "ANDROID_MUSIC", "clientVersion": Self.androidMusicVersion, "androidSdkVersion": 34,
               "hl": "zh-TW", "gl": "TW"]
            : ["clientName": "WEB_REMIX", "clientVersion": YouTubeClient.webRemix.clientVersion,
               "hl": "zh-TW", "gl": "TW"]
        var payload = body
        payload["context"] = ["client": client]
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(android ? Self.androidMusicUserAgent : Self.webRemixUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(android ? "21" : "67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(android ? Self.androidMusicVersion : YouTubeClient.webRemix.clientVersion,
                         forHTTPHeaderField: "X-Youtube-Client-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func values(forKey key: String, in object: Any) -> [Any] {
        if let dictionary = object as? [String: Any] {
            return dictionary.flatMap { entry -> [Any] in
                (entry.key == key ? [entry.value] : []) + values(forKey: key, in: entry.value)
            }
        }
        if let array = object as? [Any] {
            return array.flatMap { values(forKey: key, in: $0) }
        }
        return []
    }

    static func strings(forKey key: String, in object: Any) -> [String] {
        values(forKey: key, in: object).compactMap { $0 as? String }
    }
}

/// YouTube Music's official lyrics come first: timed ones are used as is. Without
/// timing, LRCLIB/LrcApi may still supply a timeline that matches the recording;
/// otherwise the official untimed text beats guessing from title matches.
struct YouTubeMusicFirstLyricsRepository: LyricsRepositoryProtocol {
    typealias Official = @Sendable (_ videoID: String) async throws -> SyncedLyrics?

    let official: Official
    let fallback: LyricsRepositoryProtocol

    init(official: @escaping Official, fallback: LyricsRepositoryProtocol) {
        self.official = official
        self.fallback = fallback
    }

    init(service: YouTubeMusicLyricsService = .init(), fallback: LyricsRepositoryProtocol) {
        self.init(official: { try await service.lyrics(videoID: $0) }, fallback: fallback)
    }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        var officialLyrics: SyncedLyrics?
        if context.hasYouTubeOrigin, let videoID = context.songID, !videoID.isEmpty {
            do { officialLyrics = try await official(videoID) }
            catch { try LyricsMatchingPolicy.checkCancellation(error) }
        }
        try Task.checkCancellation()
        if let officialLyrics, officialLyrics.isTimeSynced {
            return .provider(.youtubeMusic, lyrics: officialLyrics, received: 1, successfulResponses: 1, failures: [])
        }
        let report = try await fallback.lookup(context: context)
        if let officialLyrics, report.state != .synchronized {
            return .provider(.youtubeMusic, lyrics: officialLyrics, received: 1, successfulResponses: 1, failures: [])
        }
        return report
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await fallback.getLyrics(title: title, artist: artist, duration: duration)
    }
}
