import simd

/// One depth picture as an invisible mesh in room coordinates, used to hide 3D models behind the real things
/// in front of them: in Review frames from each frame's saved depth (build 1272) and in the live camera from
/// LiDAR (Phil, 2026-11-20: "Can models be obscured by objects in the room while in live view").
/// Pure maths, so CI can test it (CropTests).
///
/// The mesh is pushed back (5 cm, more far away where the depth is rougher) so a model standing against a
/// wall is not cut by it. Jumps in depth (the edge of a pillar) are left open. Phil, 2026-11-11: feet and legs
/// were chopped into blocks by the floor, so the floor itself never hides anything (a table top still does).
struct OccluderMesh: Sendable {
    var positions: [Float] = []
    var indices: [UInt32] = []
    /// The floor this picture showed (the lowest level much of it sits on), in room coordinates.
    var seenFloor: Float?

    /// `depth` is `width` by `height` metres; `confidence`, if given, the same size (ARKit: 0 low, 1 medium,
    /// 2 high), and readings below `minConfidence` are left out. `intrinsics` are the camera's for the full
    /// picture (`imageWidth` by `imageHeight`), `pose` the camera's place in the room (ARKit: x right, y up,
    /// looking down -z). Every `step`th depth pixel is a vertex. `floor` overrides the floor found in this
    /// picture (a live camera knows it better from the planes ARKit found).
    static func build(depth: [Float], confidence: [UInt8]? = nil, minConfidence: UInt8 = 0, width dw: Int, height dh: Int,
                      intrinsics k: simd_float3x3, pose: simd_float4x4, imageWidth w: Float, imageHeight h: Float,
                      step: Int = 1, floor knownFloor: Float? = nil,
                      pushBack: Float = 0.05, pushPerMetre: Float = 0.03, denoise: Bool = false) -> OccluderMesh? {
        guard dw > 8, dh > 8, step >= 1, w > 0, h > 0, depth.count >= dw * dh,
              k[0][0] > 0, k[1][1] > 0 else { return nil }
        if let confidence, confidence.count < dw * dh { return nil }
        // Phil, 2026-11-20 (build 1391): live edges flickered. A reading most of whose neighbours disagree or are
        // missing is a speck of noise: each reading becomes the middle of its 3 by 3 neighbourhood, or none.
        let depth = denoise ? median3(depth, width: dw, height: dh) : depth
        let cols = (dw - 1) / step + 1, rows = (dh - 1) / step + 1
        var mesh = OccluderMesh()
        mesh.positions.reserveCapacity(cols * rows * 3)
        var valid = [Bool](repeating: false, count: cols * rows)
        var values = [Float](repeating: 0, count: cols * rows)
        for gy in 0..<rows {
            for gx in 0..<cols {
                let x = gx * step, y = gy * step
                let d = depth[y * dw + x]
                var p = SIMD3<Float>.zero
                let sure = confidence.map { $0[y * dw + x] >= minConfidence } ?? true
                if sure, d.isFinite, d > 0.12, d < 8 {
                    let back = d + pushBack + pushPerMetre * d
                    let u = (Float(x) + 0.5) / Float(dw) * w, v = (Float(y) + 0.5) / Float(dh) * h
                    let world = pose * SIMD4((u - k[2][0]) / k[0][0] * back, -(v - k[2][1]) / k[1][1] * back, -back, 1)
                    p = SIMD3(world.x, world.y, world.z)
                    valid[gy * cols + gx] = true
                    values[gy * cols + gx] = d
                }
                mesh.positions.append(contentsOf: [p.x, p.y, p.z])
            }
        }
        // The floor: the lowest level that much of the picture sits on.
        var heights: [Float] = []
        heights.reserveCapacity(cols * rows / 4)
        for i in stride(from: 0, to: cols * rows, by: 4) where valid[i] { heights.append(mesh.positions[i * 3 + 1]) }
        heights.sort()
        if heights.count > 50 { mesh.seenFloor = heights[heights.count / 50] }
        let floor = knownFloor ?? mesh.seenFloor
        func point(_ i: Int) -> SIMD3<Float> { SIMD3(mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2]) }
        // Neighbours further apart on the grid may differ more in depth before they count as an edge.
        let spread = Float(step)
        for gy in 0..<(rows - 1) {
            for gx in 0..<(cols - 1) {
                let a = gy * cols + gx, b = a + 1, c = a + cols, e = c + 1
                guard valid[a], valid[b], valid[c], valid[e] else { continue }
                let low = min(min(values[a], values[b]), min(values[c], values[e]))
                let high = max(max(values[a], values[b]), max(values[c], values[e]))
                guard high - low < (0.03 + 0.05 * low) * spread else { continue }
                if let floor {
                    let pa = point(a), pe = point(e)
                    let normal = simd_cross(point(c) - pa, point(b) - pa)
                    let length = simd_length(normal)
                    let flat = length > 0 && abs(normal.y) / length > 0.8
                    if flat, (pa.y + pe.y) / 2 < floor + 0.12 { continue }
                }
                mesh.indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b), UInt32(b), UInt32(c), UInt32(e)])
            }
        }
        return mesh.indices.isEmpty ? nil : mesh
    }

    /// Each reading replaced by the median of the real readings (0.12 to 8 m) in its 3 by 3 neighbourhood; 0 (none)
    /// where fewer than 5 of the 9 are real.
    static func median3(_ depth: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        var near = [Float](repeating: 0, count: 9)
        for y in 0..<height {
            for x in 0..<width {
                var n = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < width else { continue }
                        let d = depth[yy * width + xx]
                        if d.isFinite, d > 0.12, d < 8 { near[n] = d; n += 1 }
                    }
                }
                guard n >= 5 else { continue }
                // Insertion sort of at most 9.
                for i in 1..<n {
                    let v = near[i]
                    var j = i - 1
                    while j >= 0, near[j] > v { near[j + 1] = near[j]; j -= 1 }
                    near[j + 1] = v
                }
                out[y * width + x] = near[n / 2]
            }
        }
        return out
    }
}

