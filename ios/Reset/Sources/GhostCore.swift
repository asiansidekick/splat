import Foundation
import simd

/// A pinhole camera in ARKit's conventions: camera space has x right, y up and looks down -z;
/// image pixels have v going down. Intrinsics are in pixels of the image the camera describes.
struct PinholeCamera {
    let cameraToWorld: simd_float4x4
    let worldToCamera: simd_float4x4
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Int
    let height: Int

    /// `intrinsics` refer to an image `imageWidth` wide; the camera is scaled to `width` x `height`.
    init(cameraToWorld: simd_float4x4, intrinsics: simd_float3x3, imageWidth: Int, width: Int, height: Int) {
        let s = Float(width) / Float(max(imageWidth, 1))
        self.cameraToWorld = cameraToWorld
        worldToCamera = cameraToWorld.inverse
        fx = intrinsics[0][0] * s
        fy = intrinsics[1][1] * s
        cx = intrinsics[2][0] * s
        cy = intrinsics[2][1] * s
        self.width = width
        self.height = height
    }

    /// The same camera drawing a picture `factor` times the size.
    func scaled(by factor: Float) -> PinholeCamera {
        PinholeCamera(
            cameraToWorld: cameraToWorld, worldToCamera: worldToCamera, fx: fx * factor, fy: fy * factor,
            cx: cx * factor, cy: cy * factor,
            width: Int((Float(width) * factor).rounded()), height: Int((Float(height) * factor).rounded()))
    }

