import XCTest
@testable import LovelyMusic

final class DrivePlaylistJournalTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func storage() -> (UserDefaults, DrivePlaylistJournalStore) {
        let suite = "DrivePlaylistJournalTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, DrivePlaylistJournalStore(defaults: defaults))
    }

    private func fixture() throws -> Data {
        let bundled = Bundle(for: Self.self).url(forResource: "evantube_drive_v1", withExtension: "json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test/fixtures/evantube_drive_v1.json")
        return try Data(contentsOf: bundled ?? source)
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Artist", artistId: nil,
             albumName: nil, albumId: nil, duration: 120, thumbnailURL: nil)
    }

    func testSharedFixtureConvergesDespiteDuplicateEventsAndInputOrder() throws {
        let data = try fixture()
        let events = try DrivePlaylistJournal.combine([data, data])
        XCTAssertEqual(events.count, 12)
        let expected = DrivePlaylistJournal.replay(events)
        XCTAssertEqual(expected.map(\.id), ["p2", "p1"])
        XCTAssertEqual(expected.map(\.title), ["Second", "Renamed"])
        XCTAssertEqual(expected[1].songs.map(\.id), ["bbbbbbbbbbb", "aaaaaaaaaaa"])
        XCTAssertTrue(expected[0].songs.isEmpty)
        XCTAssertEqual(DrivePlaylistJournal.replay(Array(events.reversed())), expected)
    }

    func testInvalidJournalsLeaveLocalAndPendingEventsUntouched() throws {
        let (_, store) = storage()
        try store.activate(accountID: "a", playlists: [Playlist(id: "local", title: "Local")])
        let before = try DrivePlaylistJournal.decode(store.ownJournalData())
        let original = String(decoding: try fixture(), as: UTF8.self)
        let invalid = [
            "not json",
            original.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"),
            original.replacingOccurrences(of: "\"youtubeId\":\"aaaaaaaaaaa\"", with: "\"youtubeId\":\"éaaaaaaaaaa\""),
            original.replacingOccurrences(of: "\"duration\":120", with: "\"duration\":-1"),
            original.replacingOccurrences(of: "\"kind\":\"rename\"", with: "\"kind\":\"future\""),
            original.replacingOccurrences(of: "\"clock\":24", with: "\"clock\":true"),
            original.replacingOccurrences(of: "\"thumbnailURL\":null", with: "\"streamURL\":null"),
        ]
        for payload in invalid {
            XCTAssertThrowsError(try store.validateJournals([Data(payload.utf8)]))
            XCTAssertThrowsError(try store.mergeJournals([Data(payload.utf8)]))
            XCTAssertEqual(try DrivePlaylistJournal.decode(store.ownJournalData()), before)
        }
        XCTAssertThrowsError(try store.validateJournals([Data(repeating: 32, count: DrivePlaylistJournal.journalLimit + 1)]))
        XCTAssertThrowsError(try store.validateJournals(Array(repeating: Data("{\"schemaVersion\":1,\"events\":[]}".utf8), count: 129)))
    }

    func testConflictingDuplicateIDsAreRejected() throws {
        let data = try fixture()
        let different = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "Renamed", with: "Conflict").utf8)
        XCTAssertThrowsError(try DrivePlaylistJournal.combine([data, different]))
    }

    func testCorruptStoredClockFailsWithoutOverflowOrOverwritingState() throws {
        let (defaults, store) = storage()
        let playlist = Playlist(id: "p", title: "Original")
        try store.activate(accountID: "a", playlists: [playlist])
        let original = try XCTUnwrap(defaults.data(forKey: "evantube_drive_journal_v1"))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var events = try XCTUnwrap(raw["events"] as? [[String: Any]])
        events[0]["clock"] = Int64.max
        raw["events"] = events
        let corrupt = try JSONSerialization.data(withJSONObject: raw)
        defaults.set(corrupt, forKey: "evantube_drive_journal_v1")
        XCTAssertThrowsError(try store.record(before: [playlist], after: []))
        XCTAssertThrowsError(try store.ownJournalData())
        XCTAssertEqual(defaults.data(forKey: "evantube_drive_journal_v1"), corrupt)
    }

    func testExhaustedValidClockRejectsMutationWithoutChangingJournal() throws {
        let (_, store) = storage()
        try store.activate(accountID: "a", playlists: [])
        let data = Data(String(decoding: try fixture(), as: UTF8.self)
            .replacingOccurrences(of: "\"clock\":24", with: "\"clock\":9007199254740991").utf8)
        let before = try store.mergeJournals([data])
        var after = before
        after[0].title = "New title"
        XCTAssertThrowsError(try store.record(before: before, after: after))
        XCTAssertEqual(try store.mergeJournals([]), before)
    }

    func testSongMetadataReplacementRetainsItsPositionAndLocalClockExceedsObservedClock() throws {
        let (_, store) = storage()
        try store.activate(accountID: "a", playlists: [])
        let base = try store.mergeJournals([fixture()])
        var modified = base
        modified[1].songs[1] = Song(id: "aaaaaaaaaaa", title: "Updated", artistName: "Artist",
                                   artistId: nil, albumName: nil, albumId: nil, duration: 121, thumbnailURL: nil)
        try store.record(before: base, after: modified)
        let events = try DrivePlaylistJournal.decode(store.ownJournalData())
        XCTAssertTrue(events.allSatisfy { $0.clock > 24 })
        XCTAssertEqual(events.map(\.kind), ["putSong"])
        let merged = try store.mergeJournals([])
        XCTAssertEqual(merged[1].songs.map(\.id), ["bbbbbbbbbbb", "aaaaaaaaaaa"])
        XCTAssertEqual(merged[1].songs[1].title, "Updated")
    }

    func testTwoOfflineDevicesRetainIndependentAddsAndLaterRemoval() throws {
        let (_, first) = storage()
        let (_, second) = storage()
        let base = Playlist(id: "p", title: "Shared")
        try first.activate(accountID: "same", playlists: [base])
        try second.activate(accountID: "same", playlists: [])
        _ = try second.mergeJournals([first.ownJournalData()])
        var one = base
        one.songs = [song("aaaaaaaaaaa")]
        var two = base
        two.songs = [song("bbbbbbbbbbb")]
        try first.record(before: [base], after: [one])
        try second.record(before: [base], after: [two])
        let combinedFirst = try first.mergeJournals([second.ownJournalData()])
        let combinedSecond = try second.mergeJournals([first.ownJournalData()])
        XCTAssertEqual(combinedFirst, combinedSecond)
        XCTAssertEqual(Set(combinedFirst[0].songs.map(\.id)), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        var removed = combinedSecond
        removed[0].songs.removeAll { $0.id == "aaaaaaaaaaa" }
        try second.record(before: combinedSecond, after: removed)
        let result = try first.mergeJournals([second.ownJournalData()])
        XCTAssertEqual(result[0].songs.map(\.id), ["bbbbbbbbbbb"])
    }

    func testDisconnectReconcilesOfflineEditsAndAccountSwitchSeedsOnlyCurrentLibrary() throws {
        let (defaults, store) = storage()
        let base = Playlist(id: "p", title: "Before")
        try store.activate(accountID: "first", playlists: [base, Playlist(id: "deleted", title: "Delete me")])
        try store.record(before: [base, Playlist(id: "deleted", title: "Delete me")], after: [base])
        store.deactivate()
        XCTAssertFalse(store.isActivated(accountID: "first"))
        var offline = base
        offline.title = "Offline rename"
        offline.songs = [song("aaaaaaaaaaa")]
        let before = try DrivePlaylistJournal.decode(store.ownJournalData())
        try store.record(before: [base], after: [offline])
        XCTAssertEqual(try DrivePlaylistJournal.decode(store.ownJournalData()), before)
        let reloaded = DrivePlaylistJournalStore(defaults: defaults)
        XCTAssertEqual(reloaded.deviceID, store.deviceID)
        try reloaded.activate(accountID: "first", playlists: [offline])
        let resumed = try reloaded.mergeJournals([])
        XCTAssertEqual(resumed[0].title, "Offline rename")
        XCTAssertEqual(resumed[0].songs.map(\.id), ["aaaaaaaaaaa"])
        XCTAssertTrue(try DrivePlaylistJournal.decode(reloaded.ownJournalData()).contains { $0.kind == "delete" })
        try reloaded.activate(accountID: "second", playlists: [offline])
        let switched = try DrivePlaylistJournal.decode(reloaded.ownJournalData())
        XCTAssertFalse(switched.contains { $0.kind == "delete" || $0.playlistId == "deleted" })
        XCTAssertTrue(reloaded.isActivated(accountID: "second"))
        XCTAssertEqual(try reloaded.mergeJournals([])[0].title, "Offline rename")
    }

    func testRepositoryRetainsMutationAfterDownloadSnapshotAndPersistsReplay() async throws {
        let (defaults, store) = storage()
        let repository = LocalPlaylistRepository(defaults: defaults, journal: store)
        let playlist = try await repository.createPlaylist(title: "Shared")
        try repository.activateDriveSync(accountID: "a")
        let downloadedBeforeLocalEdit = try store.ownJournalData()
        let added = Song(id: "4DARsEmUxMg", title: "化身孤岛的鲸 - 张靓颖", artistName: "张靓颖",
                         artistId: nil, albumName: nil, albumId: nil, duration: nil,
                         thumbnailURL: "https://i.ytimg.com/vi/4DARsEmUxMg/hqdefault.jpg")
        try await repository.addSongToPlaylist(song: added, playlistId: playlist.id)
        try repository.mergeDriveJournals([downloadedBeforeLocalEdit])
        let reloaded = LocalPlaylistRepository(defaults: defaults, journal: DrivePlaylistJournalStore(defaults: defaults))
        let values = try await reloaded.getAllPlaylists()
        XCTAssertEqual(values[0].songs.map(\.id), [added.id])
        XCTAssertEqual(values[0].songs.first?.title, added.title)
        XCTAssertEqual(values[0].songs.first?.artistName, added.artistName)
        let pending = try DrivePlaylistJournal.decode(store.ownJournalData())
        try repository.mergeDriveJournals([downloadedBeforeLocalEdit])
        XCTAssertEqual(try DrivePlaylistJournal.decode(store.ownJournalData()), pending)
    }

    func testAddingToAMissingPlaylistFailsWithoutChangingStoredSongs() async throws {
        let (defaults, store) = storage()
        let repository = LocalPlaylistRepository(defaults: defaults, journal: store)
        let playlist = try await repository.createPlaylist(title: "Local")
        try await repository.addSongToPlaylist(song: song("aaaaaaaaaaa"), playlistId: playlist.id)
        for batch in [false, true] {
            do {
                if batch {
                    _ = try await repository.addSongsToPlaylist(songs: [song("bbbbbbbbbbb")], playlistId: "missing")
                } else {
                    try await repository.addSongToPlaylist(song: song("bbbbbbbbbbb"), playlistId: "missing")
                }
                XCTFail("A missing playlist must not report a successful addition")
            } catch { }
        }
        let restarted = LocalPlaylistRepository(defaults: defaults, journal: DrivePlaylistJournalStore(defaults: defaults))
        let values = try await restarted.getAllPlaylists()
        XCTAssertEqual(values.first?.songs.map(\.id), ["aaaaaaaaaaa"])
    }

    func testRejectedLocalMutationPreservesLibraryAndJournal() async throws {
        let (defaults, store) = storage()
        let repository = LocalPlaylistRepository(defaults: defaults, journal: store)
        let playlist = try await repository.createPlaylist(title: "Valid")
        try repository.activateDriveSync(accountID: "a")
        let pending = try DrivePlaylistJournal.decode(store.ownJournalData())
        do {
            try await repository.addSongToPlaylist(song: song("invalid"), playlistId: playlist.id)
            XCTFail("Malformed local song must fail before either persistence write")
        } catch { }
        let values = try await repository.getAllPlaylists()
        XCTAssertTrue(values[0].songs.isEmpty)
        XCTAssertEqual(try DrivePlaylistJournal.decode(store.ownJournalData()), pending)
        defaults.set(Data("broken".utf8), forKey: "local_playlists")
        do {
            _ = try await repository.createPlaylist(title: "Must not overwrite corruption")
            XCTFail("Corrupt library must propagate its error")
        } catch { }
        XCTAssertEqual(defaults.data(forKey: "local_playlists"), Data("broken".utf8))
    }
}
