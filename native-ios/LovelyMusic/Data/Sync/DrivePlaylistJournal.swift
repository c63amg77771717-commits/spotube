import Foundation

enum DrivePlaylistJournalError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "歌單同步失敗：\(reason)" }
    }
}

struct DrivePlaylistJournal: Codable {
    var schemaVersion = 1
    var events: [DrivePlaylistEvent]

    static let journalLimit = 5 * 1_024 * 1_024
    static let aggregateLimit = 20 * 1_024 * 1_024
    static let eventLimit = 20_000
    static let maxClock: Int64 = 9_007_199_254_740_991

    static func decode(_ data: Data) throws -> [DrivePlaylistEvent] {
        guard data.count <= journalLimit else { throw failure("journal exceeds 5 MiB") }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["schemaVersion", "events"],
              let rows = raw["events"] as? [[String: Any]] else {
            throw failure("invalid journal envelope")
        }
        let journal = try JSONDecoder().decode(Self.self, from: data)
        guard journal.schemaVersion == 1 else { throw failure("unsupported schema version") }
        for (event, row) in zip(journal.events, rows) {
            let common: Set<String> = ["id", "deviceId", "clock", "kind", "playlistId"]
            let extra: Set<String>
            switch event.kind {
            case "create", "rename": extra = ["title"]
            case "delete": extra = []
            case "putSong": extra = ["song"]
            case "removeSong": extra = ["songId"]
            case "orderSongs", "orderPlaylists": extra = ["order"]
            default: throw failure("unknown event kind")
            }
            guard Set(row.keys) == common.union(extra) else { throw failure("invalid event fields") }
            if event.kind == "putSong" {
                guard let song = row["song"] as? [String: Any],
                      Set(song.keys) == ["youtubeId", "title", "artist", "duration", "thumbnailURL"] else {
                    throw failure("invalid song fields")
                }
            }
            try event.validate()
        }
        return journal.events
    }

    static func combine(_ journals: [Data], existing: [DrivePlaylistEvent] = []) throws -> [DrivePlaylistEvent] {
        guard journals.count <= 128, journals.reduce(0, { $0 + $1.count }) <= aggregateLimit else {
            throw failure("download limit exceeded")
        }
        var byID: [String: DrivePlaylistEvent] = [:]
        for batch in [existing] + (try journals.map(decode)) {
            for event in batch {
                if let previous = byID[event.id], previous != event { throw failure("conflicting event ID") }
                byID[event.id] = event
                guard byID.count <= eventLimit else { throw failure("event limit exceeded") }
            }
        }
        return byID.values.sorted { $0.clock == $1.clock ? $0.id < $1.id : $0.clock < $1.clock }
    }

    static func replay(_ events: [DrivePlaylistEvent]) -> [Playlist] {
        let deleted = Set(events.filter { $0.kind == "delete" }.map(\.playlistId))
        var playlists: [Playlist] = []
        for event in events.sorted(by: { $0.clock == $1.clock ? $0.id < $1.id : $0.clock < $1.clock }) {
            if event.kind == "orderPlaylists" {
                playlists = reordered(playlists, order: event.order ?? [], id: { $0.id })
                continue
            }
            guard !deleted.contains(event.playlistId) else { continue }
            if event.kind == "create" {
                if !playlists.contains(where: { $0.id == event.playlistId }) {
                    playlists.append(Playlist(id: event.playlistId, title: event.title ?? ""))
                }
                continue
            }
            guard let index = playlists.firstIndex(where: { $0.id == event.playlistId }) else { continue }
            switch event.kind {
            case "rename": playlists[index].title = event.title ?? ""
            case "putSong":
                guard let song = event.song?.localSong else { continue }
                if let position = playlists[index].songs.firstIndex(where: { $0.id == song.id }) {
                    playlists[index].songs[position] = song
                } else { playlists[index].songs.append(song) }
            case "removeSong": playlists[index].songs.removeAll { $0.id == event.songId }
            case "orderSongs": playlists[index].songs = reordered(playlists[index].songs, order: event.order ?? [], id: { $0.id })
            default: break
            }
        }
        return playlists
    }

    private static func reordered<T>(_ values: [T], order: [String], id: (T) -> String) -> [T] {
        let byID = Dictionary(values.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return order.compactMap { key in seen.insert(key).inserted ? byID[key] : nil }
            + values.filter { !seen.contains(id($0)) }
    }

    static func failure(_ reason: String) -> DrivePlaylistJournalError { .invalid(reason) }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { $0 < 128 }
    }
    static func validYouTubeID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }
}

