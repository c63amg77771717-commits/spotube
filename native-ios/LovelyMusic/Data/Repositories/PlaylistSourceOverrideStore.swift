import Foundation
import Observation

/// One explicit choice per (playlist, original recording). Does not mutate the
/// playlist, global mappings, favorites, or save signed streaming URLs.
@MainActor @Observable
final class PlaylistSourceOverrideStore {
    struct Record: Codable, Equatable {
        let playlistID: String
        let originalID: String
        let sourceID: String
        let revision: UInt64
        let title: String?
        let artist: String?
        let duration: Int?
    }
    struct Snapshot: Codable { let schema: Int; let records: [Record] }
    struct Key: Hashable { let playlist: String; let original: String }
    enum StoreError: Error { case invalidSource, conflict, corruptStorage }
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let writer: (Data, URL) throws -> Void
    private(set) var loadFailed = false
    private var values: [Key: Record] = [:]

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EvanTube/playlist-source-overrides-v2.json")
    }
    init(fileURL: URL? = nil,
         writer: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) {
        let resolvedURL = fileURL ?? Self.defaultFileURL
        self.fileURL = resolvedURL
        self.writer = writer
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: resolvedURL))
            guard snapshot.schema == 2 else { throw StoreError.corruptStorage }
            for record in snapshot.records {
                let key = Key(playlist: record.playlistID, original: record.originalID)
                guard !key.playlist.isEmpty, PlaybackSourceReplacementPolicy.isVideoID(key.original),
                      PlaybackSourceReplacementPolicy.isVideoID(record.sourceID), record.revision > 0,
                      values[key] == nil else { throw StoreError.corruptStorage }
                values[key] = record
            }
        } catch { loadFailed = true; values = [:] }
    }
    func record(playlistID: String, originalID: String) -> Record? {
        values[Key(playlist: playlistID, original: originalID)]
    }
    func revision(playlistID: String, originalID: String) -> UInt64 {
        record(playlistID: playlistID, originalID: originalID)?.revision ?? 0
    }
    func sourceID(for song: Song, legacy: (String) -> String) -> String {
        if let playlist = song.playbackPlaylistID,
           let value = record(playlistID: playlist, originalID: song.id) { return value.sourceID }
        return legacy(song.id)
    }
    func hasReplacement(playlistID: String, originalID: String, legacy: (String) -> String) -> Bool {
        if let value = record(playlistID: playlistID, originalID: originalID) {
            return value.sourceID != originalID
        }
        return legacy(originalID) != originalID
    }
    @discardableResult
    func save(candidate: Song, playlistID: String, originalID: String, expectedRevision: UInt64) throws -> Record {
        guard candidate.id != originalID else { throw StoreError.invalidSource }
        return try write(playlistID: playlistID, originalID: originalID, sourceID: candidate.id,
                         title: candidate.title, artist: candidate.artistName, duration: candidate.duration,
                         expectedRevision: expectedRevision)
    }
    @discardableResult
    func restore(playlistID: String, originalID: String, expectedRevision: UInt64) throws -> Record {
        // Explicit original marker overrides legacy A -> B rather than falling
        // back to it when the user asked to restore A.
        try write(playlistID: playlistID, originalID: originalID, sourceID: originalID,
                  title: nil, artist: nil, duration: nil, expectedRevision: expectedRevision)
    }
    func rollback(previous: Record?, playlistID: String, originalID: String,
                  fallbackSourceID: String, expectedRevision: UInt64) throws {
        _ = try write(playlistID: playlistID, originalID: originalID,
                      sourceID: previous?.sourceID ?? fallbackSourceID,
                      title: previous?.title, artist: previous?.artist, duration: previous?.duration,
                      expectedRevision: expectedRevision)
    }
    private func write(playlistID: String, originalID: String, sourceID: String,
                       title: String?, artist: String?, duration: Int?, expectedRevision: UInt64) throws -> Record {
        guard !loadFailed else { throw StoreError.corruptStorage }
        guard !playlistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              PlaybackSourceReplacementPolicy.isVideoID(originalID),
              PlaybackSourceReplacementPolicy.isVideoID(sourceID) else { throw StoreError.invalidSource }
        let key = Key(playlist: playlistID, original: originalID)
        guard revision(playlistID: playlistID, originalID: originalID) == expectedRevision,
              expectedRevision < UInt64.max else { throw StoreError.conflict }
        let record = Record(playlistID: playlistID, originalID: originalID, sourceID: sourceID,
                            revision: expectedRevision + 1, title: title, artist: artist, duration: duration)
        var next = values
        next[key] = record
        let ordered = next.values.sorted { ($0.playlistID, $0.originalID) < ($1.playlistID, $1.originalID) }
        let data = try JSONEncoder().encode(Snapshot(schema: 2, records: ordered))
        try writer(data, fileURL)
        values = next
        return record
    }
    func resolve<Value>(song: Song, legacy: (String) -> String,
                        using resolver: (String) async throws -> Value) async throws -> Value {
        let source = sourceID(for: song, legacy: legacy)
        let before = song.playbackPlaylistID.map { revision(playlistID: $0, originalID: song.id) }
        let result = try await resolver(source)
        try Task.checkCancellation()
        guard sourceID(for: song, legacy: legacy) == source,
              song.playbackPlaylistID.map({ revision(playlistID: $0, originalID: song.id) }) == before else {
            throw CancellationError()
        }
        return result
    }
}
