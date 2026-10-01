import Foundation

extension Notification.Name {
    static let personalTasteChanged = Notification.Name("personalTasteChanged")
}

/// Main-thread listening preferences; separate from playlists and cloud sync.
@MainActor
final class PersonalMusicTaste {
    static let shared = PersonalMusicTaste()
    private struct Signal: Codable {
        var song: Song
        var plays = 0
        var skips = 0
        var disliked = false
        var updated = Date()
    }
    private let defaults: UserDefaults
    private let key = "evantube.personalTaste.v1"
    private var signals: [String: Signal] = [:]
    private var current: Song?
    private var lastSample: (position: Double, time: Double)?
    private var listened = 0.0
    private var credited = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), data.count <= 4 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([String: Signal].self, from: data) {
            signals = decoded.filter { Self.usable($0.value.song) }
        }
    }

    func begin(_ song: Song?) {
        current = song
        listened = 0
        credited = false
        suspend()
    }

    func suspend() { lastSample = nil }

    func sample(position: Double, playing: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard !defaults.bool(forKey: "pauseListenHistory"), playing,
              position.isFinite, now.isFinite, let song = current, Self.usable(song) else {
            suspend()
            return
        }
        let previous = lastSample
        lastSample = (position, now)
        guard !credited, let previous else { return }
        let wall = now - previous.time
        let delta = position - previous.position
        // Ignore seeks, stalled playback and long gaps; count actual playing time.
        guard wall > 0, wall <= 5, delta > 0, delta <= wall * 3 + 1 else { return }
        listened += min(wall, delta)
        let threshold = min(30, max(1, Double(song.duration ?? 60) / 2))
        if listened >= threshold {
            credited = true
            var signal = signals[song.id] ?? Signal(song: song)
            signal.plays = min(100, signal.plays + 1)
            signal.updated = Date()
            signals[song.id] = signal
            save()
        }
    }

    func skip() {
        guard !defaults.bool(forKey: "pauseListenHistory"), !credited,
              listened >= 1, listened < 15, let song = current, Self.usable(song) else { return }
        credited = true // One vote per play session; repeated button presses do not multiply it.
        var signal = signals[song.id] ?? Signal(song: song)
        signal.skips = min(100, signal.skips + 1)
        signal.updated = Date()
        signals[song.id] = signal
        save()
    }

    func dislike(_ song: Song) {
        guard Self.usable(song) else { return }
        var signal = signals[song.id] ?? Signal(song: song)
        signal.disliked = true
        signal.updated = Date()
        signals[song.id] = signal
        save()
    }

    func reset() {
        signals.removeAll()
        begin(nil)
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: .personalTasteChanged, object: nil)
    }

    private static func usable(_ song: Song) -> Bool {
        !song.isEpisode && song.id.utf8.count == 11 && song.id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func artist(_ song: Song) -> String {
        song.artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func weight(_ song: Song, favorites: Set<String>) -> Double {
        let signal = signals[song.id]
        let age = max(0, Date().timeIntervalSince(signal?.updated ?? Date()) / 86400)
        return (Double(min(20, signal?.plays ?? 0)) * 4 / (1 + age / 30))
            + (favorites.contains(song.id) ? 12 : 0) - Double(signal?.skips ?? 0) * 5
    }

    func seeds(favorites: [Song]) -> [Song] {
        let favoriteIDs = Set(favorites.map(\.id))
        var seen = Set<String>()
        return (favorites + signals.values.map(\.song)).filter {
            Self.usable($0) && seen.insert($0.id).inserted && signals[$0.id]?.disliked != true
                && weight($0, favorites: favoriteIDs) > 0
        }.sorted {
            let left = weight($0, favorites: favoriteIDs), right = weight($1, favorites: favoriteIDs)
            return left == right ? $0.id < $1.id : left > right
        }
    }

    func ranked(_ songs: [Song], favorites: [Song]) -> [Song] {
        let favoriteIDs = Set(favorites.map(\.id))
        var affinity: [String: Double] = [:]
        for seed in seeds(favorites: favorites) {
            let artist = Self.artist(seed)
            if !artist.isEmpty { affinity[artist, default: 0] += weight(seed, favorites: favoriteIDs) }
        }
        for signal in signals.values {
            let artist = Self.artist(signal.song)
            let age = max(0, Date().timeIntervalSince(signal.updated) / 86400)
            if !artist.isEmpty {
                affinity[artist, default: 0] -= (Double(signal.skips) * 2 + (signal.disliked ? 12 : 0)) / (1 + age / 30)
            }
        }
        var seen = Set<String>()
        let candidates = songs.enumerated().filter {
            Self.usable($0.element) && signals[$0.element.id]?.disliked != true
                && seen.insert($0.element.id).inserted
        }
        func score(_ song: Song) -> Double {
            min(40, affinity[Self.artist(song), default: 0])
                - Double(signals[song.id]?.skips ?? 0) * 8
                - (favoriteIDs.contains(song.id) || (signals[song.id]?.plays ?? 0) > 0 ? 6 : 0)
        }
        return candidates.sorted {
            let left = score($0.element), right = score($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    private func save() {
        // ponytail: keep the latest 500 preferences; a database is unnecessary for this bounded profile.
        signals = Dictionary(uniqueKeysWithValues: signals.sorted {
            $0.value.updated > $1.value.updated
        }.prefix(500).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(signals), data.count <= 4 * 1024 * 1024 {
            defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .personalTasteChanged, object: nil)
    }
}
