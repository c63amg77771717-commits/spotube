import Foundation

/// Both providers share identity, version, duration and timestamp acceptance.
enum LyricsMatchingPolicy {
    static func validDuration(_ duration: Int?) -> Int? {
        duration.flatMap { (1...3600).contains($0) ? $0 : nil }
    }

    static func selectionKey(title: String, artist: String, duration: Int?) -> String {
        // Keep the existing key so old LRCLib selections remain addressable.
        LyricsLookupMetadata.identityKey(title) + "|" + LyricsLookupMetadata.performerKey(artist)
            + "|" + String(validDuration(duration) ?? 0)
    }

    static func identityMatches(title: String?, artist: String?, pair: LyricsLookupMetadata.Pair,
                                missingArtist: Bool = false) -> Bool {
        guard let title, let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return LyricsLookupMetadata.identityKey(title) == LyricsLookupMetadata.identityKey(pair.title)
            && (missingArtist || LyricsLookupMetadata.matchingPerformerKey(artist)
                == LyricsLookupMetadata.matchingPerformerKey(pair.artist))
    }

    static func checkCancellation(_ error: Error? = nil) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
    }

    static func lyrics(syncedLRC: String, plainText: String?, recordingDuration: Double?,
                       videoDuration: Int?, provider: LyricsProviderID) -> SyncedLyrics? {
        let parsed = parseLRCResult(syncedLRC)
        let timed = parsed.lines
        let video = validDuration(videoDuration)
        let compatible = video.flatMap { video in
            recordingDuration.map { $0.isFinite && $0 > 0 && abs($0 - Double(video)) <= 1 }
        } ?? false
        if compatible, let video, !timed.isEmpty, parsed.invalidTimestampCount == 0,
           parsed.untimedContentCount == 0, !parsed.unsupportedOffset,
           timed.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= Double(video) + 1 }) {
            return SyncedLyrics(lines: timed, source: provider.displayName, providerID: provider)
        }
        let plain = plainLines(plainText ?? "")
        let fallback = plain.isEmpty ? plainLines(syncedLRC) : plain
        guard !fallback.isEmpty else { return nil }
        let state: LyricsTimingState
        if parsed.unsupportedOffset { state = .unsupportedTiming }
        else if parsed.invalidTimestampCount > 0 { state = .invalidTimestamp }
        else if recordingDuration == nil || video == nil { state = .timingUnknown }
        else if !compatible { state = .durationMismatch }
        else { state = .plainOnly }
        return SyncedLyrics(lines: fallback.map { LyricLine(time: 0, text: $0) },
                            source: provider.displayName + " (plain)", isTimeSynced: false, providerID: provider, timingState: state)
    }

    static func choose(_ candidates: [LyricsCandidate], key: String, missingArtist: Bool,
                       defaults: UserDefaults, failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var seen = Set<LyricsRecordID>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return nil }
        let remembered = LyricsSelectionStore.selectedRecord(for: key, defaults: defaults)
            .flatMap { id in unique.first { $0.id == id } }
        let chosen = remembered ?? (!missingArtist && unique.count == 1 ? unique[0] : nil)
        return SyncedLyrics(lines: chosen?.lyrics.lines ?? [], source: chosen?.lyrics.source ?? "",
                            isTimeSynced: chosen?.lyrics.isTimeSynced ?? false,
                            candidates: unique, selectionKey: key, providerID: chosen?.providerID,
                            sourceFailures: failures, timingState: chosen?.lyrics.timingState)
    }

    struct LRCParseResult {
        let lines: [LyricLine]
        let invalidTimestampCount: Int
        let untimedContentCount: Int
        let unsupportedOffset: Bool
    }

    static func parseLRC(_ input: String) -> [LyricLine] { parseLRCResult(input).lines }

    /// Preserve invalid/unsupported evidence instead of silently accepting a
    /// valid subset of a damaged timeline. A finite `[offset:]` within ±30 s
    /// is the LRC overall adjustment in milliseconds and is added to every cue
    /// (positive delays the lyric; this is the adjustment Minilyrics and
    /// NetEase exports write). Anything else still rejects the timeline.
    static func parseLRCResult(_ input: String) -> LRCParseResult {
        guard let pattern = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2}(?:[.:]\\d+)?)\\]") else {
            return .init(lines: [], invalidTimestampCount: 1, untimedContentCount: 0, unsupportedOffset: false)
        }
        let offsetSeconds = lrcOffsetSeconds(input)
        var output: [LyricLine] = []
        var invalid = 0, untimed = 0
        let unsupportedOffset = offsetSeconds == nil
        if unsupportedOffset {
            return .init(lines: [], invalidTimestampCount: 0, untimedContentCount: 0, unsupportedOffset: true)
        }
        for original in input.components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("[offset:") { continue }
            if line.range(of: "^\\[(?:ar|ti|al|by|length|re|ve):", options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let matches = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = matches.last, let tail = Range(last.range, in: line) else {
                if line.range(of: "^\\[\\d", options: .regularExpression) != nil { invalid += 1 }
                else { untimed += 1 }
                continue
            }
            var end = 0
            guard matches.allSatisfy({ match in
                guard match.range.location == end else { return false }
                end = NSMaxRange(match.range); return true
            }) else { invalid += 1; continue }
            let text = String(line[tail.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let m = Range(match.range(at: 1), in: line), let s = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[m]),
                      let seconds = Double(line[s].replacingOccurrences(of: ":", with: ".")),
                      minutes.isFinite, seconds.isFinite, (0..<60).contains(seconds) else { invalid += 1; continue }
                output.append(.init(time: max(0, minutes * 60 + seconds + (offsetSeconds ?? 0)), text: text))
            }
        }
        return .init(lines: output.sorted { $0.time < $1.time }, invalidTimestampCount: invalid,
                     untimedContentCount: untimed, unsupportedOffset: unsupportedOffset)
    }

    /// nil when an offset tag is present but not a finite millisecond adjustment.
    /// Missing offset is 0. Multiple tags combine.
    static func lrcOffsetSeconds(_ input: String) -> Double? {
        var total = 0.0
        for original in input.components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("[offset:") else { continue }
            guard line.hasSuffix("]") else { return nil }
            let body = line.dropFirst("[offset:".count).dropLast()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let milliseconds = Double(body), milliseconds.isFinite, abs(milliseconds) <= 30_000 else { return nil }
            total += milliseconds / 1000
        }
        return total
    }


    private static func plainLines(_ input: String) -> [String] {
        input.components(separatedBy: .newlines).compactMap { original in
            var text = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[!text]") { text.removeFirst(7) }
            text = text.replacingOccurrences(of: "^(?:\\[\\d{1,3}:\\d{2}(?:[.:]\\d+)?\\])+", with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.range(of: "^\\[(?:ar|ti|al|by|offset|length|re|ve):", options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            return text
        }
    }
}
