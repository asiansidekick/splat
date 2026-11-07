import Foundation
import UIKit

/// A small on-device log of what the app did (sessions, tracking, saves, errors), so a test day's
/// problems can be sent back from the app without a computer. Nothing leaves the device unless
/// the person shares it.
enum Diagnostics {
    static let maxBytes = 512 * 1024

    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Reset log.txt")
    }

    private static let queue = DispatchQueue(label: "diagnostics")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            trimIfNeeded()
        }
    }

    /// Keeps the newest half once the log passes the size limit.
    private static func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
            size > maxBytes, let data = try? Data(contentsOf: url)
        else { return }
        try? data.suffix(maxBytes / 2).write(to: url, options: .atomic)
    }

    /// Called once at launch: device, system and storage, so every report says what it ran on.
    @MainActor static func logLaunch() {
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        log("Launch: Reset \(version) (\(build)), \(model()), \(device.systemName) \(device.systemVersion), "
            + "LiDAR \(Recorder.lidarAvailable ? "yes" : "no"), \(free / 1_000_000) MB free, "
            + "\(ReferenceStore.all().count) references")
    }

    /// The hardware identifier, for example iPhone15,3.
    static func model() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// A copy of the log with a header, ready to share.
    @MainActor static func reportURL() -> URL {
        let header = "Reset feedback report\nDevice: \(model()), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\n"
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "(log is empty)"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Reset feedback.txt")
        try? (header + body).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
