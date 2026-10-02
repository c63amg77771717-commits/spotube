import XCTest
@testable import LovelyMusic

final class PlaylistOrderingHistoryTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func storage() -> (UserDefaults, LocalPlaylistRepository) {
        let suite = "PlaylistOrderingHistoryTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, repository(defaults))
    }

    private func repository(_ defaults: UserDefaults) -> LocalPlaylistRepository {
        LocalPlaylistRepository(defaults: defaults, journal: DrivePlaylistJournalStore(defaults: defaults))
    }

    private func song(_ id: String, title: String? = nil) -> Song {
        Song(id: id, title: title ?? id, artistName: "Artist", artistId: nil,
             albumName: nil, albumId: nil, duration: 120, thumbnailURL: nil)
    }

    func testSingleAdditionsPutNewestFirstAfterRepositoryReopens() async throws {
        let (defaults, store) = storage()
        let playlist = try await store.createPlaylist(title: "Local")
        let older = song("aaaaaaaaaaa"), newer = song("bbbbbbbbbbb")
        try await store.addSongToPlaylist(song: older, playlistId: playlist.id)
        try await store.addSongToPlaylist(song: newer, playlistId: playlist.id)

        let reopened = try await repository(defaults).getAllPlaylists()
        XCTAssertEqual(reopened.first?.songs.map(\.id), [newer.id, older.id])
    }

    func testBulkAdditionsPrependInSourceOrderWithoutMovingDuplicates() async throws {
        let (defaults, store) = storage()
        let playlist = try await store.createPlaylist(title: "Imported")
        let older = song("aaaaaaaaaaa"), first = song("bbbbbbbbbbb"), second = song("ccccccccccc")
        try await store.addSongToPlaylist(song: older, playlistId: playlist.id)
        let added = try await store.addSongsToPlaylist(
            songs: [first, second, first, older], playlistId: playlist.id)
        let retried = try await store.addSongsToPlaylist(songs: [second, older], playlistId: playlist.id)

        XCTAssertEqual(added, 2)
        XCTAssertEqual(retried, 0)
        let reopened = try await repository(defaults).getAllPlaylists()
        XCTAssertEqual(reopened.first?.songs.map(\.id), [first.id, second.id, older.id])
    }

    func testDriveMergeAndReopenKeepNewestLocalAdditionFirst() async throws {
        let (defaults, store) = storage()
        let playlist = try await store.createPlaylist(title: "Synced")
        try await store.addSongToPlaylist(song: song("aaaaaaaaaaa"), playlistId: playlist.id)
        try store.activateDriveSync(accountID: "test-account")
        let snapshot = try DrivePlaylistJournalStore(defaults: defaults).ownJournalData()
        try await store.addSongToPlaylist(song: song("bbbbbbbbbbb"), playlistId: playlist.id)
        try store.mergeDriveJournals([snapshot])

        let reopened = try await repository(defaults).getAllPlaylists()
        XCTAssertEqual(reopened.first?.songs.map(\.id), ["bbbbbbbbbbb", "aaaaaaaaaaa"])
    }

    func testDriveReplayKeepsOfflineAdditionsAheadOfOlderSongs() {
        let device = "00000000-0000-0000-0000-000000000000"
        func event(_ clock: Int64, _ kind: String, song: Song? = nil, order: [String]? = nil) -> DrivePlaylistEvent {
            DrivePlaylistEvent(id: String(format: "00000000-0000-0000-0000-%012lld", clock),
                deviceId: device, clock: clock, kind: kind, playlistId: "shared",
                title: kind == "create" ? "Shared" : nil,
                song: song.map(DrivePlaylistSong.init), order: order)
        }
        let older = song("aaaaaaaaaaa"), first = song("bbbbbbbbbbb"), newest = song("ccccccccccc")
        let events = [
            event(1, "create"), event(2, "putSong", song: older),
            event(3, "orderSongs", order: [older.id]),
            event(4, "putSong", song: first), event(5, "orderSongs", order: [first.id, older.id]),
            event(6, "putSong", song: newest), event(7, "orderSongs", order: [newest.id, older.id]),
        ]

        let replayed = DrivePlaylistJournal.replay(Array(events.reversed()))
        XCTAssertEqual(replayed.first?.songs.map(\.id), [newest.id, first.id, older.id])
    }

    func testPlaybackHistoryDeduplicatesAndPreservesUpdatedMetadataAfterReopen() async throws {
        let (defaults, store) = storage()
        try await store.addToHistory(song: song("aaaaaaaaaaa", title: "Original"))
        try await store.addToHistory(song: song("bbbbbbbbbbb"))
        try await store.addToHistory(song: song("aaaaaaaaaaa", title: "Played again"))

        let history = try await repository(defaults).getRecentlyPlayed()
        let editablePlaylists = try await repository(defaults).getAllPlaylists()
        XCTAssertEqual(history.map(\.id), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(history.first?.title, "Played again")
        XCTAssertTrue(editablePlaylists.isEmpty,
                      "History is separate from editable and Drive-synced user playlists")
    }

    func testPlaybackHistoryRetainsSongsBeyondTheOldRecentPreviewLimit() async throws {
        let (defaults, store) = storage()
        let songs = (0..<51).map { song(String(format: "%011d", $0)) }
        for song in songs { try await store.addToHistory(song: song) }

        let reopened = try await repository(defaults).getRecentlyPlayed()
        XCTAssertEqual(reopened.map(\.id), songs.reversed().map(\.id),
                       "The complete history playlist must not discard songs after fifty plays")
    }

    func testSynchronousPlaybackRecordingKeepsCallbackOrderAndPreservesCorruptStorage() async throws {
        let (defaults, store) = storage()
        try store.recordPlayback(song: song("aaaaaaaaaaa"))
        try store.recordPlayback(song: song("bbbbbbbbbbb"))
        try store.recordPlayback(song: song("aaaaaaaaaaa"))
        let history = try await repository(defaults).getRecentlyPlayed()
        XCTAssertEqual(history.map(\.id), ["aaaaaaaaaaa", "bbbbbbbbbbb"])

        let corrupt = Data("corrupt history".utf8)
        defaults.set(corrupt, forKey: "recently_played")
        XCTAssertThrowsError(try store.recordPlayback(song: song("ccccccccccc")))
        XCTAssertEqual(defaults.data(forKey: "recently_played"), corrupt)
    }

    @MainActor
    func testLibraryExposesHistorySeparatelyFromEditablePlaylists() async throws {
        let (defaults, store) = storage()
        try await store.addToHistory(song: song("aaaaaaaaaaa"))
        try await store.addToHistory(song: song("bbbbbbbbbbb"))
        let model = LibraryViewModel(
            managePlaylistUseCase: ManagePlaylistUseCase(repository: repository(defaults)),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: LocalFavoritesRepository()))

        await model.loadLibrary()

        XCTAssertNil(model.error)
        XCTAssertTrue(model.playlists.isEmpty)
        XCTAssertEqual(model.playbackHistory.id, Playlist.playbackHistoryID)
        XCTAssertEqual(model.playbackHistory.songs.map(\.id), ["bbbbbbbbbbb", "aaaaaaaaaaa"])
        XCTAssertFalse(model.playbackHistory.isLocal, "Playback history is read-only")
    }

    @MainActor
    func testHistoryPlaylistDetailLoadsAllPersistedSongsWithoutRemoteLookup() async throws {
        let (defaults, store) = storage()
        let songs = (0..<51).map { song(String(format: "%011d", $0)) }
        for song in songs { try await store.addToHistory(song: song) }
        let model = PlaylistDetailViewModel(
            getPlaylistUseCase: GetPlaylistUseCase(repository: InnerTubeRepository(api: InnerTubeAPI())),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: repository(defaults)))

        model.loadPlaylist(playlistId: Playlist.playbackHistoryID)
        let deadline = Date().addingTimeInterval(2)
        while model.playlist == nil && model.error == nil && Date() < deadline { await Task.yield() }

        XCTAssertNil(model.error)
        XCTAssertEqual(model.playlist?.id, Playlist.playbackHistoryID)
        XCTAssertEqual(model.filteredSongs.map(\.id), songs.reversed().map(\.id))
        XCTAssertEqual(model.playlist?.songCount, songs.count)
        XCTAssertEqual(model.playlist?.isLocal, false)
        XCTAssertFalse(model.hasMoreSongs)
        model.startRename()
        XCTAssertFalse(model.isRenamingPlaylist)
    }
}
