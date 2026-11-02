import ImageIO
import SceneKit
import SwiftUI
import simd

/// The room as a coloured point cloud, made from a reference's saved frames (photo colour at each depth
/// reading), so it can be flown through away from the set (Phil, 2026-11-02).
enum SceneCloud {
    struct Result: @unchecked Sendable {
        var positions: [SIMD3<Float>] = []
        var colours: [SIMD4<Float>] = []
        var framesUsed = 0
    }

    /// Fuses every frame that has depth. Points are thinned to one per 1.5 cm cube and a point cap, and
    /// depth that jumps against a neighbour (the smeared edge of a prop) is dropped.
    static func build(frames: [Keyframe], folder: URL, maxPoints: Int = 700_000) -> Result {
        var result = Result()
        var seen = Set<UInt64>()
        let cell: Float = 0.015
        func key(_ p: SIMD3<Float>) -> UInt64 {
            let offset = Int64(1 << 20)
            let x = UInt64(truncatingIfNeeded: Int64((p.x / cell).rounded(.down)) + offset) & 0x1F_FFFF
            let y = UInt64(truncatingIfNeeded: Int64((p.y / cell).rounded(.down)) + offset) & 0x1F_FFFF
            let z = UInt64(truncatingIfNeeded: Int64((p.z / cell).rounded(.down)) + offset) & 0x1F_FFFF
            return x << 42 | y << 21 | z
        }
        for frame in frames {
            guard result.positions.count < maxPoints, let depthFile = frame.depthFile, frame.depthWidth > 8, frame.depthHeight > 8,
                  frame.imageWidth > 0, frame.imageHeight > 0, frame.intrinsics.count >= 9,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(depthFile)) else { continue }
            let depth = DepthMap.floats(data)
            let dw = frame.depthWidth, dh = frame.depthHeight
            guard depth.count >= dw * dh,
                  let rgba = colours(of: folder.appendingPathComponent(frame.imageFile), width: dw, height: dh) else { continue }
            let k = frame.cameraIntrinsics
            let pose = frame.cameraToWorld
            let w = Float(frame.imageWidth), h = Float(frame.imageHeight)
            var used = false
            for y in 0..<(dh - 1) {
                for x in 0..<(dw - 1) {
                    let d = depth[y * dw + x]
                    guard d.isFinite, d > 0.12, d < 5 else { continue }
                    let right = depth[y * dw + x + 1], below = depth[(y + 1) * dw + x]
                    guard abs(right - d) < 0.12 * d, abs(below - d) < 0.12 * d else { continue }
                    let u = (Float(x) + 0.5) / Float(dw) * w, v = (Float(y) + 0.5) / Float(dh) * h
                    let local = SIMD4((u - k[2][0]) / k[0][0] * d, -(v - k[2][1]) / k[1][1] * d, -d, 1)
                    let world4 = pose * local
                    let world = SIMD3(world4.x, world4.y, world4.z)
                    guard seen.insert(key(world)).inserted else { continue }
                    let i = (y * dw + x) * 4
                    result.positions.append(world)
                    result.colours.append(SIMD4(Float(rgba[i]) / 255, Float(rgba[i + 1]) / 255, Float(rgba[i + 2]) / 255, 1))
                    used = true
                    if result.positions.count >= maxPoints { break }
                }
                if result.positions.count >= maxPoints { break }
            }
            if used { result.framesUsed += 1 }
        }
        return result
    }

    /// The photo shrunk to the depth map's size, as RGBA bytes, top row first.
    private static func colours(of url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    /// A SceneKit point cloud for the result.
    static func geometry(_ cloud: Result) -> SCNGeometry? {
        let count = cloud.positions.count
        guard count > 0 else { return nil }
        let vertices = cloud.positions.withUnsafeBytes { Data($0) }
        let colours = cloud.colours.withUnsafeBytes { Data($0) }
        let positionSource = SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                               componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let colourSource = SCNGeometrySource(data: colours, semantic: .color, vectorCount: count, usesFloatComponents: true,
                                             componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: count, bytesPerIndex: 0)
        element.pointSize = 0.012
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 6
        let geometry = SCNGeometry(sources: [positionSource, colourSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

/// Fly through a reference as a 3D scene: one finger looks round, two fingers slide, pinch moves
/// forward and back. The numbered buttons jump to where each frame was taken.
struct ExploreView: View {
    let reference: Reference
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scene: ExploreScene
    @State private var status = "Building the 3D view…"
    @State private var ready = false
    @State private var frameIndex = 0

    init(reference: Reference) {
        self.reference = reference
        _scene = StateObject(wrappedValue: ExploreScene(reference: reference))
    }

    private var frames: [Keyframe] { reference.keyframes + reference.snapshots.map(\.frame) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ExploreSceneView(scene: scene).ignoresSafeArea()
            if !ready {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            }
            VStack {
                HStack(spacing: 14) {
                    Button("Done") { dismiss() }.font(.body.weight(.semibold))
                    Spacer()
                    Button { jump(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                    Text("From frame \(frameIndex + 1)").font(.footnote.weight(.semibold)).monospacedDigit()
                    Button { jump(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2)
                Spacer()
                if ready {
                    Text("One finger: look. Two fingers: slide. Pinch: forward and back.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.75))
                        .padding(.bottom, 10)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let result = await scene.build()
            status = result.framesUsed == 0 ? "This reference has no depth to build a 3D view from." : ""
            ready = result.framesUsed > 0
            if ready { scene.fly(to: frames.first) }
        }
    }

    private func jump(_ step: Int) {
        guard !frames.isEmpty else { return }
        frameIndex = min(max(frameIndex + step, 0), frames.count - 1)
        scene.fly(to: frames[frameIndex])
    }
}

@MainActor
final class ExploreScene: ObservableObject {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let reference: Reference
    private let placer: ModelPlacer
    private let measurer: Measurer

    init(reference: Reference) {
        self.reference = reference
        let folder = ReferenceStore.folder(for: reference.id)
        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = 60
        camera.fieldOfView = 70
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        placer = ModelPlacer(session: ARSession(), root: scene.rootNode, folder: folder)
        measurer = Measurer(session: ARSession(), parent: scene.rootNode)
        scene.background.contents = UIColor.black
        measurer.load(measurements: reference.measurements, notes: reference.notes, removed: reference.removedMarks)
        placer.load(reference.models)
        if let first = (reference.keyframes + reference.snapshots.map(\.frame)).first { place(first) }
    }

    /// Builds the point cloud off the main thread, then adds it to the scene.
    func build() async -> SceneCloud.Result {
        let frames = reference.keyframes + reference.snapshots.map(\.frame)
        let folder = ReferenceStore.folder(for: reference.id)
        let result = await Task.detached(priority: .userInitiated) { SceneCloud.build(frames: frames, folder: folder) }.value
        if let geometry = SceneCloud.geometry(result) {
            let node = SCNNode(geometry: geometry)
            node.name = "cloud"
            scene.rootNode.addChildNode(node)
        }
        Diagnostics.log("Explore: \(result.positions.count) points from \(result.framesUsed) of \(frames.count) frames")
        return result
    }

    private func place(_ frame: Keyframe) {
        let position = frame.position
        cameraNode.simdPosition = position
        cameraNode.simdLook(at: position + frame.forward, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    func fly(to frame: Keyframe?) {
        guard let frame else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        place(frame)
        SCNTransaction.commit()
    }
}

struct ExploreSceneView: UIViewRepresentable {
    let scene: ExploreScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .fly
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
