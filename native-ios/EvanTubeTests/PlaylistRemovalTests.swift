import XCTest
@testable import LovelyMusic

@MainActor
final class PlaylistRemovalTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Artist", artistId: nil,
             albumName: nil, albumId: nil, duration: 120, thumbnailURL: nil)
    }

    private func storage() -> (UserDefaults, LocalPlaylistRepository) {
        let suite = "PlaylistRemovalTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, reopen(defaults))
    }

    private func reopen(_ defaults: UserDefaults) -> LocalPlaylistRepository {
        LocalPlaylistRepository(defaults: defaults, journal: DrivePlaylistJournalStore(defaults: defaults))
    }

    private func model(_ repository: PlaylistRepositoryProtocol, id: String) async -> PlaylistDetailViewModel {
        let model = PlaylistDetailViewModel(
            getPlaylistUseCase: GetPlaylistUseCase(repository: InnerTubeRepository(api: InnerTubeAPI())),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: repository))
        model.loadPlaylist(playlistId: id)
        await wait { model.playlist != nil || model.error != nil }
        XCTAssertEqual(model.playlist?.id, id)
        return model
    }

    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { await Task.yield() }
    }

    func testSuccessfulRemovalPersistsOnlyInChosenPlaylistAndLeavesHistory() async throws {
        let (defaults, store) = storage()
        let chosen = try await store.createPlaylist(title: "Chosen")
        let other = try await store.createPlaylist(title: "Other")
        let track = song("aaaaaaaaaaa")
        try await store.addSongToPlaylist(song: track, playlistId: chosen.id)
        try await store.addSongToPlaylist(song: track, playlistId: other.id)
        try await store.addToHistory(song: track)
        let model = await model(store, id: chosen.id)

        model.removeSongs(songIds: [track.id])
        await wait { model.playlist?.songs.isEmpty == true }

        let persisted = try await reopen(defaults).getAllPlaylists()
        XCTAssertEqual(persisted.first { $0.id == chosen.id }?.songs, [])
        XCTAssertEqual(persisted.first { $0.id == other.id }?.songs.map(\.id), [track.id])
        let history = try await reopen(defaults).getRecentlyPlayed()
        XCTAssertEqual(history.map(\.id), [track.id])
        XCTAssertNil(model.error)
    }

    func testFailedRemovalExposesErrorAndPreservesVisibleAndPersistedSong() async throws {
        let (defaults, store) = storage()
        let chosen = try await store.createPlaylist(title: "Chosen")
        let track = song("aaaaaaaaaaa")
        try await store.addSongToPlaylist(song: track, playlistId: chosen.id)
        let io = RemovalIO(base: store)
        io.failure = NSError(domain: "RemovalTests", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "無法儲存歌單"])
        let model = await model(io, id: chosen.id)

        model.removeSongs(songIds: [track.id])
        await wait { model.error != nil }

        XCTAssertEqual(model.error, "無法儲存歌單")
        XCTAssertEqual(model.filteredSongs.map(\.id), [track.id])
        let persisted = try await reopen(defaults).getAllPlaylists()
        XCTAssertEqual(persisted.first?.songs.map(\.id), [track.id])
    }

    func testPendingRemovalRejectsSecondRequestWithoutReplacingFirst() async throws {
        let (defaults, store) = storage()
        let chosen = try await store.createPlaylist(title: "Chosen")
        let first = song("aaaaaaaaaaa"), second = song("bbbbbbbbbbb")
        try await store.addSongsToPlaylist(songs: [first, second], playlistId: chosen.id)
        let io = RemovalIO(base: store)
        io.delayNextRemoval = true
        let model = await model(io, id: chosen.id)

        model.removeSongs(songIds: [first.id])
        await wait { io.pending != nil }
        XCTAssertNotNil(io.pending, "The first write must be suspended before the second request")
        model.removeSongs(songIds: [second.id])
        // Give a wrongly accepted second request a chance to reach persisted storage.
        for _ in 0..<20 { await Task.yield() }
        io.pending?.resume()
        io.pending = nil
        await wait { model.filteredSongs.map(\.id) == [second.id] }

        let persisted = try await reopen(defaults).getAllPlaylists()
        XCTAssertEqual(persisted.first?.songs.map(\.id), [second.id])
        XCTAssertEqual(model.filteredSongs.map(\.id), [second.id])
    }

    func testReadOnlyPlaylistCannotRemovePersistedMembership() async throws {
        let (defaults, store) = storage()
        let chosen = try await store.createPlaylist(title: "Remote representation")
        let track = song("aaaaaaaaaaa")
        try await store.addSongToPlaylist(song: track, playlistId: chosen.id)
        let io = RemovalIO(base: store)
        io.readOnly = true
        let model = await model(io, id: chosen.id)
        XCTAssertEqual(model.playlist?.isLocal, false)

        model.removeSongs(songIds: [track.id])
        for _ in 0..<100 { await Task.yield() }

        let persisted = try await reopen(defaults).getAllPlaylists()
        XCTAssertEqual(persisted.first?.songs.map(\.id), [track.id])
        XCTAssertEqual(model.filteredSongs.map(\.id), [track.id])
    }
}

/// Delay/failure injection at the repository I/O boundary; successful writes use real storage.
private final class RemovalIO: PlaylistRepositoryProtocol {
    let base: LocalPlaylistRepository
    var failure: Error?
    var readOnly = false
    var delayNextRemoval = false
    var pending: CheckedContinuation<Void, Never>?
    init(base: LocalPlaylistRepository) { self.base = base }

    func getAllPlaylists() async throws -> [Playlist] {
        let playlists = try await base.getAllPlaylists()
        return readOnly ? playlists.map {
            Playlist(id: $0.id, title: $0.title, songs: $0.songs, isLocal: false)
        } : playlists
    }
    func removeSongFromPlaylist(songId: String, playlistId: String) async throws {
        if delayNextRemoval {
            delayNextRemoval = false
            await withCheckedContinuation { pending = $0 }
        }
        if let failure { throw failure }
        try await base.removeSongFromPlaylist(songId: songId, playlistId: playlistId)
    }
    func createPlaylist(title: String) async throws -> Playlist { try await base.createPlaylist(title: title) }
    func deletePlaylist(id: String) async throws { try await base.deletePlaylist(id: id) }
    func renamePlaylist(id: String, name: String) async throws { try await base.renamePlaylist(id: id, name: name) }
    func movePlaylist(id: String, direction: Int) async throws { try await base.movePlaylist(id: id, direction: direction) }
    func addSongToPlaylist(song: Song, playlistId: String) async throws { try await base.addSongToPlaylist(song: song, playlistId: playlistId) }
    func addSongsToPlaylist(songs: [Song], playlistId: String) async throws -> Int { try await base.addSongsToPlaylist(songs: songs, playlistId: playlistId) }
    func moveSong(songId: String, playlistId: String, direction: Int) async throws { try await base.moveSong(songId: songId, playlistId: playlistId, direction: direction) }
    func getRecentlyPlayed() async throws -> [Song] { try await base.getRecentlyPlayed() }
    func addToHistory(song: Song) async throws { try await base.addToHistory(song: song) }
}
