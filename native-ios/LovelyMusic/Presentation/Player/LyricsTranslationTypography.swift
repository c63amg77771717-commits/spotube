import SwiftUI

/// Translated lyric lines used to sit at caption size under a title-sized
/// original. Each preference is at least two Dynamic Type steps larger.
enum LyricsTranslationTypography {
    /// caption2 = 0, caption = 1, subheadline = 2, body = 3, title3 = 4, title2 = 5.
    static func rank(for preference: LyricsFontSize) -> Int {
        switch preference {
        case .small: return 3
        case .medium: return 4
        case .large: return 5
        }
    }

    static func previousCaptionRank(for preference: LyricsFontSize) -> Int {
        switch preference {
        case .small: return 0
        case .medium: return 1
        case .large: return 2
        }
    }

    static func font(for preference: LyricsFontSize) -> Font {
        switch preference {
        case .small: Theme.Typography.body
        case .medium: Theme.Typography.title3
        case .large: Theme.Typography.title2
        }
    }
}
