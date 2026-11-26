import SwiftUI

/// Translated lyric lines used to sit at caption size under a title-sized
/// original. Each preference is one step larger than the previous translation
/// size, and at least two Dynamic Type steps above the old caption.
enum LyricsTranslationTypography {
    /// caption2 = 0, caption = 1, subheadline = 2, body = 3, title3 = 4, title2 = 5, title = 6.
    static func rank(for preference: LyricsFontSize) -> Int {
        switch preference {
        case .small: return 4
        case .medium: return 5
        case .large: return 6
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
        case .small: Theme.Typography.title3
        case .medium: Theme.Typography.title2
        case .large: Theme.Typography.title
        }
    }
}