struct DrivePlaylistSong: Codable, Equatable {
    let youtubeId: String
    let title: String
    let artist: String
    let duration: Int
    let thumbnailURL: String?

    init(_ song: Song) {
        youtubeId = song.id; title = song.title; artist = song.artistName
        duration = song.duration ?? 0; thumbnailURL = song.thumbnailURL
    }
    // The protocol requires an explicit null for missing thumbnails.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(youtubeId, forKey: .youtubeId)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(duration, forKey: .duration)
        try container.encode(thumbnailURL, forKey: .thumbnailURL)
    }
    var localSong: Song {
        Song(id: youtubeId, title: title, artistName: artist, artistId: nil,
             albumName: nil, albumId: nil, duration: duration, thumbnailURL: thumbnailURL)
    }
}

struct DrivePlaylistEvent: Codable, Equatable {
    let id: String
    let deviceId: String
    let clock: Int64
    let kind: String
    let playlistId: String
    var title: String? = nil
    var song: DrivePlaylistSong? = nil
    var songId: String? = nil
    var order: [String]? = nil

    func validate() throws {
        func require(_ value: Bool) throws {
            guard value else { throw DrivePlaylistJournal.failure("malformed \(kind) event") }
        }
        try require(UUID(uuidString: id)?.uuidString.lowercased() == id)
        try require(UUID(uuidString: deviceId)?.uuidString.lowercased() == deviceId)
        try require(clock > 0 && clock <= DrivePlaylistJournal.maxClock)
        try require(kind == "orderPlaylists" ? playlistId.isEmpty : DrivePlaylistJournal.validID(playlistId))
        switch kind {
        case "create", "rename":
            try require(song == nil && songId == nil && order == nil)
            try require(title.map { !$0.isEmpty && $0.unicodeScalars.count <= 1_000 } ?? false)
        case "delete": try require(title == nil && song == nil && songId == nil && order == nil)
        case "putSong":
            try require(title == nil && songId == nil && order == nil)
            guard let song else { throw DrivePlaylistJournal.failure("missing song") }
            try require(DrivePlaylistJournal.validYouTubeID(song.youtubeId) && song.duration >= 0
                        && Int64(song.duration) <= DrivePlaylistJournal.maxClock
                        && song.title.unicodeScalars.count <= 1_000 && song.artist.unicodeScalars.count <= 1_000)
        case "removeSong":
            try require(title == nil && song == nil && order == nil)
            try require(songId.map(DrivePlaylistJournal.validYouTubeID) ?? false)
        case "orderSongs", "orderPlaylists":
            try require(title == nil && song == nil && songId == nil)
            guard let order else { throw DrivePlaylistJournal.failure("missing order") }
            try require(order.count <= 20_000 && order.allSatisfy {
                kind == "orderSongs" ? DrivePlaylistJournal.validYouTubeID($0) : DrivePlaylistJournal.validID($0)
            })
        default: throw DrivePlaylistJournal.failure("unknown event kind")
        }
    }
}

final class DrivePlaylistJournalStore {
    static let shared = DrivePlaylistJournalStore()
    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private let stateKey = "evantube_drive_journal_v1"
    let deviceID: String

