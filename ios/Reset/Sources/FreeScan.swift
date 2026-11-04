import ARKit
import SceneKit
import SwiftUI
import UIKit

/// Scan anything by just walking round it, like Scaniverse (Phil, 2026-11-04): no bounding box.
/// The LiDAR scene mesh builds up live on the camera picture; Finish colours it from pictures
/// taken on the way and saves a USDZ (Files > Reset > Scans) that can be placed in the camera.
@MainActor
final class FreeScanner: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    enum Phase: Equatable {
        case scanning, building, done(URL), failed(String)
    }

    @Published var phase: Phase = .scanning
    @Published var triangles = 0
    @Published var pictures = 0

    let view = ARSCNView()
    static var supported: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    /// One picture kept for colouring: small, with where the camera was.
    private struct Shot {
        let width: Int, height: Int
        let pixels: [UInt8]  // BGRA
        let transform: simd_float4x4
        let fx: Float, fy: Float, cx: Float, cy: Float
    }

    private var shots: [Shot] = []
    private var lastShot: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private let ciContext = CIContext()
    private static let maxShots = 70
    private static let shotWidth = 640

    func start() {
        view.delegate = self
        view.session.delegate = self
        view.automaticallyUpdatesLighting = true
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.environmentTexturing = .none
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Diagnostics.log("Free scan started")
    }

    func stop() {
        view.session.pause()
    }

    // MARK: Live mesh

    nonisolated func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor else { return nil }
        let node = SCNNode(geometry: FreeScanner.liveGeometry(mesh))
        return node
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        node.geometry = FreeScanner.liveGeometry(mesh)
    }

    private nonisolated static func liveGeometry(_ anchor: ARMeshAnchor) -> SCNGeometry {
        let mesh = read(anchor.geometry)
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })],
            elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.cyan.withAlphaComponent(0.35)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.fillMode = .lines
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    // MARK: Pictures for colour

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        guard phase == .scanning, case .normal = frame.camera.trackingState else { return }
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let count = meshes.reduce(0) { $0 + $1.geometry.faces.count }
        if count != triangles { triangles = count }
        guard frame.timestamp - lastTime > 0.4, shots.count < Self.maxShots else { return }
        if let last = lastShot {
            let moved = simd_distance(last.columns.3, frame.camera.transform.columns.3)
            let turned = Self.angle(between: last, and: frame.camera.transform)
            guard moved > 0.12 || turned > 0.2 else { return }
        }
        lastTime = frame.timestamp
        lastShot = frame.camera.transform
        if let shot = makeShot(frame) {
            shots.append(shot)
            pictures = shots.count
        }
    }

    private static func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
        let fa = SIMD3(-a.columns.2.x, -a.columns.2.y, -a.columns.2.z)
        let fb = SIMD3(-b.columns.2.x, -b.columns.2.y, -b.columns.2.z)
        return acos(max(-1, min(1, simd_dot(fa, fb))))
    }

    private func makeShot(_ frame: ARFrame) -> Shot? {
        let buffer = frame.capturedImage
        let fullWidth = CVPixelBufferGetWidth(buffer), fullHeight = CVPixelBufferGetHeight(buffer)
        let scale = CGFloat(Self.shotWidth) / CGFloat(fullWidth)
        let width = Self.shotWidth, height = Int((CGFloat(fullHeight) * scale).rounded())
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            ciContext.render(
                image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let k = frame.camera.intrinsics
        let s = Float(scale)
        return Shot(
            width: width, height: height, pixels: pixels, transform: frame.camera.transform,
            fx: k[0][0] * s, fy: k[1][1] * s, cx: k[2][0] * s, cy: k[2][1] * s)
    }

    // MARK: Finish

    private struct Raw: Sendable {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
    }

    func finish() {
        guard phase == .scanning else { return }
        let anchors = view.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        view.session.pause()
        guard !anchors.isEmpty else {
            phase = .failed("Nothing was scanned. Walk slowly round the object with the phone 0.5 to 3 m away until the blue mesh covers it.")
            return
        }
        phase = .building
        // Everything into world space, one list.
        var raw = Raw()
        for anchor in anchors {
            let part = Self.read(anchor.geometry)
            let base = UInt32(raw.vertices.count)
            let t = anchor.transform
            for (v, n) in zip(part.vertices, part.normals) {
                let w = t * SIMD4(v, 1)
                let wn = t * SIMD4(n, 0)
                raw.vertices.append(SIMD3(w.x, w.y, w.z))
                raw.normals.append(simd_normalize(SIMD3(wn.x, wn.y, wn.z)))
            }
            raw.indices.append(contentsOf: part.indices.map { $0 + base })
        }
        let shots = self.shots
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = ObjectScanner.scansFolder.appendingPathComponent("Free-\(stamp).usdz")
        Diagnostics.log("Free scan: \(raw.vertices.count) vertices, \(raw.indices.count / 3) triangles, \(shots.count) pictures")
        Task.detached(priority: .userInitiated) { [raw] in
            let colours = Self.colours(for: raw, shots: shots)
            let ok = Self.export(raw, colours: colours, to: output)
            await MainActor.run {
                if ok {
                    Diagnostics.log("Free scan saved: \(output.lastPathComponent)")
                    self.phase = .done(output)
                } else {
                    Diagnostics.log("Free scan export failed")
                    self.phase = .failed("The model could not be saved.")
                }
            }
        }
    }

    /// Each vertex takes its colour from the picture that saw it most face-on and closest.
    private nonisolated static func colours(for raw: Raw, shots: [Shot]) -> [SIMD4<Float>] {
        var colours = [SIMD4<Float>](repeating: SIMD4(0.6, 0.6, 0.6, 1), count: raw.vertices.count)
        var best = [Float](repeating: 0.1, count: raw.vertices.count)
        for shot in shots {
            let inverse = shot.transform.inverse
            let eye = SIMD3(shot.transform.columns.3.x, shot.transform.columns.3.y, shot.transform.columns.3.z)
            shot.pixels.withUnsafeBufferPointer { pixels in
                for i in 0..<raw.vertices.count {
                    let w = raw.vertices[i]
                    let c = inverse * SIMD4(w, 1)
                    let depth = -c.z
                    guard depth > 0.15 else { continue }
                    let px = shot.cx + shot.fx * c.x / depth
                    let py = shot.cy - shot.fy * c.y / depth
                    guard px >= 2, py >= 2, px < Float(shot.width - 2), py < Float(shot.height - 2) else { continue }
                    let toEye = eye - w
                    let distance = simd_length(toEye)
                    let facing = simd_dot(raw.normals[i], toEye / max(distance, 0.001))
                    guard facing > 0.2 else { continue }
                    let score = facing / (1 + distance * 0.4)
                    guard score > best[i] else { continue }
                    best[i] = score
                    let offset = (Int(py) * shot.width + Int(px)) * 4
                    colours[i] = SIMD4(
                        Float(pixels[offset + 2]) / 255, Float(pixels[offset + 1]) / 255,
                        Float(pixels[offset]) / 255, 1)
                }
            }
        }
        return colours
    }

    /// One coloured mesh with its base on the floor and its middle at the origin, saved as USDZ.
    private nonisolated static func export(_ raw: Raw, colours: [SIMD4<Float>], to url: URL) -> Bool {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for v in raw.vertices {
            low = simd_min(low, v)
            high = simd_max(high, v)
        }
        let shift = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
        let vertices = raw.vertices.map { SCNVector3($0.x - shift.x, $0.y - shift.y, $0.z - shift.z) }
        let normals = raw.normals.map { SCNVector3($0.x, $0.y, $0.z) }
        let colourData = colours.withUnsafeBufferPointer { Data(buffer: $0) }
        let colourSource = SCNGeometrySource(
            data: colourData, semantic: .color, vectorCount: colours.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), colourSource],
            elements: [SCNGeometryElement(indices: raw.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.9
        material.isDoubleSided = true
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        try? FileManager.default.removeItem(at: url)
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }

    // MARK: Reading ARKit meshes

    private nonisolated static func read(_ g: ARMeshGeometry) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        func floats(_ source: ARGeometrySource) -> [SIMD3<Float>] {
            (0..<source.count).map { i in
                let p = source.buffer.contents().advanced(by: source.offset + source.stride * i)
                    .assumingMemoryBound(to: Float.self)
                return SIMD3(p[0], p[1], p[2])
            }
        }
        let faces = g.faces
        let per = faces.indexCountPerPrimitive
        var indices = [UInt32]()
        indices.reserveCapacity(faces.count * per)
        for i in 0..<faces.count * per {
            let p = faces.buffer.contents().advanced(by: i * faces.bytesPerIndex)
            indices.append(faces.bytesPerIndex == 4 ? p.assumingMemoryBound(to: UInt32.self).pointee
                : UInt32(p.assumingMemoryBound(to: UInt16.self).pointee))
        }
        return (floats(g.vertices), floats(g.normals), indices)
    }
}

