import SceneKit
import simd

/// Phil, 2026-11-26: "Can we add a soft edge to a hard cropped scan". The placed model's "Hard edge" tool goes Hard
/// edge, Soft edge, Softer edge and back, like Sizes: the model fades out toward the edges where it was cut (Trim's
/// Erase and Keep, or the scanner's box), so it blends into the room instead of ending in a hard line. Saved with the
/// model, so it comes back on every phone. A model with no cut edges (a whole scan, a mannequin) is left as it is.
final class SoftEdgeCache {
    /// One mesh of the model: its own geometry (put back for a hard edge), what the soft one is built from, and how
    /// far each of its points is from a cut edge.
    struct Part {
        let node: SCNNode
        let original: SCNGeometry
        let sources: [SCNGeometrySource]
        let elements: [[UInt32]]
        let materials: [SCNMaterial]
        /// Its points in the model's own coordinates, so the fade is the same size on every part.
        let positions: [SIMD3<Float>]
        var distance: [Float] = []
    }

    /// The model node these parts belong to (a model loaded again has new nodes, and a new cache).
    weak var model: SCNNode?
    var parts: [Part]
    /// The model's longest side, in its own coordinates.
    let size: Float
    var openEdges = 0
    /// The step shown now.
    var shown = 0
    /// The soft geometry built for each step, kept so going round the steps is instant.
    private var built: [Int: [SCNGeometry]] = [:]

    init(model: SCNNode, parts: [Part], size: Float) {
        self.model = model
        self.parts = parts
        self.size = size
    }

    /// The fade reach the distances were worked out to: the softest step's.
    var limit: Float { SoftEdgeMath.width(step: SoftEdgeMath.stepNames.count - 1, size: size) }

    /// Shows the model with the given step's edge.
    func show(step: Int) {
        shown = step
        let width = SoftEdgeMath.width(step: step, size: size)
        guard width > 0, openEdges > 0 else {
            for part in parts { part.node.geometry = part.original }
            return
        }
        if built[step] == nil {
            built[step] = parts.map { part -> SCNGeometry in
                let fade = part.distance.map { SoftEdgeMath.fade($0, width: width) }
                guard fade.contains(where: { $0 < SoftEdge.solid }) else { return part.original }
                let geometry = SoftEdge.softened(sources: part.sources, elements: part.elements, materials: part.materials, fade: fade)
                geometry.name = part.original.name
                return geometry
            }
        }
        for (part, geometry) in zip(parts, built[step] ?? []) { part.node.geometry = geometry }
    }

    /// Reads the model's meshes, or nil when one can't be read (not triangles, or not plain numbers).
    /// `file` is the model's file, read again with ModelIO when SceneKit's own numbers can't be rebuilt from.
    @MainActor
    static func gather(model: SCNNode, file: URL, skip: Set<String>) -> SoftEdgeCache? {
        var nodes: [SCNNode] = []
        func walk(_ node: SCNNode) {
            if let name = node.name, skip.contains(name) { return }
            if node.geometry != nil { nodes.append(node) }
            node.childNodes.forEach(walk)
        }
        walk(model)
        guard !nodes.isEmpty else { return nil }
        var unified: [ScanTrimmer.UnifiedMesh]?
        var unifiedRead = false
        var parts: [Part] = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for (number, node) in nodes.enumerated() {
            guard let geometry = node.geometry, let ownPositions = SoftEdge.positions(of: geometry),
                  let ownElements = SoftEdge.triangles(of: geometry) else {
                Diagnostics.log("Soft edge: mesh \(number) can't be read")
                return nil
            }
            var sources = geometry.sources, positions = ownPositions, elements = ownElements
            if !SoftEdge.sourcesAgree(geometry) {
                // As in Trim (build 1317): a scan straight from the scanner numbers its picture coordinates apart from
                // its points. ModelIO reads the file with one numbering for all of them.
                if !unifiedRead {
                    unified = ScanTrimmer.unifiedMeshes(of: file)
                    unifiedRead = true
                }
                let triangleCount = ownElements.reduce(0) { $0 + $1.count / 3 }
                guard let unified, number < unified.count, unified[number].triangles == triangleCount,
                      unified[number].elements.count == ownElements.count else {
                    Diagnostics.log("Soft edge: mesh \(number) numbers its parts apart and ModelIO gave no match")
                    return nil
                }
                let mesh = unified[number]
                sources = [SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })]
                if mesh.normals.count == mesh.positions.count {
                    sources.append(SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) }))
                }
                if mesh.uvs.count == mesh.positions.count {
                    let flip = Self.picturesFlipped(mesh.uvs, geometry: geometry)
                    sources.append(SCNGeometrySource(textureCoordinates: mesh.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat(flip ? 1 - $0.y : $0.y)) }))
                }
                positions = mesh.positions
                elements = mesh.elements
            }
            let matrix = node.simdConvertTransform(matrix_identity_float4x4, to: model)
            let placed = positions.map { (matrix * SIMD4($0, 1)).xyz }
            for p in placed where p.x.isFinite && p.y.isFinite && p.z.isFinite {
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
            parts.append(Part(node: node, original: geometry, sources: sources, elements: elements, materials: geometry.materials, positions: placed))
        }
        guard low.x <= high.x else { return nil }
        let extent = high - low
        return SoftEdgeCache(model: model, parts: parts, size: max(extent.x, extent.y, extent.z))
    }

    /// ModelIO's picture coordinates may be the other way up from SceneKit's reading of the same file (Trim, build
    /// 1318): the way up whose sorted heights best match SceneKit's own is taken. Flipped when they can't be compared.
    private static func picturesFlipped(_ uvs: [SIMD2<Float>], geometry: SCNGeometry) -> Bool {
        guard let own = ScanTrimmer.pictureHeights(of: geometry), own.count == uvs.count else { return true }
        let mine = uvs.map(\.y).sorted(), theirs = own.sorted()
        var plain: Float = 0, flipped: Float = 0
        for i in mine.indices {
            plain += abs(mine[i] - theirs[i])
            flipped += abs((1 - mine[mine.count - 1 - i]) - theirs[i])
        }
        return flipped < plain
    }

    /// Works out every part's distances from its cut edges (slow on a big scan, so off the main thread). Takes plain
    /// numbers only: each part's points and triangles.
    static func measure(_ meshes: [(positions: [SIMD3<Float>], triangles: [[UInt32]])], limit: Float, size: Float) -> (distances: [[Float]], openEdges: Int) {
        var all: [[Float]] = []
        var open = 0
        for mesh in meshes {
            let found = SoftEdgeMath.distances(positions: mesh.positions, triangles: mesh.triangles, limit: limit, tolerance: max(size * 1e-5, 1e-6))
            all.append(found.distance)
            open += found.openEdges
        }
        return (all, open)
    }
}

