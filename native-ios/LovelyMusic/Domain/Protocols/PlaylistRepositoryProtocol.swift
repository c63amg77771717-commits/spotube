import Foundation

protocol PlaylistRepositoryProtocol {
    func getAllPlaylists() async throws -> [Playlist]
    func createPlaylist(title: String) async throws -> Playlist
    func deletePlaylist(id: String) async throws
    func renamePlaylist(id: String, name: String) async throws
    func movePlaylist(id: String, direction: Int) async throws
    func addSongToPlaylist(song: Song, playlistId: String) async throws
    func addSongsToPlaylist(songs: [Song], playlistId: String) async throws -> Int
    func removeSongFromPlaylist(songId: String, playlistId: String) async throws
    func moveSong(songId: String, playlistId: String, direction: Int) async throws
    func getRecentlyPlayed() async throws -> [Song]
    func addToHistory(song: Song) async throws
}
