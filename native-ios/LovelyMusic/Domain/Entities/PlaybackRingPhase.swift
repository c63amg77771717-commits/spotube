import Foundation

struct PlaybackRingPhase {
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    mutating func setPlaying(_ playing: Bool, at time: TimeInterval) {
        if playing {
            if startedAt == nil { startedAt = time }
        } else if let start = startedAt {
            accumulated += max(0, time - start)
            startedAt = nil
        }
    }

    func degrees(at time: TimeInterval) -> Double {
        let elapsed = accumulated + (startedAt.map { max(0, time - $0) } ?? 0)
        return elapsed.truncatingRemainder(dividingBy: 5) * 72
    }
}
