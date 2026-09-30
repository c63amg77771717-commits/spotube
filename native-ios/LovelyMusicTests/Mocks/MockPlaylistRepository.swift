import Foundation
@testable import LovelyMusic

final class MockPlaylistRepository: PlaylistRepositoryProtocol {
    var playlists: [Playlist] = []
    var history: [Song] = []
    var shouldThrow = false

    func getAllPlaylists() async throws -> [Playlist] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return playlists
    }

    func createPlaylist(title: String) async throws -> Playlist {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        let p = Playlist(title: title)
        playlists.append(p)
        return p
    }

    func deletePlaylist(id: String) async throws {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        playlists.removeAll { $0.id == id }
    }

    func renamePlaylist(id: String, name: String) async throws {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].title = name
    }

    func addSongToPlaylist(song: Song, playlistId: String) async throws {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        if !playlists[idx].songs.contains(where: { $0.id == song.id }) {
            playlists[idx].songs.append(song)
        }
    }

    func addSongsToPlaylist(songs: [Song], playlistId: String) async throws -> Int {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return 0 }
        var ids = Set(playlists[idx].songs.map(\.id))
        let additions = songs.filter { ids.insert($0.id).inserted }
        playlists[idx].songs.append(contentsOf: additions)
        return additions.count
    }

    func removeSongFromPlaylist(songId: String, playlistId: String) async throws {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        guard let idx = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[idx].songs.removeAll { $0.id == songId }
    }

    func getRecentlyPlayed() async throws -> [Song] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return history
    }

    func addToHistory(song: Song) async throws {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
    }
}
