import UIKit
import XCTest
@testable import LovelyMusic

final class PlaylistCoverTests: XCTestCase {
    private func song(_ id: String, thumbnail: String? = nil) -> Song {
        Song(id: id, title: id, artistName: "歌手", artistId: nil,
             albumName: nil, albumId: nil, duration: 180, thumbnailURL: thumbnail)
    }

    func testAutomaticCoverFollowsFirstSongAfterReordering() {
        var playlist = Playlist(title: "歌單", thumbnailURL: "https://example.com/playlist.jpg",
                                songs: [song("first", thumbnail: "https://example.com/first.jpg"),
                                        song("second", thumbnail: "https://example.com/second.jpg")])
        XCTAssertEqual(playlist.automaticCoverURL, "https://example.com/first.jpg")
        playlist.songs.reverse()
        XCTAssertEqual(playlist.automaticCoverURL, "https://example.com/second.jpg")
    }

    func testMissingFirstArtworkNeverUsesAnotherSongsArtwork() {
        let playlist = Playlist(title: "歌單", songs: [song("local-first-song"),
                                song("second", thumbnail: "https://example.com/second.jpg")])
        XCTAssertNil(playlist.automaticCoverURL)
        let youtubePlaylist = Playlist(title: "YouTube", songs: [song("abcdefghijk"),
                                       song("second", thumbnail: "https://example.com/second.jpg")])
        XCTAssertEqual(youtubePlaylist.automaticCoverURL,
                       "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
    }

    func testEmptyPlaylistUsesRemoteArtworkOnlyForRemotePlaylists() {
        XCTAssertNil(Playlist(title: "空歌單", thumbnailURL: "https://example.com/stale.jpg").automaticCoverURL)
        XCTAssertEqual(Playlist(title: "遠端歌單", thumbnailURL: "https://example.com/remote.jpg",
                                isLocal: false).automaticCoverURL, "https://example.com/remote.jpg")
    }

    @MainActor func testCustomCoverWinsSurvivesRestartAndRestoresAutomaticCover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlist = Playlist(id: "../playlist/一", title: "歌單",
                                songs: [song("first", thumbnail: "https://example.com/first.jpg")])
        let store = PlaylistCoverStore(directory: directory)
        let imageData = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200))
            .image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
            }.pngData())
        try store.setCover(data: imageData, for: playlist.id)
        let customCover = store.cover(for: playlist)
        let savedImage = try XCTUnwrap(customCover.image)
        XCTAssertNil(customCover.thumbnailURL, "Custom covers take precedence over song artwork")
        XCTAssertLessThanOrEqual(max(savedImage.size.width, savedImage.size.height), 1024)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "Playlist IDs cannot create nested or parent paths")
        XCTAssertEqual(files.first?.pathExtension, "jpg")
        XCTAssertNil(store.cover(for: Playlist(id: "other", title: "另一歌單")).image)

        let restartedStore = PlaylistCoverStore(directory: directory)
        XCTAssertNotNil(restartedStore.cover(for: playlist).image)
        try restartedStore.restoreAutomaticCover(for: playlist.id)
        XCTAssertNil(restartedStore.cover(for: playlist).image)
        XCTAssertEqual(restartedStore.cover(for: playlist).thumbnailURL, "https://example.com/first.jpg")
        XCTAssertNil(PlaylistCoverStore(directory: directory).cover(for: playlist).image)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @MainActor func testInvalidPhotoDoesNotReplaceExistingCover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaylistCoverStore(directory: directory)
        let playlist = Playlist(id: "playlist", title: "歌單")
        let imageData = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
            .image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }.pngData())
        try store.setCover(data: imageData, for: playlist.id)
        XCTAssertThrowsError(try store.setCover(data: Data("invalid image".utf8), for: playlist.id))
        XCTAssertNotNil(PlaylistCoverStore(directory: directory).cover(for: playlist).image)
    }
}
