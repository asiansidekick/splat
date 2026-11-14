import ARKit
import SwiftUI

/// Phil, 2026-11-08: inside Reset ARKit found no surfaces at all (0 planes, the room map fine), while Apple's
/// Measure found them on the same phone and table. This runs ARKit on its own, with nothing else of Reset's
/// attached, in two steps (plain, then with LiDAR depth as Reset asks), and logs how many surfaces each finds.
@MainActor
final class SurfaceTest: ObservableObject {
    let session = ARSession()
    @Published private(set) var status = "Point at the table and move the phone slowly."
    @Published private(set) var found = 0
    @Published private(set) var done = false
    private var timer: Timer?
    private var step = 0
    private var stepStart = Date()
    private var results: [String] = []
    private let steps: [(name: String, depth: Bool)] = [("ARKit on its own", false), ("ARKit with LiDAR depth", true)]

    static let willStart = Notification.Name("SurfaceTestWillStart")
    static let didEnd = Notification.Name("SurfaceTestDidEnd")

    func start() {
        Diagnostics.log("Surface test: started")
        // Reset's own camera session first steps aside: two sessions at once fight for the camera.
        NotificationCenter.default.post(name: SurfaceTest.willStart, object: nil)
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            run(step: 0)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session.pause()
        if !done { Diagnostics.log("Surface test: closed early. " + results.joined(separator: "; ")) }
        NotificationCenter.default.post(name: SurfaceTest.didEnd, object: nil)
    }

    private func run(step: Int) {
        self.step = step
        stepStart = Date()
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if steps[step].depth, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func tick() {
        guard !done, let frame = session.currentFrame else { return }
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        found = planes.count
        let hit = session.raycast(frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any)).first != nil
        let left = max(0, 12 - Int(Date().timeIntervalSince(stepStart)))
        status = "Step \(step + 1) of \(steps.count): \(steps[step].name). \(found) surfaces found. \(left) s left."
        guard left == 0 else { return }
        let line = "\(steps[step].name): \(planes.count) planes (\(planes.filter { $0.alignment == .horizontal }.count) level), estimated surface at the middle \(hit ? "yes" : "no"), \(frame.rawFeaturePoints?.points.count ?? 0) feature points"
        results.append(line)
        Diagnostics.log("Surface test: " + line)
        if step + 1 < steps.count {
            run(step: step + 1)
        } else {
            done = true
            session.pause()
            timer?.invalidate()
            status = "Done. " + results.joined(separator: "\n") + "\n\nSend the feedback log."
        }
    }
}

struct SurfaceTestView: View {
    @StateObject private var test = SurfaceTest()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraView(session: test.session, onMake: { $0.debugOptions = [.showFeaturePoints] })
                .ignoresSafeArea()
            Text(test.status)
                .font(Theme.headline)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 6)
                .multilineTextAlignment(.center)
                .padding(24)
        }
        .navigationTitle("Surface test")
        .onAppear { test.start() }
        .onDisappear { test.stop() }
    }
}
