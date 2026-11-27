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
                      pushBack: Float = 0.05, pushPerMetre: Float = 0.03, pushPerMetreSquared: Float = 0, denoise: Bool = false,
                      maxDepth: Float = 8) -> OccluderMesh? {
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
                if sure, d.isFinite, d > 0.12, d < maxDepth {
                    let back = d + pushBack + pushPerMetre * d + pushPerMetreSquared * d * d
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
            // A reading below 0 means that picture didn't see this spot at all (it was out of view): it doesn't vote.
            var n = 0, seen = 0
            for frame in frames where frame[i] >= 0 {
                seen += 1
                if frame[i] > 0 { values[n] = frame[i]; n += 1 }
            }
            // Thin things (wires, rails) are read in only some pictures: 2 in 5 is enough to keep them, and the nearer
            // third of the readings wins, so a wire doesn't flicker in and out (Phil, 2026-11-26).
            guard n > 0, n * 5 >= seen * 2 else { continue }
            for a in 1..<max(n, 1) {
                let v = values[a]
                var b = a - 1
                while b >= 0, values[b] > v { values[b + 1] = values[b]; b -= 1 }
                values[b + 1] = v
            }
            out[i] = values[n / 3]
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


/// A picked thing's outline held still in the room (Phil, 2026-11-20: "the model flickers through"). The outline is
/// kept as a flat card through the tapped point, facing the camera that saw it, and is redrawn for wherever the camera
/// is now, so the thing stays in front even in pictures where Vision misses it.
struct HeldOutline: Sendable {
    /// A camera picture's lens: focal lengths and centre in pixels, and the picture's size.
    struct Lens: Sendable, Equatable {
        var fx: Float, fy: Float, cx: Float, cy: Float
        var imageWidth: Float, imageHeight: Float
    }

    var cells: [Bool]
    var width: Int
    var height: Int
    /// The camera (camera to room) and lens of the picture the outline came from.
    var pose: simd_float4x4
    var lens: Lens
    /// How far in front of that camera the card stands, along its view.
    var distance: Float

    /// The card's distance for a thing touched at `point`, seen from `pose`; at least 10 cm.
    static func distance(of point: SIMD3<Float>, from pose: simd_float4x4) -> Float {
        let forward = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        let origin = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        return max(0.1, simd_dot(point - origin, forward))
    }

    /// The outline as seen from another camera, on a grid the same size: each cell looks along its ray to the card.
    func seen(from target: simd_float4x4, lens to: Lens) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        let forward = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        let source = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let onCard = source + forward * distance
        let inverse = pose.inverse
        let origin = SIMD3(target.columns.3.x, target.columns.3.y, target.columns.3.z)
        let turn = simd_float3x3(SIMD3(target.columns.0.x, target.columns.0.y, target.columns.0.z),
                                 SIMD3(target.columns.1.x, target.columns.1.y, target.columns.1.z),
                                 SIMD3(target.columns.2.x, target.columns.2.y, target.columns.2.z))
        let toSx = to.imageWidth / Float(width), toSy = to.imageHeight / Float(height)
        let fromSx = lens.imageWidth / Float(width), fromSy = lens.imageHeight / Float(height)
        let reach = simd_dot(onCard - origin, forward)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) * toSx, v = (Float(y) + 0.5) * toSy
                let ray = turn * SIMD3((u - to.cx) / to.fx, -(v - to.cy) / to.fy, -1)
                let facing = simd_dot(ray, forward)
                guard abs(facing) > 1e-5 else { continue }
                let t = reach / facing
                guard t > 0 else { continue }
                let hit = inverse * SIMD4(origin + ray * t, 1)
                guard hit.z < -0.01 else { continue }
                let su = lens.fx * hit.x / -hit.z + lens.cx, sv = -lens.fy * hit.y / -hit.z + lens.cy
                let sx = Int((su / fromSx).rounded(.down)), sy = Int((sv / fromSy).rounded(.down))
                guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                out[y * width + x] = cells[sy * width + sx]
            }
        }
        return out
    }

    /// How much two outlines agree: the cells in both over the cells in either (1 when both are empty).
    static func overlap(_ a: [Bool], _ b: [Bool]) -> Float {
        guard a.count == b.count else { return 0 }
        var both = 0, either = 0
        for i in 0..<a.count where a[i] || b[i] {
            either += 1
            if a[i] && b[i] { both += 1 }
        }
        return either == 0 ? 1 : Float(both) / Float(either)
    }

    /// Whether a fresh outline from Vision is the held thing, or only a part of it or something else.
    static func agrees(_ fresh: [Bool], with held: [Bool]) -> Bool { overlap(fresh, held) >= 0.6 }
}

