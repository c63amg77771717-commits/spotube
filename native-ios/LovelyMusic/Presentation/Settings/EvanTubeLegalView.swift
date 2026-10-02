import SwiftUI

struct EvanTubeLegalDocument {
    let title: String
    let identifier: String
    let intro: String
    let summary: String
    let sections: [(title: String, body: String)]
    let references: [(title: String, url: String)]

    static let privacy = Self(
        title: "隱私權政策",
        identifier: "privacy",
        intro: "本政策說明 EvanTube 如何處理資料。製作者為 Evan Liao，聯絡信箱為 c63amg77771717@gmail.com。生效日期：2026 年 10 月 2 日。",
        summary: "本機資料由你管理 · Drive 同步由你選擇 · 不販售個人資料",
        sections: [
            ("1. 本機資料", "EvanTube 的本機歌單、歌曲資訊、近期播放與搜尋紀錄、播放偏好、自訂封面及快取保存在你的裝置，用於播放、管理歌單及個人化推薦。透過第三方帳號管理的資料，另由該平台處理。為協助排查播放故障，另在本機保留最近 100 筆診斷事件，包含時間、歌曲識別碼、播放路徑、回應狀態、錯誤分類及是否帶入認證資訊。診斷不包含密碼、Cookie、授權權杖、API 金鑰或音訊網址，不隨歌單同步、不自動上傳，並排除在 App 系統備份之外。你可在「播放診斷」中清除或匯出，再自行選擇保存或分享；已匯出至其他位置的副本需自行刪除。"),
            ("2. 線上請求", "使用搜尋、排行、推薦、歌詞或串流時，相關音樂服務可能收到搜尋字詞、歌曲或歌手識別碼、地區及必要連線資訊，例如 IP 位址。EvanTube 不會因此將整份本機聆聽紀錄自動上傳給製作者。"),
            ("3. 登入資料", "使用 Google 或 YouTube 登入時，EvanTube 可能使用帳號識別資料、授權憑證或登入工作階段，以提供你選擇的功能。我們不要求你把 Google 帳號密碼交給製作者。登入憑證使用 iOS 鑰匙圈或登入服務提供的儲存機制管理。"),
            ("4. Google Drive 歌單同步", "只有你登入並啟用同步後，EvanTube 才讀寫 Drive 中的應用程式專用資料。同步內容包含歌單與歌曲資訊、排序、變更及刪除紀錄，以及用於合併版本的隨機同步識別碼與變更序號；目前不包含音訊檔或自行選取的封面照片。此權限不授予 EvanTube 任意讀取你的其他 Drive 檔案。"),
            ("5. 照片與權限", "選取歌單封面時，只使用你透過系統選擇器選定的照片，並保存在本機。與功能無關的相片、麥克風或位置資料，不在 EvanTube 的蒐集範圍。新增需要權限的功能時，會先說明用途並請你授權。 若你允許推播通知，且此版本已設定通知服務，EvanTube 會將通知權杖、語言、App 與 iOS 版本傳送至通知服務以提供通知；通知權杖也保存在本機。你可在 iOS 設定中關閉通知。"),
            ("6. 廣告與資料分享", "EvanTube 不投放 App 內廣告、不使用廣告追蹤，已移除原版廣告 SDK。我們不販售個人資料，也不將本機歌單或聆聽紀錄提供給廣告商。你選擇使用的第三方服務仍依各自政策處理必要資料。"),
            ("7. 保存、刪除與撤回授權", "本機資料保存至你刪除、清除或移除相關資料。你可刪除歌單、清除紀錄與快取、移除自訂封面，以及登出或停用同步。登出或刪除 App 不會自動刪除 Drive 雲端副本；Google 授權與雲端資料需另由 Google 帳戶及 Drive 管理。"),
            ("8. 第三方服務", "Google／YouTube、Google Drive、Apple／iTunes 音樂資料及其他你使用的音樂或歌詞來源，適用各自的隱私政策。EvanTube 與 Google、YouTube、Apple 並無官方隸屬或背書關係。"),
            ("9. 更新與聯絡", "政策變更會更新日期與說明；涉及新的資料用途時，會在必要時另取得同意。若需協助管理 EvanTube 相關資料，請聯絡 Evan Liao：c63amg77771717@gmail.com。第三方帳號資料請另使用該服務提供的管理方式。"),
        ],
        references: [
            ("Google 隱私權政策", "https://policies.google.com/privacy"),
            ("Google 帳戶授權管理", "https://myaccount.google.com/permissions"),
            ("Google Drive 應用程式資料說明", "https://developers.google.com/workspace/drive/api/guides/appdata"),
        ]
    )

