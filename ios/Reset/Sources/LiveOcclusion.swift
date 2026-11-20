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

    /// What the camera should deliver for hiding models: people occlusion, and LiDAR depth smoothed over time (Phil,
    /// 2026-11-20, build 1391: the edges flickered with the raw depth of each picture).
    static func semantics(for config: ARWorldTrackingConfiguration) -> ARConfiguration.FrameSemantics {
        var wanted = config.frameSemantics
        wanted.remove(.personSegmentationWithDepth)
        let withPeople = wanted.union(.personSegmentationWithDepth)
        if peopleWanted {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(withPeople) {
                wanted = withPeople
            } else if !loggedNoPeople {
                loggedNoPeople = true
                Diagnostics.log("Behind real things: people occlusion not supported here (with \(config.frameSemantics.rawValue))")
            }
        }
        let smoothed = wanted.union(.smoothedSceneDepth)
        if on, wanted.contains(.sceneDepth), ARWorldTrackingConfiguration.supportsFrameSemantics(smoothed) { wanted = smoothed }
        return wanted
    }
    private static var loggedNoPeople = false

    static func addPeople(to config: ARWorldTrackingConfiguration) {
        config.frameSemantics = semantics(for: config)
    }

    /// Turns people occlusion and smoothed depth on or off in the running camera, keeping the room where it is (no reset).
    static func applyPeople(to session: ARSession) {
        guard let current = session.configuration as? ARWorldTrackingConfiguration else { return }
        let wanted = semantics(for: current)
        guard wanted != current.frameSemantics, let config = current.copy() as? ARWorldTrackingConfiguration else { return }
        // The room is already found: running again with the saved map would look for it all over again.
        config.initialWorldMap = nil
        config.frameSemantics = wanted
        session.run(config)
        Diagnostics.log("Behind real things: people occlusion \(wanted.contains(.personSegmentationWithDepth) ? "on" : "off"), smoothed depth \(wanted.contains(.smoothedSceneDepth))")
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
    /// The floor heights the latest pictures showed, for pictures that show little or no floor. The middle one is used:
    /// build 1391 took the lowest, and one picture of the shiny floor's reflection sent it 1.8 m too low (Phil, 2026-11-20).
    private var seenFloors: [Float] = []
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
        // Phil, 2026-11-20: the model he was posing vanished. While a model is picked its tools are on it, so it stays in
        // full view; it goes behind real things again after Done.
        let editing = placer?.selectedModel != nil
        let wanted = BehindReal.on && hasModels && !paused() && !editing
        if wanted != wasOn {
            wasOn = wanted
            Diagnostics.log("Behind real things: live \(wanted ? "on" : "off")\(editing ? " (a model is picked)" : ""), LiDAR depth \(frame.sceneDepth != nil), smoothed \(frame.smoothedSceneDepth != nil)")
        }
        guard wanted, let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { clear(); return }
        guard !building else { return }
        building = true
        let map = depth.depthMap
        let values = DepthMap.floats(DepthMap.copy(map, keepingOnly: depth.confidenceMap))
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let image = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let pose = frame.camera.transform
        let cameraY = pose.columns.3.y
        // The floor: the lowest flat surface ARKit found well below the camera, else the middle of the floors the latest
        // pictures showed (a camera below the floor means the room moved: start again).
        let planeFloor = frame.anchors.compactMap { anchor -> Float? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            let y = plane.transform.columns.3.y
            return y < cameraY - 0.5 ? y : nil
        }.min()
        if let low = seenFloors.min(), cameraY < low + 0.2 { seenFloors = [] }
        let floor = planeFloor ?? (seenFloors.count >= 3 ? seenFloors.sorted()[seenFloors.count / 2] : nil)
        // The camera picture's brightness at about a quarter of its size, to sharpen the edges with (EdgeDepth).
        let guide = Self.luma(frame.capturedImage, step: max(2, Int(image.width) / 480))
        let models = placer?.worldPositions ?? []
        let logNow = frame.timestamp - lastLog > 10
        let timestamp = frame.timestamp
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let mesh: OccluderMesh?
            if let guide {
                let clean = OccluderMesh.median3(values, width: width, height: height)
                let sharp = EdgeDepth.refine(depth: clean, width: width, height: height, guide: guide.values,
                                             guideWidth: guide.width, guideHeight: guide.height)
                // The guide covers the whole picture less any odd pixels at the right and bottom.
                let step = Float(image.width) / Float(guide.width)
                mesh = OccluderMesh.build(depth: sharp, width: guide.width, height: guide.height, intrinsics: intrinsics, pose: pose,
                                          imageWidth: Float(guide.width) * step, imageHeight: Float(guide.height) * step, step: 1,
                                          floor: floor, pushBack: 0.08, pushPerMetre: 0.04)
            } else {
                mesh = OccluderMesh.build(depth: values, width: width, height: height, intrinsics: intrinsics, pose: pose,
                                          imageWidth: Float(image.width), imageHeight: Float(image.height), step: 1, floor: floor,
                                          pushBack: 0.08, pushPerMetre: 0.04, denoise: true)
            }
            let seconds = Date().timeIntervalSince(started)
            let report = logNow ? Self.report(models, depth: values, width: width, height: height, intrinsics: intrinsics,
                                                     pose: pose, image: image) : ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.building = false
                guard self.wasOn else { self.clear(); return }
                if let mesh, let seen = mesh.seenFloor, seen < cameraY - 0.6 {
                    self.seenFloors.append(seen)
                    if self.seenFloors.count > 31 { self.seenFloors.removeFirst() }
                }
                self.node.geometry = mesh?.geometry()
                self.built += 1
                if timestamp - self.lastLog > 10 {
                    self.lastLog = timestamp
                    Diagnostics.log("Behind real things: \((mesh?.indices.count ?? 0) / 3) triangles from \(width)x\(height) depth\(guide.map { ", sharpened to \($0.width)x\($0.height)" } ?? ""), \(Int(seconds * 1000)) ms, floor \(floor.map { String(format: "%.2f", $0) } ?? "none"), \(self.built) made\(report)")
                }
            }
        }
    }

    /// For the log: how far away each model is, and how far the real surface is in that direction. A model further
    /// than the surface is hidden by it, which is right if it was placed there, and tells us when it was placed wrong
    /// (a guessed distance without LiDAR puts a model behind the wall).
    nonisolated private static func report(_ models: [(name: String, position: SIMD3<Float>)], depth: [Float], width: Int, height: Int,
                                           intrinsics k: simd_float3x3, pose: simd_float4x4, image: CGSize) -> String {
        var parts: [String] = []
        let toCamera = pose.inverse
        for model in models.prefix(4) {
            let c = toCamera * SIMD4(model.position, 1)
            let distance = -c.z
            guard distance > 0.05 else { parts.append("\(model.name) behind the camera"); continue }
            let u = k[0][0] * c.x / distance + k[2][0], v = -k[1][1] * c.y / distance + k[2][1]
            let x = Int(u / Float(image.width) * Float(width)), y = Int(v / Float(image.height) * Float(height))
            guard x >= 0, x < width, y >= 0, y < height else { parts.append(String(format: "%@ %.2f m, off the picture", model.name, distance)); continue }
            let real = depth[y * width + x]
            parts.append(String(format: "%@ %.2f m, real surface there %.2f m%@", model.name, distance, real,
                                real > 0.12 && real + 0.1 < distance ? " (hidden: it stands behind it)" : ""))
        }
        return parts.isEmpty ? "" : "; " + parts.joined(separator: "; ")
    }

    /// The brightness of a camera picture, `step` times smaller each way (each value the average of a 2 by 2 patch).
    nonisolated static func luma(_ buffer: CVPixelBuffer, step: Int) -> (values: [UInt8], width: Int, height: Int)? {
        guard step >= 2, CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let ow = w / step, oh = h / step
        guard ow > 8, oh > 8 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: ow * oh)
        for y in 0..<oh {
            let a = pixels + y * step * row, b = a + row
            for x in 0..<ow {
                let i = x * step
                out[y * ow + x] = UInt8((Int(a[i]) + Int(a[i + 1]) + Int(b[i]) + Int(b[i + 1])) / 4)
            }
        }
        return (out, ow, oh)
    }
}
