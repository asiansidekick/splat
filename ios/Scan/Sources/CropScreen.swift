import SceneKit
import SwiftUI
import simd

/// After the whole area is built: shows the model with a suggested crop round the object (floor
/// cut away), adjustable from above and from the side. Cut rebuilds just what is inside.
struct CropScreen: View {
    @EnvironmentObject var model: ScanModel
    let folder: ScanFolder

    @State private var loaded: CropScene?
    @State private var box = CropBox(min: .zero, max: .one)
    @State private var suggested: CropBox?
    @State private var view: CropAxis = .above

    var body: some View {
        VStack(spacing: 0) {
            if let loaded {
                ModelPreview(scene: loaded.scene, box: box)
                    .frame(maxHeight: .infinity)
                Picker("View", selection: $view) {
                    Text("From above").tag(CropAxis.above)
                    Text("From the side").tag(CropAxis.side)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                CropEditor(points: loaded.drawPoints, all: loaded.bounds, axis: view, box: $box)
                    .frame(height: 230)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Text(sizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                buttons
            } else {
                Spacer()
                ProgressView("Loading the scan…").tint(.white)
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .task(id: folder.url) { await load() }
    }

    private var sizeText: String {
        let s = box.size * 100
        return String(format: "Keeps %.0f × %.0f × %.0f cm (W × D × H)", s.x, s.z, s.y)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Keep all") { model.keepAll(folder) }
                .buttonStyle(.bordered)
            if let suggested, suggested != box {
                Button("Auto") { box = suggested }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button {
                guard let loaded else { return }
                let sessionBox = loaded.mapping.toSession(box)
                ScanLog.add("Cut: model box \(box.min) to \(box.max), session box \(sessionBox.min) to \(sessionBox.max), mapping \(loaded.mapping)")
                model.build(folder, crop: sessionBox)
            } label: {
                Label("Cut", systemImage: "scissors").font(.headline)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func load() async {
        let url = folder.full
        let session = folder.sessionBounds
        let result = await Task.detached(priority: .userInitiated) { CropScene.load(url, sessionBounds: session) }.value
        guard let result else {
            ScanLog.add("Crop: couldn't read \(url.lastPathComponent)")
            model.keepAll(folder)
            return
        }
        loaded = result
        box = result.suggestion.box
        suggested = result.suggestion.box
        ScanLog.add("Crop: \(result.pointCount) points, model bounds \(result.bounds.min) to \(result.bounds.max), floor \(result.suggestion.floorY.map { String(format: "%.3f", $0) } ?? "none"), suggested \(box.min) to \(box.max), mapping \(result.mapping)")
    }
}

enum CropAxis: Hashable { case above, side }

/// The loaded full model and what the crop screen needs from it.
struct CropScene: @unchecked Sendable {
    let scene: SCNScene
    let bounds: CropBox
    let drawPoints: [SIMD3<Float>]
    let pointCount: Int
    let suggestion: CropMath.Result
    let mapping: CropMath.Mapping

    static func load(_ url: URL, sessionBounds: CropBox?) -> CropScene? {
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        let points = vertices(scene)
        guard let bounds = CropBox.around(points) else { return nil }
        let sample = CropMath.thin(points, limit: 120_000)
        let suggestion = CropMath.suggest(sample) ?? CropMath.Result(box: bounds, floorY: nil)
        return CropScene(scene: scene, bounds: bounds, drawPoints: CropMath.thin(points, limit: 6000),
                         pointCount: points.count, suggestion: suggestion,
                         mapping: CropMath.mapping(model: bounds, session: sessionBounds))
    }

    /// Every mesh vertex in scene (world) coordinates.
    static func vertices(_ scene: SCNScene) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first,
                  source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else { return }
            let m = node.simdWorldTransform
            let stride = source.dataStride, offset = source.dataOffset
            source.data.withUnsafeBytes { raw in
                for i in 0..<source.vectorCount {
                    let base = offset + i * stride
                    guard base + 12 <= raw.count else { break }
                    let p = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                                         raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                         raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self), 1)
                    let w = m * p
                    out.append(SIMD3(w.x, w.y, w.z))
                }
            }
        }
        return out
    }
}

/// The model in 3D (drag to turn, pinch to zoom) with the crop box drawn round it.
struct ModelPreview: UIViewRepresentable {
    let scene: SCNScene
    let box: CropBox

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        let node = SCNNode()
        node.name = "crop-box"
        scene.rootNode.addChildNode(node)
        update(node)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if let node = scene.rootNode.childNode(withName: "crop-box", recursively: false) { update(node) }
    }

    private func update(_ node: SCNNode) {
        let s = box.size
        let shape = SCNBox(width: CGFloat(s.x), height: CGFloat(s.y), length: CGFloat(s.z), chamferRadius: 0)
        let edges = SCNMaterial()
        edges.diffuse.contents = UIColor.systemYellow
        edges.emission.contents = UIColor.systemYellow
        edges.fillMode = .lines
        edges.isDoubleSided = true
        edges.lightingModel = .constant
        shape.materials = [edges]
        node.geometry = shape
        node.simdPosition = box.centre
    }
}

/// A flat view of the scan's points with the crop drawn as a rectangle. Drag an edge to move it,
/// or drag inside to slide the whole box.
struct CropEditor: View {
    let points: [SIMD3<Float>]
    let all: CropBox
    let axis: CropAxis
    @Binding var box: CropBox

    @State private var grab: Grab?
    private enum Edge { case left, right, top, bottom, inside }
    private struct Grab { let edge: Edge; let start: CropBox }

    /// Horizontal axis is x in both views; vertical is z (from above) or y (from the side, up).
    private var vIndex: Int { axis == .above ? 2 : 1 }
    private var flipV: Bool { axis == .side }

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(all: all, v: vIndex, flip: flipV, size: geo.size)
            Canvas { ctx, _ in
                var dots = Path()
                for p in points {
                    let q = fit.screen(p.x, p[vIndex])
                    dots.addRect(CGRect(x: q.x - 0.75, y: q.y - 0.75, width: 1.5, height: 1.5))
                }
                ctx.fill(dots, with: .color(.white.opacity(0.55)))
                let r = fit.rect(box)
                ctx.fill(Path(r), with: .color(.yellow.opacity(0.12)))
                ctx.stroke(Path(r), with: .color(.yellow), lineWidth: 2)
                for c in [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.yellow))
                }
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if grab == nil { grab = Grab(edge: pick(g.startLocation, fit.rect(box)), start: box) }
                    guard let grab else { return }
                    apply(grab, dx: Float(g.translation.width) / fit.scale,
                          dv: Float(g.translation.height) / fit.scale * (flipV ? -1 : 1))
                }
                .onEnded { _ in grab = nil })
        }
    }

    private func pick(_ p: CGPoint, _ r: CGRect) -> Edge {
        let reach: CGFloat = 30
        let inV = p.y > r.minY - reach && p.y < r.maxY + reach
        let inH = p.x > r.minX - reach && p.x < r.maxX + reach
        var best: (Edge, CGFloat) = (.inside, .infinity)
        if inV { for (e, d) in [(Edge.left, abs(p.x - r.minX)), (.right, abs(p.x - r.maxX))] where d < best.1 { best = (e, d) } }
        if inH { for (e, d) in [(Edge.top, abs(p.y - r.minY)), (.bottom, abs(p.y - r.maxY))] where d < best.1 { best = (e, d) } }
        return best.1 <= reach ? best.0 : .inside
    }

    private func apply(_ grab: Grab, dx: Float, dv: Float) {
        var b = grab.start
        let v = vIndex
        // Screen top is the larger value from the side (y up) and the smaller one from above.
        let topIsMax = flipV
        switch grab.edge {
        case .left: b.min.x += dx
        case .right: b.max.x += dx
        case .top: if topIsMax { b.max[v] += dv } else { b.min[v] += dv }
        case .bottom: if topIsMax { b.min[v] += dv } else { b.max[v] += dv }
        case .inside:
            b.min.x += dx; b.max.x += dx
            b.min[v] += dv; b.max[v] += dv
        }
        b.keepOpen()
        box = b
    }
}

