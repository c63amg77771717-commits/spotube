import SwiftUI
import UniformTypeIdentifiers

struct MB3ImportView: View {
    let viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var document: MB3ImportDocument?
    @State private var selected: Set<String> = []
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("將 MB3 匯出的 ZIP 歌單加入媒體庫。可播放的 YouTube 歌曲會保留原始順序；缺少有效歌曲 ID 的項目會列為略過。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("選取 MB3 ZIP", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.brandGradientStart)

                    if let document {
                        HStack {
                            Text("\(document.playlists.count) 份歌單 · \(document.rowCount) 首來源歌曲")
                                .font(.headline)
                            Spacer()
                            Button(selected.count == document.playlists.count ? "取消全選" : "全選") {
                                selected = selected.count == document.playlists.count
                                    ? [] : Set(document.playlists.map(\.id))
                            }
                        }
                        Text("已有同名歌單會合併；同一首歌不會重複加入。確認後才會寫入媒體庫。")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)

                        ForEach(document.playlists) { playlist in
                            Button {
                                if !selected.insert(playlist.id).inserted {
                                    selected.remove(playlist.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(playlist.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(Theme.Colors.brandGradientStart)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .foregroundStyle(Theme.Colors.textPrimary)
                                        Text("可匯入 \(playlist.songs.count) 首 · 略過 \(playlist.skipped) 首")
                                            .font(.caption)
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(Theme.Colors.backgroundSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            importSelected()
                        } label: {
                            if isImporting {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("確認匯入所選歌單")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Colors.brandGradientStart)
                        .disabled(isImporting || selected.isEmpty)
                    }

                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Colors.backgroundSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
            }
            .background(Theme.Colors.backgroundPrimary)
            .navigationTitle("匯入 MB3 歌單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    document = try MB3PlaylistImporter.parse(zipURL: url)
                    selected = Set(document?.playlists.filter { !$0.songs.isEmpty }.map(\.id) ?? [])
                    message = nil
                } catch {
                    document = nil
                    selected = []
                    message = error.localizedDescription
                }
            }
        }
    }

    private func importSelected() {
        guard let document else { return }
        let chosen = document.playlists.filter { selected.contains($0.id) }
        isImporting = true
        message = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let result = try await viewModel.importMB3(chosen)
                message = "已建立 \(result.created) 份歌單、加入 \(result.added) 首；重複 \(result.duplicates) 首、略過 \(result.skipped) 首。"
            } catch {
                await viewModel.loadLibrary()
                message = "匯入中斷：\(error.localizedDescription)。已寫入的歌曲保留，可重新匯入繼續。"
            }
        }
    }
}
