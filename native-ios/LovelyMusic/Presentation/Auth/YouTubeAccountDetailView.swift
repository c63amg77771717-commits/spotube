import SwiftUI

/// The saved YouTube session is separate from Google Drive OAuth.
/// Showing this screen does not touch cookies or change the existing login.
struct YouTubeAccountDetailView: View {
    let authManager: YouTubeAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogin = false
    @State private var showingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube 帳號") {
                    LabeledContent("名稱", value: authManager.accountName ?? "YouTube User")
                    LabeledContent("工作階段",
                                   value: authManager.isLoggedIn ? "已儲存登入資訊" : "尚未登入")
                    Text("此狀態只代表裝置已保存 YouTube 登入資訊，不保證雲端帳號目前有效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("重新登入 YouTube", systemImage: "arrow.clockwise") {
                        showingLogin = true
                    }
                    .accessibilityIdentifier("account_reauthenticate")
                    if authManager.isLoggedIn {
                        Button("登出 YouTube", systemImage: "rectangle.portrait.and.arrow.right",
                               role: .destructive) {
                            showingSignOut = true
                        }
                        .accessibilityIdentifier("account_sign_out")
                    }
                }
            }
            .navigationTitle("YouTube 帳號")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("account_details_done")
                }
            }
            .sheet(isPresented: $showingLogin) {
                YouTubeLoginView(authManager: authManager) {}
            }
            .confirmationDialog("確定登出 YouTube？", isPresented: $showingSignOut) {
                Button("登出", role: .destructive) {
                    authManager.logout()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("將清除本機 YouTube 登入資訊；不影響 Google Drive 同步帳號。")
            }
        }
    }
}
