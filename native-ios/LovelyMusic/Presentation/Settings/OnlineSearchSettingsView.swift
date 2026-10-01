import SwiftUI

struct OnlineSearchSettingsView: View {
    @State private var key = ""
    @State private var hasOverride = false
    @State private var message: String?
    @State private var isError = false
    private let keyStore = YouTubeSearchKeyStore()

    var body: some View {
        Form {
            Section {
                Label(statusText, systemImage: isConfigured ? "checkmark.circle" : "key")
                    .foregroundStyle(Theme.Colors.brandGradient)
                    .accessibilityIdentifier("search_key_status")
                Text("用於搜尋 YouTube 的公開音樂資料。歌單同步使用另一組 Google 登入設定。")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Section {
                SecureField("YouTube Data API 金鑰", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("search_api_key")
                Button("儲存金鑰") { saveKey() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("search_api_key_save")
                if hasOverride {
                    Button("移除自訂金鑰", role: .destructive) {
                        do {
                            try keyStore.remove()
                            key = ""
                            hasOverride = false
                            isError = false
                            message = SecretsProvider.youtubeDataAPIKey.isEmpty
                                ? "已移除自訂金鑰；媒體庫搜尋仍可使用。"
                                : "已移除自訂金鑰，改用 EvanTube 內建搜尋。"
                        } catch { showError(error.localizedDescription) }
                    }
                }
                if let message {
                    Text(message)
                        .foregroundStyle(isError ? Theme.Colors.error : Theme.Colors.textSecondary)
                        .accessibilityIdentifier("search_api_key_message")
                }
            } header: {
                Text("自訂搜尋金鑰")
            } footer: {
                Text("自訂金鑰只儲存在這台裝置的安全鑰匙圈，不會隨 Google Drive 歌單同步。")
            }
            Section("建立自己的金鑰") {
                Link("開啟 Google Cloud", destination:
                    URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!)
                Link("YouTube API 設定說明", destination:
                    URL(string: "https://developers.google.com/youtube/v3/getting-started")!)
                Text("啟用 YouTube Data API v3，再建立 API 金鑰。將 API 限制為 YouTube Data API v3，iOS 軟體包 ID 設為 com.c63amg77771717.evantube。")
                    .font(.footnote)
                Text("使用同一組金鑰的裝置共用該專案的搜尋配額。此金鑰提供搜尋資料，播放可用性仍由音樂來源決定。")
                    .font(.footnote)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("線上搜尋")
        .task {
            do { hasOverride = !((try keyStore.read()) ?? "").isEmpty }
            catch { showError(error.localizedDescription) }
        }
    }

    private var isConfigured: Bool { hasOverride || !SecretsProvider.youtubeDataAPIKey.isEmpty }
    private var statusText: String {
        if hasOverride { return "已設定自訂搜尋金鑰" }
        return isConfigured ? "EvanTube 線上搜尋已啟用" : "尚未設定線上搜尋金鑰"
    }

    private func saveKey() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^AIza[A-Za-z0-9_-]{35}$", options: .regularExpression) != nil else {
            showError("請輸入有效的 Google API 金鑰（AIza 開頭），不是 OAuth Client ID。")
            return
        }
        do {
            try keyStore.save(value)
            hasOverride = true
            key = ""
            isError = false
            message = "已儲存，返回線上搜尋即可使用。"
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ text: String) {
        isError = true
        message = text
    }
}