/// Fits the scan's bounds (x and one other axis) into the editor with a margin, keeping aspect.
private struct Fit {
    let originX: Float, originV: Float, scale: Float, flip: Bool, v: Int
    let size: CGSize, offX: CGFloat, offY: CGFloat, spanV: Float

    init(all: CropBox, v: Int, flip: Bool, size: CGSize) {
        let pad: Float = 0.08
        let w = Swift.max(all.size.x, 0.01) * (1 + 2 * pad)
        let h = Swift.max(all.size[v], 0.01) * (1 + 2 * pad)
        scale = Swift.min(Float(size.width) / w, Float(size.height) / h)
        originX = all.min.x - all.size.x * pad
        originV = all.min[v] - all.size[v] * pad
        spanV = h
        offX = (size.width - CGFloat(w * scale)) / 2
        offY = (size.height - CGFloat(h * scale)) / 2
        self.flip = flip
        self.v = v
        self.size = size
    }

    func screen(_ x: Float, _ vv: Float) -> CGPoint {
        let sx = offX + CGFloat((x - originX) * scale)
        let along = (vv - originV) * scale
        let sy = flip ? offY + CGFloat(spanV * scale - along) : offY + CGFloat(along)
        return CGPoint(x: sx, y: sy)
    }

    func rect(_ b: CropBox) -> CGRect {
        let a = screen(b.min.x, b.min[v]), c = screen(b.max.x, b.max[v])
        return CGRect(x: Swift.min(a.x, c.x), y: Swift.min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
    }
}
