import SwiftUI

struct ReplacementSourceSearchSheet: View {
    @Bindable var model: ReplacementSourceSearchModel
    let onSelect: (PlaybackSourceCandidate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pending: PlaybackSourceCandidate?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.original.title).font(Theme.Typography.headline)
                    Text(model.original.artistName).foregroundStyle(Theme.Colors.textSecondary)
                    TextField("歌手與歌名", text: $model.query)
                        .submitLabel(.search)
                        .onSubmit { Task { await model.search() } }
                    Button("搜尋替代來源") { Task { await model.search() } }
                        .disabled(model.isLoading || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("只搜尋目前這首歌曲。歌單中的歌名與歌手保持不變，來源需由你確認。")
                }
                if model.isLoading { ProgressView("搜尋中") }
                if let message = model.errorMessage { Text(message).foregroundStyle(Theme.Colors.textSecondary) }
                Section("選擇播放來源") {
                    ForEach(model.candidates) { candidate in
                        Button { pending = candidate } label: {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(candidate.song.title).foregroundStyle(Theme.Colors.textPrimary)
                                Text(candidate.song.artistName).foregroundStyle(Theme.Colors.textSecondary)
                                Text(candidate.match.label).font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if !model.isLoading && model.errorMessage == nil && model.candidates.isEmpty {
                        Text("沒有可確認的來源，請調整歌手與歌名後再搜尋。")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.backgroundPrimary)
            .navigationTitle("替代播放來源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.cancel(); dismiss() }
                }
            }
            .task { await model.search() }
            .onDisappear { model.cancel() }
            .alert("確認播放來源", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("使用此來源") {
                    if let candidate = pending, model.contains(candidate) { onSelect(candidate) }
                    pending = nil
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                if let candidate = pending {
                    Text("\(candidate.song.title)\n\(candidate.song.artistName)\n\(candidate.match.label)\n可隨時恢復原來源。")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
