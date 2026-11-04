import ARKit
import SceneKit
import SwiftUI
import UIKit

/// Scan anything by just walking round it, like Scaniverse (Phil, 2026-11-04): no bounding box.
/// The LiDAR depth of each picture taken on the way becomes a small mesh, textured with that same
/// picture (so the texture lines up exactly), and drawn live as a blue skin to show what is covered.
/// Finish joins them into one USDZ (Files > Reset > Scans) that can be placed in the camera.
///
/// ARKit's own scene mesh is not used: on Phil's iPhone 14 Pro (iOS 26) it stayed empty, in line
/// with every LiDAR pixel being reported as low confidence.
@MainActor
final class FreeScanner: NSObject, ObservableObject, ARSCNViewDelegate {
    enum Phase: Equatable {
        case scanning, building, done(URL), failed(String)
    }

    @Published var phase: Phase = .scanning
    @Published var triangles = 0
    @Published var pictures = 0

    let view = ARSCNView()
    static var supported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    /// One picture and the surface its depth saw, in room coordinates.
    private struct Shot: Sendable {
        let jpeg: Data
        let transform: simd_float4x4
        var vertices: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []  // 0 to 1 across the picture, y down
        var indices: [UInt32] = []
    }

    private var shots: [Shot] = []
    private var lastShot: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var lastLog: TimeInterval = 0
    private let ciContext = CIContext()
    private static let maxShots = 100
    private static let shotWidth = 1280
    /// Every third depth pixel makes a mesh vertex.
    private static let step = 3

    func start() {
        view.delegate = self
        view.automaticallyUpdatesLighting = true
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        configuration.environmentTexturing = .none
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Diagnostics.log("Free scan started")
    }

    func stop() {
        view.session.pause()
    }

    // MARK: Frames

