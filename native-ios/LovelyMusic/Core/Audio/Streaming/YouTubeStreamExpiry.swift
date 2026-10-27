import Foundation

/// googlevideo playback URLs carry a unix expiry in the `expire` query item.
/// A missing parameter is not treated as expired; callers still apply the
/// six-hour `streamResolvedAt` bound for URLs that never included one.
enum YouTubeStreamExpiry {
    /// `leeway` marks a URL that is about to expire as already unusable, so
    /// resume rebuilds it instead of handing AVPlayer a stream that dies mid-buffer.
    static func isExpired(_ url: URL, now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard url.isFileURL == false,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "expire" })?.value,
              let seconds = TimeInterval(raw), seconds.isFinite
        else { return false }
        return seconds <= now.timeIntervalSince1970 + leeway
    }
}
