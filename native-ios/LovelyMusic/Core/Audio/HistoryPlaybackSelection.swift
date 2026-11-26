import Foundation

/// A recently played row does not carry the queue it came from.
///
/// The playlist stored on the song is used when that playlist is loaded and
/// still contains the song. Otherwise a playlist that is the only one containing
/// the song is used. When neither is available, the history list on screen is
/// the queue, starting at the tapped song, so the rest of that list continues.
enum HistoryPlaybackSelection {
    struct Selection: Equatable {
        var song: Song
        var queue: [Song]
    }

    static func selection(song: Song, history: [Song], playlists: [Playlist]) -> Selection {
        if let playlist = sourcePlaylist(for: song, playlists: playlists) {
            let songs = playlist.songs.map { $0.inPlaylist(playlist.id) }
            if let match = songs.first(where: { $0.id == song.id }) {
                return Selection(song: match, queue: songs)
            }
        }
        if let index = history.firstIndex(where: { $0.id == song.id }) {
            return Selection(song: history[index], queue: history)
        }
        return Selection(song: song, queue: [song] + history.filter { $0.id != song.id })
    }

    private static func sourcePlaylist(for song: Song, playlists: [Playlist]) -> Playlist? {
        let usable = playlists.filter {
            $0.id != Playlist.playbackHistoryID && $0.songs.contains { $0.id == song.id }
        }
        if let id = song.playbackPlaylistID, let match = usable.first(where: { $0.id == id }) {
            return match
        }
        return usable.count == 1 ? usable[0] : nil
    }
}