extension ModelPlacer {
    /// The soft edge step of the selected model (0 hard, 1 soft, 2 softer).
    var selectedSoftEdge: Int {
        guard let id = selectedModel else { return 0 }
        return models.first { $0.id == id }?.softEdge ?? 0
    }

    /// Whether the selected model can have a soft edge: a model with a mesh of its own, not a cut-out card, a
    /// mannequin or a posable character.
    var selectedCanSoften: Bool {
        guard let id = selectedModel, let model = models.first(where: { $0.id == id }) else { return false }
        return !selectedIsCutout && !selectedHasRig && model.mannequin == nil && !model.file.hasSuffix(".fbx")
    }

    /// The tool's word: the edge it has now.
    var softEdgeWord: String {
        if let id = selectedModel, softEdgeClosed.contains(id) { return "No cut edge" }
        return SoftEdgeMath.stepNames[min(max(selectedSoftEdge, 0), SoftEdgeMath.stepNames.count - 1)]
    }

    /// Hard edge, Soft edge, Softer edge, then hard again.
    func cycleSoftEdge() {
        guard let id = selectedModel, let index = models.firstIndex(where: { $0.id == id }) else { return }
        Haptics.tap()
        if softEdgeClosed.contains(id) {
            showSoftEdgeHint("This model has no cut edges to soften")
            return
        }
        let next = ((models[index].softEdge ?? 0) + 1) % SoftEdgeMath.stepNames.count
        models[index].softEdge = next == 0 ? nil : next
        models[index].moved = Date()
        applySoftEdge(id)
        showSoftEdgeHint(SoftEdgeMath.stepNames[next])
        Diagnostics.log("Soft edge: \(models[index].name) now \(SoftEdgeMath.stepNames[next].lowercased())")
    }

    private func showSoftEdgeHint(_ words: String) {
        dimensionHint = words
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if dimensionHint == words { dimensionHint = nil }
        }
    }

    /// Shows the model with the edge saved for it. The first time a model is softened its cut edges are found off the
    /// main thread; until then it shows as it is.
    func applySoftEdge(_ id: UUID) {
        guard let node = modelNodes[id], let model = models.first(where: { $0.id == id }) else { return }
        let step = model.softEdge ?? 0
        if let cache = softEdgeCaches[id], cache.model === node {
            if cache.shown != step {
                cache.show(step: step)
                applyLight(id)
            }
            return
        }
        softEdgeCaches[id] = nil
        guard step > 0, softEdgeWorking.insert(id).inserted else { return }
        guard let cache = SoftEdgeCache.gather(model: node, file: folder.appendingPathComponent(model.file), skip: Self.unlitHelpers) else {
            softEdgeWorking.remove(id)
            Diagnostics.log("Soft edge: \(model.name) can't be softened (its meshes can't be read)")
            return
        }
        let meshes = cache.parts.map { (positions: $0.positions, triangles: $0.elements) }
        let limit = cache.limit, size = cache.size, name = model.name
        let started = Date()
        Task { @MainActor [weak self] in
            let measured = await Task.detached(priority: .userInitiated) { SoftEdgeCache.measure(meshes, limit: limit, size: size) }.value
            guard let self else { return }
            self.softEdgeWorking.remove(id)
            for i in cache.parts.indices where i < measured.distances.count { cache.parts[i].distance = measured.distances[i] }
            cache.openEdges = measured.openEdges
            // Loaded again, or deleted, while it was worked out: this cache is for nodes no longer shown. A model
            // loaded again is worked out afresh.
            guard self.modelNodes[id] === node else {
                if self.modelNodes[id] != nil { self.applySoftEdge(id) }
                return
            }
            self.softEdgeCaches[id] = cache
            let points = meshes.reduce(0) { $0 + $1.positions.count }
            Diagnostics.log(String(format: "Soft edge: %@, %d parts, %d points, %d cut edges, %.0f cm across, worked out in %.2f s",
                                   name, meshes.count, points, measured.openEdges, size * 100, Date().timeIntervalSince(started)))
            if measured.openEdges == 0 {
                self.softEdgeClosed.insert(id)
                // Nothing to soften: it stays saved as hard.
                if let index = self.models.firstIndex(where: { $0.id == id }), self.models[index].softEdge != nil {
                    self.models[index].softEdge = nil
                    self.models[index].moved = Date()
                }
                if self.selectedModel == id { self.showSoftEdgeHint("This model has no cut edges to soften") }
            }
            let now = self.models.first { $0.id == id }?.softEdge ?? 0
            cache.show(step: now)
            self.applyLight(id)
            self.objectWillChange.send()
        }
    }
}
