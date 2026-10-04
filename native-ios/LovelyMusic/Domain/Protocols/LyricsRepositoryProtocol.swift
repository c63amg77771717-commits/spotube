import Foundation

protocol LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics?
    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics?
}

extension LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration)
    }
}

struct SyncedLyrics {
    let lines: [LyricLine]
    let source: String
}

struct LyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}
