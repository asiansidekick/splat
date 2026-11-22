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
    /// `held` is its outline kept still in the room, so a picture where Vision misses it doesn't let a model through
    /// (Phil, 2026-11-20: "the model flickers through still"). `differentSince` is when Vision first saw something else
    /// there; after a while that is taken as the thing having really changed (a door swung).
    private struct Pick {
        let id = UUID()
        let anchor: SIMD3<Float>
        var held: HeldOutline?
        var history: [[Bool]] = []
        var differentSince: TimeInterval?
        /// A plain surface (a wall) grown from the touch by colour and depth, not a thing Vision found.
        var grown = false
    }
    private var picks: [Pick] = [] { didSet { placer?.inFrontCount = picks.count } }
    /// The picked things' outlines, cut from the camera picture: a sheet 30 cm in front of the camera that hides every
    /// model behind it, turned as the camera was for that picture and kept at the camera.
    private let pickNode = SCNNode()
    private var pickBusy = false
    private var lastPickLog: TimeInterval = 0
    private var pickFound = true
    /// The last few sharpened depths and picked outlines while the camera holds still (EdgeDepth.steady, OutlineVote).
    private var depthHistory: [[Float]] = []
    private var depthHistoryPose: simd_float4x4?
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

    /// The camera picture at about 480 wide, as brightness and the two colour differences per pixel.
    nonisolated static func colour(_ buffer: CVPixelBuffer, step: Int) -> (values: [SIMD3<Float>], width: Int, height: Int)? {
        guard step >= 2, CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let ow = w / step, oh = h / step
        guard ow > 8, oh > 8, cw > 0, ch > 0 else { return nil }
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self), chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        var out = [SIMD3<Float>](repeating: .zero, count: ow * oh)
        for y in 0..<oh {
            let ly: Int = y * step
            let cy: Int = min(ch - 1, ly * ch / h)
            for x in 0..<ow {
                let lx: Int = x * step
                let cx: Int = min(cw - 1, lx * cw / w)
                let c: Int = cy * chromaRow + cx * 2
                let l: Float = Float(luma[ly * lumaRow + lx])
                let u: Float = Float(chroma[c]), v: Float = Float(chroma[c + 1])
                out[y * ow + x] = SIMD3<Float>(l, u, v)
            }
        }
        return (out, ow, oh)
    }

    /// The latest LiDAR depth, if any, for growing a surface.
    private static func depthGrid(_ frame: ARFrame) -> (values: [Float], width: Int, height: Int)? {
        guard let map = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return nil }
        return (DepthMap.floats(DepthMap.copy(map)), CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(map))
    }

    /// The plain surface under a point of the picture (0 to 1 each way), grown by colour and, where known, depth
    /// (RegionGrow); nil when it is a speck or the whole picture.
    nonisolated private static func surface(in image: CVPixelBuffer, depth: (values: [Float], width: Int, height: Int)?,
                                            at n: CGPoint) -> (cells: [Bool], width: Int, height: Int)? {
        let full = CVPixelBufferGetWidth(image)
        guard let picture = colour(image, step: max(2, full / 480)) else { return nil }
        let w = picture.width, h = picture.height
        var grid: [Float]?
        if let depth, depth.width > 0, depth.height > 0 {
            var values = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let dy = min(depth.height - 1, y * depth.height / h)
                for x in 0..<w { values[y * w + x] = depth.values[dy * depth.width + min(depth.width - 1, x * depth.width / w)] }
            }
            grid = values
        }
        let seedX = min(w - 1, max(0, Int(n.x * CGFloat(w)))), seedY = min(h - 1, max(0, Int(n.y * CGFloat(h))))
        let cells = RegionGrow.grow(colour: picture.values, depth: grid, width: w, height: h, seedX: seedX, seedY: seedY)
        let count = cells.filter { $0 }.count
        let total: Int = w * h
        guard count * 300 >= total, count * 100 <= total * 85 else { return nil }
        return (cells, w, h)
    }

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
        // Tapping inside something already in front takes it out.
        let lens = Self.lens(camera)
        let touched = existing.filter { pick in
            guard let held = pick.held else { return false }
            let seen = held.seen(from: camera.transform, lens: lens)
            let x = min(held.width - 1, Int(n.x * CGFloat(held.width))), y = min(held.height - 1, Int(n.y * CGFloat(held.height)))
            return seen[y * held.width + x]
        }
        if !touched.isEmpty {
            let gone = Set(touched.map(\.id))
            picks.removeAll { gone.contains($0.id) }
            Haptics.tap()
            Diagnostics.log("In front: taken out, \(picks.count) left")
            return
        }
        let depth = Self.depthGrid(frame)
        Task.detached(priority: .userInitiated) {
            let found = Self.instances(in: image)
            // No thing there (a wall, a door frame): grow the touched surface by colour and depth instead.
            let surface = (found?.label(at: n) ?? 0) == 0 ? Self.surface(in: image, depth: depth, at: n) : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let surface {
                    let held = HeldOutline(cells: surface.cells, width: surface.width, height: surface.height, pose: camera.transform,
                                           lens: lens, distance: HeldOutline.distance(of: anchor, from: camera.transform))
                    var pick = Pick(anchor: anchor, held: held)
                    pick.grown = true
                    self.picks.append(pick)
                    Haptics.success()
                    let distance: Float = simd_length(anchor - camera.transform.columns.3.xyz)
                    let share: Int = surface.cells.filter { $0 }.count * 100 / max(1, surface.cells.count)
                    Diagnostics.log(String(format: "In front: picked a surface at %.2f, %.2f, %.2f m away, %d%% of the picture, %d in front",
                                           Double(n.x), Double(n.y), Double(distance), share, self.picks.count))
                    self.pickFound = true
                    return
                }
                guard let found, let label = found.label(at: n), label > 0 else {
                    self.placer?.modelError = "Couldn't tell that apart from what's around it. Tap the middle of it, or step back so all of it shows."
                    Haptics.warning()
                    Diagnostics.log(String(format: "In front: nothing found at %.2f, %.2f (%d things in the picture, no surface either)", n.x, n.y, found?.count ?? 0))
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
                    var held: HeldOutline?
                    if let mask = try? found.observation.generateScaledMaskForImage(forInstances: IndexSet(integer: Int(label)), from: found.handler),
                       let cells = Self.cells(of: mask) {
                        held = HeldOutline(cells: cells.inside, width: cells.width, height: cells.height, pose: camera.transform,
                                           lens: Self.lens(camera), distance: HeldOutline.distance(of: anchor, from: camera.transform))
                    }
                    self.picks.append(Pick(anchor: anchor, held: held))
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

        /// The thing covering most of an outline (cells across the whole picture), if it covers at least 30% of it.
        /// Finds a picked thing again even when the tapped point has slid off it (an anchor at the wrong depth).
        func label(covering cells: [Bool], width cw: Int, height ch: Int) -> UInt8? {
            guard cw > 0, ch > 0, cells.count == cw * ch else { return nil }
            var counts = [Int](repeating: 0, count: 256)
            var total = 0
            for y in stride(from: 0, to: ch, by: 2) {
                let ly = min(height - 1, y * height / ch)
                for x in stride(from: 0, to: cw, by: 2) where cells[y * cw + x] {
                    total += 1
                    counts[Int(labels[ly * width + min(width - 1, x * width / cw)])] += 1
                }
            }
            guard total > 0 else { return nil }
            var best = 0, most = 0
            for label in 1..<256 where counts[label] > most { best = label; most = counts[label] }
            return best > 0 && most * 10 >= total * 3 ? UInt8(best) : nil
        }

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

    /// Each picked thing's sheet, by id, drawn nearest first (see ModelPlacer.applyLayers).
    private var sheetNodes: [UUID: SCNNode] = [:]
    /// Picked things nearest the camera first.
    private var layerOrder: [UUID] = []
    /// Whether picked things are shaped by real depth now (so each model goes behind them all and depth decides).
    private var pickDepth = false
    private var pickDepthHistory: [[Float]] = []

    private func clearSheets() {
        for node in sheetNodes.values { node.removeFromParentNode() }
        sheetNodes = [:]
        if !layerOrder.isEmpty {
            layerOrder = []
            placer?.nearerThings = [:]
            placer?.applyLayers()
        }
    }

    /// A picked thing's shape: real depth (LiDAR) where the thing is, so a model is hidden only where the thing is
    /// nearer than it (Phil, 2026-11-21: the rail hides her legs, not the staircase behind her); else the flat outline
    /// 30 cm from the camera that hides every model behind it.
    private struct Shape: @unchecked Sendable { let mesh: OccluderMesh; let inRoom: Bool }

    private func showSheets(_ sheets: [UUID: Shape]) {
        for (id, node) in sheetNodes where !picks.contains(where: { $0.id == id }) {
            node.removeFromParentNode()
            sheetNodes[id] = nil
        }
        for pick in picks {
            let node: SCNNode
            if let existing = sheetNodes[pick.id] {
                node = existing
            } else {
                node = SCNNode()
                node.name = "live.inFront.thing"
                node.categoryBitMask = ReviewPick.occluderMask
                sheetNodes[pick.id] = node
            }
            node.renderingOrder = 10 * (layerOrder.firstIndex(of: pick.id) ?? 0) + 5
            let shape = sheets[pick.id]
            let parent = shape?.inRoom == true ? view?.scene.rootNode : pickNode
            if node.parent !== parent { node.removeFromParentNode(); parent?.addChildNode(node) }
            node.geometry = shape.flatMap { $0.mesh.geometry(readsDepth: $0.inRoom) }
        }
    }

    /// Orders the picked things by distance from the camera and tells each model how many are nearer than it, so a row
    /// of posed people seen down its length goes behind each real thing in front of it.
    private func orderLayers(camera: simd_float4x4) {
        let eye = camera.columns.3.xyz
        let order = picks.sorted { simd_distance($0.anchor, eye) < simd_distance($1.anchor, eye) }
        let ids = order.map(\.id)
        var nearer: [UUID: Int] = [:]
        for (id, place) in placer?.modelPlaces ?? [:] {
            let distance = simd_distance(place, eye)
            nearer[id] = pickDepth ? order.count : order.filter { simd_distance($0.anchor, eye) < distance }.count
        }
        let changed = ids != layerOrder || nearer != placer?.nearerThings
        layerOrder = ids
        if changed {
            placer?.nearerThings = nearer
            for (k, id) in ids.enumerated() { sheetNodes[id]?.renderingOrder = 10 * k + 5 }
        }
        placer?.applyLayers()
    }

    private func layerReport() -> String {
        guard let placer else { return "" }
        return placer.models.map { "\(placer.layer(of: $0.id))" }.joined(separator: "/")
    }

    /// The lens of a camera picture, for HeldOutline.
    nonisolated private static func lens(_ camera: ARCamera) -> HeldOutline.Lens {
        let k = camera.intrinsics
        return HeldOutline.Lens(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                imageWidth: Float(camera.imageResolution.width), imageHeight: Float(camera.imageResolution.height))
    }

    /// What one tick learned about one picked thing.
    private struct PickUpdate: Sendable {
        let id: UUID
        /// Vision's outline when it is the held thing (or has been something else for long enough to take over).
        var taken: [Bool]?
        /// Whether Vision saw something different there this picture.
        var different = false
        var source = "held"
        var width = 0
    }

    /// Each tick: shows every picked thing's outline, the one held still in the room redrawn for the camera as it is now,
    /// and swaps in Vision's fresh outline only when it agrees with the held one. Holding still, the last 6 agreeing
    /// outlines are voted on so the edge doesn't shimmer.
    private func updatePicks(_ frame: ARFrame, on: Bool) {
        guard on, !picks.isEmpty else {
            clearSheets()
            return
        }
        orderLayers(camera: frame.camera.transform)
        guard !pickBusy else { return }
        pickBusy = true
        let image = frame.capturedImage
        let camera = frame.camera
        let current = picks
        let timestamp = frame.timestamp
        let logNow = timestamp - lastPickLog > 10
        let pose = camera.transform
        let still = Self.still(maskHistoryPose, pose)
        if !still {
            maskHistoryPose = pose
            for i in picks.indices { picks[i].history = [] }
        }
        let lens = Self.lens(camera)
        // Real depth to shape the picked things with, sharpened by the picture like the whole room's.
        var depthValues: [Float]?
        var depthSize = (0, 0)
        if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            let map = depth.depthMap
            depthValues = DepthMap.floats(DepthMap.copy(map))
            depthSize = (CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(map))
        }
        let guide = depthValues == nil ? nil : Self.luma(image, step: max(2, Int(camera.imageResolution.width) / 480))
        let depthGrid = picks.contains(where: \.grown) ? Self.depthGrid(frame) : nil
        if !still { pickDepthHistory = [] }
        let depthHistory = pickDepthHistory
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let found = Self.instances(in: image)
            var updates: [PickUpdate] = []
            var sheets: [UUID: Shape] = [:]
            var sharp: [Float]?
            var room: (depth: [Float], width: Int, height: Int)?
            if let depthValues, let guide {
                let clean = OccluderMesh.median3(depthValues, width: depthSize.0, height: depthSize.1)
                let refined = EdgeDepth.refine(depth: clean, width: depthSize.0, height: depthSize.1, guide: guide.values,
                                               guideWidth: guide.width, guideHeight: guide.height)
                if refined.count == guide.width * guide.height {
                    sharp = refined
                    room = (EdgeDepth.steady(depthHistory + [refined]), guide.width, guide.height)
                }
            }
            for pick in current {
                var update = PickUpdate(id: pick.id)
                let held = pick.held?.seen(from: pose, lens: lens)
                var fresh: [Bool]?
                var width = 0
                if pick.grown {
                    if let n = Self.imagePoint(of: pick.anchor, camera: camera), let grown = Self.surface(in: image, depth: depthGrid, at: n),
                       grown.width == pick.held?.width {
                        fresh = grown.cells
                        width = grown.width
                    }
                }
                // The thing under the held outline, else under the tapped point.
                let label = pick.grown ? nil : found.flatMap { found in
                    held.flatMap { found.label(covering: $0, width: pick.held!.width, height: pick.held!.height) }
                        ?? Self.imagePoint(of: pick.anchor, camera: camera).flatMap { found.label(at: $0) }
                }
                if let found, let label,
                   let mask = try? found.observation.generateScaledMaskForImage(forInstances: IndexSet(integer: Int(label)), from: found.handler),
                   let cells = Self.cells(of: mask) {
                    fresh = cells.inside
                    width = cells.width
                }
                var outline = held
                if let fresh {
                    if held == nil || HeldOutline.agrees(fresh, with: held!) {
                        update.taken = fresh
                        update.source = "fresh"
                    } else if let since = pick.differentSince, timestamp - since > 1.5 {
                        update.taken = fresh
                        update.source = "changed"
                    } else {
                        update.different = true
                    }
                }
                if let taken = update.taken {
                    outline = OutlineVote.steady(pick.history + [taken])
                }
                update.width = update.taken != nil ? width : (pick.held?.width ?? width)
                if let outline, update.width > 0 {
                    let height = outline.count / update.width
                    if let room, let mesh = Self.depthShape(cells: outline, width: update.width, height: height, room: room, camera: camera) {
                        sheets[pick.id] = Shape(mesh: mesh, inRoom: true)
                    } else if let sheet = Self.sheet(cells: outline, width: update.width, height: height, camera: camera) {
                        sheets[pick.id] = Shape(mesh: sheet, inRoom: false)
                    }
                }
                updates.append(update)
            }
            let seconds = Date().timeIntervalSince(started)
            let rotation = simd_quatf(camera.transform)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pickBusy = false
                guard !self.picks.isEmpty else { self.clearSheets(); return }
                let keepHistory = Self.still(self.maskHistoryPose, pose)
                for update in updates {
                    guard let i = self.picks.firstIndex(where: { $0.id == update.id }) else { continue }
                    var pick = self.picks[i]
                    if let taken = update.taken {
                        let w = update.width
                        let h = taken.count / max(1, w)
                        if keepHistory {
                            pick.history.append(taken)
                            if pick.history.count > Self.historyLength { pick.history.removeFirst() }
                        }
                        let steady = keepHistory ? OutlineVote.steady(pick.history) : taken
                        pick.held = HeldOutline(cells: steady, width: w, height: h, pose: pose, lens: lens,
                                                distance: HeldOutline.distance(of: pick.anchor, from: pose))
                        pick.differentSince = nil
                    } else if update.different {
                        if pick.differentSince == nil { pick.differentSince = timestamp }
                    } else {
                        pick.differentSince = nil
                    }
                    self.picks[i] = pick
                }
                self.pickNode.simdOrientation = rotation
                if let sharp, keepHistory {
                    self.pickDepthHistory.append(sharp)
                    if self.pickDepthHistory.count > Self.historyLength { self.pickDepthHistory.removeFirst() }
                }
                self.pickDepth = room != nil
                self.showSheets(sheets)
                let sources = updates.map(\.source).joined(separator: ", ")
                let shown = !sheets.isEmpty
                if logNow || shown != self.pickFound {
                    self.lastPickLog = timestamp
                    self.pickFound = shown
                    Diagnostics.log("In front: \(updates.count) picked things (\(sources)), Vision \(found == nil ? "found nothing" : "ran"), \(sheets.values.reduce(0) { $0 + $1.mesh.indices.count / 3 }) triangles (\(room != nil ? "real depth" : "flat, no depth")), layers \(self.layerReport()), \(Int(seconds * 1000)) ms")
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

    /// The real surface (sharpened LiDAR depth) inside a picked thing's outline, in the room: hides a model only where
    /// the thing is nearer than the model. Nil when too little of the outline has depth.
    nonisolated private static func depthShape(cells: [Bool], width cw: Int, height ch: Int,
                                               room: (depth: [Float], width: Int, height: Int), camera: ARCamera) -> OccluderMesh? {
        let gw = room.width, gh = room.height
        guard cw > 0, ch > 0, gw > 8, gh > 8, cells.count == cw * ch else { return nil }
        // The depth at each cell of the outline (nearest sharpened reading); the outline itself gives the edges.
        var depth = [Float](repeating: 0, count: cw * ch)
        var inside = 0, measured = 0
        for y in 0..<ch {
            let gy = min(gh - 1, y * gh / ch)
            for x in 0..<cw where cells[y * cw + x] {
                inside += 1
                let d = room.depth[gy * gw + min(gw - 1, x * gw / cw)]
                if d.isFinite, d > 0.12 { depth[y * cw + x] = d; measured += 1 }
            }
        }
        guard inside > 0, measured * 3 >= inside else { return nil }
        let strips = DepthStrips.make(width: cw, height: ch, depth: depth, maxRun: 24) { x, y in cells[y * cw + x] }
        let image = camera.imageResolution
        let k = camera.intrinsics
        let pose = camera.transform
        let sx = Float(image.width) / Float(cw), sy = Float(image.height) / Float(ch)
        var mesh = OccluderMesh()
        mesh.positions.reserveCapacity(strips.count * 12)
        mesh.indices.reserveCapacity(strips.count * 6)
        func vertex(_ x: Float, _ y: Float, _ d: Float) {
            // A little behind the real surface (more far away, where LiDAR is rougher) so a model touching it isn't cut.
            let back = d + 0.03 + 0.02 * d
            let u = x * sx, v = y * sy
            let p = pose * SIMD4((u - k[2][0]) / k[0][0] * back, -(v - k[2][1]) / k[1][1] * back, -back, 1)
            mesh.positions.append(contentsOf: [p.x, p.y, p.z])
        }
        for strip in strips {
            let first = UInt32(mesh.positions.count / 3)
            let left = Float(strip.x0), right = Float(strip.x1), top = Float(strip.y), bottom = Float(strip.y + 1)
            vertex(left, top, strip.d0); vertex(right, top, strip.d1); vertex(left, bottom, strip.d0); vertex(right, bottom, strip.d1)
            mesh.indices.append(contentsOf: [first, first + 2, first + 1, first + 1, first + 2, first + 3])
        }
        return mesh.indices.isEmpty ? nil : mesh
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
