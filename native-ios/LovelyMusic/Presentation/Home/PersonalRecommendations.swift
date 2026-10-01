import Foundation
import Observation

@MainActor @Observable
final class PersonalRecommendations {
    private(set) var songs: [Song] = []
    private(set) var reasons: [String: String] = [:]
    private(set) var status = "播放或收藏歌曲後，這裡會逐漸貼近你的喜好"
    private(set) var isLoading = false
    private var generation = UUID()
    private var cachedRelated: [String: (date: Date, songs: [Song])] = [:]
    private let taste: PersonalMusicTaste

    init(taste: PersonalMusicTaste? = nil) { self.taste = taste ?? .shared }

    func refresh(favorites: [Song], fallback: [Song], force: Bool = false,
                 related: (String) async throws -> [Song]) async {
        let request = UUID()
        generation = request
        isLoading = true
        defer { if generation == request { isLoading = false } }
        let favorites = ContentPreferences.filteredSongs(favorites)
        var artists = Set<String>()
        let seeds = Array(taste.seeds(favorites: favorites).filter {
            artists.insert($0.artistName.lowercased()).inserted
        }.prefix(3))
        var candidates: [Song] = []
        var descriptions: [String: String] = [:]
        var groups: [[Song]] = []
        for seed in seeds {
            guard !Task.isCancelled, generation == request else { return }
            let results: [Song]
            if !force, let cached = cachedRelated[seed.id], Date().timeIntervalSince(cached.date) < 900 {
                results = cached.songs
            } else {
                do {
                    results = Array(try await related(seed.id).prefix(30))
                    guard !Task.isCancelled, generation == request else { return }
                    if cachedRelated.count >= 12 { cachedRelated.removeAll() }
                    cachedRelated[seed.id] = (Date(), results)
                } catch {
                    continue
                }
            }
            let filtered = ContentPreferences.filteredSongs(results).filter { $0.id != seed.id }
            groups.append(filtered)
            for song in filtered where descriptions[song.id] == nil {
                descriptions[song.id] = "因為你喜歡 \(seed.artistName) · \(seed.title)"
            }
        }
        guard !Task.isCancelled, generation == request else { return }
        // Interleave seed results so a single favorite artist cannot consume the whole shelf.
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where index < group.count { candidates.append(group[index]) }
        }
        let hasRelated = !candidates.isEmpty
        candidates += ContentPreferences.filteredSongs(fallback)
        let ranked = taste.ranked(candidates, favorites: favorites)
        var artistCounts: [String: Int] = [:]
        songs = Array(ranked.filter {
            let artist = $0.artistName.lowercased()
            guard artistCounts[artist, default: 0] < 3 else { return false }
            artistCounts[artist, default: 0] += 1
            return true
        }.prefix(12))
        reasons = descriptions
        status = seeds.isEmpty ? "先播放或收藏歌曲；目前顯示音源推薦"
            : (hasRelated ? "依常聽歌手、收藏與相關歌曲推薦" : "暫時無法取得相關歌曲；先依你的歌手偏好排列音源推薦")
    }

    func clear() {
        generation = UUID()
        cachedRelated.removeAll()
        songs = []
        reasons = [:]
        isLoading = false
    }

    func dislike(_ song: Song) {
        songs.removeAll { $0.id == song.id }
        reasons.removeValue(forKey: song.id)
        taste.dislike(song)
    }
}