    static let terms = Self(
        title: "使用條款",
        identifier: "terms",
        intro: "本條款適用於 EvanTube，由 Evan Liao 製作與維護。生效日期：2026 年 10 月 1 日。",
        summary: "免費使用 · 尊重音樂與授權 · 重要歌單保留備份",
        sections: [
            ("1. 使用範圍", "EvanTube 提供個人音樂播放、探索、歌單管理與可選的雲端同步。使用時應符合適用法律、內容授權及來源平台的規範；使用第三方帳號時，仍適用該服務的條款與年齡要求。"),
            ("2. 費用與第三方條件", "EvanTube 目前不設付費升級或訂閱。第三方服務的登入、地區、內容授權或其他使用條件仍由該服務決定，EvanTube 不保證能解除這些條件。"),
            ("3. 音樂與影片權利", "歌曲、影片、歌詞及專輯封面的權利屬於各自權利人。使用 EvanTube 不會取得重新散布或商業利用的授權。下載與離線功能只適用於你有權保存、且來源明確允許保存的內容。"),
            ("4. 歌單與自訂封面", "請確認匯入歌單與選取封面的用途具有必要權限。同步可能因網路、帳號或服務變更而延遲或失敗，請為重要歌單保留備份；EvanTube 不應作為唯一的備份方式。"),
            ("5. 合理使用", "請勿利用 EvanTube 侵害他人權利、繞過存取限制、干擾服務，或從事違法活動。Google、YouTube 與其他內容來源的帳號或內容限制，依各平台規範處理。"),
            ("6. 開源與第三方授權", "EvanTube 的自製品牌與新增內容由製作者管理。LovelyMusic 等開源程式碼及第三方元件仍依各自授權使用，本條款不減少原授權賦予的權利。授權文字、原作者聲明與必要的素材致謝會保留。"),
            ("7. 服務可用性與責任", "我們會盡力維護 EvanTube，但無法保證每首歌曲均可播放、線上內容永久可用，或服務完全不中斷。第三方服務可能變更、限制或停止。依法不得排除的使用者權利及責任，不因本條款受到排除。"),
            ("8. 更新與聯絡", "條款調整會標示更新日期；重大變更會在 App 中說明。若不願使用變更後的服務，可停止相關功能或使用。問題請聯絡 Evan Liao：c63amg77771717@gmail.com。"),
        ],
        references: [
            ("YouTube 服務條款", "https://www.youtube.com/t/terms"),
            ("Google 隱私權政策", "https://policies.google.com/privacy"),
        ]
    )
}

struct EvanTubeLegalView: View {
    let document: EvanTubeLegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("EvanTube")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.brandGradient)
                Text(document.summary)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(document.intro)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(document.sections.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(document.sections[index].title)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.brandGradient)
                        Text(document.sections[index].body)
                            .font(Theme.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.lg)
                    .background(Theme.Colors.surfaceCard,
                                in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
                }

                Text("相關服務")
                    .font(Theme.Typography.headline)
                ForEach(document.references.indices, id: \.self) { index in
                    if let url = URL(string: document.references[index].url) {
                        Link(destination: url) {
                            Label(document.references[index].title, systemImage: "arrow.up.right")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .foregroundStyle(Theme.Colors.brandGradient)
                    }
                }
                if let email = URL(string: "mailto:c63amg77771717@gmail.com") {
                    Link("聯絡 Evan Liao", destination: email)
                        .frame(minHeight: 44)
                        .foregroundStyle(Theme.Colors.brandGradient)
                }
                Text("© 2026 Evan Liao · EvanTube")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .accessibilityIdentifier("legal_footer")
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .accessibilityIdentifier("legal_" + document.identifier)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
                    .accessibilityIdentifier("legal_back")
            }
        }
    }
}
