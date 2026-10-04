import Combine
import PhotosUI
import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: String
    @State private var viewModel: PlaylistDetailViewModel
    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selectedSongs: Set<String> = []
    @State private var topSafeAreaInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @State private var coverStore = PlaylistCoverStore.shared
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoPlaylistId: String?
    @State private var showPhotoPicker = false
    @State private var showCoverError = false
    @State private var coverError = ""
    @State private var showRemoveSongsConfirmation = false
    @State private var songsToRemove: Set<String> = []

    init(
        playlistId: String, getPlaylistUseCase: GetPlaylistUseCase,
        managePlaylistUseCase: ManagePlaylistUseCase? = nil
    ) {
        self.playlistId = playlistId
        self._viewModel = State(
            initialValue: PlaylistDetailViewModel(
                getPlaylistUseCase: getPlaylistUseCase,
                managePlaylistUseCase: managePlaylistUseCase
            ))
    }

    var body: some View {
        // Previously this used a root `GeometryReader` purely to read the
        // parent's top safe-area inset and forward it to `ParallaxHeaderView`.
        // `.onGeometryChange` captures the same value without wrapping the
        // subtree in a layout proxy, preserving ScrollView perf characteristics.
        scrollBody(topInset: topSafeAreaInset)
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { newValue in
                topSafeAreaInset = newValue
            }
            .background(Theme.Colors.backgroundPrimary)
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
            .confirmationDialog(
                "要從此歌單移除 \(songsToRemove.count) 首歌曲嗎？",
                isPresented: $showRemoveSongsConfirmation,
                titleVisibility: .visible
            ) {
                Button("移除歌曲", role: .destructive) {
                    viewModel.removeSongs(songIds: songsToRemove)
                }
                .disabled(viewModel.isRemovingSongs)
                Button("取消", role: .cancel) { songsToRemove = [] }
            } message: {
                Text("只會從此歌單移除，不影響其他歌單、收藏或目前的播放佇列。")
            }
            .alert("無法移除歌曲", isPresented: Binding(
                get: { viewModel.removalError != nil },
                set: { if !$0 { viewModel.removalError = nil } }
            )) {
                Button("好", role: .cancel) { viewModel.removalError = nil }
            } message: {
                Text(viewModel.removalError ?? "")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CustomBackButton(style: .glassOrb)
                }
                if let playlist = viewModel.playlist {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Menu {
                                Button {
                                    photoPlaylistId = playlist.id
                                    showPhotoPicker = true
                                } label: {
                                    Label("從相片選擇封面", systemImage: "photo")
                                }
                                Button {
                                    selectedPhoto = nil
                                    photoPlaylistId = nil
                                    do {
                                        try coverStore.restoreAutomaticCover(for: playlist.id)
                                    } catch {
                                        coverError = error.localizedDescription
                                        showCoverError = true
                                    }
                                } label: {
                                    Label("還原自動封面", systemImage: "arrow.counterclockwise")
                                }
                                .disabled(coverStore.cover(for: playlist).image == nil)
                                if playlist.isLocal {
                                    Button {
                                        viewModel.startRename()
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.body)
                                    .foregroundStyle(Theme.Colors.brandGradient)
                                    .frame(width: Theme.SizeTokens.touchTarget, height: Theme.SizeTokens.touchTarget)
                            }
                            .accessibilityLabel("歌單選項")
                            .accessibilityIdentifier("playlist_detail_options")

                            if !playlist.songs.isEmpty {
                                SelectEditButton(isEditing: editMode == .active) {
                                    withAnimation(Theme.AnimationPresets.smooth) {
                                        editMode = editMode == .active ? .inactive : .active
                                        if editMode == .inactive { selectedSongs.removeAll() }
                                        playerVM.isDockHidden = editMode == .active
                                    }
                                }
                                .disabled(viewModel.isRemovingSongs)
                            }
                        }
                    }
                }
            }
            .alert("Rename Playlist", isPresented: $viewModel.isRenamingPlaylist) {
                TextField("Playlist name", text: $viewModel.renameText)
                Button("Rename") {
                    Task { await viewModel.confirmRename() }
                }
                .disabled(viewModel.renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {
                    viewModel.renameText = ""
                }
            }
            .alert("無法變更封面", isPresented: $showCoverError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(coverError)
            }
            .task(id: playlistId) {
                viewModel.loadPlaylist(playlistId: playlistId)
            }
            .task(id: selectedPhoto) {
                guard let photo = selectedPhoto, let requestedPlaylistId = photoPlaylistId,
                      requestedPlaylistId == playlistId else { return }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        throw PlaylistCoverStore.CoverError.invalidImage
                    }
                    guard !Task.isCancelled, selectedPhoto == photo,
                          requestedPlaylistId == playlistId,
                          viewModel.playlist?.id == requestedPlaylistId else { return }
                    try coverStore.setCover(data: data, for: requestedPlaylistId)
                    selectedPhoto = nil
                    photoPlaylistId = nil
                } catch {
                    guard !Task.isCancelled, selectedPhoto == photo,
                          requestedPlaylistId == playlistId else { return }
                    selectedPhoto = nil
                    photoPlaylistId = nil
                    coverError = error.localizedDescription
                    showCoverError = true
                }
            }
            .onChange(of: playlistId) { _, _ in
                selectedPhoto = nil
                photoPlaylistId = nil
                showPhotoPicker = false
                songsToRemove = []
                showRemoveSongsConfirmation = false
                selectedSongs = []
            }
            .onChange(of: viewModel.removedSongIDs) { _, removed in
                selectedSongs.subtract(removed)
                if selectedSongs.isEmpty && editMode == .active {
                    editMode = .inactive
                    playerVM.isDockHidden = false
                }
            }
            .onChange(of: searchText) { _, newValue in
                viewModel.searchText = newValue
            }
            .onDisappear {
                if playerVM.isDockHidden {
                    withAnimation(Theme.AnimationPresets.smooth) {
                        playerVM.isDockHidden = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistsChanged)) { _ in
                if !viewModel.isRemovingSongs { viewModel.loadPlaylist(playlistId: playlistId) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .recentlyPlayedChanged)) { _ in
                if playlistId == Playlist.playbackHistoryID {
                    viewModel.loadPlaylist(playlistId: playlistId)
                }
            }
    }

    private func scrollBody(topInset: CGFloat) -> some View {
        // MARK: SafeArea — `.ignoresSafeArea(edges: .top)` is restricted to top
        // only (verified polish-A4). `.dockSafeBottom()` adds 16pt margin so
        // the last track clears the dock during inset transitions.
        ScrollView {
            if let playlist = viewModel.playlist {
                LazyVStack(spacing: 0) {
                    let cover = coverStore.cover(for: playlist)
                    ParallaxHeaderView(thumbnailURL: cover.thumbnailURL, customImage: cover.image, topInset: topInset) {
                        Text(playlist.title)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .multilineTextAlignment(.center)

                        if let count = playlist.songCount {
                            Text("\(count) songs")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Playlist: \(playlist.title)")

                    if editMode == .active {
                        selectionHeader
                    } else {
                        PlayShuffleButtons(
                            onPlay: {
                                if let first = playlist.songs.first {
                                    playerVM.play(song: first, fromQueue: playlist.songs)
                                }
                            },
                            onShuffle: {
                                if let random = playlist.songs.randomElement() {
                                    playerVM.play(
                                        song: random, fromQueue: playlist.songs.shuffled())
                                }
                            }
                        )
                    }

                    Rectangle()
                        .fill(Theme.Colors.divider)
                        .frame(height: 0.5)
                        .padding(.horizontal, Theme.Spacing.lg)

                    // Inline search (only show when there are songs to search)
                    if playlist.songs.count > 5 {
                        InlineSearchBar(text: $searchText, placeholder: "Search songs")
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.xs)
                    }

                    ForEach(Array(viewModel.filteredSongs.enumerated()), id: \.element.id) {
                        index, song in
                        let isCurrentPlaying =
                            editMode == .inactive && playerVM.currentSong?.id == song.id

                        PlaylistSongRowView(
                            song: song,
                            index: index,
                            totalCount: viewModel.filteredSongs.count,
                            isCurrentlyPlaying: isCurrentPlaying,
                            editMode: editMode,
                            isSelected: selectedSongs.contains(song.id),
                            isDownloadEnabled: featureFlags.isDownloadEnabled,
                            isDownloaded: downloadManager.isDownloaded(songId: song.id),
                            onTap: {
                                if editMode == .active {
                                    toggleSelection(song.id)
                                } else if let playlist = viewModel.playlist {
                                    playerVM.play(song: song, fromQueue: playlist.songs)
                                }
                            },
                            onPlayNext: { playerVM.playNext(song) },
                            onAddToQueue: { playerVM.addToQueue(song) },
                            canMove: playlist.isLocal && searchText.isEmpty,
                            onMoveUp: { Task { await viewModel.moveSong(song, direction: -1) } },
                            onMoveDown: { Task { await viewModel.moveSong(song, direction: 1) } },
                            canRemove: playlist.isLocal,
                            isRemoving: viewModel.isRemovingSongs,
                            onRemove: {
                                songsToRemove = [song.id]
                                showRemoveSongsConfirmation = true
                            },
                            onDownloadTap: {
                                if downloadManager.isDownloaded(songId: song.id) {
                                    downloadManager.removeDownload(songId: song.id)
                                } else {
                                    downloadManager.downloadSong(song)
                                }
                            }
                        )
                        .onAppear {
                            if searchText.isEmpty,
                                song.id == viewModel.filteredSongs.last?.id,
                                viewModel.hasMoreSongs
                            {
                                viewModel.loadMoreSongs()
                            }
                        }

                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            } else if viewModel.isLoading {
                VStack(spacing: Theme.Spacing.lg) {
                    ShimmerView(width: 280, height: 280, cornerRadius: Theme.CornerRadius.medium)
                    ShimmerView(width: 180, height: 22)
                    ShimmerView(width: 120, height: 16)
                }
                .padding(.top, Theme.Spacing.xxxl)
                .frame(maxWidth: .infinity)
            } else if let error = viewModel.error {
                ErrorStateView(error) {
                    viewModel.loadPlaylist(playlistId: playlistId)
                }
            }
        }
        .dockHidingOnScroll()
        .dockSafeBottom()
        .scrollIndicators(.visible)
        .trackScrollPhase()
        .refreshable {
            viewModel.loadPlaylist(playlistId: playlistId)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active && !selectedSongs.isEmpty {
                multiSelectToolbar
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Selection

    private var selectionHeader: some View {
        HStack {
            Text("\(selectedSongs.count) selected")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Button(
                selectedSongs.count == viewModel.filteredSongs.count
                    ? LocalizationManager.text("Deselect All") : LocalizationManager.text("Select All")
            ) {
                withAnimation(Theme.AnimationPresets.gentle) {
                    if selectedSongs.count == viewModel.filteredSongs.count {
                        selectedSongs.removeAll()
                    } else {
                        selectedSongs = Set(viewModel.filteredSongs.map(\.id))
                    }
                }
            }
            .font(Theme.Typography.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Colors.brandGradientStart)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func toggleSelection(_ id: String) {
        guard !viewModel.isRemovingSongs else { return }
        withAnimation(Theme.AnimationPresets.gentle) {
            if selectedSongs.contains(id) {
                selectedSongs.remove(id)
            } else {
                selectedSongs.insert(id)
            }
        }
    }

    // MARK: - Multi-Select Toolbar

    private var multiSelectToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.xl) {
                if viewModel.playlist?.isLocal == true {
                    Button {
                        songsToRemove = selectedSongs
                        showRemoveSongsConfirmation = true
                    } label: {
                        Label(viewModel.isRemovingSongs ? "正在移除…" : "移除歌曲", systemImage: "trash")
                    }
                    .tint(Theme.Colors.error)
                    .disabled(viewModel.isRemovingSongs)
                }

                if featureFlags.isDownloadEnabled {
                    Button {
                        let songsToDownload = viewModel.filteredSongs.filter {
                            selectedSongs.contains($0.id)
                                && !downloadManager.isDownloaded(songId: $0.id)
                        }
                        for song in songsToDownload {
                            downloadManager.downloadSong(song)
                        }
                        withAnimation(Theme.AnimationPresets.smooth) {
                            selectedSongs.removeAll()
                            editMode = .inactive
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(Theme.Colors.brandGradientStart)
                }
            }
            .font(Theme.Typography.subheadline.weight(.medium))
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
            .disabled(viewModel.isRemovingSongs)
        }
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Extracted Row View

private struct PlaylistSongRowView: View {
    let song: Song
    let index: Int
    let totalCount: Int
    let isCurrentlyPlaying: Bool
    let editMode: EditMode
    let isSelected: Bool
    let isDownloadEnabled: Bool
    let isDownloaded: Bool
    let onTap: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let canMove: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let canRemove: Bool
    let isRemoving: Bool
    let onRemove: () -> Void
    let onDownloadTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.md) {
                    if editMode == .active {
                        SelectionIndicator(isSelected: isSelected)
                    }

                    AsyncThumbnail(
                        url: song.thumbnailURL, size: 48, cornerRadius: Theme.CornerRadius.small)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                        Text(song.title)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(
                                isCurrentlyPlaying
                                    ? Theme.Colors.brandGradientStart : Theme.Colors.textPrimary
                            )
                            .lineLimit(1)
                        Text(song.artistName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(song.formattedDuration)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(Theme.Colors.textTertiary)

                    if editMode == .inactive {
                        Menu {
                            if canRemove {
                                Button(role: .destructive, action: onRemove) {
                                    Label("從此歌單移除", systemImage: "trash")
                                }
                                .disabled(isRemoving)
                            }
                            if canMove {
                                Button(action: onMoveUp) {
                                    Label("上移歌曲", systemImage: "arrow.up")
                                }
                                .disabled(index == 0)
                                Button(action: onMoveDown) {
                                    Label("下移歌曲", systemImage: "arrow.down")
                                }
                                .disabled(index == totalCount - 1)
                            }
                            Button {
                                onPlayNext()
                            } label: {
                                Label(
                                    "Play Next",
                                    systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button {
                                onAddToQueue()
                            } label: {
                                Label("Add to Queue", systemImage: "text.badge.plus")
                            }
                            if isDownloadEnabled {
                                Button(action: onDownloadTap) {
                                    if isDownloaded {
                                        Label("Remove Download", systemImage: "trash")
                                    } else {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                }
                            }
                            if let url = song.youtubeURL {
                                ShareLink(
                                    item: url,
                                    subject: Text(song.title),
                                    message: Text("🎵 \(song.title) - \(song.artistName)")
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            } else {
                                ShareLink(item: "🎵 \(song.title) - \(song.artistName)") {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("More options for \(song.title)")
                        .accessibilityIdentifier("playlist_song_menu_\(song.id)")
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
                .padding(.horizontal, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(song.title) by \(song.artistName)")
            .accessibilityHint(editMode == .active ? "Double tap to select" : "Double tap to play")
            .accessibilityIdentifier("playlist_song_row_\(song.id)")

            if index < totalCount - 1 {
                Rectangle()
                    .fill(Theme.Colors.divider)
                    .frame(height: 0.5)
                    .padding(
                        .leading,
                        (editMode == .active ? 28 + Theme.Spacing.md : 0) + 48 + Theme.Spacing.md
                            + Theme.Spacing.lg)
            }
        }
    }
}
