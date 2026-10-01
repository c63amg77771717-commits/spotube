import Foundation

@main
struct RecommendationPolicyChecks {
    @MainActor static func main() {
        let name = "EvanTube.RecommendationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let taste = PersonalMusicTaste(defaults: defaults)
        func song(_ id: String, _ artist: String = "Artist") -> Song {
            Song(id: id, title: id, artistName: artist, artistId: nil,
                 albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)
        }
        let a = song("aaaaaaaaaaa"), b = song("bbbbbbbbbbb", "Other"), c = song("ccccccccccc")
        func listen(_ value: Song) {
            taste.begin(value)
            for time in 0...35 { taste.sample(position: Double(time), playing: true, now: Double(time)) }
        }
        assert(taste.seeds(favorites: [a]).map(\.id) == [a.id], "favorites must seed recommendations")
        listen(b)
        assert(taste.seeds(favorites: []).map(\.id) == [b.id], "qualified listening must create a seed")
        let reloaded = PersonalMusicTaste(defaults: defaults)
        assert(reloaded.seeds(favorites: []).map(\.id) == [b.id], "taste must survive restart")
        taste.begin(a)
        taste.sample(position: 0, playing: true, now: 0)
        taste.sample(position: 120, playing: true, now: 1)
        assert(!taste.seeds(favorites: []).contains(where: { $0.id == a.id }), "seeking must not count as listening")
        for _ in 0..<3 {
            taste.begin(a)
            taste.sample(position: 0, playing: true, now: 0)
            taste.sample(position: 2, playing: true, now: 2)
            taste.skip()
        }
        assert(!taste.seeds(favorites: [a]).contains(where: { $0.id == a.id }), "repeated early skips reduce preference")
        taste.dislike(b)
        assert(!taste.ranked([b, c, c], favorites: []).contains(where: { $0.id == b.id }), "disliked songs must be hidden")
        assert(taste.ranked([c, c], favorites: []).count == 1, "deduplicate recommendations")
        taste.reset()
        defaults.set(true, forKey: "pauseListenHistory")
        listen(a)
        assert(taste.seeds(favorites: []).isEmpty, "paused listening history must not learn")
        defaults.set(false, forKey: "pauseListenHistory")
        assert(taste.ranked([b, c], favorites: [a]).first?.id == c.id, "favorite artist affinity must rank related songs")
        taste.reset()
        assert(taste.seeds(favorites: []).isEmpty, "reset clears learned taste")
        print("10 recommendation policy checks passed")
    }
}
