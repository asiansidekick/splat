import ARKit
import SceneKit
import UIKit

/// Phil, 2026-11-20: "Can models be obscured by objects in the room while in live view". One setting for live and
/// Review ("Models go behind real things", on unless turned off), shared with Review frames (ReviewStage).
@MainActor
enum BehindReal {
    nonisolated static let key = "review.hidesBehindSet"
    nonisolated static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// People walking in front of a model hide it: ARKit's people occlusion, drawn by ARSCNView itself. Works without
    /// LiDAR (A12 and later), so it works even where the depth can't be trusted. Left off with the Storyboard look,
    /// which draws the camera view with its own SceneKit technique.
    static var peopleWanted: Bool { on && !StoryboardLook.shared.on }

    static func addPeople(to config: ARWorldTrackingConfiguration) {
        guard peopleWanted else { return }
        let wanted = config.frameSemantics.union(.personSegmentationWithDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(wanted) {
            config.frameSemantics = wanted
        } else if !loggedNoPeople {
            loggedNoPeople = true
            Diagnostics.log("Behind real things: people occlusion not supported here (with \(config.frameSemantics.rawValue))")
        }
    }
    private static var loggedNoPeople = false

    /// True when the running camera's people occlusion matches the setting.
    static func peopleMatch(_ config: ARWorldTrackingConfiguration) -> Bool {
        let has = config.frameSemantics.contains(.personSegmentationWithDepth)
        if !peopleWanted { return !has }
        return has || !ARWorldTrackingConfiguration.supportsFrameSemantics(config.frameSemantics.union(.personSegmentationWithDepth))
    }

    /// Turns people occlusion on or off in the running camera, keeping the room where it is (no reset).
    static func applyPeople(to session: ARSession) {
        guard let current = session.configuration as? ARWorldTrackingConfiguration, !peopleMatch(current),
              let config = current.copy() as? ARWorldTrackingConfiguration else { return }
        // The room is already found: running again with the saved map would look for it all over again.
        config.initialWorldMap = nil
        if peopleWanted { addPeople(to: config) } else { config.frameSemantics.remove(.personSegmentationWithDepth) }
        session.run(config)
        Diagnostics.log("Behind real things: people occlusion \(config.frameSemantics.contains(.personSegmentationWithDepth) ? "on" : "off")")
    }
}

/// Hides placed models behind the real things in front of them in the live camera: an invisible mesh made from the
/// LiDAR depth of the latest camera picture (OccluderMath.swift, as Review frames do with saved depth), remade ten
/// times a second while there are models to hide. Watches the session from a timer, so the session's delegate is
/// left alone. Without LiDAR depth only people hide models (BehindReal.addPeople).
@MainActor
final class LiveOccluder {
    private weak var view: ARSCNView?
    private weak var placer: ModelPlacer?
    /// True while the camera picture is covered (Reset's backdrop or walk-through), when there is nothing real to hide behind.
    private let paused: () -> Bool
    private let node = SCNNode()
    private var timer: Timer?
    private var building = false
    private var lastTimestamp: TimeInterval = 0
    private var lastPeopleCheck: TimeInterval = 0
    /// The lowest floor seen in this session, for pictures that show little or no floor.
    private var seenFloor: Float?
    private var built = 0
    private var lastLog: TimeInterval = 0
    private var wasOn = false

    /// Starts hiding models behind real things in this camera view, for as long as the view lives.
    @discardableResult
    static func attach(to view: ARSCNView, placer: ModelPlacer, paused: @escaping () -> Bool = { false }) -> LiveOccluder {
        let occluder = LiveOccluder(view: view, placer: placer, paused: paused)
        occluder.start()
        return occluder
    }

    private init(view: ARSCNView, placer: ModelPlacer, paused: @escaping () -> Bool) {
        self.view = view
        self.placer = placer
        self.paused = paused
        node.name = "live.occluder"
        // After the photo ghost (-10), before models: it fills the depth buffer, draws no colour.
        node.renderingOrder = -5
        // Taps pass through it to the models behind (ReviewPick leaves this mask out).
        node.categoryBitMask = ReviewPick.occluderMask
        view.scene.rootNode.addChildNode(node)
    }

    private func start() {
        // The timer holds the occluder; it stops when the view is gone.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [self] _ in
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func clear() {
        node.geometry = nil
    }

    private func tick() {
        guard let view else {
            timer?.invalidate()
            timer = nil
            node.removeFromParentNode()
            return
        }
        guard let frame = view.session.currentFrame else { clear(); return }
        // A camera that stood still since the last tick is paused (a lens, the model builder, another screen).
        let running = frame.timestamp != lastTimestamp
        lastTimestamp = frame.timestamp
        guard running, view.window != nil else { return }
        guard case .normal = frame.camera.trackingState else { return }
        if frame.timestamp - lastPeopleCheck > 3 {
            lastPeopleCheck = frame.timestamp
            BehindReal.applyPeople(to: view.session)
        }
        let hasModels = !(placer?.models.isEmpty ?? true)
        let wanted = BehindReal.on && hasModels && !paused()
        if wanted != wasOn {
            wasOn = wanted
            Diagnostics.log("Behind real things: live \(wanted ? "on" : "off"), LiDAR depth \(frame.sceneDepth != nil || frame.smoothedSceneDepth != nil)")
        }
        guard wanted, let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { clear(); return }
        guard !building else { return }
        building = true
        let map = depth.depthMap
        let values = DepthMap.floats(DepthMap.copy(map, keepingOnly: depth.confidenceMap))
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let image = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let pose = frame.camera.transform
        let cameraY = pose.columns.3.y
        // The floor ARKit found, else the lowest seen so far (a camera can't be below the floor: then the room moved).
        let planeFloor = frame.anchors.compactMap { anchor -> Float? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal, plane.classification == .floor else { return nil }
            return plane.transform.columns.3.y
        }.min()
        if let floor = seenFloor, cameraY < floor + 0.2 { seenFloor = nil }
        let floor = planeFloor ?? seenFloor
        let timestamp = frame.timestamp
        Task.detached(priority: .userInitiated) {
            let mesh = OccluderMesh.build(depth: values, width: width, height: height, intrinsics: intrinsics, pose: pose,
                                          imageWidth: Float(image.width), imageHeight: Float(image.height), step: 2, floor: floor)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.building = false
                guard self.wasOn else { self.clear(); return }
                if let mesh, let seen = mesh.seenFloor, seen < cameraY - 0.6 { self.seenFloor = min(self.seenFloor ?? seen, seen) }
                self.node.geometry = mesh?.geometry()
                self.built += 1
                if timestamp - self.lastLog > 10 {
                    self.lastLog = timestamp
                    Diagnostics.log("Behind real things: \((mesh?.indices.count ?? 0) / 3) triangles from \(width)x\(height) depth, floor \(floor.map { String(format: "%.2f", $0) } ?? "none"), \(self.built) made")
                }
            }
        }
    }
}
