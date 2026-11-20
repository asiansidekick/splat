import ModelIO
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
        /// The scan's own sources, used again in each new geometry (the black screen of build 1312 was the camera, not these).
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
    /// How each material was lit as scanned: shown unlit here, put back for saving.
    private var lighting: [(material: SCNMaterial, model: SCNMaterial.LightingModel)] = []
    private let cameraNode = SCNNode()
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
        // No light is added: the scan's colours are photographs and are shown unlit, exactly as they are. (A light on
        // top of that doubled them to plain white, build 1313.)
        var found: [Piece] = []
        var unreadable = false
        // Build 1317's log: the scan's picture coordinates (2176) outnumber its points (1872), a layout SceneKit shows
        // but cannot rebuild from (the picture scrambled). ModelIO reads the file with one numbering for all three.
        let unified = Self.unifiedMeshes(of: url)
        var meshNumber = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            guard let ownPositions = Self.positions(of: geometry), let ownElements = Self.triangles(of: geometry) else {
                unreadable = true
                return
            }
            var sources = geometry.sources
            var positions = ownPositions, elements = ownElements
            if let unified, meshNumber < unified.count, unified[meshNumber].triangles == elements.reduce(0, { $0 + $1.count / 3 }) {
                let mesh = unified[meshNumber]
                sources = [SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })]
                if mesh.normals.count == mesh.positions.count {
                    sources.append(SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) }))
                }
                if mesh.uvs.count == mesh.positions.count {
                    // ModelIO gives the file's picture coordinates (up is 1); SceneKit's own reading of the same file
                    // may have them the other way up. Build 1318 showed the photo in the wrong places, the signature of
                    // that flip, so the way up is taken from SceneKit's own numbers when they can be compared.
                    var flip = true
                    if let own = Self.pictureHeights(of: geometry), own.count == mesh.uvs.count {
                        let mine = mesh.uvs.map(\.y).sorted(), theirs = own.sorted()
                        var plain: Float = 0, flipped: Float = 0
                        for i in mine.indices {
                            plain += abs(mine[i] - theirs[i])
                            flipped += abs((1 - mine[mine.count - 1 - i]) - theirs[i])
                        }
                        flip = flipped < plain
                        Diagnostics.log(String(format: "Trim picture: flip %@ (plain %.1f, flipped %.1f)", flip ? "yes" : "no", plain, flipped))
                    } else {
                        Diagnostics.log("Trim picture: no SceneKit numbers to compare, flip yes")
                    }
                    sources.append(SCNGeometrySource(textureCoordinates: mesh.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat(flip ? 1 - $0.y : $0.y)) }))
                }
                positions = mesh.positions
                elements = mesh.elements
                Diagnostics.log("Trim piece (ModelIO): \(mesh.positions.count) points, \(mesh.normals.count) normals, \(mesh.uvs.count) picture coordinates, \(mesh.triangles) triangles")
            } else {
                Diagnostics.log("Trim piece: ModelIO gave \(unified.map { "\($0.count) meshes" } ?? "nothing"), mesh \(meshNumber); using the scan's own sources")
            }
            meshNumber += 1
            let described = geometry.sources.map { "\($0.semantic.rawValue.replacingOccurrences(of: "kGeometrySourceSemantic", with: "")) \($0.vectorCount)x\($0.componentsPerVector)x\($0.bytesPerComponent)" }
            let picture = geometry.materials.first.map { String(describing: type(of: $0.diffuse.contents ?? "none")) } ?? "no material"
            Diagnostics.log("Trim piece: \(described.joined(separator: ", ")); \(geometry.materials.count) materials, picture \(picture), mapping \(geometry.materials.first?.diffuse.mappingChannel ?? -1)")
            for material in geometry.materials {
                lighting.append((material, material.lightingModel))
                material.lightingModel = .constant
                material.isDoubleSided = true
            }
            let piece = Piece(node: node, sources: sources, materials: geometry.materials, positions: positions, elements: elements)
            found.append(piece)
        }
        guard !found.isEmpty, !unreadable else {
            failed = "This scan is in a form that can't be trimmed here."
            Diagnostics.log("Trim: \(found.count) pieces read, unreadable \(unreadable)")
            return
        }
        pieces = found
        original = found.map(\.elements)
        count()
        // The same numbers shown from the start, so the first loop changes nothing but the triangles.
        rebuild()
        placeCamera()
        ready = true
        Diagnostics.log("Trim opened: \(url.lastPathComponent), \(found.count) pieces, \(triangles) triangles")
    }

    /// The up-and-down picture coordinate of every point, as SceneKit read them.
    nonisolated static func pictureHeights(of geometry: SCNGeometry) -> [Float]? {
        guard let source = geometry.sources(for: .texcoord).first, source.usesFloatComponents,
            source.bytesPerComponent == 4, source.componentsPerVector >= 2
        else { return nil }
        let stride = source.dataStride, offset = source.dataOffset, count = source.vectorCount
        let data = source.data
        guard stride > 0, count > 0, data.count >= offset + (count - 1) * stride + 8 else { return nil }
        var out: [Float] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count { out.append(raw.loadUnaligned(fromByteOffset: offset + i * stride + 4, as: Float.self)) }
        }
        return out
    }

    /// One mesh as ModelIO reads it: points, normals and picture coordinates all numbered the same way.
    struct UnifiedMesh {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var elements: [[UInt32]]
        var triangles: Int { elements.reduce(0) { $0 + $1.count / 3 } }
    }

    nonisolated static func unifiedMeshes(of url: URL) -> [UnifiedMesh]? {
        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { return nil }
        var out: [UnifiedMesh] = []
        for mesh in meshes {
            let count = mesh.vertexCount
            guard count > 0, let position = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return nil }
            func floats(_ data: MDLVertexAttributeData, _ parts: Int) -> [Float] {
                var list: [Float] = []
                list.reserveCapacity(count * parts)
                for i in 0..<count {
                    let base = data.dataStart + i * data.stride
                    for part in 0..<parts { list.append(base.loadUnaligned(fromByteOffset: part * 4, as: Float.self)) }
                }
                return list
            }
            let p = floats(position, 3)
            var normals: [SIMD3<Float>] = []
            if let data = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) {
                let n = floats(data, 3)
                normals = (0..<count).map { SIMD3(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) }
            }
            var uvs: [SIMD2<Float>] = []
            if let data = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2) {
                let t = floats(data, 2)
                uvs = (0..<count).map { SIMD2(t[$0 * 2], t[$0 * 2 + 1]) }
            }
            var elements: [[UInt32]] = []
            for submesh in (mesh.submeshes as? [MDLSubmesh]) ?? [] {
                guard submesh.geometryType == .triangles else { return nil }
                let buffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                var list: [UInt32] = []
                list.reserveCapacity(submesh.indexCount)
                for i in 0..<submesh.indexCount { list.append(map.bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
                guard !list.contains(where: { Int($0) >= count }) else { return nil }
                elements.append(list)
            }
            out.append(UnifiedMesh(positions: (0..<count).map { SIMD3(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }, normals: normals, uvs: uvs, elements: elements))
        }
        return out
    }

    /// Reset's own camera, looking at the whole model from the front and a little above.
    private func placeCamera() {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for piece in pieces {
            let matrix = piece.node.simdWorldTransform
            // Every 20th point is plenty for a box round the model.
            for index in stride(from: 0, to: piece.positions.count, by: 20) {
                let p = (matrix * SIMD4(piece.positions[index], 1)).xyz
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        guard low.x <= high.x else { return }
        let middle = (low + high) / 2
        let reach = max(simd_length(high - low), 0.1)
        let camera = SCNCamera()
        camera.zNear = Double(reach) * 0.01
        camera.zFar = Double(reach) * 20
        camera.fieldOfView = 50
        cameraNode.camera = camera
        cameraNode.simdPosition = middle + SIMD3(0, reach * 0.35, reach * 1.3)
        cameraNode.simdLook(at: middle)
        if cameraNode.parent == nil { scene.rootNode.addChildNode(cameraNode) }
        view?.pointOfView = cameraNode
        view?.defaultCameraController.target = SCNVector3(middle.x, middle.y, middle.z)
    }

    private func count() {
        triangles = pieces.reduce(0) { $0 + $1.elements.reduce(0) { $0 + $1.count / 3 } }
    }

    nonisolated static func positions(of geometry: SCNGeometry) -> [SIMD3<Float>]? {
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
    nonisolated static func triangles(of geometry: SCNGeometry) -> [[UInt32]]? {
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

    /// The view exists (it can come after the model is loaded): it looks through Reset's camera.
    func viewReady() {
        if cameraNode.camera != nil { view?.pointOfView = cameraNode }
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
        // The view stays exactly where it was turned to: a cut changes the triangles, never the angle.
        let eye = view?.pointOfView
        let eyePlace = eye?.simdWorldTransform
        defer {
            if let eye, let eyePlace { eye.simdWorldTransform = eyePlace }
            if view?.pointOfView == nil, cameraNode.camera != nil { view?.pointOfView = cameraNode }
        }
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
        cameraNode.removeFromParentNode()
        for item in lighting {
            item.material.lightingModel = item.model
            item.material.isDoubleSided = false
        }
        let tops = scene.rootNode.childNodes
        for node in tops { node.simdPosition -= shift }
        defer {
            for node in tops { node.simdPosition += shift }
            if let lightNode { scene.rootNode.addChildNode(lightNode) }
            scene.rootNode.addChildNode(cameraNode)
            view?.pointOfView = cameraNode
            for item in lighting {
                item.material.lightingModel = .constant
                item.material.isDoubleSided = true
            }
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
        trimmer.viewReady()
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
