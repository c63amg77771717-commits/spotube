import Foundation

/// Main-thread listening preferences; separate from playlists and cloud sync.
@MainActor
final class PersonalMusicTaste {
    static let shared = PersonalMusicTaste()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func begin(_ song: Song?) {}
    func sample(position: Double, playing: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {}
    func skip() {}
    func dislike(_ song: Song) {}
    func reset() {}
    func seeds(favorites: [Song]) -> [Song] { [] }
    func ranked(_ songs: [Song], favorites: [Song]) -> [Song] { [] }
}
