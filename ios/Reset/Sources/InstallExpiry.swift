import Foundation

/// A sideloaded app stops opening when its free Apple ID signature runs out (7 days). The signature's
/// end date is in the app's own provisioning profile, so the app can warn before it happens
/// (Phil, 2026-11-05). Apps from TestFlight or the App Store have no such profile, so nothing shows.
enum InstallExpiry {
    static var expires: Date? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        return object["ExpirationDate"] as? Date
    }

    /// Words for the warning when the install ends within two days, or has just ended; nil otherwise.
    static var warning: String? {
        guard let date = expires else { return nil }
        let hours = date.timeIntervalSinceNow / 3600
        guard hours < 48 else { return nil }
        if hours <= 0 { return "This install has expired: open Sideloadly and install it again (your references are kept)." }
        let left = hours < 24 ? "\(Int(hours.rounded(.up))) hours" : "2 days"
        return "This install runs out in \(left). Connect to Sideloadly and install again to keep using it. References are kept."
    }
}
