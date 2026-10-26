import Foundation

/// The Android Music client version used for timed lyrics. If YouTube stops
/// accepting it, editing remote-config/lyrics.json on the repository's
/// `evantube-remote-config` branch fixes installed apps on their next launch,
/// without a new build. The last valid value is cached; bad input is ignored.
enum YouTubeMusicLyricsClientConfig {
    static let defaultAndroidMusicVersion = "7.27.52"
    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/c63amg77771717-commits/spotube/evantube-remote-config/remote-config/lyrics.json")!
    private static let versionKey = "lyrics.youtubeMusic.androidMusicVersion"

    static func androidMusicVersion(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: versionKey).flatMap(validVersion) ?? defaultAndroidMusicVersion
    }

    /// "7.27.52"-style versions only; anything else could break every request.
    static func validVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^\d{1,3}(\.\d{1,4}){1,3}$"#, options: .regularExpression) == nil ? nil : trimmed
    }

    /// Applies `{"androidMusicVersion": "…"}`; returns whether a value was stored.
    @discardableResult
    static func apply(_ data: Data, defaults: UserDefaults = .standard) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = (object["androidMusicVersion"] as? String).flatMap(validVersion) else { return false }
        defaults.set(version, forKey: versionKey)
        return true
    }

    /// Best effort at launch: a missing file or network error keeps the cached value.
    static func refresh(session: URLSession = .shared, defaults: UserDefaults = .standard) async {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16 * 1024 else { return }
        apply(data, defaults: defaults)
    }
}
