import SwiftUI
import UIKit

/// How an imported photo used as a reference sits over the live camera (Phil, 2026-11-08): moved, scaled, turned and
/// mirrored by hand to line it up with the set. Kept per reference on this phone.
struct PhotoPose: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var angle: Double = 0
    var flipped = false

    static func load(_ id: UUID) -> PhotoPose {
        guard let data = UserDefaults.standard.data(forKey: "photoPose.\(id.uuidString)"),
              let pose = try? JSONDecoder().decode(PhotoPose.self, from: data) else { return PhotoPose() }
        return pose
    }

    func save(_ id: UUID) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "photoPose.\(id.uuidString)") }
    }

    var isStraight: Bool { self == PhotoPose() }
}

extension View {
    /// The photo placed as `pose` says, inside a box of `size`.
    func posed(_ pose: PhotoPose) -> some View {
        scaleEffect(x: pose.flipped ? -pose.scale : pose.scale, y: pose.scale)
            .rotationEffect(.radians(pose.angle))
            .offset(x: pose.x, y: pose.y)
    }
}

/// The touch layer over an imported photo: one finger sideways sets the ghost strength (as everywhere in Reset), two
/// fingers move it, pinch scales, twist turns, and a double tap puts it back.
struct PhotoAdjustLayer: UIViewRepresentable {
    @Binding var pose: PhotoPose
    /// Ghost strength, 0 to 1, and a call with false when the finger lifts.
    @Binding var strength: Double
    var swiping: (Bool) -> Void
    var changed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        let one = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.swipe(_:)))
        one.maximumNumberOfTouches = 1
        let two = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.move(_:)))
        two.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let twist = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.twist(_:)))
        let reset = UITapGestureRecognizer(target: c, action: #selector(Coordinator.reset(_:)))
        reset.numberOfTapsRequired = 2
        for g in [one, two, pinch, twist, reset] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PhotoAdjustLayer
        private var startStrength: Double?

        init(_ parent: PhotoAdjustLayer) { self.parent = parent }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func swipe(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            switch g.state {
            case .began, .changed:
                if startStrength == nil {
                    guard abs(t.x) > abs(t.y) else { return }
                    startStrength = parent.strength
                }
                guard let start = startStrength else { return }
                parent.strength = min(1, max(0, start + Double(t.x / max(view.bounds.width, 1))))
                parent.swiping(true)
            default:
                startStrength = nil
                parent.swiping(false)
            }
        }

        @objc func move(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            parent.pose.x += t.x
            parent.pose.y += t.y
            if g.state == .ended { parent.changed() }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            parent.pose.scale = min(max(parent.pose.scale * g.scale, 0.2), 8)
            g.scale = 1
            if g.state == .ended { parent.changed() }
        }

        @objc func twist(_ g: UIRotationGestureRecognizer) {
            parent.pose.angle += Double(g.rotation)
            g.rotation = 0
            if g.state == .ended { parent.changed() }
        }

        @objc func reset(_ g: UITapGestureRecognizer) {
            parent.pose = PhotoPose()
            parent.changed()
        }
    }
}
