import Foundation

final class ManagePlaylistUseCase {
    private let repository: PlaylistRepositoryProtocol

    init(repository: PlaylistRepositoryProtocol) {
        self.repository = repository
    }

    func getAllPlaylists() async throws -> [Playlist] {
        try await repository.getAllPlaylists()
    }

    func createPlaylist(title: String) async throws -> Playlist {
        try await repository.createPlaylist(title: title)
    }

    func deletePlaylist(id: String) async throws {
        try await repository.deletePlaylist(id: id)
    }

    func renamePlaylist(id: String, name: String) async throws {
        try await repository.renamePlaylist(id: id, name: name)
    }

    func movePlaylist(id: String, direction: Int) async throws {
        try await repository.movePlaylist(id: id, direction: direction)
    }

    func addSong(_ song: Song, to playlistId: String) async throws {
        try await repository.addSongToPlaylist(song: song, playlistId: playlistId)
    }

    func addSongs(_ songs: [Song], to playlistId: String) async throws -> Int {
        try await repository.addSongsToPlaylist(songs: songs, playlistId: playlistId)
    }

    func removeSong(songId: String, from playlistId: String) async throws {
        try await repository.removeSongFromPlaylist(songId: songId, playlistId: playlistId)
    }

    func moveSong(songId: String, in playlistId: String, direction: Int) async throws {
        try await repository.moveSong(songId: songId, playlistId: playlistId, direction: direction)
    }

    func getRecentlyPlayed() async throws -> [Song] {
        try await repository.getRecentlyPlayed()
    }

    func addToHistory(_ song: Song) async throws {
        try await repository.addToHistory(song: song)
    }
}