    private init(
        cameraToWorld: simd_float4x4, worldToCamera: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float,
        width: Int, height: Int
    ) {
        self.cameraToWorld = cameraToWorld
        self.worldToCamera = worldToCamera
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// The point at pixel (u, v) with depth d (metres along the view direction), in world space.
    func unproject(u: Float, v: Float, depth d: Float) -> SIMD3<Float> {
        let local = SIMD4<Float>((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
        let world = cameraToWorld * local
        return SIMD3(world.x, world.y, world.z)
    }

    /// Pixel position and depth of a world point, or nil when it is behind the camera.
    func project(_ point: SIMD3<Float>) -> (u: Float, v: Float, depth: Float)? {
        let p = worldToCamera * SIMD4<Float>(point, 1)
        let z = -p.z
        guard z > 0.05 else { return nil }
        return (fx * p.x / z + cx, -fy * p.y / z + cy, z)
    }
}

/// The 3D ghost's maths, free of ARKit and UIKit so the tests run it on a Mac: building a
/// coloured point cloud from LiDAR depth, checking it against live depth, and drawing it.
enum GhostCore {
    /// Points closer together than this are merged.
    static let voxel: Float = 0.015
    static let maxRange: Float = 4
    /// Differences smaller than this, plus `perMetre` per metre away, are LiDAR or tracking noise.
    static let threshold: Float = 0.06
    static let perMetre: Float = 0.02
    /// A gone point needs this many gone neighbours (of 26) to count, so only solid patches show.
    static let minNeighbours = 6

    struct Cloud {
        var positions: [SIMD3<Float>] = []
        /// RGB, 0 to 1.
        var colors: [SIMD3<Float>] = []
        /// How many depth views landed on each point.
        var hits: [UInt16] = []
    }

    enum State: UInt8 {
        case unchecked = 0, matched = 1, gone = 2
    }

    static func cell(_ point: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((point.x / voxel).rounded(.down)), Int32((point.y / voxel).rounded(.down)), Int32((point.z / voxel).rounded(.down)))
    }

    /// Adds one depth view to the cloud, one point per voxel. `depth` is row major at the camera's
    /// size; `rgba` is the photo at the same size, top row first. `filled` maps voxels to points.
    /// Returns the usable readings.
    ///
    /// Readings on the edge of something are skipped: the LiDAR smears them halfway between the
    /// prop and what is behind it, which leaves specks floating in mid-air.
    @discardableResult
    static func add(
        depth: [Float], rgba: [UInt8]?, camera: PinholeCamera, step: Int = 2, maxPoints: Int,
        to cloud: inout Cloud, filled: inout [SIMD3<Int32>: Int32]
    ) -> Int {
        let w = camera.width
        let h = camera.height
        guard depth.count == w * h else { return 0 }
        if cloud.hits.count != cloud.positions.count { cloud.hits = Array(repeating: 1, count: cloud.positions.count) }
        var readings = 0
        var landed = Set<Int32>()
        for v in stride(from: 0, to: h, by: step) {
            for u in stride(from: 0, to: w, by: step) {
                let d = depth[v * w + u]
                guard d > 0.1, d < maxRange else { continue }
                var smeared = false
                for (du, dv) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let x = u + du
                    let y = v + dv
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    let n = depth[y * w + x]
                    if n > 0.1, abs(n - d) > 0.04 + 0.04 * d { smeared = true; break }
                }
                if smeared { continue }
                readings += 1
                let point = camera.unproject(u: Float(u), v: Float(v), depth: d)
                let c = cell(point)
                if let index = filled[c] {
                    if landed.insert(index).inserted, cloud.hits[Int(index)] < .max { cloud.hits[Int(index)] += 1 }
                    continue
                }
                guard cloud.positions.count < maxPoints else { continue }
                var color = SIMD3<Float>(0.8, 0.8, 0.8)
                if let rgba, rgba.count == w * h * 4 {
                    let o = (v * w + u) * 4
                    color = SIMD3(Float(rgba[o]), Float(rgba[o + 1]), Float(rgba[o + 2])) / 255
                }
                let index = Int32(cloud.positions.count)
                filled[c] = index
                landed.insert(index)
                cloud.positions.append(point)
                cloud.colors.append(color)
                cloud.hits.append(1)
            }
        }
        return readings
    }

    /// Only the points that at least `minHits` depth views agree on: a speck seen once is noise.
    static func solid(_ cloud: Cloud, minHits: UInt16 = 2) -> Cloud {
        guard cloud.hits.count == cloud.positions.count else { return cloud }
        var out = Cloud()
        for i in cloud.positions.indices where cloud.hits[i] >= minHits {
            out.positions.append(cloud.positions[i])
            out.colors.append(cloud.colors[i])
            out.hits.append(cloud.hits[i])
        }
        return out
    }

    /// Voxel cell to point index, for finding a point's neighbours.
    static func cells(of positions: [SIMD3<Float>]) -> [SIMD3<Int32>: Int32] {
        var cells = [SIMD3<Int32>: Int32](minimumCapacity: positions.count)
        for (index, point) in positions.enumerated() { cells[cell(point)] = Int32(index) }
        return cells
    }

    /// Scores each point against one live depth map: the live depth landing on the point counts
    /// towards "still there", seeing through to something further away towards "gone". Something
    /// nearer than the point stands in front of it, which says nothing about it.
    static func check(
        positions: [SIMD3<Float>], scores: inout [Int8], depth: [Float], confidence: [UInt8]?, camera: PinholeCamera
    ) {
        let w = camera.width
        let h = camera.height
        guard depth.count == w * h, scores.count == positions.count else { return }
        let sure = confidence?.count == w * h ? confidence : nil
        for index in positions.indices {
            guard let p = camera.project(positions[index]), p.depth > 0.1, p.depth < maxRange else { continue }
            let z = p.depth
            let x = Int(p.u.rounded())
            let y = Int(p.v.rounded())
            guard x >= 0, x < w, y >= 0, y < h else { continue }
            let pixel = y * w + x
            if let sure, sure[pixel] < 1 { continue }
            let d = depth[pixel]
            guard d > 0.1 else { continue }
            let limit = threshold + perMetre * z
            if d > z + limit {
                scores[index] = min(scores[index] + 1, 4)
            } else if d >= z - limit {
                scores[index] = max(scores[index] - 2, -4)
            }
        }
    }

    /// Each point's state from its score. A gone point with too few gone neighbours is noise and
    /// counts as unchecked.
    static func states(scores: [Int8], positions: [SIMD3<Float>], cells: [SIMD3<Int32>: Int32]) -> [State] {
        var states = scores.map { $0 >= 3 ? State.gone : ($0 < 0 ? State.matched : State.unchecked) }
        let gone = states.map { $0 == .gone }
        for index in positions.indices where gone[index] {
            let c = cell(positions[index])
            var neighbours = 0
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                        if let other = cells[c &+ SIMD3(dx, dy, dz)], gone[Int(other)] { neighbours += 1 }
                    }
                }
            }
            if neighbours < minNeighbours { states[index] = .unchecked }
        }
        return states
    }

    static let outlineColor = SIMD3<Float>(1, 0.84, 0.1)
    static let goneColor = SIMD3<Float>(0.25, 0.6, 1)
    /// An outline needs a step back of at least this share of the distance, plus `minStep`, so
    /// the gentle slope of a floor or table top never draws a line.
    static let stepShare: Float = 0.12
    static let minStep: Float = 0.08
    /// Lines shorter than this many pixels (at the drawing's half size) are noise.
    static let minLine = 40
    /// Gone patches smaller than this many pixels (half size) are noise.
    static let minGoneArea = 150

    /// Draws the cloud as the camera sees it, as clean edge outlines only so the set stays
    /// visible: RGBA bytes, premultiplied, top row first, at the camera's size. Yellow lines
    /// where the set steps back sharply (the silhouettes of props against what is behind them),
    /// blue lines round anything large that has gone. Flat surfaces draw nothing. `strength` is
    /// the ghost strength slider.
    static func render(cloud: Cloud, states: [State]?, camera: PinholeCamera, strength: Float) -> [UInt8] {
        // Worked out at half size: dots cover the gaps between voxels with a quarter of the work,
        // and lines come out two pixels wide, bold enough to read at arm's length.
        let small = camera.scaled(by: 0.5)
        let w = small.width
        let h = small.height
        var near = [Float](repeating: .infinity, count: w * h)
        var owner = [Int32](repeating: -1, count: w * h)
        near.withUnsafeMutableBufferPointer { near in
            owner.withUnsafeMutableBufferPointer { owner in
                for index in cloud.positions.indices {
                    guard let p = small.project(cloud.positions[index]) else { continue }
                    let z = p.depth
                    // About the voxel's own size, so the shape does not grow; the closing below
                    // fills what gaps are left.
                    let r = Int(min(4, max(1, (small.fx * voxel * 0.5 / z).rounded())))
                    let x0 = Int(p.u.rounded())
                    let y0 = Int(p.v.rounded())
                    guard x0 >= -r, x0 < w + r, y0 >= -r, y0 < h + r else { continue }
                    for y in max(0, y0 - r)...min(h - 1, y0 + r) {
                        for x in max(0, x0 - r)...min(w - 1, x0 + r) {
                            let i = y * w + x
                            if z < near[i] {
                                near[i] = z
                                owner[i] = Int32(index)
                            }
                        }
                    }
                }
            }
        }

        // Close the gaps between dots without growing anything: take the nearest depth around
        // each pixel, then shrink back by taking the furthest, so holes fill but silhouettes stay
        // where they are.
        let surface = maxFilter(minFilter(near, width: w, height: h, radius: 2), width: w, height: h, radius: 2)

        // Silhouettes: the near side of a big step back in depth.
        var outline = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let z = surface[i]
                guard z.isFinite else { continue }
                let limit = z * (1 + stepShare) + minStep
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let n = surface[ny * w + nx]
                    if n.isFinite, n > limit { outline[i] = true; break }
                }
            }
        }
        outline = keepLarge(outline, width: w, height: h, minSize: minLine)

        // Gone: only patches big enough to be a prop, outlined round their edge.
        var goneEdge = [Bool](repeating: false, count: w * h)
        if let states {
            var gone = [Bool](repeating: false, count: w * h)
            for i in 0..<(w * h) where owner[i] >= 0 && states[Int(owner[i])] == .gone { gone[i] = true }
            gone = keepLarge(gone, width: w, height: h, minSize: minGoneArea)
            for y in 0..<h {
                for x in 0..<w where gone[y * w + x] {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx
                        let ny = y + dy
                        if nx < 0 || nx >= w || ny < 0 || ny >= h || !gone[ny * w + nx] { goneEdge[y * w + x] = true; break }
                    }
                }
            }
        }

        // Back to full size: each half-size pixel is a 2 x 2 block, and lines are thickened by
        // one more pixel so they read clearly. Blue wins where they meet.
        let W = camera.width
        let H = camera.height
        var out = [UInt8](repeating: 0, count: W * H * 4)
        let alpha = min(1, max(0.6, strength))
        func put(_ i: Int, _ color: SIMD3<Float>, _ a: Float) {
            let o = i * 4
            out[o] = UInt8(min(255, color.x * a * 255))
            out[o + 1] = UInt8(min(255, color.y * a * 255))
            out[o + 2] = UInt8(min(255, color.z * a * 255))
            out[o + 3] = UInt8(a * 255)
        }
        var painted = [UInt8](repeating: 0, count: W * H)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let kind: UInt8 = goneEdge[i] ? 2 : (outline[i] ? 1 : 0)
                guard kind > 0 else { continue }
                for by in -1...2 {
                    for bx in -1...2 {
                        let X = x * 2 + bx
                        let Y = y * 2 + by
                        guard X >= 0, X < W, Y >= 0, Y < H else { continue }
                        let n = Y * W + X
                        guard kind > painted[n] else { continue }
                        painted[n] = kind
                        put(n, kind == 2 ? goneColor : outlineColor, kind == 2 ? 1 : alpha)
                    }
                }
            }
        }
        return out
    }

    /// Keeps only the connected groups (touching, diagonals too) of at least `minSize` pixels.
    static func keepLarge(_ mask: [Bool], width w: Int, height h: Int, minSize: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var group: [Int] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            group.removeAll(keepingCapacity: true)
            while let i = stack.popLast() {
                group.append(i)
                let x = i % w
                let y = i / w
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let n = ny * w + nx
                        if mask[n], !seen[n] {
                            seen[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            if group.count >= minSize { for i in group { out[i] = true } }
        }
        return out
    }

    /// Each pixel's largest value within `radius`, ignoring empty (infinite) pixels; empty
    /// pixels stay empty.
    static func maxFilter(_ values: [Float], width w: Int, height h: Int, radius: Int) -> [Float] {
        func pass(_ input: [Float], horizontal: Bool) -> [Float] {
            var out = input
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard input[i].isFinite else { continue }
                    var m = input[i]
                    for k in -radius...radius {
                        let nx = horizontal ? x + k : x
                        let ny = horizontal ? y : y + k
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let v = input[ny * w + nx]
                        if v.isFinite, v > m { m = v }
                    }
                    out[i] = m
                }
            }
            return out
        }
        return pass(pass(values, horizontal: true), horizontal: false)
    }

    /// Each pixel's smallest value within `radius`, done as two passes (rows, then columns).
    static func minFilter(_ values: [Float], width w: Int, height h: Int, radius: Int) -> [Float] {
        var rows = values
        for y in 0..<h {
            for x in 0..<w {
                var m = Float.infinity
                for dx in -radius...radius where x + dx >= 0 && x + dx < w { m = min(m, values[y * w + x + dx]) }
                rows[y * w + x] = m
            }
        }
        var out = rows
        for y in 0..<h {
            for x in 0..<w {
                var m = Float.infinity
                for dy in -radius...radius where y + dy >= 0 && y + dy < h { m = min(m, rows[(y + dy) * w + x]) }
                out[y * w + x] = m
            }
        }
        return out
    }
}
