import MediaPlayer

@MainActor
final class RemoteCommandManager {
    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onNext: (@MainActor () -> Void)?
    var onPrevious: (@MainActor () -> Void)?
    var onSeek: (@MainActor (TimeInterval) -> Void)?

    func setup() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any previously registered targets to prevent accumulation
        // when setup() is called multiple times.
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPlay?()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPause?()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onNext?()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPrevious?()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                if let event = event as? MPChangePlaybackPositionCommandEvent {
                    self?.onSeek?(event.positionTime)
                }
            }
            return .success
        }

        // Track navigation is the lock-screen/control-center transport.
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }

    /// Removes all command center targets. Call on deallocation or when the
    /// manager is no longer needed to prevent leaked handler closures.
    func tearDown() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
    }
}
