import UIKit

/// Keeps one bounded stall recovery runnable after the screen locks.
/// The expiration handler stops the work instead of spinning until jetsam.
@MainActor
final class PlaybackBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String, onExpire: @escaping @MainActor () -> Void) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let ending = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}
