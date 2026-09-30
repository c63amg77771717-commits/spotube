import Foundation
import os

extension Notification.Name {
    static let playlistsChanged = Notification.Name("playlistsChanged")
    static let recentlyPlayedChanged = Notification.Name("recentlyPlayedChanged")
}

final class LocalPlaylistRepository: PlaylistRepositoryProtocol {
    private let defaults = UserDefaults.standard
    private let playlistsKey = "local_playlists"
    private let historyKey = "recently_played"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    func getAllPlaylists() async throws -> [Playlist] {
        loadPlaylists()
    }

    func createPlaylist(title: String) async throws -> Playlist {
        var playlists = loadPlaylists()
        let playlist = Playlist(title: title)
        playlists.append(playlist)
        savePlaylists(playlists)
        return playlist
    }

    func deletePlaylist(id: String) async throws {
        var playlists = loadPlaylists()
        playlists.removeAll { $0.id == id }
        savePlaylists(playlists)
    }

    func renamePlaylist(id: String, name: String) async throws {
        var playlists = loadPlaylists()
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = name
        savePlaylists(playlists)
    }

    func movePlaylist(id: String, direction: Int) async throws {
        guard direction == -1 || direction == 1 else { return }
        var playlists = loadPlaylists()
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists.indices.contains(index + direction) else { return }
        playlists.swapAt(index, index + direction)
        savePlaylists(playlists)
    }

    func addSongToPlaylist(song: Song, playlistId: String) async throws {
        var playlists = loadPlaylists()
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        if !playlists[index].songs.contains(where: { $0.id == song.id }) {
            playlists[index].songs.append(song)
            savePlaylists(playlists)
        }
    }

    func addSongsToPlaylist(songs: [Song], playlistId: String) async throws -> Int {
        var playlists = loadPlaylists()
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return 0 }
        var existingIDs = Set(playlists[index].songs.map(\.id))
        let additions = songs.filter { existingIDs.insert($0.id).inserted }
        guard !additions.isEmpty else { return 0 }
        playlists[index].songs.append(contentsOf: additions)
        savePlaylists(playlists)
        return additions.count
    }

    func removeSongFromPlaylist(songId: String, playlistId: String) async throws {
        var playlists = loadPlaylists()
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].songs.removeAll { $0.id == songId }
        savePlaylists(playlists)
    }

    func moveSong(songId: String, playlistId: String, direction: Int) async throws {
        guard direction == -1 || direction == 1 else { return }
        var playlists = loadPlaylists()
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistId }),
              let songIndex = playlists[playlistIndex].songs.firstIndex(where: { $0.id == songId }),
              playlists[playlistIndex].songs.indices.contains(songIndex + direction) else { return }
        playlists[playlistIndex].songs.swapAt(songIndex, songIndex + direction)
        savePlaylists(playlists)
    }

    func getRecentlyPlayed() async throws -> [Song] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        do {
            return try Self.decoder.decode([Song].self, from: data)
        } catch {
            Log.playlist.error("Failed to decode recently played: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func addToHistory(song: Song) async throws {
        var history: [Song]
        do {
            history = try await getRecentlyPlayed()
        } catch {
            Log.playlist.error("Failed to load history for addToHistory: \(error.localizedDescription, privacy: .public)")
            history = []
        }
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
        do {
            let data = try Self.encoder.encode(history)
            defaults.set(data, forKey: historyKey)
            Task { @MainActor in
                NotificationCenter.default.post(name: .recentlyPlayedChanged, object: nil)
            }
        } catch {
            Log.playlist.error("Failed to encode history: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func loadPlaylists() -> [Playlist] {
        guard let data = defaults.data(forKey: playlistsKey) else { return [] }
        do {
            let playlists = try Self.decoder.decode([CodablePlaylist].self, from: data)
            return playlists.map { $0.toPlaylist() }
        } catch {
            Log.playlist.error("Failed to decode playlists: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func savePlaylists(_ playlists: [Playlist]) {
        let codable = playlists.map { CodablePlaylist(from: $0) }
        do {
            let data = try Self.encoder.encode(codable)
            defaults.set(data, forKey: playlistsKey)
            Task { @MainActor in
                NotificationCenter.default.post(name: .playlistsChanged, object: nil)
            }
        } catch {
            Log.playlist.error("Failed to encode playlists: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Codable wrapper for Playlist

private struct CodablePlaylist: Codable {
    let id: String
    let title: String
    let thumbnailURL: String?
    let songs: [Song]

    init(from playlist: Playlist) {
        self.id = playlist.id
        self.title = playlist.title
        self.thumbnailURL = playlist.thumbnailURL
        self.songs = playlist.songs
    }

    func toPlaylist() -> Playlist {
        Playlist(
            id: id,
            title: title,
            thumbnailURL: thumbnailURL,
            songCount: songs.count,
            songs: songs,
            isLocal: true
        )
    }
}
