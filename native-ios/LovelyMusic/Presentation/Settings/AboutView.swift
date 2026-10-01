import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "版本 \(version)（\(build)）"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                VStack(spacing: Theme.Spacing.md) {
                    Image("LaunchLogo")
                        .resizable().scaledToFit()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .accessibilityHidden(true)
                    Image("EvanTubeLaunchWordmark")
                        .resizable().scaledToFit()
                        .frame(width: 230)
                        .accessibilityLabel("EvanTube")
                    Text("More Than Music")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(.white)
                    Text(version)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.lg)
                .background(Color(hex: "#080D15"),
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))

                Text("你的音樂，你的歌單。EvanTube 整合音樂探索、播放與歌單管理，讓喜歡的音樂陪你走過日常與深夜。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Label("製作者", systemImage: "person.crop.circle")
                        .foregroundStyle(Theme.Colors.brandGradient)
                    Text("Evan Liao")
                        .font(Theme.Typography.headline)
                        .accessibilityIdentifier("about_creator")
                    if let email = URL(string: "mailto:c63amg77771717@gmail.com") {
                        Link("c63amg77771717@gmail.com", destination: email)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.brandGradient)
                            .frame(minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("about_contact")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.lg)
                .background(Theme.Colors.surfaceCard,
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))

                VStack(spacing: 0) {
                    NavigationLink {
                        EvanTubeLegalView(document: .privacy)
                    } label: { documentRow("隱私權政策", icon: "lock.shield") }
                    .accessibilityIdentifier("about_privacy")
                    Divider()
                    NavigationLink {
                        EvanTubeLegalView(document: .terms)
                    } label: { documentRow("使用條款", icon: "doc.text") }
                    .accessibilityIdentifier("about_terms")
                    Divider()
                    NavigationLink {
                        EvanTubeCreditsView()
                    } label: { documentRow("授權與致謝", icon: "heart.text.square") }
                    .accessibilityIdentifier("about_credits")
                }
                .buttonStyle(.plain)
                .background(Theme.Colors.surfaceCard,
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))

                Text("自製內容由製作者保有權利；開源元件、音樂與第三方素材依各自授權使用。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("© 2026 Evan Liao · EvanTube")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .accessibilityIdentifier("about_footer")
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("關於 EvanTube")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain).accessibilityIdentifier("about_back")
            }
        }
    }

    private func documentRow(_ title: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(Theme.Colors.brandGradient)
                .frame(width: 28)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.Colors.textTertiary)
        }
        .font(Theme.Typography.body)
        .padding(Theme.Spacing.lg)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

private struct EvanTubeCreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("開源與設計參考").font(Theme.Typography.title2)
                    .foregroundStyle(Theme.Colors.brandGradient)
                Text("EvanTube 的原始碼基礎為 LovelyMusic，依 Apache License 2.0 使用。保留原專案著作權與授權聲明；修改與新增內容由 Evan Liao 維護。")
                externalLink("LovelyMusic 原專案", "https://github.com/iletai/LovelyMusic-iOS")
                NavigationLink {
                    ScrollView {
                        Text(verbatim: apacheLicense)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .padding(Theme.Spacing.lg)
                    }
                    .background(Theme.Colors.backgroundPrimary)
                    .dockSafeBottom()
                    .navigationTitle("Apache License 2.0")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Apache License 2.0（完整授權）", systemImage: "doc.text")
                        .frame(minHeight: 44, alignment: .leading)
                        .foregroundStyle(Theme.Colors.brandGradient)
                }
                .accessibilityIdentifier("credits_apache_license")
                Text("歌單與媒體庫操作的功能設計參考：Beans Music。")
                externalLink("Beans Music", "https://github.com/XIaodou0416/Beans-Music")

                Text("示範音樂").font(Theme.Typography.title2)
                    .foregroundStyle(Theme.Colors.brandGradient)
                Text("內建示範音樂由 Kevin MacLeod（incompetech.com）創作，依 Creative Commons Attribution 3.0 Unported（CC BY 3.0）授權使用。")
                externalLink("音樂來源 — Incompetech", "https://archive.org/details/Incompetech")
                externalLink("素材授權 — CC BY 3.0", "https://creativecommons.org/licenses/by/3.0/")
                externalLink("作曲者 — Kevin MacLeod", "https://incompetech.com")

                Text("第三方服務").font(Theme.Typography.title2)
                    .foregroundStyle(Theme.Colors.brandGradient)
                Text("本 App 使用 YouTube API Services；相關影片與音樂由 YouTube 提供，使用時適用 YouTube 服務條款及 Google 隱私權政策。其他音樂、歌詞、封面與元件的權利屬於各自權利人。EvanTube 與這些服務並無官方隸屬或背書關係。")
                externalLink("YouTube 服務條款", "https://www.youtube.com/t/terms")
                externalLink("Google 隱私權政策", "https://policies.google.com/privacy")
                Text("© 2026 Evan Liao · EvanTube").font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("授權與致謝")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { CustomBackButton(style: .plain) }
        }
    }

    private func externalLink(_ title: String, _ destination: String) -> some View {
        Group {
            if let url = URL(string: destination) {
                Link(destination: url) {
                    Label(title, systemImage: "arrow.up.right")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .foregroundStyle(Theme.Colors.brandGradient)
            }
        }
    }

    private var apacheLicense: String {
        guard let url = Bundle.main.url(forResource: "LovelyMusic-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "授權文件無法載入。請查看 LovelyMusic 原專案內的 LICENSE 文件。"
        }
        return text
    }
}
