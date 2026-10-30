import MediaPlayer

@MainActor
final class RemoteCommandManager {
    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onNext: (@MainActor () -> Void)?
    var onPrevious: (@MainActor () -> Void)?
    var onSeek: (@MainActor (TimeInterval) -> Void)?
    private var boundSession: MPNowPlayingSession?

    private var commandCenter: MPRemoteCommandCenter {
        boundSession?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
    }

    func bind(session: MPNowPlayingSession) {
        guard boundSession !== session else { return }
        tearDown()
        boundSession = session
        setup()
    }

    func setup() {
        let commandCenter = self.commandCenter

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
            MainActorRemoteCommand.run { self?.onPlay?() }
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            MainActorRemoteCommand.run { self?.onPause?() }
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            MainActorRemoteCommand.run { self?.onNext?() }
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            MainActorRemoteCommand.run { self?.onPrevious?() }
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return MainActorRemoteCommand.run { self?.onSeek?(position) }
        }

        // Track navigation is the lock-screen/control-center transport.
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }

    /// Removes all command center targets. Call on deallocation or when the
    /// manager is no longer needed to prevent leaked handler closures.
    func tearDown() {
        let commandCenter = self.commandCenter
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
    }
}

/// Headphone and lock-screen commands must change playback before the handler
/// returns. `Task { @MainActor }` waits behind UI work and feels late in the background.
enum MainActorRemoteCommand {
    @discardableResult
    static func run(_ action: (@MainActor () -> Void)?) -> MPRemoteCommandHandlerStatus {
        guard let action else { return .commandFailed }
        if Thread.isMainThread {
            MainActor.assumeIsolated(action)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(action)
            }
        }
        return .success
    }
}
