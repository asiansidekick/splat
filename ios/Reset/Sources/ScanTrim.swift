import SceneKit
import SwiftUI
import simd

/// Trimming a scan (Phil, 2026-11-17: "can I crop with the same kind of tools cut-out does?"): turn the model with a
/// finger, then draw a loop round what to erase, or round what to keep. A loop cuts straight through the model from
/// where it is looked at. Only the list of triangles changes; the points, colours and pictures stay as scanned.
@MainActor
final class ScanTrimmer: ObservableObject {
    /// One piece of the model: its points, and for each of its materials the triangles still there.
    private struct Piece {
        let node: SCNNode
        let sources: [SCNGeometrySource]
        let materials: [SCNMaterial]
        let positions: [SIMD3<Float>]
        var elements: [[UInt32]]
    }

    let scene = SCNScene()
    weak var view: SCNView?
    private var pieces: [Piece] = []
    private var history: [[[[UInt32]]]] = []
    private var original: [[[UInt32]]] = []
    @Published private(set) var canUndo = false
    @Published private(set) var changed = false
    @Published private(set) var triangles = 0
    @Published private(set) var failed: String?
    @Published private(set) var ready = false

    func load(_ url: URL) {
        guard let loaded = try? SCNScene(url: url, options: nil) else {
            failed = "This scan couldn't be opened."
            return
        }
        for child in loaded.rootNode.childNodes { scene.rootNode.addChildNode(child) }
        scene.background.contents = UIColor(white: 0.12, alpha: 1)
        // The scan's colours are photographs: even light from everywhere shows them as they are.
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .ambient
        light.light?.intensity = 1000
        light.name = "trim-light"
        scene.rootNode.addChildNode(light)
        var found: [Piece] = []
        var unreadable = false
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            guard let positions = Self.positions(of: geometry), let elements = Self.triangles(of: geometry) else {
                unreadable = true
                return
            }
            found.append(Piece(node: node, sources: geometry.sources, materials: geometry.materials, positions: positions, elements: elements))
        }
        guard !found.isEmpty, !unreadable else {
            failed = "This scan is in a form that can't be trimmed here."
            Diagnostics.log("Trim: \(found.count) pieces read, unreadable \(unreadable)")
            return
        }
        pieces = found
        original = found.map(\.elements)
        count()
        ready = true
        Diagnostics.log("Trim opened: \(url.lastPathComponent), \(found.count) pieces, \(triangles) triangles")
    }

    private func count() {
        triangles = pieces.reduce(0) { $0 + $1.elements.reduce(0) { $0 + $1.count / 3 } }
    }

    private static func positions(of geometry: SCNGeometry) -> [SIMD3<Float>]? {
        guard let source = geometry.sources(for: .vertex).first, source.usesFloatComponents,
            source.bytesPerComponent == 4, source.componentsPerVector >= 3
        else { return nil }
        let stride = source.dataStride, offset = source.dataOffset, count = source.vectorCount
        let data = source.data
        guard stride > 0, data.count >= offset + (count - 1) * stride + 12 else { return nil }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = offset + i * stride
                out.append(SIMD3(
                    raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)))
            }
        }
        return out
    }

    /// The corner numbers of every triangle, one list for each material.
    private static func triangles(of geometry: SCNGeometry) -> [[UInt32]]? {
        var all: [[UInt32]] = []
        for element in geometry.elements {
            guard element.primitiveType == .triangles else { return nil }
            let count = element.primitiveCount * 3, bytes = element.bytesPerIndex
            let data = element.data
            guard data.count >= count * bytes else { return nil }
            var out: [UInt32] = []
            out.reserveCapacity(count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    switch bytes {
                    case 1: out.append(UInt32(raw.load(fromByteOffset: i, as: UInt8.self)))
                    case 2: out.append(UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                    default: out.append(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    }
                }
            }
            all.append(out)
        }
        return all
    }

    /// A loop drawn on the screen, in the view's points: erases what is inside it, or keeps only that.
    func apply(loop: [CGPoint], keep: Bool) {
        guard ready, loop.count >= 3, let view, let eye = view.pointOfView, let camera = eye.camera else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let projection = simd_float4x4(camera.projectionTransform(withViewportSize: size))
        let toClip = projection * eye.simdWorldTransform.inverse
        let path = loop.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let before = pieces.map(\.elements)
        var removed = 0
        for index in pieces.indices {
            let matrix = toClip * pieces[index].node.simdWorldTransform
            let screen: [SIMD2<Float>?] = pieces[index].positions.map { point in
                let clip = matrix * SIMD4(point, 1)
                guard clip.w > 0.0001 else { return nil }
                return SIMD2((clip.x / clip.w + 1) / 2 * Float(size.width), (1 - clip.y / clip.w) / 2 * Float(size.height))
            }
            for e in pieces[index].elements.indices {
                let old = pieces[index].elements[e]
                let new = TrimMath.trim(old, screen: screen, loop: path, keep: keep)
                removed += (old.count - new.count) / 3
                pieces[index].elements[e] = new
            }
        }
        guard removed > 0 else { return }
        // Keeping nothing would leave an empty model: that loop missed, so it is not done.
        if pieces.allSatisfy({ $0.elements.allSatisfy(\.isEmpty) }) {
            for index in pieces.indices { pieces[index].elements = before[index] }
            return
        }
        history.append(before)
        if history.count > 12 { history.removeFirst() }
        rebuild()
        Diagnostics.log("Trim: \(keep ? "kept" : "erased") a loop, \(removed) triangles gone, \(triangles) left")
    }

    func undo() {
        guard let last = history.popLast() else { return }
        for index in pieces.indices { pieces[index].elements = last[index] }
        rebuild()
    }

    func startAgain() {
        guard changed else { return }
        history.append(pieces.map(\.elements))
        for index in pieces.indices { pieces[index].elements = original[index] }
        rebuild()
    }

    private func rebuild() {
        for piece in pieces {
            var elements: [SCNGeometryElement] = []
            var materials: [SCNMaterial] = []
            for (e, list) in piece.elements.enumerated() where !list.isEmpty {
                elements.append(SCNGeometryElement(indices: list, primitiveType: .triangles))
                if e < piece.materials.count { materials.append(piece.materials[e]) }
            }
            if elements.isEmpty {
                piece.node.geometry = nil
            } else {
                let geometry = SCNGeometry(sources: piece.sources, elements: elements)
                geometry.materials = materials.isEmpty ? piece.materials : materials
                piece.node.geometry = geometry
            }
        }
        count()
        canUndo = !history.isEmpty
        changed = pieces.map(\.elements) != original
    }

    /// Writes the trimmed model over the scan's file, standing on its own middle again. The first, untrimmed model is
    /// kept beside it once, as "<name> untrimmed.usdz".
    func save(over url: URL) -> Bool {
        guard ready else { return false }
        // Where what is left now stands: its lowest point and middle go back to the model's origin.
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for piece in pieces {
            let matrix = piece.node.simdWorldTransform
            for list in piece.elements {
                for corner in list where Int(corner) < piece.positions.count {
                    let p = (matrix * SIMD4(piece.positions[Int(corner)], 1)).xyz
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
        }
        guard low.x <= high.x else { return false }
        let shift = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
        let lightNode = scene.rootNode.childNode(withName: "trim-light", recursively: false)
        lightNode?.removeFromParentNode()
        let tops = scene.rootNode.childNodes
        for node in tops { node.simdPosition -= shift }
        defer {
            for node in tops { node.simdPosition += shift }
            if let lightNode { scene.rootNode.addChildNode(lightNode) }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString).usdz")
        guard scene.write(to: temporary, options: nil, delegate: nil, progressHandler: nil) else {
            Diagnostics.log("Trim: the model couldn't be written")
            return false
        }
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " untrimmed.usdz")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            Diagnostics.log("Trim: save failed, \(error.localizedDescription)")
            return false
        }
        Diagnostics.log("Trim saved: \(url.lastPathComponent), \(triangles) triangles")
        return true
    }
}

