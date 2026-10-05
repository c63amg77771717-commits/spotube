import SwiftUI

private struct EvanTubeRegion: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let taiwan = EvanTubeRegion(code: "TW", label: "華語／台灣")
    static let all: [EvanTubeRegion] = [
        taiwan,
        .init(code: "HK", label: "粵語／香港"),
        .init(code: "JP", label: "日語／日本"),
        .init(code: "KR", label: "韓語／韓國"),
        .init(code: "US", label: "英語／美國"),
        .init(code: "GB", label: "英語／英國"),
        .init(code: "CA", label: "英語／加拿大"),
        .init(code: "AU", label: "英語／澳洲"),
        .init(code: "SG", label: "多語／新加坡"),
        .init(code: "FR", label: "法語／法國"),
        .init(code: "DE", label: "德語／德國"),
        .init(code: "ES", label: "西語／西班牙"),
        .init(code: "MX", label: "西語／墨西哥"),
        .init(code: "BR", label: "葡語／巴西"),
        .init(code: "PT", label: "葡語／葡萄牙"),
        .init(code: "IT", label: "義語／義大利"),
        .init(code: "TH", label: "泰語／泰國"),
        .init(code: "VN", label: "越語／越南"),
        .init(code: "ID", label: "印尼語／印尼"),
        .init(code: "IN", label: "印地語／印度"),
        .init(code: "TR", label: "土耳其語／土耳其"),
        .init(code: "PL", label: "波蘭語／波蘭"),
    ]
}

@MainActor @Observable
final class EvanTubeHomeFeeds {
    var chart: EvanTubeOnlineFeed?
    var weekly: EvanTubeOnlineFeed?
    var releases: EvanTubeOnlineFeed?
    var chartError: String?
    var weeklyError: String?
    var releaseError: String?
    var isLoading = false
    var isLoadingChart = false
    private var generation = UUID()
    private var chartGeneration = UUID()

    func refresh(region: String,
                 loadChart: @MainActor (String) async throws -> EvanTubeOnlineFeed = { try await EvanTubeOnlineFeedService.chart(region: $0) },
                 loadWeekly: @MainActor () async throws -> EvanTubeOnlineFeed = { try await EvanTubeOnlineFeedService.weekly() },
                 loadReleases: @MainActor () async throws -> EvanTubeOnlineFeed = { try await EvanTubeOnlineFeedService.releases() }) async {
        let request = UUID()
        generation = request
        chartGeneration = request
        isLoading = true
        isLoadingChart = false
        defer { if generation == request { isLoading = false } }
        async let chartRequest = Self.fetch { try await loadChart(region) }
        async let weeklyRequest = Self.fetch { try await loadWeekly() }
        async let releaseRequest = Self.fetch { try await loadReleases() }
        let chartResult = await chartRequest
        guard !Task.isCancelled, generation == request else { return }
        if chartGeneration == request {
            switch chartResult {
            case .success(let feed): chart = feed; chartError = nil
            case .failure(let error): chartError = "無法取得排行榜（\(error.localizedDescription)）；請稍後重試。"
            }
        }
        let weeklyResult = await weeklyRequest
        guard !Task.isCancelled, generation == request else { return }
        switch weeklyResult {
        case .success(let feed): weekly = feed; weeklyError = nil
        case .failure: weeklyError = "無法取得 ListenBrainz 週榜；請檢查連線後重試。"
        }
        let releaseResult = await releaseRequest
        guard !Task.isCancelled, generation == request else { return }
        switch releaseResult {
        case .success(let feed): releases = feed; releaseError = nil
        case .failure: releaseError = "無法取得最新發行來源；請檢查連線後重試。"
        }
    }

    func changeRegion(_ region: String) async {
        let request = UUID()
        chartGeneration = request
        chart = nil
        chartError = nil
        isLoadingChart = true
        defer { if chartGeneration == request { isLoadingChart = false } }
        let result = await Self.fetch { try await EvanTubeOnlineFeedService.chart(region: region) }
        guard !Task.isCancelled, chartGeneration == request else { return }
        switch result {
        case .success(let feed): chart = feed
        case .failure(let error): chartError = "無法取得排行榜（\(error.localizedDescription)）；請稍後重試。"
        }
    }

