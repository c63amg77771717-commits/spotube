import Foundation

final class SearchMusicUseCase {
    private let repository: InnerTubeRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let favoritesRepository: FavoritesRepositoryProtocol
    private let youtubeService: YouTubeSearchService
    private let youtubeKeyStore: YouTubeSearchKeyStore

    init(
        repository: InnerTubeRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol = LocalPlaylistRepository(),
        favoritesRepository: FavoritesRepositoryProtocol = LocalFavoritesRepository(),
        youtubeService: YouTubeSearchService = YouTubeSearchService(),
        youtubeKeyStore: YouTubeSearchKeyStore = YouTubeSearchKeyStore()
    ) {
        self.repository = repository
        self.playlistRepository = playlistRepository
        self.favoritesRepository = favoritesRepository
        self.youtubeService = youtubeService
        self.youtubeKeyStore = youtubeKeyStore
    }

    /// Online search is available without a user-supplied Data API key:
    /// the repository loads YouTube Music's public web-client configuration
    /// on demand. A custom Data API key remains optional.
    var isOnlineConfigured: Bool { true }

    func execute(query: String, filter: SearchFilter? = nil) async throws -> SearchResult {
        do {
            return try await repository.search(query: query, filter: filter)
        } catch InnerTubeError.sourceNotConfigured {
            return try await executeLibrary(query: query, filter: filter)
        }
    }

    func executeLibrary(query: String, filter: SearchFilter? = nil) async throws -> SearchResult {
        let query = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return .empty }
        guard filter == nil || filter == .songs || filter == .playlists else { return .empty }

        let playlists = try await playlistRepository.getAllPlaylists()
        let favorites = try await favoritesRepository.getAllFavorites()
        let history = try await playlistRepository.getRecentlyPlayed()
        func matches(_ song: Song) -> Bool {
            [song.title, song.artistName, song.albumName ?? ""].contains {
                Self.normalized($0).contains(query)
            }
        }

        var songIDs = Set<String>()
        let songs = (playlists.flatMap(\.songs) + favorites + history).filter {
            matches($0) && songIDs.insert($0.id).inserted
        }
        let matchingPlaylists = playlists.filter {
            Self.normalized($0.title).contains(query) || $0.songs.contains(where: matches)
        }
        return SearchResult(
            songs: filter == .playlists ? [] : songs,
            albums: [], artists: [],
            playlists: filter == .songs ? [] : matchingPlaylists,
            continuation: nil
        )
    }

    func executeOnline(query: String, filter: SearchFilter? = nil) async throws -> SearchResult {
        // The user-provided Data API key only implements song search.
        // Browse videos and mixed results through anonymous YouTube Music InnerTube.
        if filter == .songs, let key = try youtubeKey() {
            return try await youtubeService.search(query: query, key: key)
        }
        return try await repository.search(query: query, filter: filter)
    }

    func continueSearch(token: String) async throws -> SearchResult {
        if token.hasPrefix(YouTubeSearchService.continuationPrefix) {
            guard let key = try youtubeKey() else { throw YouTubeSearchError.keyMissing }
            return try await youtubeService.continueSearch(token: token, key: key)
        }
        return try await repository.searchContinuation(token: token)
    }

    func suggestions(query: String) async throws -> [String] {
        do {
            return try await repository.searchSuggestions(query: query)
        } catch InnerTubeError.sourceNotConfigured {
            let result = try await executeLibrary(query: query, filter: .songs)
            var titles = Set<String>()
            return Array(result.songs.map(\.title).filter {
                titles.insert(Self.normalized($0)).inserted
            }.prefix(10))
        }
    }

    private func youtubeKey() throws -> String? {
        if let key = try youtubeKeyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        let key = SecretsProvider.youtubeDataAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func normalized(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
            ?? value
        return simplified.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_TW")
        )
    }
}