    private struct State: Codable {
        var accountID: String
        var active: Bool
        var events: [DrivePlaylistEvent]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: "evantube_drive_device_id"),
           UUID(uuidString: saved)?.uuidString.lowercased() == saved { deviceID = saved }
        else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: "evantube_drive_device_id")
        }
    }

    func isActivated(accountID: String) -> Bool {
        locked { (try? state()).map { $0.accountID == accountID && $0.active } ?? false }
    }

    func activate(accountID: String, playlists: [Playlist]) throws {
        try locked {
            let previous = try state()
            var next = previous?.accountID == accountID ? previous! : State(accountID: accountID, active: true, events: [])
            next.events += try differences(before: DrivePlaylistJournal.replay(next.events), after: playlists, existing: next.events)
            next.active = true
            try persist(next)
        }
    }

    func deactivate() {
        locked {
            guard var saved = try? state() else { return }
            saved.active = false
            // Encoding an already validated state cannot fail; preserve the last state if it does.
            try? persist(saved)
        }
    }

    func ownJournalData() throws -> Data {
        try locked { try JSONEncoder().encode(DrivePlaylistJournal(events: (try state()?.events ?? []).filter { $0.deviceId == deviceID })) }
    }

    func validateJournals(_ journals: [Data]) throws {
        try locked { _ = try DrivePlaylistJournal.combine(journals, existing: state()?.events ?? []) }
    }

    func mergeJournals(_ journals: [Data]) throws -> [Playlist] {
        try locked {
            guard var saved = try state(), saved.active else { throw DrivePlaylistJournal.failure("sync is disconnected") }
            saved.events = try DrivePlaylistJournal.combine(journals, existing: saved.events)
            let playlists = DrivePlaylistJournal.replay(saved.events)
            try persist(saved)
            return playlists
        }
    }

    func record(before: [Playlist], after: [Playlist]) throws {
        try locked {
            guard var saved = try state(), saved.active else { return }
            saved.events += try differences(before: before, after: after, existing: saved.events)
            try persist(saved)
        }
    }

    private func differences(before: [Playlist], after: [Playlist], existing: [DrivePlaylistEvent]) throws -> [DrivePlaylistEvent] {
        var clock = existing.map(\.clock).max() ?? 0
        var events: [DrivePlaylistEvent] = []
        func append(_ kind: String, _ playlistID: String, title: String? = nil, song: Song? = nil, songID: String? = nil, order: [String]? = nil) throws {
            guard clock < DrivePlaylistJournal.maxClock else { throw DrivePlaylistJournal.failure("event clock limit exceeded") }
            clock = max(Int64(Date().timeIntervalSince1970 * 1_000), clock + 1)
            let event = DrivePlaylistEvent(id: UUID().uuidString.lowercased(), deviceId: deviceID, clock: clock,
                                          kind: kind, playlistId: playlistID, title: title,
                                          song: song.map(DrivePlaylistSong.init), songId: songID, order: order)
            try event.validate()
            events.append(event)
        }
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(after.map(\.id))
        for playlist in before where !currentIDs.contains(playlist.id) { try append("delete", playlist.id) }
        for playlist in after {
            let old = previous[playlist.id]
            if old == nil { try append("create", playlist.id, title: playlist.title) }
            else if old?.title != playlist.title { try append("rename", playlist.id, title: playlist.title) }
            let oldSongs = Dictionary((old?.songs ?? []).map { ($0.id, DrivePlaylistSong($0)) }, uniquingKeysWith: { first, _ in first })
            let songIDs = Set(playlist.songs.map(\.id))
            for song in old?.songs ?? [] where !songIDs.contains(song.id) { try append("removeSong", playlist.id, songID: song.id) }
            for song in playlist.songs where oldSongs[song.id] != DrivePlaylistSong(song) { try append("putSong", playlist.id, song: song) }
            if old?.songs.map(\.id) != playlist.songs.map(\.id) { try append("orderSongs", playlist.id, order: playlist.songs.map(\.id)) }
        }
        if before.map(\.id) != after.map(\.id) { try append("orderPlaylists", "", order: after.map(\.id)) }
        return events
    }

    private func state() throws -> State? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        guard data.count <= DrivePlaylistJournal.aggregateLimit else { throw DrivePlaylistJournal.failure("journal storage limit exceeded") }
        let saved = try JSONDecoder().decode(State.self, from: data)
        guard saved.events.count <= DrivePlaylistJournal.eventLimit else { throw DrivePlaylistJournal.failure("event limit exceeded") }
        for event in saved.events { try event.validate() }
        _ = try DrivePlaylistJournal.combine([], existing: saved.events)
        let own = try JSONEncoder().encode(DrivePlaylistJournal(events: saved.events.filter { $0.deviceId == deviceID }))
        guard own.count <= DrivePlaylistJournal.journalLimit else { throw DrivePlaylistJournal.failure("journal storage limit exceeded") }
        return saved
    }

    private func persist(_ state: State) throws {
        guard state.events.count <= DrivePlaylistJournal.eventLimit else { throw DrivePlaylistJournal.failure("event limit exceeded") }
        let data = try JSONEncoder().encode(state)
        let own = try JSONEncoder().encode(DrivePlaylistJournal(events: state.events.filter { $0.deviceId == deviceID }))
        guard data.count <= DrivePlaylistJournal.aggregateLimit, own.count <= DrivePlaylistJournal.journalLimit else {
            throw DrivePlaylistJournal.failure("journal storage limit exceeded")
        }
        defaults.set(data, forKey: stateKey)
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}
