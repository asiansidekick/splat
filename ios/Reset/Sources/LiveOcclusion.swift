import ARKit
import SceneKit
import UIKit
import Vision

/// Phil, 2026-11-20: "Can models be obscured by objects in the room while in live view". One setting for live and
/// Review ("Models go behind real things", on unless turned off), shared with Review frames (ReviewStage).
@MainActor
enum BehindReal {
    nonisolated static let key = "review.hidesBehindSet"
    nonisolated static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Phil, 2026-11-20 (chose "Both, automatic off by default"): the whole room from LiDAR hides models only when this
    /// is on. Normally the real things that go in front are picked by tapping them ("In front").
    nonisolated static let wholeRoomKey = "live.wholeRoom"
    nonisolated static var wholeRoom: Bool { UserDefaults.standard.bool(forKey: wholeRoomKey) }

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
        if on, wholeRoom, wanted.contains(.sceneDepth), ARWorldTrackingConfiguration.supportsFrameSemantics(smoothed) { wanted = smoothed }
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

    /// Real things picked to go in front of the models: where each was tapped, in the room.
    private struct Pick { let id = UUID(); let anchor: SIMD3<Float> }
    private var picks: [Pick] = [] { didSet { placer?.inFrontCount = picks.count } }
    /// The picked things' outlines, cut from the camera picture: a sheet 30 cm in front of the camera that hides every
    /// model behind it, turned as the camera was for that picture and kept at the camera.
    private let pickNode = SCNNode()
    private var pickBusy = false
    private var lastPickLog: TimeInterval = 0
    private var pickFound = true
    private var lastPickSeen: TimeInterval = 0
    /// The last few sharpened depths and picked outlines while the camera holds still (EdgeDepth.steady, OutlineVote).
    private var depthHistory: [[Float]] = []
    private var depthHistoryPose: simd_float4x4?
    private var maskHistory: [[Bool]] = []
    private var maskHistoryPose: simd_float4x4?
    nonisolated static let historyLength = 6

