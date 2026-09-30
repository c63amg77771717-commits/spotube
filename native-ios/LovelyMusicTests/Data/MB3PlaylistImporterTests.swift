import XCTest
@testable import LovelyMusic

final class MB3PlaylistImporterTests: XCTestCase {
    func testCombinedExportKeepsOrderAndSkipsInvalidOrDuplicateIDs() throws {
        let source: [String: Any] = [
            "playlists": [
                ["category": "own", "playlist_id": "1", "playlist_name": "中文歌單"],
                ["category": "saved", "playlist_id": "2", "playlist_name": "Favorites"],
            ],
            "songs": [
                ["category": "own", "playlist_id": "1", "playlist_name": "中文歌單",
                 "youtube_id": "abcdefghijk", "title": "First", "order": 2],
                ["category": "own", "playlist_id": "1", "playlist_name": "中文歌單",
                 "youtube_id": "12345678901", "title": "Second", "order": 1],
                ["category": "own", "playlist_id": "1", "playlist_name": "中文歌單",
                 "youtube_id": "abcdefghijk", "title": "Repeated"],
                ["category": "saved", "playlist_id": "2", "playlist_name": "Favorites",
                 "youtube_id": "not-a-valid-id", "title": "Unplayable"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        let parsed = try MB3PlaylistImporter.parseJSON(data)

        XCTAssertEqual(parsed.playlists.map(\.name), ["中文歌單", "Favorites"])
        XCTAssertEqual(parsed.playlists[0].songs.map(\.id), ["12345678901", "abcdefghijk"])
        XCTAssertEqual(parsed.playlists[0].skipped, 1)
        XCTAssertEqual(parsed.playlists[1].skipped, 1)
        XCTAssertEqual(parsed.rowCount, 4)
    }
}
