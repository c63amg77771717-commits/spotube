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
                 discover: ((Song) async throws -> [Song])? = nil,
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
        var sourceFailed = false
        var retainedRelated = false
        for seed in seeds {
            guard !Task.isCancelled, generation == request else { return }
            let results: [Song]
            if !force, let cached = cachedRelated[seed.id], Date().timeIntervalSince(cached.date) < 900,
               !ContentPreferences.filteredSongs(cached.songs).isEmpty {
                results = ContentPreferences.filteredSongs(cached.songs)
            } else {
                var fetched: [Song] = []
                var sourceError: Error?
                do {
                    fetched = try await related(seed.id)
                } catch {
                    sourceError = error
                }
                guard !Task.isCancelled, generation == request else { return }
                fetched = ContentPreferences.filteredSongs(fetched).filter {
                    $0.id != seed.id && EvanTubeOnlineSongResolver.isPlayable($0)
                }
                if fetched.isEmpty, let discover {
                    do {
                        fetched = try await discover(seed)
                        sourceError = nil
                    } catch {
                        sourceError = error
                    }
                }
                guard !Task.isCancelled, generation == request else { return }
                let fetchedSongs = Array(ContentPreferences.filteredSongs(fetched).filter {
                    $0.id != seed.id && EvanTubeOnlineSongResolver.isPlayable($0)
                }.prefix(30))
                if fetchedSongs.isEmpty, sourceError != nil {
                    sourceFailed = true
                    results = ContentPreferences.filteredSongs(cachedRelated[seed.id]?.songs ?? [])
                    retainedRelated = retainedRelated || !results.isEmpty
                } else {
                    results = fetchedSongs
                    if results.isEmpty {
                        cachedRelated.removeValue(forKey: seed.id)
                    } else {
                        if cachedRelated.count >= 12 { cachedRelated.removeAll() }
                        cachedRelated[seed.id] = (Date(), results)
                    }
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
        if seeds.isEmpty {
            status = songs.isEmpty ? "先播放或收藏歌曲，建立你的聆聽偏好" : "先播放或收藏歌曲；目前顯示音源推薦"
        } else if retainedRelated, !songs.isEmpty {
            status = "暫時無法更新推薦；保留上次的相關歌曲"
        } else if songs.contains(where: { descriptions[$0.id] != nil }) {
            status = "依常聽歌手、收藏與線上歌曲推薦"
        } else if sourceFailed {
            status = songs.isEmpty ? "暫時無法取得相關歌曲；請檢查連線或下拉重新整理"
                : "暫時無法取得相關歌曲；先依你的歌手偏好排列音源推薦"
        } else {
            status = songs.isEmpty ? "目前沒有新的相關歌曲；可先查看線上榜單"
                : "目前沒有新的相關歌曲；先依你的歌手偏好排列音源推薦"
        }
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
