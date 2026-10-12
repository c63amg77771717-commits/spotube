import Foundation
import Observation

/// Local IDs only: never modifies playlist metadata or stores an expiring URL.
@MainActor
@Observable
final class PlaybackSourceReplacementStore {
    static let storageKey = "evantube.playbackSourceReplacements.v1"
    private let defaults: UserDefaults
    private var replacements: [String: String]
    private var revisions: [String: UInt64] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode([String: String].self, from: $0)
        } ?? [:]
        self.replacements = decoded.filter { !$0.key.isEmpty && $0.key != $0.value && PlaybackSourceReplacementPolicy.isVideoID($0.value) }
    }

    func sourceID(for originalID: String) -> String { replacements[originalID] ?? originalID }
    func hasReplacement(for originalID: String) -> Bool { replacements[originalID] != nil }

    func save(sourceID: String, for originalID: String) throws {
        guard !originalID.isEmpty, originalID != sourceID,
              PlaybackSourceReplacementPolicy.isVideoID(sourceID) else { throw StoreError.invalidSource }
        var next = replacements
        next[originalID] = sourceID
        try commit(next, changedID: originalID)
    }

    func restore(originalID: String) throws {
        var next = replacements
        next.removeValue(forKey: originalID)
        try commit(next, changedID: originalID)
    }

    private func commit(_ next: [String: String], changedID: String) throws {
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: Self.storageKey)
        replacements = next
        revisions[changedID, default: 0] &+= 1
    }

    func resolve<Value>(originalID: String, using resolver: (String) async throws -> Value) async throws -> Value {
        let source = sourceID(for: originalID)
        let revision = revisions[originalID, default: 0]
        let result = try await resolver(source)
        try Task.checkCancellation()
        guard revisions[originalID, default: 0] == revision, sourceID(for: originalID) == source else {
            throw CancellationError()
        }
        return result
    }

    enum StoreError: Error { case invalidSource }
}
