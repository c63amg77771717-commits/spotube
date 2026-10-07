import Foundation

final class GetLyricsUseCase {
    private let repository: LyricsRepositoryProtocol

    init(repository: LyricsRepositoryProtocol) {
        self.repository = repository
    }

    func executeReport(song: Song, includeDurationInQuery: Bool = true) async throws -> LyricsLookupReport {
        let started = ProcessInfo.processInfo.systemUptime
        let context = LyricsLookupContext(song: song, includeDurationInQuery: includeDurationInQuery)
        var report: LyricsLookupReport
        do { report = try await repository.lookup(context: context) }
        catch {
            try LyricsMatchingPolicy.checkCancellation(error)
            report = .legacy(nil, failures: LyricsSourceFailure.from(error, providerID: .lrclib))
        }
        try Task.checkCancellation()
        let elapsed = Int(max(0, min(600000, (ProcessInfo.processInfo.systemUptime - started) * 1000)))
        report.diagnosticContext = context
        report.recordFinal(context: context, lookupLatencyMilliseconds: elapsed)
        return report
    }

    func execute(song: Song) async throws -> SyncedLyrics? {
        try await repository.getLyrics(context: LyricsLookupContext(song: song))
    }

    func execute(title: String, artist: String, duration: Int? = nil, allowVideoCredits: Bool = false) async throws -> SyncedLyrics? {
        try await repository.getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: allowVideoCredits)
    }
}
