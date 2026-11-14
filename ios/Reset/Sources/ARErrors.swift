import ARKit
import Foundation

enum ARErrors {
    /// A plain explanation of why the camera session stopped, with what to do about it.
    static func message(for error: Error) -> String {
        guard let error = error as? ARError else {
            return "The camera stopped: \(error.localizedDescription). Go back and try again."
        }
        switch error.code {
        case .cameraUnauthorized:
            return "Camera access is off. Turn it on in Settings, Reset, Camera, then come back."
        case .unsupportedConfiguration:
            return "This device does not support the AR features Reset needs."
        case .sensorUnavailable, .sensorFailed:
            return "The camera is not available right now. Close other camera apps and try again."
        case .worldTrackingFailed:
            return "Tracking failed. Go back and open the reference again, starting where it was recorded."
        case .invalidWorldMap:
            return "This reference's room map could not be read. Record the setup again."
        default:
            return "The camera stopped: \(error.localizedDescription). Go back and try again."
        }
    }
}