private struct FreeScanCamera: UIViewRepresentable {
    let scanner: FreeScanner
    func makeUIView(context: Context) -> ARSCNView { scanner.view }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}

struct FreeScanView: View {
    /// Called with the finished USDZ when the person taps Place.
    let place: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = FreeScanner()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if scanner.phase == .scanning {
                FreeScanCamera(scanner: scanner).ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button("Cancel") {
                        scanner.stop()
                        dismiss()
                    }
                    .padding(10)
                    Spacer()
                    if scanner.phase == .scanning {
                        Text("\(scanner.triangles / 1000)k triangles · \(scanner.pictures) pictures")
                            .font(.footnote.monospacedDigit())
                            .padding(10)
                    }
                }
                Spacer()
                controls.padding(.bottom, 30)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
        }
        .preferredColorScheme(.dark)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    @ViewBuilder private var controls: some View {
        switch scanner.phase {
        case .scanning:
            VStack(spacing: 10) {
                Text("Walk slowly round it. The blue mesh shows what is covered.").font(.footnote)
                pill("Finish") { scanner.finish() }
            }
        case .building:
            VStack(spacing: 10) {
                ProgressView()
                Text("Colouring and saving…").font(.subheadline)
            }
        case .done(let url):
            VStack(spacing: 10) {
                Text("Saved in Files > Reset > Scans").font(.footnote)
                pill("Place in the camera") {
                    place(url)
                    dismiss()
                }
            }
        case .failed(let message):
            Text(message).font(.subheadline).multilineTextAlignment(.center).padding()
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(.black)
        }
    }
}
