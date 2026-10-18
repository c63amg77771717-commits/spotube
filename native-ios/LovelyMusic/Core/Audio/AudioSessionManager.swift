import AVFoundation
import os

enum AudioSessionManager {
    static var onResume: (@MainActor @Sendable () -> Void)?
    static let mixWithOthersKey = "evantube.audio.mixWithOthers"

    static let systemPlayerPolicyKey = "evantube.audio.systemPlayerPolicy.v2"
    static var mixingEnabledByPreference: Bool { false }

    /// Migrate before category activation, including prior installations that
    /// explicitly stored true. Do not change any unrelated preference.
    static func migrateSystemPlayerPolicy(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: mixWithOthersKey) as? Bool != false {
            defaults.set(false, forKey: mixWithOthersKey)
        }
        if defaults.integer(forKey: systemPlayerPolicyKey) != 2 {
            defaults.set(2, forKey: systemPlayerPolicyKey)
        }
    }

    /// Configure the audio session category at app launch.
    ///
    /// Apple recommends configuring the category early but **activating lazily**
    /// (just before playback begins). Activating at launch with no audio to play
    /// leaves the session "active but silent", which can prevent iOS from binding
    /// the app as the current Now Playing app on first play (see F1 in
    /// `nowplaying-investigation.md`).
    @discardableResult
    static func setCategory() -> Bool {
        migrateSystemPlayerPolicy()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default,
                options: [])
            PlaybackDiagnostics.shared.record(.init(phase: .audioSessionConfigured,
                audioMixingEnabled: session.categoryOptions.contains(.mixWithOthers)))
            return true
        } catch {
            Log.audioSession.error("setCategory failed, code=\((error as NSError).code)")
            return false
        }
    }

    /// Activate the audio session immediately before `AVPlayer.rate = 1.0`.
    ///
    /// Category configuration does not activate the session. Return false on
    /// either configuration or activation failure so the engine keeps playback paused.
    @discardableResult
    static func activate() -> Bool {
        // Reapply the selected mixing policy after resets; activate only on play.
        // Headset controls and Now Playing are verified separately on a physical device.
        guard setCategory() else {
            PlaybackDiagnostics.shared.record(.init(phase: .audioSessionActivated, audioActivationSucceeded: false))
            return false
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            PlaybackDiagnostics.shared.record(.init(phase: .audioSessionActivated,
                audioMixingEnabled: AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers),
                audioActivationSucceeded: true))
            Log.audioSession.info("Audio session activated for playback")
            return true
        } catch {
            PlaybackDiagnostics.shared.record(.init(phase: .audioSessionActivated, audioActivationSucceeded: false))
            Log.audioSession.error("Activation failed, code=\((error as NSError).code)")
            return false
        }
    }

    static func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            break  // Handled by AudioEngine
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    onResume?()
                }
            }
        @unknown default:
            break
        }
    }
}
