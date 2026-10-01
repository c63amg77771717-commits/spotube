import XCTest
@testable import LovelyMusic

final class SearchRegressionTests: XCTestCase {
    func testImportedSongCanBeSearchedWithoutAnOnlineSource() async throws {
        guard SecretsProvider.innerTubeKeyWebRemix.isEmpty else {
            throw XCTSkip("This regression requires the keyless test build")
        }
        let repository = LocalPlaylistRepository()
        let playlist = try await repository.createPlaylist(title: "SearchRegression-\(UUID())")
        let song = Song(
            id: "4DARsEmUxMg", title: "化身孤島的鯨", artistName: "張靚穎",
            artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil
        )
        try await repository.addSongToPlaylist(song: song, playlistId: playlist.id)
        do {
            let result = try await SearchMusicUseCase(
                repository: InnerTubeRepository(api: InnerTubeAPI())
            ).execute(query: "化身孤島的鯨", filter: .songs)
            XCTAssertEqual(result.songs.filter { $0.id == song.id }.count, 1)
            try await repository.deletePlaylist(id: playlist.id)
        } catch {
            try await repository.deletePlaylist(id: playlist.id)
            XCTFail("Imported songs must remain searchable without an online key: \(error)")
        }
    }
}
