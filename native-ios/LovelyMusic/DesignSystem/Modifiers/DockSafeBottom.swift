import SwiftUI

// MARK: - DockSafeBottom

private struct DockBottomInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var dockBottomInset: CGFloat {
        get { self[DockBottomInsetKey.self] }
        set { self[DockBottomInsetKey.self] = newValue }
    }
}

/// Scroll margins survive navigation pushes and let the final row clear the measured dock.
struct DockSafeBottomModifier: ViewModifier {
    @Environment(\.dockBottomInset) private var dockBottomInset

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, dockBottomInset + Theme.Spacing.lg, for: .scrollContent)
    }
}

extension View {
    /// Apply once to each page's outer scroll view.
    func dockSafeBottom() -> some View {
        modifier(DockSafeBottomModifier())
    }
}