/// Phil, 2026-11-20: "Edges and perspective are key to this app". LiDAR depth is 256 by 192 for the whole view, so an
/// edge made from it alone is blocky and wanders by about 10 screen pixels. The camera picture is much sharper: each
/// finer pixel takes its depth from the nearby LiDAR readings whose brightness in the picture matches its own (joint
/// bilateral upsampling, Kopf et al. 2007), and never a blend of a near and a far thing, so the edge of a pillar
/// follows the pillar's outline in the picture. Pure maths, so CI can test it (CropTests).
enum EdgeDepth {
    /// `depth` is `dw` by `dh` metres (0 = no reading); `guide` the camera picture's brightness, `gw` by `gh`, covering
    /// the same view. Returns depth at the guide's size.
    static func refine(depth: [Float], width dw: Int, height dh: Int, guide: [UInt8], guideWidth gw: Int, guideHeight gh: Int,
                       lumaSpread: Float = 14) -> [Float] {
        guard dw > 1, dh > 1, gw > 1, gh > 1, depth.count >= dw * dh, guide.count >= gw * gh else { return [] }
        // The brightness of the picture where each LiDAR reading is (the average over its patch of the picture).
        var lumaAt = [Float](repeating: 0, count: dw * dh)
        let sx = Float(gw) / Float(dw), sy = Float(gh) / Float(dh)
        for j in 0..<dh {
            let y0 = Int(Float(j) * sy), y1 = max(y0 + 1, min(gh, Int(Float(j + 1) * sy)))
            for i in 0..<dw {
                let x0 = Int(Float(i) * sx), x1 = max(x0 + 1, min(gw, Int(Float(i + 1) * sx)))
                var sum = 0, n = 0
                for y in y0..<y1 { for x in x0..<x1 { sum += Int(guide[y * gw + x]); n += 1 } }
                lumaAt[j * dw + i] = Float(sum) / Float(max(n, 1))
            }
        }
        var rangeWeight = [Float](repeating: 0, count: 256)
        for k in 0..<256 { rangeWeight[k] = exp(-Float(k * k) / (2 * lumaSpread * lumaSpread)) + 0.0005 }
        var out = [Float](repeating: 0, count: gw * gh)
        var ds = [Float](repeating: 0, count: 16), ws = [Float](repeating: 0, count: 16)
        for y in 0..<gh {
            let fy = (Float(y) + 0.5) / sy - 0.5
            let jy = Int(fy.rounded(.down))
            for x in 0..<gw {
                let fx = (Float(x) + 0.5) / sx - 0.5
                let ix = Int(fx.rounded(.down))
                let luma = Int(guide[y * gw + x])
                var n = 0
                for j in (jy - 1)...(jy + 2) where j >= 0 && j < dh {
                    let dyy = Float(j) - fy
                    for i in (ix - 1)...(ix + 2) where i >= 0 && i < dw {
                        let d = depth[j * dw + i]
                        guard d.isFinite, d > 0 else { continue }
                        let dxx = Float(i) - fx
                        let spatial = max(0, 1 - (dxx * dxx + dyy * dyy) / 6.25)
                        let difference = min(255, abs(luma - Int(lumaAt[j * dw + i])))
                        ds[n] = d
                        ws[n] = spatial * rangeWeight[difference]
                        n += 1
                    }
                }
                guard n > 0 else { continue }
                // Sort by depth, then split at the biggest jump (a near and a far thing): the side that matches best wins.
                for a in 1..<n {
                    let d = ds[a], w = ws[a]
                    var b = a - 1
                    while b >= 0, ds[b] > d { ds[b + 1] = ds[b]; ws[b + 1] = ws[b]; b -= 1 }
                    ds[b + 1] = d; ws[b + 1] = w
                }
                var split = n, gap: Float = 0
                for a in 1..<n {
                    let jump = ds[a] - ds[a - 1]
                    if jump > 0.05 + 0.05 * ds[a - 1], jump > gap { gap = jump; split = a }
                }
                var nearW: Float = 0, nearD: Float = 0, farW: Float = 0, farD: Float = 0
                for a in 0..<n {
                    if a < split { nearW += ws[a]; nearD += ws[a] * ds[a] } else { farW += ws[a]; farD += ws[a] * ds[a] }
                }
                if nearW >= farW { if nearW > 0 { out[y * gw + x] = nearD / nearW } } else { out[y * gw + x] = farD / farW }
            }
        }
        return out
    }

