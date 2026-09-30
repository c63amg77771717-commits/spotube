import Foundation

struct MB3ImportResult {
    let created: Int
    let added: Int
    let duplicates: Int
    let skipped: Int
}

@MainActor @Observable
final class LibraryViewModel {
    private let managePlaylistUseCase: ManagePlaylistUseCase
    private let manageFavoritesUseCase: ManageFavoritesUseCase

    private(set) var playlists: [Playlist] = []
    private(set) var recentlyPlayed: [Song] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var favoritesCount: Int = 0

    // Create playlist
    var isCreatingPlaylist = false
    var newPlaylistName = ""

    // Rename playlist
    var isRenamingPlaylist = false
    var renamingPlaylistId: String?
    var renameText = ""

    // Delete confirmation
    var showDeleteConfirmation = false
    var playlistToDelete: Playlist?

    init(managePlaylistUseCase: ManagePlaylistUseCase, manageFavoritesUseCase: ManageFavoritesUseCase) {
        self.managePlaylistUseCase = managePlaylistUseCase
        self.manageFavoritesUseCase = manageFavoritesUseCase
    }

    func loadLibrary() async {
        isLoading = true
        error = nil
        do {
            playlists = try await managePlaylistUseCase.getAllPlaylists()
            recentlyPlayed = ContentPreferences.filteredSongs(
                try await managePlaylistUseCase.getRecentlyPlayed()
            )
            favoritesCount = manageFavoritesUseCase.getFavoritesCount()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func createPlaylist() async {
        guard !newPlaylistName.isEmpty else { return }
        do {
            let playlist = try await managePlaylistUseCase.createPlaylist(title: newPlaylistName)
            playlists.append(playlist)
            newPlaylistName = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func importMB3(_ selected: [MB3ImportedPlaylist]) async throws -> MB3ImportResult {
        var known = try await managePlaylistUseCase.getAllPlaylists()
        var created = 0
        var added = 0
        var duplicates = 0
        for source in selected where !source.songs.isEmpty {
            try Task.checkCancellation()
            let target: Playlist
            if let existing = known.first(where: {
                $0.title.localizedCaseInsensitiveCompare(source.name) == .orderedSame
            }) {
                target = existing
            } else {
                target = try await managePlaylistUseCase.createPlaylist(title: source.name)
                known.append(target)
                created += 1
            }
            let count = try await managePlaylistUseCase.addSongs(source.songs, to: target.id)
            added += count
            duplicates += source.songs.count - count
        }
        await loadLibrary()
        return MB3ImportResult(
            created: created, added: added, duplicates: duplicates,
            skipped: selected.reduce(0) { $0 + $1.skipped }
        )
    }

    func startRename(playlist: Playlist) {
        renamingPlaylistId = playlist.id
        renameText = playlist.title
        isRenamingPlaylist = true
    }

    func confirmRename() async {
        guard let id = renamingPlaylistId, !renameText.isEmpty else { return }
        do {
            try await managePlaylistUseCase.renamePlaylist(id: id, name: renameText)
            await loadLibrary()
        } catch {
            self.error = error.localizedDescription
        }
        isRenamingPlaylist = false
        renamingPlaylistId = nil
    }

    func requestDelete(playlist: Playlist) {
        playlistToDelete = playlist
        showDeleteConfirmation = true
    }

    func confirmDelete() async {
        guard let playlist = playlistToDelete else { return }
        playlists.removeAll { $0.id == playlist.id }
        do {
            try await managePlaylistUseCase.deletePlaylist(id: playlist.id)
        } catch {
            self.error = error.localizedDescription
            await loadLibrary()
        }
        playlistToDelete = nil
    }

    func deletePlaylist(at offsets: IndexSet) {
        let idsToDelete = offsets.map { playlists[$0].id }
        playlists.remove(atOffsets: offsets)
        Task {
            for id in idsToDelete {
                do {
                    try await managePlaylistUseCase.deletePlaylist(id: id)
                } catch {
                    Log.playlist.error("Failed to delete playlist \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func deletePlaylists(ids: Set<String>) {
        playlists.removeAll { ids.contains($0.id) }
        Task {
            for id in ids {
                do {
                    try await managePlaylistUseCase.deletePlaylist(id: id)
                } catch {
                    Log.playlist.error("Failed to delete playlist \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
