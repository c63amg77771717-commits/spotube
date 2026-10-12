import Foundation
import Observation

@MainActor
@Observable
final class ReplacementSourceSearchModel: Identifiable {
    let id: UUID
    let original: Song
    var query: String {
        didSet { if query != oldValue { invalidateSearch() } }
    }
    private(set) var candidates: [PlaybackSourceCandidate] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isActive = true
    private let excludedIDs: Set<String>
    private let searcher: (String) async throws -> [Song]
    private let contextIsCurrent: () -> Bool
    private var generation: UInt64 = 0
    private var searchTask: Task<Void, Never>?

    init(id: UUID = UUID(), original: Song, excludedIDs: Set<String>,
         contextIsCurrent: @escaping () -> Bool = { true },
         searcher: @escaping (String) async throws -> [Song]) {
        self.id = id
        self.original = original
        self.query = PlaybackSourceReplacementPolicy.query(for: original)
        self.excludedIDs = excludedIDs.union([original.id])
        self.contextIsCurrent = contextIsCurrent
        self.searcher = searcher
    }

    func search() async {
        guard isActive, contextIsCurrent() else { cancel(); return }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        invalidateSearch()
        guard !value.isEmpty else { errorMessage = "請輸入歌手與歌名"; return }
        let requestGeneration = generation
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let songs = try await self.searcher(value)
                try Task.checkCancellation()
                guard self.accepts(requestGeneration) else { return }
                self.candidates = PlaybackSourceReplacementPolicy.candidates(songs, for: self.original, excluding: self.excludedIDs)
            } catch {
                guard self.accepts(requestGeneration), !Task.isCancelled,
                      !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                // Never display/log raw request errors: URLs can include keys or metadata.
                if let error = error as? YouTubeSearchError {
                    switch error {
                    case .quotaExceeded: self.errorMessage = "搜尋服務限流，請稍後再試；原歌曲保持不變。"
                    case .keyMissing, .keyRejected: self.errorMessage = "搜尋服務需要設定或認證，請檢查搜尋設定。"
                    case .networkUnavailable: self.errorMessage = "目前無法連線，請恢復網路後再搜尋。"
                    default: self.errorMessage = "搜尋服務暫時無法使用，請稍後再試。"
                    }
                } else if (error as? URLError) != nil {
                    self.errorMessage = "目前無法連線，請恢復網路後再搜尋。"
                } else { self.errorMessage = "搜尋服務暫時無法使用，請檢查來源設定後再試。" }
            }
            guard self.accepts(requestGeneration) else { return }
            self.isLoading = false
            self.searchTask = nil
        }
        searchTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if accepts(requestGeneration) { isLoading = false }
    }

    func contains(_ candidate: PlaybackSourceCandidate) -> Bool {
        isActive && contextIsCurrent() && candidates.contains { $0.id == candidate.id && $0.song == candidate.song }
    }

    func reportSaveFailure() { errorMessage = "無法保存來源，請再試一次。" }

    private func accepts(_ value: UInt64) -> Bool {
        guard isActive, generation == value else { return false }
        guard contextIsCurrent() else { cancel(); return false }
        return true
    }
    private func invalidateSearch() {
        generation &+= 1
        searchTask?.cancel()
        searchTask = nil
        candidates = []
        errorMessage = nil
        isLoading = false
    }
    func cancel() { isActive = false; invalidateSearch() }
}