/// The model, turned with a finger and pinched to zoom.
struct TrimSceneView: UIViewRepresentable {
    let trimmer: ScanTrimmer

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = trimmer.scene
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        trimmer.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}

struct ScanTrimScreen: View {
    enum Tool: String, CaseIterable {
        case turn = "Turn", erase = "Erase", keep = "Keep"
        var icon: String {
            switch self {
            case .turn: return "rotate.3d"
            case .erase: return "eraser"
            case .keep: return "lasso"
            }
        }
        var help: String {
            switch self {
            case .turn: return "Drag to turn. Pinch to zoom."
            case .erase: return "Draw a loop round what to remove"
            case .keep: return "Draw a loop round what to keep"
            }
        }
    }

    let folder: ScanFolder
    /// Called on closing: true when the trimmed model was saved.
    let done: (Bool) -> Void
    @StateObject private var trimmer = ScanTrimmer()
    @State private var tool: Tool = .turn
    @State private var loop: [CGPoint] = []
    @State private var saveFailed = false

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            TrimSceneView(trimmer: trimmer).ignoresSafeArea()
            if tool != .turn {
                // The loop is drawn over the model; the model holds still under it.
                Canvas { context, _ in
                    guard loop.count > 1 else { return }
                    var path = Path()
                    path.addLines(loop)
                    path.closeSubpath()
                    context.fill(path, with: .color((tool == .erase ? Color.red : Theme.accent).opacity(0.18)))
                    context.stroke(path, with: .color(tool == .erase ? Color.red : Theme.accent), lineWidth: 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { loop.append($0.location) }
                        .onEnded { _ in
                            trimmer.apply(loop: loop, keep: tool == .keep)
                            loop = []
                        }
                )
                .ignoresSafeArea()
            }
            if let failed = trimmer.failed {
                Text(failed).font(Theme.footnote).foregroundStyle(.white).padding(30).multilineTextAlignment(.center)
            }
            controls
        }
        .preferredColorScheme(.dark)
        .onAppear { trimmer.load(folder.model) }
        .alert("The trimmed model couldn't be saved", isPresented: $saveFailed) { Button("OK") {} }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Cancel") { done(false) }
                Spacer()
                Button("Save") {
                    if trimmer.save(over: folder.model) { done(true) } else { saveFailed = true }
                }
                .disabled(!trimmer.changed)
                .opacity(trimmer.changed ? 1 : 0.4)
            }
            .font(Theme.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.top, 10)
            Spacer()
            Text(tool.help)
                .font(Theme.footnote.weight(.semibold))
                .shadow(color: .black.opacity(0.8), radius: 2)
            HStack(spacing: 8) {
                ForEach(Tool.allCases, id: \.self) { item in
                    button(item.rawValue, item.icon, on: tool == item) { tool = item }
                }
                button("Undo", "arrow.uturn.backward", enabled: trimmer.canUndo) { trimmer.undo() }
                button("Start again", "arrow.counterclockwise", enabled: trimmer.changed) { trimmer.startAgain() }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 26)
        }
        .foregroundStyle(.white)
    }

    private func button(_ title: String, _ icon: String, on: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(Theme.title3)
                Text(title).font(Theme.caption2.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(on ? Theme.active : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(on ? Color.black : Color.white)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