    /// ARSCNView is its own session delegate, so frames are read here.
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let frame = self.view.session.currentFrame { self.handle(frame) }
            }
        }
    }

    private func handle(_ frame: ARFrame) {
        guard phase == .scanning else { return }
        if frame.timestamp - lastLog > 2 {
            lastLog = frame.timestamp
            Diagnostics.log("Free scan: \(shots.count) pictures, \(triangles) triangles, tracking \(frame.camera.trackingState), depth \(frame.sceneDepth != nil)")
        }
        guard case .normal = frame.camera.trackingState else { return }
        guard frame.timestamp - lastTime > 0.4, shots.count < Self.maxShots else { return }
        if let last = lastShot {
            let moved = simd_distance(last.columns.3, frame.camera.transform.columns.3)
            let turned = Self.angle(between: last, and: frame.camera.transform)
            guard moved > 0.15 || turned > 0.25 else { return }
        }
        guard let shot = makeShot(frame) else { return }
        lastTime = frame.timestamp
        lastShot = frame.camera.transform
        shots.append(shot)
        pictures = shots.count
        triangles += shot.indices.count / 3
        show(shot)
    }

    private static func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
        let fa = SIMD3(-a.columns.2.x, -a.columns.2.y, -a.columns.2.z)
        let fb = SIMD3(-b.columns.2.x, -b.columns.2.y, -b.columns.2.z)
        return acos(max(-1, min(1, simd_dot(fa, fb))))
    }

    /// Keeps the picture as a JPEG and turns its depth into a grid mesh.
    private func makeShot(_ frame: ARFrame) -> Shot? {
        guard let depth = Measurer.depth(of: frame), depth.width > 4, depth.height > 4 else { return nil }
        let buffer = frame.capturedImage
        let fullWidth = CVPixelBufferGetWidth(buffer), fullHeight = CVPixelBufferGetHeight(buffer)
        let scale = CGFloat(Self.shotWidth) / CGFloat(fullWidth)
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = ciContext.jpegRepresentation(
            of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [key: 0.8])
        else { return nil }
        var shot = Shot(jpeg: jpeg, transform: frame.camera.transform)
        // Intrinsics are for the full-size picture; depth pixels map onto it by proportion.
        let k = frame.camera.intrinsics
        let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
        let imageWidth = Float(fullWidth), imageHeight = Float(fullHeight)
        let step = Self.step
        let columns = (depth.width - 1) / step + 1, rows = (depth.height - 1) / step + 1
        var grid = [Int32](repeating: -1, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                let i = min(c * step, depth.width - 1), j = min(r * step, depth.height - 1)
                let d = depth.values[j * depth.width + i]
                guard d.isFinite, (0.15...5).contains(d) else { continue }
                let u = (Float(i) + 0.5) / Float(depth.width) * imageWidth
                let v = (Float(j) + 0.5) / Float(depth.height) * imageHeight
                let local = SIMD4((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
                let w = frame.camera.transform * local
                grid[r * columns + c] = Int32(shot.vertices.count)
                shot.vertices.append(SIMD3(w.x, w.y, w.z))
                shot.uvs.append(SIMD2(u / imageWidth, v / imageHeight))
            }
        }
        func depthAt(_ c: Int, _ r: Int) -> Float {
            depth.values[min(r * step, depth.height - 1) * depth.width + min(c * step, depth.width - 1)]
        }
        for r in 0..<rows - 1 {
            for c in 0..<columns - 1 {
                let a = grid[r * columns + c], b = grid[r * columns + c + 1]
                let d = grid[(r + 1) * columns + c], e = grid[(r + 1) * columns + c + 1]
                guard a >= 0, b >= 0, d >= 0, e >= 0 else { continue }
                let ds = [depthAt(c, r), depthAt(c + 1, r), depthAt(c, r + 1), depthAt(c + 1, r + 1)]
                // No skin across a jump between a near thing and a far one.
                guard let low = ds.min(), let high = ds.max(), high - low < 0.04 + 0.06 * low else { continue }
                shot.indices.append(contentsOf: [UInt32(a), UInt32(d), UInt32(b), UInt32(b), UInt32(d), UInt32(e)])
            }
        }
        return shot.indices.isEmpty ? nil : shot
    }

    /// Draws a picture's surface in the camera view: a see-through blue skin with bright lines.
    private func show(_ shot: Shot) {
        let source = SCNGeometrySource(vertices: shot.vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: shot.indices, primitiveType: .triangles)
        let skin = SCNGeometry(sources: [source], elements: [element])
        let skinMaterial = SCNMaterial()
        skinMaterial.diffuse.contents = UIColor(red: 0.1, green: 0.5, blue: 1, alpha: 1)
        skinMaterial.transparency = 0.3
        skinMaterial.lightingModel = .constant
        skinMaterial.isDoubleSided = true
        skinMaterial.writesToDepthBuffer = false
        skin.materials = [skinMaterial]
        let wire = SCNGeometry(sources: [source], elements: [element])
        let wireMaterial = SCNMaterial()
        wireMaterial.diffuse.contents = UIColor.cyan
        wireMaterial.transparency = 0.6
        wireMaterial.lightingModel = .constant
        wireMaterial.isDoubleSided = true
        wireMaterial.fillMode = .lines
        wireMaterial.writesToDepthBuffer = false
        wire.materials = [wireMaterial]
        let node = SCNNode()
        node.addChildNode(SCNNode(geometry: skin))
        node.addChildNode(SCNNode(geometry: wire))
        view.scene.rootNode.addChildNode(node)
    }

    // MARK: Finish

    func finish() {
        guard phase == .scanning else { return }
        view.session.pause()
        guard !shots.isEmpty else {
            phase = .failed("Nothing was scanned. Walk slowly round the object with the phone 0.5 to 3 m away until the blue skin covers it.")
            return
        }
        phase = .building
        let shots = self.shots
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = ObjectScanner.scansFolder.appendingPathComponent("Free-\(stamp).usdz")
        Diagnostics.log("Free scan finishing: \(shots.count) pictures, \(triangles) triangles")
        Task.detached(priority: .userInitiated) {
            let ok = Self.export(shots, to: output)
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

    /// One model: each picture's mesh with that picture as its texture. The middle is at the origin
    /// and the lowest point on the floor.
    private nonisolated static func export(_ shots: [Shot], to url: URL) -> Bool {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for shot in shots {
            for v in shot.vertices {
                low = simd_min(low, v)
                high = simd_max(high, v)
            }
        }
        let shift = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
        var vertices = [SCNVector3](), uvs = [CGPoint]()
        var elements = [SCNGeometryElement](), materials = [SCNMaterial]()
        for shot in shots {
            guard let image = UIImage(data: shot.jpeg) else { continue }
            let base = UInt32(vertices.count)
            for v in shot.vertices {
                let p = v - shift
                vertices.append(SCNVector3(p.x, p.y, p.z))
            }
            uvs.append(contentsOf: shot.uvs.map { CGPoint(x: Double($0.x), y: Double($0.y)) })
            elements.append(SCNGeometryElement(indices: shot.indices.map { $0 + base }, primitiveType: .triangles))
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.lightingModel = .constant
            material.isDoubleSided = true
            materials.append(material)
        }
        guard !elements.isEmpty else { return false }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uvs)],
            elements: elements)
        geometry.materials = materials
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        try? FileManager.default.removeItem(at: url)
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
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
                Text("Walk slowly round it. The blue skin shows what is covered.").font(.footnote)
                pill("Finish") { scanner.finish() }
            }
        case .building:
            VStack(spacing: 10) {
                ProgressView()
                Text("Joining the pictures and saving…").font(.subheadline)
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