    private static func fetch(_ source: @MainActor () async throws -> EvanTubeOnlineFeed) async -> Result<EvanTubeOnlineFeed, Error> {
        do { return .success(try await source()) }
        catch { return .failure(error) }
    }
}

struct EvanTubeHomeView: View {
    let viewModel: HomeViewModel
    @Environment(DIContainer.self) private var container
    @Environment(PlayerViewModel.self) private var playerVM
    @State private var feeds = EvanTubeHomeFeeds()
    @State private var region = EvanTubeRegion.taiwan
    @State private var actionMessage: String?
    @State private var manualSearchItem: EvanTubeOnlineItem?
    @State private var resolutionID = UUID()
    @State private var personal = PersonalRecommendations()
    @State private var preferenceRevision = 0
    @State private var resetTasteConfirmation = false
    @AppStorage("hideExplicitContent") private var hideExplicitContent = false
    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.scenePhase) private var scenePhase

    // Explicit Debug automation previews use local fixtures, not changing online feeds.
    private var isAutomationPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["REVIEW_MODE"] == "1"
            && ["-evantubeSettingsPreview", "-evantubeSearchPreview",
                "-evantubePlaylistRemovalPreview"].contains(where: CommandLine.arguments.contains)
        #else
        false
        #endif
    }

    private var recommendationRefreshKey: String {
        "\(preferenceRevision)-\(hideExplicitContent)-\(isTabActive)-\(scenePhase == .active)-"
            + recommendations.prefix(60).map(\.id).joined(separator: ",")
    }

    private var recommendations: [Song] {
        var seen = Set<String>()
        return viewModel.sections.flatMap(\.items).compactMap { item -> Song? in
            guard case let .song(song) = item, seen.insert(song.id).inserted else { return nil }
            return song
        }
    }

    private var onlineRecommendations: EvanTubeOnlineFeed? {
        if let chart = feeds.chart, !chart.items.isEmpty { return chart }
        if let weekly = feeds.weekly, !weekly.items.isEmpty { return weekly }
        return nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                recentSection
                nativeSection
                onlineSection(title: "最近熱門", subtitle: feeds.chart?.sourceName ?? "\(region.label) 音樂排行榜", items: Array((feeds.chart?.items ?? []).prefix(6)), source: feeds.chart, error: feeds.chartError)
                chartSection
                onlineSection(title: "本週精選", subtitle: "ListenBrainz 社群週榜", items: feeds.weekly?.items ?? [], source: feeds.weekly, error: feeds.weeklyError)
                onlineSection(title: "最新發行", subtitle: "ListenBrainz · MusicBrainz · 最近 7 天", items: Array((feeds.releases?.items ?? []).prefix(20)), source: feeds.releases, error: feeds.releaseError)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 22)
        }
        .dockSafeBottom()
        .background(Theme.Colors.backgroundPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $manualSearchItem) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text(actionMessage ?? "請搜尋並選擇想聽的版本。")
                    .font(.headline)
                Text("搜尋：\(item.title) \(item.artist)")
                    .font(.subheadline).textSelection(.enabled)
                Button(item.kind == .release ? "搜尋專輯或專輯歌曲" : "前往搜尋並選擇版本", systemImage: "magnifyingglass") {
                    let search = container.searchViewModel
                    // Clear before switching scope so it cannot submit an old library query.
                    search.query = ""
                    search.selectLibraryScope(false)
                    search.selectFilter(item.kind == .release && search.availableFilters.contains(.albums) ? .albums : .songs)
                    search.query = "\(item.title) \(item.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
                    search.search()
                    manualSearchItem = nil
                    NotificationCenter.default.post(name: .switchToSearchTab, object: nil)
                }
                .accessibilityIdentifier("home_chart_choose_version")
                Button("稍後再選", role: .cancel) { manualSearchItem = nil }
            }
            .padding(24)
            .presentationDetents([.medium])
        }
        .refreshable {
            guard !isAutomationPreview else { return }
            viewModel.refresh()
            viewModel.loadRecentlyPlayed()
            await refreshPersonal(force: true)
            await feeds.refresh(region: region.code)
        }
        .task {
            viewModel.loadHome()
            viewModel.loadRecentlyPlayed()
        }
        .task(id: "\(isTabActive)-\(scenePhase == .active)") {
            guard !isAutomationPreview, isTabActive, scenePhase == .active,
                  feeds.chart == nil || feeds.chartError != nil else { return }
            await feeds.refresh(region: region.code)
        }
        .task(id: recommendationRefreshKey) {
            guard isTabActive, scenePhase == .active else { return }
            await refreshPersonal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .personalTasteChanged)) { _ in
            preferenceRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
            preferenceRevision += 1
        }
        .confirmationDialog("重設聆聽偏好？收藏仍會影響推薦。", isPresented: $resetTasteConfirmation) {
            Button("重設聆聽偏好", role: .destructive) {
                personal.clear()
                PersonalMusicTaste.shared.reset()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image("EvanTubeLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text("Evan").foregroundStyle(Theme.Colors.textPrimary)
                        Text("Tube").foregroundStyle(Theme.Colors.brandGradient)
                    }
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("MORE THAN MUSIC")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .tracking(2.5)
                        .foregroundStyle(Theme.Colors.brandGradient)
                }
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .switchToSearchTab, object: nil)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.brandGradient)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("搜尋")
            }
            Text("晚安，\n音樂總在對的時候出現。")
                .font(.system(size: 25, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近播放", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.brandGradient)
                Spacer()
                Text("媒體庫")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if viewModel.recentlyPlayed.isEmpty {
                emptyCard("播放歌曲後會顯示在這裡")
            } else {
                ForEach(Array(viewModel.recentlyPlayed.prefix(5))) { song in
                    songRow(song)
                }
            }
        }
    }

    private var nativeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                sectionTitle("為你推薦", subtitle: personal.status)
                Spacer()
                Menu {
                    Button("重新整理推薦", systemImage: "arrow.clockwise") {
                        Task { await refreshPersonal(force: true) }
                    }
                    Button("重設聆聽偏好", systemImage: "arrow.counterclockwise") {
                        resetTasteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.Colors.brandGradient)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("推薦設定")
            }
            if personal.isLoading {
                ProgressView("正在更新推薦…").font(.caption)
            }
            if personal.songs.isEmpty {
                if let feed = onlineRecommendations {
                    Text("先聽線上榜單推薦；播放或收藏後會更貼近你的喜好")
                        .font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                    sourceLabel(feed)
                    ForEach(Array(feed.items.prefix(12))) { item in onlineRow(item) }
                } else {
                    emptyCard(personal.isLoading || viewModel.isLoading || feeds.isLoading || feeds.isLoadingChart
                              ? "正在尋找你可能喜歡的歌曲…"
                              : (feeds.chartError ?? feeds.weeklyError ?? "目前沒有推薦歌曲；播放或收藏後下拉重新整理"))
                }
            } else {
                ForEach(ContentPreferences.filteredSongs(personal.songs)) { song in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            songRow(song)
                            Button {
                                personal.dislike(song)
                            } label: {
                                Image(systemName: "hand.thumbsdown")
                                    .foregroundStyle(Theme.Colors.brandGradient)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("不喜歡 \(song.title)，減少這類推薦")
                        }
                        Text(personal.reasons[song.id] ?? "音源推薦")
                            .font(.caption2).foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(2).padding(.horizontal, 10)
                    }
                }
            }
        }
    }

    @MainActor private func refreshPersonal(force: Bool = false) async {
        guard !isAutomationPreview else { return }
        let favorites = (try? await container.manageFavoritesUseCase.getAllFavorites()) ?? []
        guard !Task.isCancelled else { return }
        await personal.refresh(favorites: favorites, fallback: recommendations, force: force, discover: { seed in
            let artist = seed.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = artist.isEmpty ? seed.title : "\(artist) music"
            return try await container.searchMusicUseCase.executeOnline(query: query, filter: .songs).songs
        }) { id in
            try await container.getRelatedSongsUseCase.execute(videoId: id)
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                sectionTitle("各語系音樂排行", subtitle: feeds.chart?.sourceName ?? "榜單按地區統計")
                Spacer(minLength: 8)
                Menu {
                    ForEach(EvanTubeRegion.all) { option in
                        Button(option.label) {
                            region = option
                            Task { if !isAutomationPreview { await feeds.changeRegion(option.code) } }
                        }
                    }
                } label: {
                    Text(region.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Colors.brandGradient)
                        .lineLimit(1)
                }
            }
            if let error = feeds.chartError {
                emptyCard(error)
                Button("重新載入排行榜") {
                    Task { if !isAutomationPreview { await feeds.changeRegion(region.code) } }
                }
                .disabled(feeds.isLoadingChart)
                .accessibilityIdentifier("chart_retry")
            }
            if let chart = feeds.chart, !chart.items.isEmpty {
                sourceLabel(chart)
                ForEach(chart.items) { item in onlineRow(item) }
            } else if feeds.chartError == nil {
                emptyCard(feeds.isLoading || feeds.isLoadingChart ? "正在載入 \(region.label) 榜單…" : "目前 \(region.label) 榜單沒有歌曲；下拉重新整理")
            }
        }
    }

    private func onlineSection(
        title: String, subtitle: String, items: [EvanTubeOnlineItem], source: EvanTubeOnlineFeed?, error: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, subtitle: subtitle)
            if let error { emptyCard(error) }
            if let source, !items.isEmpty {
                sourceLabel(source)
                ForEach(items) { item in onlineRow(item) }
            } else if error == nil {
                emptyCard(feeds.isLoading ? "正在載入…" : "目前沒有可顯示的線上資料；下拉重新整理")
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).foregroundStyle(Theme.Colors.textPrimary)
            Text(subtitle).font(.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func sourceLabel(_ feed: EvanTubeOnlineFeed) -> some View {
        HStack(spacing: 4) {
            Text(feed.sourceName)
            if let updated = feed.updatedAt {
                Text("· 更新 \(updated.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        .font(.caption2)
        .foregroundStyle(Theme.Colors.textSecondary)
    }

    private func songRow(_ song: Song) -> some View {
        Button { playerVM.play(song: song) } label: {
            HStack(spacing: 12) {
                AsyncThumbnail(url: song.thumbnailURL, size: 48, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).lineLimit(1).foregroundStyle(Theme.Colors.textPrimary)
                    Text(song.artistName).lineLimit(1).font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill")
                    .foregroundStyle(Theme.Colors.brandGradient)
            }
            .padding(10)
            .background(Theme.Colors.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home_song_\(song.id)")
    }

    private func onlineRow(_ item: EvanTubeOnlineItem) -> some View {
        Button { Task { await resolveAndOpen(item) } } label: {
            HStack(spacing: 12) {
                AsyncThumbnail(url: item.artworkURL, size: 48, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1).foregroundStyle(Theme.Colors.textPrimary)
                    Text(item.artist).lineLimit(1).font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: item.kind == .release ? "square.stack" : "play.fill")
                    .foregroundStyle(Theme.Colors.brandGradient)
            }
            .padding(10)
            .background(Theme.Colors.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func emptyCard(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.Colors.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func resolveAndOpen(_ item: EvanTubeOnlineItem) async {
        let request = UUID()
        resolutionID = request
        manualSearchItem = nil
        actionMessage = "正在尋找「\(item.title)」的線上版本…"
        do {
            if item.kind == .release {
                let resolved = try await EvanTubeOnlineAlbumResolver.resolve(item, searchUseCase: container.searchMusicUseCase)
                guard !Task.isCancelled, resolutionID == request else { return }
                guard let album = resolved else {
                    actionMessage = "目前音源找不到「\(item.title)」的可開啟專輯版本；可到搜尋找這張專輯的歌曲。"
                    manualSearchItem = item
                    return
                }
                actionMessage = nil
                NotificationCenter.default.post(name: .navigateToAlbum, object: nil, userInfo: ["browseId": album.id])
            } else {
                let resolved = try await EvanTubeOnlineSongResolver.resolve(item) { query in
                    try await container.searchMusicUseCase.executeOnline(query: query, filter: .songs).songs
                }
                guard !Task.isCancelled, resolutionID == request else { return }
                guard let song = resolved else {
                    actionMessage = "無法確認「\(item.title)」的唯一對應版本；請搜尋並選擇想聽的版本。"
                    manualSearchItem = item
                    return
                }
                actionMessage = nil
                playerVM.play(song: song)
            }
        } catch {
            guard !Task.isCancelled, resolutionID == request else { return }
            actionMessage = "版本搜尋失敗：\(error.localizedDescription)"
            manualSearchItem = item
        }
    }

}
