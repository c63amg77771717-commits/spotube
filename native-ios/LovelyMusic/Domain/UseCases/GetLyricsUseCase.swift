import Foundation

final class GetLyricsUseCase {
    private let repository: LyricsRepositoryProtocol

    init(repository: LyricsRepositoryProtocol) {
        self.repository = repository
    }

    func execute(song: Song) async throws -> SyncedLyrics? {
        try await repository.getLyrics(context: LyricsLookupContext(song: song))
    }

    func execute(title: String, artist: String, duration: Int? = nil, allowVideoCredits: Bool = false) async throws -> SyncedLyrics? {
        try await repository.getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: allowVideoCredits)
    }
}