/// A picked thing's outline as runs along each row with the real depth at each end (Phil, 2026-11-21 log on 1401:
/// the depth mesh inside the outline was up to 176,000 triangles, took up to 375 ms and came and went with noisy LiDAR).
/// The outline gives the edges; depth only says how near each part is, so holes in the depth are filled from the
/// nearest reading in the row (or the row above) and a run is cut where the depth jumps or after `maxRun` pixels.
enum DepthStrips {
    struct Strip: Equatable { var x0: Int; var x1: Int; var y: Int; var d0: Float; var d1: Float }

    static func make(width: Int, height: Int, depth: [Float], maxRun: Int = 16, jump: Float = 0.04,
                     inside: (Int, Int) -> Bool) -> [Strip] {
        guard width > 0, height > 0, depth.count >= width * height, maxRun >= 1 else { return [] }
        var strips: [Strip] = []
        var above = [Float](repeating: 0, count: width)
        for y in 0..<height {
            // This row's depth inside the outline, holes filled from the left, then the right, then the row above.
            var row = [Float](repeating: 0, count: width)
            var inRow = [Bool](repeating: false, count: width)
            var last: Float = 0
            for x in 0..<width where inside(x, y) {
                inRow[x] = true
                let d = depth[y * width + x]
                if d.isFinite, d > 0.12, d < 8 { last = d; row[x] = d } else { row[x] = last }
            }
            last = 0
            for x in stride(from: width - 1, through: 0, by: -1) where inRow[x] {
                if row[x] > 0 { last = row[x] } else { row[x] = last > 0 ? last : above[x] }
            }
            var x = 0
            while x < width {
                guard inRow[x], row[x] > 0 else { x += 1; continue }
                let start = x
                var end = x + 1
                while end < width, inRow[end], row[end] > 0, end - start < maxRun, abs(row[end] - row[end - 1]) < jump * max(1, row[end - 1]) {
                    end += 1
                }
                strips.append(Strip(x0: start, x1: end, y: y, d0: row[start], d1: row[end - 1]))
                x = end
            }
            for x in 0..<width where row[x] > 0 { above[x] = row[x] }
        }
        return strips
    }
}

/// A plain surface picked by touch (Phil, 2026-11-22: "a wall I could not select as in front"): Vision's subject
/// finder only knows things, not walls, so the picked area grows out from the touch over pixels of like colour,
/// stopping at edges in the picture and, where depth is known, at steps in depth. Works with the camera alone.
enum RegionGrow {
    /// `colour` holds brightness and the two colour differences per pixel (0-255 each), `depth` metres or 0.
    static func grow(colour: [SIMD3<Float>], depth: [Float]?, width: Int, height: Int, seedX: Int, seedY: Int,
                     step: Float = 7, drift: Float = 55, depthJump: Float = 0.06) -> [Bool] {
        guard width > 2, height > 2, colour.count >= width * height, seedX >= 0, seedX < width, seedY >= 0, seedY < height else { return [] }
        // Soften the picture (3 by 3) so a surface's grain and noise don't stop the growing.
        var soft = colour
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum = SIMD3<Float>(repeating: 0)
                for dy in -1...1 { for dx in -1...1 { sum += colour[(y + dy) * width + x + dx] } }
                soft[y * width + x] = sum / 9
            }
        }
        func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d = a - b
            return abs(d.x) + 1.5 * (abs(d.y) + abs(d.z))
        }
        // The seed's colour: the middle of its 5 by 5 patch.
        var seedSum = SIMD3<Float>(repeating: 0), seedCount: Float = 0
        for y in max(0, seedY - 2)...min(height - 1, seedY + 2) {
            for x in max(0, seedX - 2)...min(width - 1, seedX + 2) { seedSum += soft[y * width + x]; seedCount += 1 }
        }
        let seedColour = seedSum / seedCount
        var inside = [Bool](repeating: false, count: width * height)
        var queue = [seedY * width + seedX]
        inside[queue[0]] = true
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let n = ny * width + nx
                guard !inside[n] else { continue }
                guard distance(soft[n], soft[i]) <= step, distance(soft[n], seedColour) <= drift else { continue }
                if let depth {
                    let a = depth[i], b = depth[n]
                    if a > 0.12, b > 0.12, abs(a - b) > depthJump * max(1, a) { continue }
                }
                inside[n] = true
                queue.append(n)
            }
        }
        return close(inside, width: width, height: height, radius: 2)
    }

    /// Fills specks and thin cracks left inside the grown area (grow by `radius`, then shrink back).
    static func close(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        func spread(_ m: [Bool], _ value: Bool) -> [Bool] {
            var out = m
            for y in 0..<height {
                for x in 0..<width where m[y * width + x] == value {
                    for dy in -radius...radius {
                        let yy = y + dy
                        guard yy >= 0, yy < height else { continue }
                        for dx in -radius...radius {
                            let xx = x + dx
                            guard xx >= 0, xx < width else { continue }
                            out[yy * width + xx] = value
                        }
                    }
                }
            }
            return out
        }
        // Shrinking: the outside grows back; the picture's border doesn't count as outside.
        return spread(spread(mask, true), false)
    }
}

