import Foundation
import os

extension Notification.Name {
    static let playlistsChanged = Notification.Name("playlistsChanged")
    static let recentlyPlayedChanged = Notification.Name("recentlyPlayedChanged")
}

final class LocalPlaylistRepository: PlaylistRepositoryProtocol {
    private let defaults: UserDefaults
    private let journal: DrivePlaylistJournalStore
    // ponytail: one lock serializes all repository instances; per-library locks if needed later.
    private static let lock = NSRecursiveLock()
    private let playlistsKey = "local_playlists"
    private let historyKey = "recently_played"
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, journal: DrivePlaylistJournalStore = .shared) {
        self.defaults = defaults
        self.journal = journal
    }

    func getAllPlaylists() async throws -> [Playlist] {
        try locked { try loadPlaylists() }
    }

    func createPlaylist(title: String) async throws -> Playlist {
        try mutate { playlists in
            let playlist = Playlist(title: title)
            playlists.append(playlist)
            return playlist
        }
    }

    func deletePlaylist(id: String) async throws {
        try mutate { $0.removeAll { $0.id == id } }
    }

    func renamePlaylist(id: String, name: String) async throws {
        try mutate { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[index].title = name
        }
    }

    func movePlaylist(id: String, direction: Int) async throws {
        guard direction == -1 || direction == 1 else { return }
        try mutate { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == id }),
                  playlists.indices.contains(index + direction) else { return }
            playlists.swapAt(index, index + direction)
        }
    }

    func addSongToPlaylist(song: Song, playlistId: String) async throws {
        _ = try await addSongsToPlaylist(songs: [song], playlistId: playlistId)
    }

    func addSongsToPlaylist(songs: [Song], playlistId: String) async throws -> Int {
        try mutate { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else {
                throw NSError(domain: "EvanTube.Playlist", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: LocalizationManager.text("Playlist not found. Please select it again.")
                ])
            }
            var existingIDs = Set(playlists[index].songs.map(\.id))
            let additions = songs.filter { existingIDs.insert($0.id).inserted }
            playlists[index].songs.append(contentsOf: additions)
            return additions.count
        }
    }

    func removeSongFromPlaylist(songId: String, playlistId: String) async throws {
        try mutate { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            playlists[index].songs.removeAll { $0.id == songId }
        }
    }

    func moveSong(songId: String, playlistId: String, direction: Int) async throws {
        guard direction == -1 || direction == 1 else { return }
        try mutate { playlists in
            guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistId }),
                  let songIndex = playlists[playlistIndex].songs.firstIndex(where: { $0.id == songId }),
                  playlists[playlistIndex].songs.indices.contains(songIndex + direction) else { return }
            playlists[playlistIndex].songs.swapAt(songIndex, songIndex + direction)
        }
    }

    func activateDriveSync(accountID: String) throws {
        try locked { try journal.activate(accountID: accountID, playlists: loadPlaylists()) }
    }

    func mergeDriveJournals(_ journals: [Data]) throws {
        try locked {
            let before = try loadPlaylists()
            let merged = try journal.mergeJournals(journals)
            try savePlaylists(merged, before: before, recording: false)
        }
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

    private func loadPlaylists() throws -> [Playlist] {
        guard let data = defaults.data(forKey: playlistsKey) else { return [] }
        return try Self.decoder.decode([CodablePlaylist].self, from: data).map { $0.toPlaylist() }
    }

    private func savePlaylists(_ playlists: [Playlist], before: [Playlist], recording: Bool = true) throws {
        // Compare persisted fields only; replay reconstructs derived Playlist properties.
        let data = try Self.encoder.encode(playlists.map { CodablePlaylist(from: $0) })
        let previous = try Self.encoder.encode(before.map { CodablePlaylist(from: $0) })
        guard data != previous else { return }
        // Pre-encode before the journal write so an encoding failure cannot record an uncommitted mutation.
        if recording { try journal.record(before: before, after: playlists) }
        defaults.set(data, forKey: playlistsKey)
        Task { @MainActor in
            NotificationCenter.default.post(name: .playlistsChanged, object: nil)
        }
    }

    private func mutate<T>(_ operation: (inout [Playlist]) throws -> T) throws -> T {
        try locked {
            let before = try loadPlaylists()
            var playlists = before
            let result = try operation(&playlists)
            try savePlaylists(playlists, before: before)
            return result
        }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try operation()
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
