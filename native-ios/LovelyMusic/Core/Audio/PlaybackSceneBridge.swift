import Foundation

/// Forwards UIKit scene callbacks to the live engine without creating a second one.
/// The first engine to attach wins so unit tests cannot replace the app's engine.
@MainActor
final class PlaybackSceneBridge {
    static let shared = PlaybackSceneBridge()
    private weak var engine: AudioEngine?

    func attach(_ engine: AudioEngine) {
        if self.engine == nil {
            self.engine = engine
        }
    }

    func didEnterBackground() {
        engine?.applicationDidEnterBackground()
    }

    func didBecomeActive() {
        engine?.applicationDidBecomeActive()
    }

    func didReceiveMemoryWarning() {
        engine?.applicationDidReceiveMemoryWarning()
    }
}