extension OccluderMesh {
    /// The mesh without its specks: pieces of fewer than `minTriangles` joined triangles (Phil's 1424 recording, looking
    /// down from a balcony: stray LiDAR readings punched changing holes in a model with nothing real in front of it).
    func withoutSpecks(minTriangles: Int) -> OccluderMesh {
        let count = positions.count / 3
        guard minTriangles > 1, indices.count >= 3, count > 0 else { return self }
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func join(_ a: Int, _ b: Int) { let ra = root(a), rb = root(b); if ra != rb { parent[ra] = rb } }
        let triangles = indices.count / 3
        for t in 0..<triangles {
            let a = Int(indices[t * 3]), b = Int(indices[t * 3 + 1]), c = Int(indices[t * 3 + 2])
            join(a, b); join(b, c)
        }
        var sizes = [Int](repeating: 0, count: count)
        for t in 0..<triangles { sizes[root(Int(indices[t * 3]))] += 1 }
        var out = self
        out.indices = []
        out.indices.reserveCapacity(indices.count)
        for t in 0..<triangles where sizes[root(Int(indices[t * 3]))] >= minTriangles {
            out.indices.append(contentsOf: indices[(t * 3)..<(t * 3 + 3)])
        }
        return out
    }
}

/// A depth picture moved to where another camera sees it (Phil, 2026-11-26: thin wires flickered while the phone moved;
/// the pictures before can only vote once they are seen from where the camera is now). Each reading is put back in the
/// room and seen again from the new camera, nearest winning; spots the old picture didn't cover read -1 (not seen).
enum DepthWarp {
    struct Lens: Sendable { var fx: Float, fy: Float, cx: Float, cy: Float }

    static func warp(_ depth: [Float], width: Int, height: Int, lens: Lens, from: simd_float4x4, to: simd_float4x4,
                     typical: Float = 2) -> [Float] {
        guard width > 0, height > 0, depth.count >= width * height else { return [] }
        var out = [Float](repeating: -1, count: width * height)
        let move = to.inverse * from
        // Spots the old picture had in view (judged at `typical` metres) start as seen but empty (0): an old picture with
        // no reading there votes "nothing", so one stray reading now doesn't win alone.
        let back = from.inverse * to
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) + 0.5, v = Float(y) + 0.5
                let p = back * SIMD4((u - lens.cx) / lens.fx * typical, -(v - lens.cy) / lens.fy * typical, -typical, 1)
                guard p.z < -0.05 else { continue }
                let ou = lens.fx * p.x / -p.z + lens.cx, ov = -lens.fy * p.y / -p.z + lens.cy
                if ou >= 0, ou < Float(width), ov >= 0, ov < Float(height) { out[y * width + x] = 0 }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let d = depth[y * width + x]
                guard d > 0, d.isFinite else { continue }
                let u = Float(x) + 0.5, v = Float(y) + 0.5
                let p = move * SIMD4((u - lens.cx) / lens.fx * d, -(v - lens.cy) / lens.fy * d, -d, 1)
                guard p.z < -0.05 else { continue }
                let z = -p.z
                let nu = lens.fx * p.x / z + lens.cx, nv = -lens.fy * p.y / z + lens.cy
                // Two pixels each way, so a nearer picture leaves no cracks.
                let x0 = Int((nu - 0.5).rounded(.down)), y0 = Int((nv - 0.5).rounded(.down))
                for yy in y0...(y0 + 1) where yy >= 0 && yy < height {
                    for xx in x0...(x0 + 1) where xx >= 0 && xx < width {
                        let i = yy * width + xx
                        if out[i] <= 0 || z < out[i] { out[i] = z }
                    }
                }
            }
        }
        return out
    }
}

/// How far behind a LiDAR reading a hiding surface is put, so a model at about the same distance isn't cut by noise.
/// LiDAR's scatter grows with the square of distance (Phil's 1427 recording in low light: a scan 4.3 m away over an alley
/// flickered in dashes as readings there fell in front of it one picture and behind it the next): 12 cm at 1 m, as
/// before, so wires near the camera still hide what's behind them; about 60 cm at 4.3 m.
enum DepthMargin {
    static func back(_ d: Float) -> Float { d + 0.06 + 0.04 * d + 0.02 * d * d }
}
