import Foundation

/// Pure identity decisions, scoped to one lookup invocation. Never stores HTTP results
/// or persists a provider failure, candidate selection, lyric content or negative lookup.
final class LyricsLookupScoringSession {
    struct LineKey: Hashable {
        let time: UInt64
        let text: String
        init(_ line: LyricLine) { time = line.time.bitPattern; text = line.text }
    }

    private struct ContextKey: Hashable {
        let lookupID: String
        let songID: String?
        let title: String
        let artist: String
        let artistSource: String?
        let album: String?
        let duration: Int?
        let artistID: String?
        let albumID: String?
        let video: Bool
        let videoType: String?
        let queryDuration: Bool
        let derivedTitle: String
        let derivedArtist: String
        init(_ metadata: LyricsCanonicalMetadata) {
            let c = metadata.context
            lookupID = c.diagnosticLookupID; songID = c.songID; title = c.title; artist = c.artist
            artistSource = c.artistNameSource?.rawValue; album = c.album; duration = c.duration
            artistID = c.artistID; albumID = c.albumID; video = c.hasYouTubeOrigin
            videoType = c.musicVideoType; queryDuration = c.includeDurationInQuery
            derivedTitle = metadata.pair.title; derivedArtist = metadata.pair.artist
        }
    }

    private struct CandidateKey: Hashable {
        let id: LyricsRecordID
        let title: String
        let artist: String
        let duration: UInt64?
        let album: String?
        let source: String
        let lyricProvider: LyricsProviderID?
        let timing: String
        let synchronized: Bool
        let lines: [LineKey]
        init(_ c: LyricsCandidate) {
            id = c.id; title = c.title; artist = c.artist; duration = c.duration?.bitPattern; album = c.album
            source = c.lyrics.source; lyricProvider = c.lyrics.providerID
            timing = c.lyrics.timingState.rawValue; synchronized = c.lyrics.isTimeSynced
            lines = c.lyrics.lines.map(LineKey.init)
        }
    }

    private struct Key: Hashable {
        let context: ContextKey
        let candidate: CandidateKey
        let remembered: LyricsRecordID?
    }
    private var decisions: [Key: LyricsIdentityDecision] = [:]
    private(set) var evaluationCount = 0
    private(set) var reuseCount = 0

    func decision(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata,
                  remembered: LyricsRecordID? = nil) -> LyricsIdentityDecision {
        // A canceled lookup must not consume reused decisions or retain its table.
        if Task.isCancelled {
            decisions.removeAll()
            evaluationCount += 1
            return LyricsCandidateScorer.decision(candidate, metadata: metadata, remembered: remembered)
        }
        let key = Key(context: ContextKey(metadata), candidate: CandidateKey(candidate), remembered: remembered)
        if let value = decisions[key] { reuseCount += 1; return value }
        let value = LyricsCandidateScorer.decision(candidate, metadata: metadata, remembered: remembered)
        evaluationCount += 1
        if decisions.count >= 512 { decisions.removeAll() }
        decisions[key] = value
        return value
    }
}

/// Equivalent candidate evidence is stricter than a matching composition/title.
/// It does not claim that providers or a human verified the original audio recording.
enum LyricsRecordingEvidence {
    struct Key: Hashable {
        let title: String
        let artist: String
        let album: String
        let versions: [String]
        let duration: UInt64
        let lines: [LyricsLookupScoringSession.LineKey]
    }

    static func key(_ candidate: LyricsCandidate) -> Key? {
        guard candidate.identityDecision?.kind == .confirmed,
              let album = candidate.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty,
              let duration = candidate.duration, duration.isFinite, duration > 0, duration <= 86400,
              candidate.lyrics.timingState == .structurallyCompatible || candidate.lyrics.timingState == .durationMismatch,
              candidate.lyrics.lines.count >= 2 else { return nil }
        let lines = candidate.lyrics.lines
        guard lines.allSatisfy({ $0.time.isFinite && $0.time >= 0 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              zip(lines, lines.dropFirst()).allSatisfy({ $0.0.time <= $0.1.time }),
              Set(lines.map(\.time)).count >= 2 else { return nil }
        return Key(title: LyricsLookupMetadata.identityKey(candidate.title),
                   artist: LyricsLookupMetadata.performerKey(candidate.artist),
                   album: LyricsLookupMetadata.identityKey(album),
                   versions: LyricsCanonicalMetadata.versions(candidate.title).union(LyricsCanonicalMetadata.versions(album)).sorted(),
                   duration: duration.bitPattern, lines: lines.map(LyricsLookupScoringSession.LineKey.init))
    }

    static func groups(_ candidates: [LyricsCandidate]) -> [[LyricsRecordID]] {
        var groups: [Key: [LyricsRecordID]] = [:]
        for candidate in candidates {
            guard let key = key(candidate) else { continue }
            if !groups[key, default: []].contains(candidate.id) { groups[key, default: []].append(candidate.id) }
        }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted { $0.providerID.rawValue + $0.recordID < $1.providerID.rawValue + $1.recordID } }
            .sorted { $0[0].providerID.rawValue + $0[0].recordID < $1[0].providerID.rawValue + $1[0].recordID }
    }
}
