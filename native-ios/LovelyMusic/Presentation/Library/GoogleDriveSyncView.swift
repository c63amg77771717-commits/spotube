import GoogleSignInSwift
import SwiftUI

struct GoogleDriveSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sync = GoogleDrivePlaylistSync.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("跨裝置歌單", systemImage: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(Theme.Colors.brandGradient)
                    Text("同步 EvanTube 與匯入歌單。使用相同 Google 帳號，即可在不同 iOS 裝置更新歌單。")
                    Text("同步內容包含歌單名稱、歌曲順序與增刪紀錄，不會上傳音樂檔案。離線修改會在 App 重新連線後同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Google 帳號") {
                    if let email = sync.email {
                        Text(email).textSelection(.enabled)
                        if sync.isEnabled {
                            Label("已開啟同步", systemImage: "checkmark.circle.fill")
                            Button("立即同步") { Task { await sync.sync() } }
                                .disabled(sync.isBusy)
                        } else {
                            Text("按下開始後，這台裝置的歌單會與此帳號的雲端歌單合併。")
                                .font(.footnote)
                            Button("開始與此帳號同步") { Task { await sync.activate() } }
                                .disabled(sync.isBusy)
                        }
                        Button("中斷連線", role: .destructive) { sync.disconnect() }
                    } else {
                        GoogleSignInButton { Task { await sync.signIn() } }
                            .disabled(sync.isBusy)
                    }
                }
                Section("同步狀態") {
                    if sync.isBusy { ProgressView("正在處理…") }
                    if let date = sync.lastSync {
                        LabeledContent("最後成功同步", value: date.formatted(date: .abbreviated, time: .shortened))
                    } else { Text("尚未完成同步").foregroundStyle(.secondary) }
                    if let error = sync.message {
                        Text(error).foregroundStyle(.red)
                        Text("本機歌單仍可使用；恢復連線後可重新同步。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.backgroundPrimary)
            .navigationTitle("Google Drive 同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await sync.restore() }
        }
        .preferredColorScheme(.dark)
    }
}
