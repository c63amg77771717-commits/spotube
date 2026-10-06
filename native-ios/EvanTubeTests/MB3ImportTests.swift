import XCTest
import ZIPFoundation
@testable import LovelyMusic

final class MB3ImportTests: XCTestCase {
    func testCombinedMB3RowsPreservePlaylistAndSongOrder() throws {
        let export: [String: Any] = [
            "playlists": [
                ["category": "own", "playlist_id": "7", "playlist_name": "Player"],
                ["category": "saved", "playlist_id": "9", "playlist_name": "收藏"],
            ],
            "songs": [
                ["category": "own", "playlist_id": "7", "playlist_name": "Player",
                 "youtube_id": "abcdefghijk", "title": "Later", "order": 2],
                ["category": "own", "playlist_id": "7", "playlist_name": "Player",
                 "youtube_id": "12345678901", "title": "Earlier", "order": 1],
                ["category": "own", "playlist_id": "7", "playlist_name": "Player",
                 "youtube_id": "abcdefghijk", "title": "Repeated", "order": 3],
                ["category": "saved", "playlist_id": "9", "playlist_name": "收藏",
                 "youtube_id": "invalid", "title": "Skipped"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: export)
        let result = try MB3PlaylistImporter.parseJSON(data)
        XCTAssertEqual(result.playlists.map(\.name), ["Player", "收藏"])
        XCTAssertEqual(result.playlists[0].songs.map(\.id), ["12345678901", "abcdefghijk"])
        XCTAssertEqual(result.playlists[0].skipped, 1)
        XCTAssertEqual(result.playlists[1].skipped, 1)
        XCTAssertEqual(result.rowCount, 4)
    }

    func testZIPFilePickerInputReadsCombinedJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("MB3_All_Playlists.json")
        let zipURL = directory.appendingPathComponent("MB3_Playlists_Complete.zip")
        let export: [String: Any] = [
            "playlists": [["category": "own", "playlist_id": "7", "playlist_name": "Player"]],
            "songs": [["category": "own", "playlist_id": "7", "playlist_name": "Player",
                       "youtube_id": "abcdefghijk", "title": "Song", "order": 1]],
        ]
        try JSONSerialization.data(withJSONObject: export).write(to: jsonURL)
        try FileManager.default.zipItem(at: jsonURL, to: zipURL, shouldKeepParent: false)

        let parsed = try MB3PlaylistImporter.parse(zipURL: zipURL)
        XCTAssertEqual(parsed.playlists.count, 1)
        XCTAssertEqual(parsed.playlists[0].songs.map(\.id), ["abcdefghijk"])
    }

    func testLocalPlaylistBulkImportAndOrderingSurviveReload() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "local_playlists")
        defer { defaults.removeObject(forKey: "local_playlists") }
        let repository = LocalPlaylistRepository()
        let first = try await repository.createPlaylist(title: "First")
        let second = try await repository.createPlaylist(title: "Second")
        let a = song("abcdefghijk")
        let b = song("12345678901")
        let added = try await repository.addSongsToPlaylist(songs: [a, b, a], playlistId: first.id)
        let retried = try await repository.addSongsToPlaylist(songs: [a, b], playlistId: first.id)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(retried, 0)

        try await repository.moveSong(songId: b.id, playlistId: first.id, direction: -1)
        try await repository.movePlaylist(id: second.id, direction: -1)
        let reloaded = try await repository.getAllPlaylists()
        XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded[1].songs.map(\.id), [b.id, a.id])
    }

    func testTitlePriorityUsesFirstNonemptyTitleThenRawTitleThenNameThenID() throws {
        let rows: [[String: Any]] = [
            ["youtube_id": "abcdefghijk", "title": "Edited title", "title_raw": "Original title", "name": "Name"],
            ["youtube_id": "12345678901", "title": "  ", "title_raw": " Raw title ", "name": "Name"],
            ["youtube_id": "video000001", "title_raw": "", "name": "Fallback name"],
            ["youtube_id": "video000002", "title": "", "title_raw": "", "name": ""]
        ].map { row in var value = row; value["playlist_id"] = "7"; value["playlist_name"] = "Player"; return value }
        let result = try MB3PlaylistImporter.parseJSON(JSONSerialization.data(withJSONObject: ["songs": rows]))
        XCTAssertEqual(result.playlists.first?.songs.map(\.title), ["Edited title", "Raw title", "Fallback name", "video000002"])
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "", artistId: nil,
             albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
    }
}
