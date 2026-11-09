import CoreMotion
import Foundation

/// The phone's gravity, a few times a second, for the pitch and roll guides.
@MainActor
final class Motion {
    static let shared = Motion()

    private let manager = CMMotionManager()
    private var gravity: (x: Double, y: Double, z: Double)?
    private var users = 0

    func start() {
        users += 1
        guard users == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            // A light smoothing, so a shaky hand doesn't make the guide twitch.
            if let old = self?.gravity {
                let k = 0.4
                self?.gravity = (old.x + (g.x - old.x) * k, old.y + (g.y - old.y) * k, old.z + (g.z - old.z) * k)
            } else {
                self?.gravity = (g.x, g.y, g.z)
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        manager.stopDeviceMotionUpdates()
        gravity = nil
    }

    func attitude(uprightAngle: Double, front: Bool) -> Attitude? {
        guard let gravity else { return nil }
        return Attitude.from(gravity: gravity, uprightAngle: uprightAngle, front: front)
    }
}
