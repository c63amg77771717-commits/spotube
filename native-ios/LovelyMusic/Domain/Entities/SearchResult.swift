import Foundation

struct SearchResult {
    let songs: [Song]
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]
    let continuation: String?

    static let empty = SearchResult(songs: [], albums: [], artists: [], playlists: [], continuation: nil)
}

enum SearchFilter: CaseIterable {
    case songs
    case albums
    case artists
    case playlists

    var displayName: String {
        switch self {
        case .songs: return LocalizationManager.text("Songs")
        case .albums: return LocalizationManager.text("Albums")
        case .artists: return LocalizationManager.text("Artists")
        case .playlists: return LocalizationManager.text("Playlists")
        }
    }
}
