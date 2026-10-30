import Foundation
import MetricKit

/// On-device note of background transitions, memory pressure, and MetricKit
/// diagnostics. Jetsam often leaves nothing in Analytics; the next launch can
/// still show what MetricKit delivered.
final class RuntimeDiagnosticLog: @unchecked Sendable {
    static let shared = RuntimeDiagnosticLog()
    static let capacity = 200

    private let lock = NSLock()
    private var lines: [String] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("EvanTube", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("RuntimeDiagnostics.log")
        }
        if let stored = try? String(contentsOf: self.fileURL, encoding: .utf8) {
            lines = stored.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count > Self.capacity {
                lines = Array(lines.suffix(Self.capacity))
            }
        }
    }

    func append(_ message: String) {
        let line = Self.format(message, at: Date())
        lock.lock()
        lines.append(line)
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
        let snapshot = lines.joined(separator: "\n")
        let destination = fileURL
        lock.unlock()
        try? Self.write(snapshot, to: destination)
    }

    func snapshot() -> [String] {
        lock.lock()
        let copy = lines
        lock.unlock()
        return copy
    }

    static func format(_ message: String, at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970)
        return "\(seconds) \(sanitize(message))"
    }

    static func sanitize(_ text: String) -> String {
        let pattern = "https?://\\S+"
        let value: String
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            value = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[url]")
        } else {
            value = text
        }
        if value.count > 1_600 {
            return String(value.prefix(1_600))
        }
        return value
    }

    private static func write(_ text: String, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(text.utf8).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

enum MetricKitDiagnosticSummary {
    static func payloadLine(crashCount: Int, cpuCount: Int, hangCount: Int, diskWriteCount: Int) -> String {
        "metrickit payload crashes=\(max(0, crashCount)) cpu=\(max(0, cpuCount)) hangs=\(max(0, hangCount)) disk=\(max(0, diskWriteCount))"
    }

    static func crashLine(exceptionType: Int?, exceptionCode: Int?, signal: Int?, terminationReason: String?) -> String {
        let reason = RuntimeDiagnosticLog.sanitize(terminationReason ?? "")
        return "metrickit crash type=\(exceptionType.map(String.init) ?? "-") code=\(exceptionCode.map(String.init) ?? "-") signal=\(signal.map(String.init) ?? "-") termination=\(reason)"
    }
}

/// Retained for the process lifetime. MetricKit delivers payloads on a later launch.
final class RuntimeDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = RuntimeDiagnostics()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        RuntimeDiagnosticLog.shared.append("metrickit subscriber started")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        RuntimeDiagnosticLog.shared.append("metrickit metrics count=\(payloads.count)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics ?? []
            let cpus = payload.cpuExceptionDiagnostics ?? []
            let hangs = payload.hangDiagnostics ?? []
            let disk = payload.diskWriteExceptionDiagnostics ?? []
            RuntimeDiagnosticLog.shared.append(
                MetricKitDiagnosticSummary.payloadLine(
                    crashCount: crashes.count,
                    cpuCount: cpus.count,
                    hangCount: hangs.count,
                    diskWriteCount: disk.count
                )
            )
            for crash in crashes {
                RuntimeDiagnosticLog.shared.append(
                    MetricKitDiagnosticSummary.crashLine(
                        exceptionType: crash.exceptionType?.intValue,
                        exceptionCode: crash.exceptionCode?.intValue,
                        signal: crash.signal?.intValue,
                        terminationReason: crash.terminationReason
                    )
                )
                if let tree = try? crash.callStackTree.jsonRepresentation() {
                    let text = String(decoding: tree, as: UTF8.self)
                    RuntimeDiagnosticLog.shared.append("metrickit crash-stacks \(text)")
                }
            }
            for cpu in cpus {
                RuntimeDiagnosticLog.shared.append(
                    "metrickit cpu total=\(cpu.totalCPUTime) sampled=\(cpu.totalSampledTime)"
                )
                if let tree = try? cpu.callStackTree.jsonRepresentation() {
                    RuntimeDiagnosticLog.shared.append(
                        "metrickit cpu-stacks \(String(decoding: tree, as: UTF8.self))"
                    )
                }
            }
            for hang in hangs {
                RuntimeDiagnosticLog.shared.append("metrickit hang \(hang.hangDuration)")
            }
        }
    }
}