    /// Phil, 2026-11-20: "reduce the flickering ... assume a continuous edge if the camera is relatively still". While the
    /// camera holds still the same pixel shows the same thing, so each pixel takes the middle of its last few depths:
    /// an edge pixel that flips between near and far now and then stays on the side it is on most of the time.
    /// Readings of 0 (none) count as none; a pixel with readings in fewer than half the pictures has none.
    static func steady(_ history: [[Float]]) -> [Float] {
        guard let last = history.last else { return [] }
        let frames = history.filter { $0.count == last.count }
        guard frames.count > 1 else { return last }
        var out = [Float](repeating: 0, count: last.count)
        var values = [Float](repeating: 0, count: frames.count)
        for i in 0..<last.count {
            var n = 0
            for frame in frames where frame[i] > 0 { values[n] = frame[i]; n += 1 }
            guard n * 2 >= frames.count, n > 0 else { continue }
            for a in 1..<max(n, 1) {
                let v = values[a]
                var b = a - 1
                while b >= 0, values[b] > v { values[b + 1] = values[b]; b -= 1 }
                values[b + 1] = v
            }
            out[i] = values[n / 2]
        }
        return out
    }

    /// The nearest LiDAR reading for each finer pixel: what the edges looked like before (for the tests to compare).
    static func nearest(depth: [Float], width dw: Int, height dh: Int, guideWidth gw: Int, guideHeight gh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            let j = min(dh - 1, Int((Float(y) + 0.5) * Float(dh) / Float(gh)))
            for x in 0..<gw {
                let i = min(dw - 1, Int((Float(x) + 0.5) * Float(dw) / Float(gw)))
                out[y * gw + x] = depth[j * dw + i]
            }
        }
        return out
    }
}

/// Outlines from the last few pictures while the camera holds still: a pixel is inside if it was in most of them.
enum OutlineVote {
    static func steady(_ history: [[Bool]]) -> [Bool] {
        guard let last = history.last else { return [] }
        let frames = history.filter { $0.count == last.count }
        guard frames.count > 1 else { return last }
        var out = [Bool](repeating: false, count: last.count)
        for i in 0..<last.count {
            var n = 0
            for frame in frames where frame[i] { n += 1 }
            out[i] = n * 2 > frames.count
        }
        return out
    }
}

/// A picked thing's outline as runs of pixels, row by row (LiveOcclusion.swift draws each run as one strip).
enum OutlineStrips {
    struct Strip: Equatable { var x0: Int; var x1: Int; var y0: Int; var y1: Int }

    /// `inside(x, y)` says whether a pixel of a `width` by `height` outline is the thing; every `stepY`th row is read.
    static func make(width: Int, height: Int, stepY: Int, inside: (Int, Int) -> Bool) -> [Strip] {
        guard width > 0, height > 0, stepY >= 1 else { return [] }
        var strips: [Strip] = []
        for y in stride(from: 0, to: height, by: stepY) {
            var start: Int?
            for x in 0...width {
                let isInside = x < width && inside(x, y)
                if isInside, start == nil { start = x }
                if !isInside, let from = start {
                    strips.append(Strip(x0: from, x1: x, y0: y, y1: min(height, y + stepY)))
                    start = nil
                }
            }
        }
        return strips
    }
}

