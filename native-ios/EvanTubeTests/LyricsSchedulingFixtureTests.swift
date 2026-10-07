import Foundation
import XCTest
@testable import LovelyMusic

/// A reproducible scheduling experiment, not a production provider change.
final class LyricsSchedulingFixtureTests: XCTestCase {
    func testTwoIndependentFixtureStagesCompareSequentialAndBoundedParallelScheduling() async throws {
        let sequential = SchedulingActivity()
        let seqStart = ProcessInfo.processInfo.systemUptime
        let first = try await fixtureStage(0, activity: sequential)
        let second = try await fixtureStage(1, activity: sequential)
        let seqMs = (ProcessInfo.processInfo.systemUptime - seqStart) * 1000
        let parallel = SchedulingActivity()
        let parStart = ProcessInfo.processInfo.systemUptime
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 0..<2 { group.addTask { try await fixtureStage(id, activity: parallel) } }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values.sorted()
        }
        let parMs = (ProcessInfo.processInfo.systemUptime - parStart) * 1000
        XCTAssertEqual(values, [first, second])
        let seqPeak = await sequential.peak
        let parPeak = await parallel.peak
        XCTAssertEqual(seqPeak, 1)
        XCTAssertEqual(parPeak, 2)
        let evidence: [String: Any] = ["fixtureDelayMilliseconds": [100, 160], "stageCount": 2,
            "sequentialMilliseconds": seqMs, "boundedParallelMilliseconds": parMs,
            "parallelPeak": parPeak, "productionSchedulingChanged": false,
            "realSourceLookupSpeedupValidated": false, "UIRenderingMeasured": false]
        let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-bounded-scheduling-fixture"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testBoundedFixtureCancellationDrainsAllStages() async throws {
        let activity = SchedulingActivity()
        let task = Task {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for id in 0..<2 { group.addTask { try await fixtureStage(id, activity: activity) } }
                for try await _ in group { }
            }
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let active = await activity.active
        let peak = await activity.peak
        XCTAssertEqual(active, 0)
        XCTAssertLessThanOrEqual(peak, 2)
    }
}

private actor SchedulingActivity {
    private(set) var active = 0
    private(set) var peak = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

private func fixtureStage(_ id: Int, activity: SchedulingActivity) async throws -> Int {
    try Task.checkCancellation()
    await activity.begin()
    do {
        try await Task.sleep(nanoseconds: id == 0 ? 100_000_000 : 160_000_000)
        try Task.checkCancellation()
        await activity.end()
        return id
    } catch {
        await activity.end()
        throw error
    }
}
