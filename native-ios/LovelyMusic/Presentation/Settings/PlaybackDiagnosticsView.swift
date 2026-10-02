import SwiftUI
import UIKit

struct PlaybackDiagnosticsView: View {
    @State private var showClearConfirmation = false
    @State private var showClearError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("發生無法播放時，請立即匯出診斷；成功播放後也可匯出，方便比對。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                SettingsGroup(header: "播放診斷", footer: "最多保留最近 100 筆事件，重新開啟 App 後仍可匯出。") {
                    PlaybackDiagnosticsExportButton()
                    SettingsDivider()
                    Button {
                        showClearConfirmation = true
                    } label: {
                        Label("清除診斷紀錄", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                    .foregroundStyle(Theme.Colors.error)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("playback_diagnostic_clear")
                }
                Text("紀錄包含事件時間、歌曲識別碼、播放路徑、回應狀態、隨機與重複模式、佇列來源，以及是否帶入認證資訊。錯誤以分類保存，不記錄密碼、Cookie、權杖、API 金鑰或音訊網址。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text("紀錄只儲存在這台裝置，不會隨歌單同步或自動上傳。匯出後由你選擇保存或分享。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("播放診斷")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { ToolbarItem(placement: .topBarLeading) { CustomBackButton(style: .plain) } }
        .confirmationDialog("清除本機保留的播放診斷紀錄？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                do { try PlaybackDiagnostics.shared.clear() }
                catch { showClearError = true }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("無法清除診斷紀錄", isPresented: $showClearError) {
            Button("確定", role: .cancel) { }
        }
    }
}

struct PlaybackDiagnosticsExportButton: View {
    private struct ReportFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
    @State private var report: ReportFile?
    @State private var showExportError = false

    var body: some View {
        Button {
            do { report = ReportFile(url: try PlaybackDiagnostics.shared.exportReport()) }
            catch { showExportError = true }
        } label: {
            Label("匯出播放診斷", systemImage: "square.and.arrow.up")
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.brandGradient)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playback_diagnostic_export")
        .sheet(item: $report, onDismiss: { try? PlaybackDiagnostics.shared.discardExport() }) {
            file in PlaybackDiagnosticShareSheet(url: file.url)
        }
        .alert("無法匯出播放診斷", isPresented: $showExportError) {
            Button("確定", role: .cancel) { }
        } message: { Text("請稍後重試。") }
    }
}

private struct PlaybackDiagnosticShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? PlaybackDiagnostics.shared.discardExport()
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
