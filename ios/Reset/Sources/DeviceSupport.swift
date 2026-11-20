import Foundation

/// Phil, 2026-11-18 (before Reset goes on an iPad Pro): when a device lacks the hardware or system a feature needs,
/// the feature says so politely instead of hiding or failing.
enum DeviceSupport {
    static func apology(_ feature: String) -> String {
        "Sorry, Reset doesn't support \(feature) on this device."
    }
}
