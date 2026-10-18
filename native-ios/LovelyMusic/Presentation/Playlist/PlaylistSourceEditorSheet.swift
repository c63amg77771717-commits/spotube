import SwiftUI

/// A playlist-row action; unlike playback-error source replacement it does
/// not require this recording to be selected or broken.
struct PlaylistSourceEditorSheet: View {
    @Bindable var editor: PlaylistSourceEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingConfirmation: PlaybackSourceCandidate?

    var body: some View {
        NavigationStack {
            List {
                Section("原歌曲（歌單名稱不變）") {
                    Text(editor.original.title)
                        .font(Theme.Typography.headline)
                    Text(editor.original.artistName)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Section {
                    TextField("搜尋同一首歌的其他來源", text: $editor.query)
                        .submitLabel(.search)
                        .onSubmit { Task { await editor.search() } }
                        .accessibilityIdentifier("playlist_source_query")
                    Button("搜尋來源") { Task { await editor.search() } }
                        .disabled(editor.isSearching || editor.isCommitting ||
                                  editor.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("搜尋時不會暫停目前音樂；按試聽才暫停原曲。每個來源必須試聽後由你確認。")
                }
                if editor.isSearching { ProgressView("搜尋中") }
                if let error = editor.errorMessage {
                    Text(error).foregroundStyle(Theme.Colors.textSecondary)
                        .accessibilityIdentifier("playlist_source_error")
                }
                Section("候選播放來源") {
                    ForEach(editor.candidates) { candidate in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(candidate.song.title)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .font(Theme.Typography.headline)
                            Text(candidate.song.artistName)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            HStack(spacing: Theme.Spacing.sm) {
                                Text(candidate.song.formattedDuration)
                                Text(candidate.match.label)
                            }
                            .font(Theme.Typography.caption)
                            .foregroundStyle(candidate.match == .differentVersion
                                ? Theme.Colors.brandGradientStart : Theme.Colors.textSecondary)
                            HStack {
                                Button {
                                    Task { await editor.preview(candidate) }
                                } label: {
                                    Label(editor.wasPreviewed(candidate) ? "重新試聽" : "試聽",
                                          systemImage: "play.circle")
                                }
                                .accessibilityIdentifier("playlist_source_preview_" + candidate.id)
                                .disabled(editor.isPreviewing || editor.isCommitting)

                                Spacer()
                                if editor.wasPreviewed(candidate) {
                                    Button("使用此來源") {
                                        pendingConfirmation = candidate
                                    }
                                    .accessibilityIdentifier("playlist_source_confirm_" + candidate.id)
                                    .disabled(editor.isCommitting)
                                } else {
                                    Text(editor.isPreviewing ? "試聽驗證中" : "需先試聽")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    if !editor.isSearching && editor.candidates.isEmpty &&
                       editor.errorMessage == nil {
                        Text("找不到能確認的來源，請調整關鍵字。")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.backgroundPrimary)
            .navigationTitle("更換歌單播放來源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editor.cancel(); dismiss() }
                }
            }
            .task { await editor.search() }
            .onDisappear { editor.cancel() }
            .onChange(of: editor.didFinish) { _, finished in
                if finished { dismiss() }
            }
            .confirmationDialog("確認替換歌單來源",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }),
                titleVisibility: .visible) {
                Button("確認使用此來源") {
                    guard let candidate = pendingConfirmation else { return }
                    pendingConfirmation = nil
                    Task { _ = await editor.confirm(candidate) }
                }
                Button("取消", role: .cancel) { pendingConfirmation = nil }
            } message: {
                if let candidate = pendingConfirmation {
                    Text(candidate.match == .differentVersion
                         ? "此為不同錄音版本（可能為現場／混音／翻唱），確認要在目前歌單使用？"
                         : "只替換此歌單的音源，保留原歌曲資訊與排序；可隨時恢復。")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
