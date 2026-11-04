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
final class FreeScanner: NSObject, ObservableObject {
    enum Phase: Equatable {
        case scanning, building, done(URL), failed(String)
    }

    @Published var phase: Phase = .scanning
    /// Whether the scan overlay is showing at all.
    @Published var active = false
    @Published var triangles = 0
    @Published var pictures = 0

    static var supported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    /// The camera view's own session is used, so models and marks stay where they are.
    private weak var recorder: Recorder?
    private var skins = SCNNode()

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

    func start(_ recorder: Recorder) {
        guard !active else { return }
        guard recorder.session.currentFrame?.sceneDepth != nil || recorder.session.currentFrame == nil else {
            phase = .failed("Turn LiDAR on (top bar) to scan.")
            active = true
            return
        }
        self.recorder = recorder
        shots = []
        lastShot = nil
        lastTime = 0
        previous = nil
        triangles = 0
        pictures = 0
        phase = .scanning
        active = true
        skins = SCNNode()
        recorder.modelsNode.addChildNode(skins)
        recorder.frameTap = { [weak self] frame in self?.handle(frame) }
        Diagnostics.log("Free scan started")
    }

    /// Leaves the scan screen; the scanned model (if any) was saved to Files already.
    func close() {
        recorder?.frameTap = nil
        skins.removeFromParentNode()
        skins = SCNNode()
        shots = []
        active = false
    }

    private func handle(_ frame: ARFrame) {
        guard phase == .scanning else { return }
        if frame.timestamp - lastLog > 2 {
            lastLog = frame.timestamp
            Diagnostics.log("Free scan: \(shots.count) pictures, \(triangles) triangles, tracking \(frame.camera.trackingState), depth \(frame.sceneDepth != nil)")
        }
        // The LiDAR depth lags a moving phone and the picture blurs, so pictures are only kept when
        // the phone is moving slowly.
        let slow = isSlow(frame)
        guard slow, case .normal = frame.camera.trackingState else { return }
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

    private var previous: (transform: simd_float4x4, time: TimeInterval)?

    /// Under 20 cm/s and 40 degrees/s since the last frame.
    private func isSlow(_ frame: ARFrame) -> Bool {
        defer { previous = (frame.camera.transform, frame.timestamp) }
        guard let previous, frame.timestamp > previous.time else { return false }
        let dt = Float(frame.timestamp - previous.time)
        let moved = simd_distance(previous.transform.columns.3, frame.camera.transform.columns.3) / dt
        let turned = Self.angle(between: previous.transform, and: frame.camera.transform) / dt
        return moved < 0.2 && turned < 0.7
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
        let mesh = DepthMesh.build(
            depth: depth.values, width: depth.width, height: depth.height, camera: frame.camera.transform,
            intrinsics: frame.camera.intrinsics, imageWidth: Float(fullWidth), imageHeight: Float(fullHeight),
            step: Self.step)
        shot.vertices = mesh.vertices
        shot.uvs = mesh.uvs
        shot.indices = mesh.indices
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
        skins.addChildNode(node)
    }

    // MARK: Finish

    func finish() {
        guard phase == .scanning else { return }
        recorder?.frameTap = nil
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

/// The scan controls, over the camera view: Cancel and a count on top, Finish, then Place.
struct FreeScanOverlay: View {
    @ObservedObject var scanner: FreeScanner
    /// Called with the finished USDZ when the person taps Place.
    let place: (URL) -> Void

    var body: some View {
        if scanner.active {
            VStack(spacing: 10) {
                HStack {
                    Button("Cancel") { scanner.close() }
                    Spacer()
                    if scanner.phase == .scanning {
                        Text("\(scanner.triangles / 1000)k triangles · \(scanner.pictures) pictures")
                            .font(.footnote.monospacedDigit())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 108)
                switch scanner.phase {
                case .scanning:
                    Text("Walk slowly round it. The blue skin shows what is covered.").font(.footnote)
                    pill("Finish") { scanner.finish() }
                case .building:
                    ProgressView()
                    Text("Joining the pictures and saving…").font(.subheadline)
                case .done(let url):
                    Text("Saved in Files > Reset > Scans").font(.footnote)
                    pill("Place in the camera") {
                        place(url)
                        scanner.close()
                    }
                case .failed(let message):
                    Text(message).font(.subheadline).multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
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