    /// Whether the camera is where it was (within 1.5 cm and 0.8°).
    nonisolated static func still(_ a: simd_float4x4?, _ b: simd_float4x4) -> Bool {
        guard let a else { return false }
        let moved = simd_length(a.columns.3.xyz - b.columns.3.xyz)
        let turned = acos(min(1, max(-1, simd_dot(-a.columns.2.xyz, -b.columns.2.xyz))))
        let rolled = acos(min(1, max(-1, simd_dot(a.columns.0.xyz, b.columns.0.xyz))))
        return moved < 0.015 && turned < 0.014 && rolled < 0.014
    }
    nonisolated static let sheetDistance: Float = 0.3

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
        pickNode.name = "live.inFront"
        pickNode.renderingOrder = -6
        pickNode.categoryBitMask = ReviewPick.occluderMask
        if let eye = view.pointOfView {
            pickNode.constraints = [SCNTransformConstraint.positionConstraint(inWorldSpace: true) { [weak eye] _, position in
                eye?.presentation.worldPosition ?? position
            }]
        }
        view.scene.rootNode.addChildNode(pickNode)
        placer.onPickInFront = { [weak self] point, view in self?.pick(at: point, in: view) }
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
            pickNode.removeFromParentNode()
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
        let shown = BehindReal.on && hasModels && !paused()
        updatePicks(frame, on: shown)
        let wanted = shown && BehindReal.wholeRoom && !editing
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
        if !Self.still(depthHistoryPose, pose) {
            depthHistory = []
            depthHistoryPose = pose
        }
        let history = depthHistory
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let mesh: OccluderMesh?
            var latest: [Float]?
            if let guide {
                let clean = OccluderMesh.median3(values, width: width, height: height)
                let sharp = EdgeDepth.refine(depth: clean, width: width, height: height, guide: guide.values,
                                             guideWidth: guide.width, guideHeight: guide.height)
                latest = sharp
                let steady = EdgeDepth.steady(history + [sharp])
                // The guide covers the whole picture less any odd pixels at the right and bottom.
                let step = Float(image.width) / Float(guide.width)
                mesh = OccluderMesh.build(depth: steady, width: guide.width, height: guide.height, intrinsics: intrinsics, pose: pose,
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
                if let latest, Self.still(self.depthHistoryPose, pose) {
                    self.depthHistory.append(latest)
                    if self.depthHistory.count > Self.historyLength { self.depthHistory.removeFirst() }
                }
                if let mesh, let seen = mesh.seenFloor, seen < cameraY - 0.6 {
                    self.seenFloors.append(seen)
                    if self.seenFloors.count > 31 { self.seenFloors.removeFirst() }
                }
                self.node.geometry = mesh?.geometry()
                self.built += 1
                if timestamp - self.lastLog > 10 {
                    self.lastLog = timestamp
                    Diagnostics.log("Behind real things: \((mesh?.indices.count ?? 0) / 3) triangles from \(width)x\(height) depth, \(history.count + 1) still pictures\(guide.map { ", sharpened to \($0.width)x\($0.height)" } ?? ""), \(Int(seconds * 1000)) ms, floor \(floor.map { String(format: "%.2f", $0) } ?? "none"), \(self.built) made\(report)")
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

    // MARK: Picked things in front (Phil, 2026-11-20)

    /// A tap while picking: finds the thing under the finger in the camera picture (Vision's subject finder) and puts it
    /// in front, or takes it out if it is in front already.
    private func pick(at point: CGPoint, in view: ARSCNView) {
        guard let frame = view.session.currentFrame else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let toImage = frame.displayTransform(for: Screen.orientation, viewportSize: size).inverted()
        let n = CGPoint(x: point.x / size.width, y: point.y / size.height).applying(toImage)
        guard n.x >= 0, n.x <= 1, n.y >= 0, n.y <= 1 else { return }
        let anchor = Self.anchor(in: frame, at: n, session: view.session)
        let image = frame.capturedImage
        let camera = frame.camera
        let existing = picks
        Task.detached(priority: .userInitiated) {
            let found = Self.instances(in: image)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let found, let label = found.label(at: n), label > 0 else {
                    self.placer?.modelError = "Couldn't tell that thing apart from what's behind it. Tap the middle of it, or step back so all of it shows."
                    Haptics.warning()
                    Diagnostics.log(String(format: "In front: nothing found at %.2f, %.2f (%d things in the picture)", n.x, n.y, found?.count ?? 0))
                    return
                }
                // Tapping a thing already in front takes it out.
                let already = existing.filter { pick in
                    Self.imagePoint(of: pick.anchor, camera: camera).map { found.label(at: $0) == label } ?? false
                }
                if !already.isEmpty {
                    let gone = Set(already.map(\.id))
                    self.picks.removeAll { gone.contains($0.id) }
                    Haptics.tap()
                    Diagnostics.log("In front: taken out, \(self.picks.count) left")
                } else {
                    self.picks.append(Pick(anchor: anchor))
                    Haptics.success()
                    Diagnostics.log(String(format: "In front: picked thing %d at %.2f, %.2f, %.2f m away, %d in front", label, n.x, n.y,
                                           simd_length(anchor - camera.transform.columns.3.xyz), self.picks.count))
                }
                self.pickFound = true
            }
        }
    }

    /// Where in the room the tapped point is: LiDAR depth, else a surface ARKit can find, else 2 m away.
    private static func anchor(in frame: ARFrame, at n: CGPoint, session: ARSession) -> SIMD3<Float> {
        let k = frame.camera.intrinsics
        let image = frame.camera.imageResolution
        let u = Float(n.x) * Float(image.width), v = Float(n.y) * Float(image.height)
        let ray = SIMD3((u - k[2][0]) / k[0][0], -(v - k[2][1]) / k[1][1], -1)
        var distance: Float = 2
        if let depth = (frame.sceneDepth ?? frame.smoothedSceneDepth)?.depthMap {
            let values = DepthMap.floats(DepthMap.copy(depth))
            let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
            if let d = DepthMap.sample(values, width: w, height: h, x: min(w - 1, Int(n.x * CGFloat(w))), y: min(h - 1, Int(n.y * CGFloat(h))), radius: 2, range: 0.15...8) {
                distance = d
            }
        } else if let hit = session.raycast(frame.raycastQuery(from: n, allowing: .estimatedPlane, alignment: .any)).first {
            return hit.worldTransform.columns.3.xyz
        }
        let world = frame.camera.transform * SIMD4(ray * distance, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    /// Where a point in the room shows in the camera picture, 0 to 1 each way; nil behind the camera or off the picture.
    nonisolated private static func imagePoint(of point: SIMD3<Float>, camera: ARCamera) -> CGPoint? {
        let c = camera.transform.inverse * SIMD4(point, 1)
        guard c.z < -0.05 else { return nil }
        let k = camera.intrinsics
        let image = camera.imageResolution
        let u = (k[0][0] * c.x / -c.z + k[2][0]) / Float(image.width)
        let v = (-k[1][1] * c.y / -c.z + k[2][1]) / Float(image.height)
        guard u > -0.02, u < 1.02, v > -0.02, v < 1.02 else { return nil }
        return CGPoint(x: CGFloat(u), y: CGFloat(v))
    }

    /// Vision's separate things in a camera picture.
    private struct Instances: @unchecked Sendable {
        let observation: VNInstanceMaskObservation
        let handler: VNImageRequestHandler
        let labels: [UInt8]
        let width: Int
        let height: Int
        var count: Int { observation.allInstances.count }

        /// The thing at a point (0 to 1 each way), or the nearest one within a little of it.
        func label(at n: CGPoint) -> UInt8? {
            let x = Int(n.x * CGFloat(width)), y = Int(n.y * CGFloat(height))
            let reach = max(2, width / 30)
            var best: (label: UInt8, distance: Int)?
            for yy in max(0, y - reach)...min(height - 1, y + reach) {
                for xx in max(0, x - reach)...min(width - 1, x + reach) {
                    let label = labels[yy * width + xx]
                    guard label > 0 else { continue }
                    let distance = (xx - x) * (xx - x) + (yy - y) * (yy - y)
                    if distance < (best?.distance ?? Int.max) { best = (label, distance) }
                }
            }
            return best?.label
        }
    }

    nonisolated private static func instances(in image: CVPixelBuffer) -> Instances? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
        do { try handler.perform([request]) } catch {
            Diagnostics.log("In front: Vision failed: \(error.localizedDescription)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask), w > 0, h > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { labels[y * w + x] = bytes[y * row + x] } }
        return Instances(observation: observation, handler: handler, labels: labels, width: w, height: h)
    }

    /// Each tick: finds the picked things in the latest picture and makes their outlines the sheet that hides models.
    private func updatePicks(_ frame: ARFrame, on: Bool) {
        guard on, !picks.isEmpty else {
            pickNode.geometry = nil
            return
        }
        guard !pickBusy else { return }
        pickBusy = true
        let image = frame.capturedImage
        let camera = frame.camera
        let anchors = picks.map(\.anchor)
        let timestamp = frame.timestamp
        let logNow = timestamp - lastPickLog > 10
        let pose = camera.transform
        if !Self.still(maskHistoryPose, pose) {
            maskHistory = []
            maskHistoryPose = pose
        }
        let history = maskHistory
        Task.detached(priority: .userInitiated) {
            let started = Date()
            var geometry: OccluderMesh?
            var latest: [Bool]?
            var labels = IndexSet()
            if let found = Self.instances(in: image) {
                for anchor in anchors {
                    if let n = Self.imagePoint(of: anchor, camera: camera), let label = found.label(at: n) { labels.insert(Int(label)) }
                }
                if !labels.isEmpty, let mask = try? found.observation.generateScaledMaskForImage(forInstances: labels, from: found.handler) {
                    if let cells = Self.cells(of: mask) {
                        latest = cells.inside
                        let steady = OutlineVote.steady(history + [cells.inside])
                        geometry = Self.sheet(cells: steady, width: cells.width, height: cells.height, camera: camera)
                    }
                }
            }
            let seconds = Date().timeIntervalSince(started)
            let rotation = simd_quatf(camera.transform)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pickBusy = false
                guard !self.picks.isEmpty else { self.pickNode.geometry = nil; return }
                if let latest, Self.still(self.maskHistoryPose, pose) {
                    self.maskHistory.append(latest)
                    if self.maskHistory.count > Self.historyLength { self.maskHistory.removeFirst() }
                }
                let found = geometry != nil
                // A picture or two where Vision misses the thing keeps the last outline, so it doesn't blink.
                if found || timestamp - self.lastPickSeen > 0.5 {
                    self.pickNode.simdOrientation = rotation
                    self.pickNode.geometry = geometry?.geometry(readsDepth: false)
                }
                if found { self.lastPickSeen = timestamp }
                if logNow || found != self.pickFound {
                    self.lastPickLog = timestamp
                    self.pickFound = found
                    Diagnostics.log("In front: \(labels.count) of \(anchors.count) picked things found, \((geometry?.indices.count ?? 0) / 6) strips, \(Int(seconds * 1000)) ms")
                }
            }
        }
    }

    /// Vision's mask (at the camera picture's size) as cells every 2 pixels each way: inside or not.
    nonisolated private static func cells(of mask: CVPixelBuffer) -> (inside: [Bool], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask), w > 3, h > 3 else { return nil }
        let float = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float
        let cw = w / 2, ch = h / 2
        var inside = [Bool](repeating: false, count: cw * ch)
        for y in 0..<ch {
            let line = base.advanced(by: (y * 2) * row)
            for x in 0..<cw {
                inside[y * cw + x] = float ? line.assumingMemoryBound(to: Float.self)[x * 2] > 0.5 : line.assumingMemoryBound(to: UInt8.self)[x * 2] > 127
            }
        }
        return (inside, cw, ch)
    }

    /// The outline's cells as rows of strips on a sheet 30 cm in front of the camera, in the camera's own coordinates.
    nonisolated private static func sheet(cells: [Bool], width: Int, height: Int, camera: ARCamera) -> OccluderMesh? {
        let image = camera.imageResolution
        let k = camera.intrinsics
        let sx = Float(image.width) / Float(width), sy = Float(image.height) / Float(height)
        let d = sheetDistance
        var mesh = OccluderMesh()
        func vertex(_ u: Float, _ v: Float) {
            mesh.positions.append(contentsOf: [(u * sx - k[2][0]) / k[0][0] * d, -(v * sy - k[2][1]) / k[1][1] * d, -d])
        }
        let strips = OutlineStrips.make(width: width, height: height, stepY: 1) { x, y in cells[y * width + x] }
        for strip in strips {
            let first = UInt32(mesh.positions.count / 3)
            let top = Float(strip.y0), bottom = Float(strip.y1), left = Float(strip.x0), right = Float(strip.x1)
            vertex(left, top); vertex(right, top); vertex(left, bottom); vertex(right, bottom)
            mesh.indices.append(contentsOf: [first, first + 2, first + 1, first + 1, first + 2, first + 3])
        }
        return mesh.indices.isEmpty ? nil : mesh
    }
}
