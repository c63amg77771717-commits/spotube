import XCTest
@testable import LovelyMusic

final class SearchRegressionTests: XCTestCase {
    func testLibrarySearchMatchesSimplifiedChineseAndDeduplicatesSongsAcrossSources() async throws {
        let suite = "SearchRegression.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = LocalPlaylistRepository(
            defaults: defaults, journal: DrivePlaylistJournalStore(defaults: defaults)
        )
        let playlist = try await repository.createPlaylist(title: "My MIX")
        let song = Song(
            id: "4DARsEmUxMg", title: "化身孤島的鯨 LIVE", artistName: "張靚穎",
            artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil
        )
        try await repository.addSongToPlaylist(song: song, playlistId: playlist.id)
        try await repository.addToHistory(song: song)
        let useCase = SearchMusicUseCase(
            repository: InnerTubeRepository(api: InnerTubeAPI()), playlistRepository: repository
        )

        let result = try await useCase.executeLibrary(query: "鲸 live")
        XCTAssertEqual(result.songs.map(\.id), [song.id])
        XCTAssertEqual(result.playlists.map(\.id), [playlist.id], "A matching song should find its local playlist")
        XCTAssertTrue(result.albums.isEmpty)
        XCTAssertTrue(result.artists.isEmpty)
        XCTAssertNil(result.continuation)

        let playlists = try await useCase.executeLibrary(query: "my mix", filter: .playlists)
        XCTAssertEqual(playlists.playlists.map(\.id), [playlist.id])
        XCTAssertTrue(playlists.songs.isEmpty)
        let albums = try await useCase.executeLibrary(query: "鲸", filter: .albums)
        XCTAssertTrue(albums.albums.isEmpty)
        let artists = try await useCase.executeLibrary(query: "张靓颖", filter: .artists)
        XCTAssertTrue(artists.artists.isEmpty)
    }

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
