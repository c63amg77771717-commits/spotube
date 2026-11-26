import Foundation
import Observation

/// Lock-screen flag for display links. Scene phase can stay active on iOS 26
/// while the process is already backgrounded; the engine sets this directly.
@MainActor
@Observable
final class PlaybackInterfaceGate {
    static let shared = PlaybackInterfaceGate()
    private(set) var suspended = false

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
    }
}
