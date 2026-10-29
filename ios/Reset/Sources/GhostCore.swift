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

    /// Voxel cell to point index, for finding a point's neighbours.
    static func cells(of positions: [SIMD3<Float>]) -> [SIMD3<Int32>: Int32] {
        var cells = [SIMD3<Int32>: Int32](minimumCapacity: positions.count)
        for (index, point) in positions.enumerated() { cells[cell(point)] = Int32(index) }
        return cells
    }

    /// Scores each point against one live depth map: the live depth landing on the point counts
    /// towards "still there", seeing through to something further away towards "gone". Something
    /// nearer than the point stands in front of it, which says nothing about it.
    ///
    /// "Gone" needs every live reading within `window` pixels to see past the point, so a prop
    /// edge a few centimetres out after tracking drift does not count as gone because the live
    /// depth beside it hits the wall behind.
    static func check(
        positions: [SIMD3<Float>], scores: inout [Int8], depth: [Float], confidence: [UInt8]?, camera: PinholeCamera,
        window: Int = 0
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
            var nearest = d
            if window > 0 {
                for wy in max(0, y - window)...min(h - 1, y + window) {
                    for wx in max(0, x - window)...min(w - 1, x + window) {
                        let n = depth[wy * w + wx]
                        if n > 0.1, n < nearest { nearest = n }
                    }
                }
            }
            if nearest > z + limit {
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
    /// A silhouette needs a step back of at least this share of the distance, plus `minStep`, so
    /// the gentle slope of a floor or table top never draws a line.
    static let stepShare: Float = 0.08
    static let minStep: Float = 0.04
    /// A crease (the edge of a box, where a table top meets its side) turns the surface by at
    /// least this many degrees.
    static let creaseDegrees: Float = 50
    /// Drawn lines shorter than this many pixels are noise.
    static let minLine = 50
    /// Gone lines shorter than this many pixels are noise.
    static let minGoneLine = 60

    // MARK: Edges

    /// The edges of things in one depth view, as world points: silhouettes (where the set steps
    /// back sharply) and creases (where a surface folds, like the corner of a box). Found on a
    /// smoothed copy of the depth so LiDAR noise and smeared readings do not draw lines, and only
    /// lines several pixels long are kept.
    ///
    /// With the view's photo (`photoScale` times the depth map's size, RGBA, top row first) the
    /// lines follow the photo's sharp edges where they run beside the LiDAR's blurry ones, which
    /// makes clean, unbroken outlines; where the photo shows no edge (same colour both sides)
    /// the LiDAR's edge is kept.
    static func edgePoints(depth raw: [Float], camera: PinholeCamera, photo: [UInt8]? = nil) -> [SIMD3<Float>] {
        let w = camera.width
        let h = camera.height
        guard raw.count == w * h, w > 8, h > 8 else { return [] }
        let (edge, depth) = depthEdges(raw, width: w, height: h, camera: camera)
        if let photo, photo.count == w * h * photoScale * photoScale * 4 {
            return photoEdgePoints(edge: edge, depth: depth, photo: photo, camera: camera)
        }
        var out: [SIMD3<Float>] = []
        for y in 0..<h {
            for x in 0..<w where edge[y * w + x] {
                out.append(camera.unproject(u: Float(x), v: Float(y), depth: depth[y * w + x]))
            }
        }
        return out
    }

    /// Photos are read at this many times the depth map's size for the outlines.
    static let photoScale = 3
    /// Photo edges count within this many depth pixels of a LiDAR edge.
    static let photoReach = 3
    /// How sharp a photo edge must be to start a line, and to carry one on: the colour change
    /// across three pixels, 0 to 4 (4 is black to white).
    static let photoStrong: Float = 0.3
    static let photoWeak: Float = 0.12

    /// The LiDAR's edge pixels (silhouettes and creases) and the smoothed depth they were
    /// found on.
    static func depthEdges(_ raw: [Float], width w: Int, height h: Int, camera: PinholeCamera) -> (edge: [Bool], depth: [Float]) {
        let depth = smoothed(raw, width: w, height: h)
        func at(_ x: Int, _ y: Int) -> Float { depth[y * w + x] }
        func valid(_ d: Float) -> Bool { d > 0.1 && d < maxRange }

        var edge = [Bool](repeating: false, count: w * h)
        // Silhouettes: the near side of a big step back.
        var jump = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let z = at(x, y)
                guard valid(z) else { continue }
                let limit = z * (1 + stepShare) + minStep
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let n = at(nx, ny)
                    if valid(n), n > limit { jump[y * w + x] = true; break }
                    // Something smaller and nearer beside it also counts as a step, for the
                    // marking below, so creases are not looked for across it.
                    if valid(n), z > n * (1 + stepShare) + minStep { jump[y * w + x] = true }
                }
            }
        }
        // The silhouette line itself: only the pixel right beside the step, for a thin line.
        for y in 0..<h {
            for x in 0..<w {
                let z = at(x, y)
                guard valid(z) else { continue }
                let limit = z * (1 + stepShare) + minStep
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    if at(nx, ny) > limit, valid(at(nx, ny)) { edge[y * w + x] = true; break }
                }
            }
        }

        // Creases: surface normals either side of a pixel turn sharply.
        var points = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h {
            for x in 0..<w where valid(at(x, y)) {
                points[y * w + x] = camera.unproject(u: Float(x), v: Float(y), depth: at(x, y))
            }
        }
        let r = 2
        var normals = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in r..<(h - r) {
            for x in r..<(w - r) {
                let i = y * w + x
                guard valid(at(x, y)), !jump[i] else { continue }
                let corners = [at(x - r, y), at(x + r, y), at(x, y - r), at(x, y + r)]
                guard corners.allSatisfy({ valid($0) && abs($0 - at(x, y)) < 0.1 * at(x, y) + 0.05 }) else { continue }
                let across = points[i + r] - points[i - r]
                let down = points[i + r * w] - points[i - r * w]
                let n = simd_cross(across, down)
                let length = simd_length(n)
                if length > 1e-9 { normals[i] = n / length }
            }
        }
        // How sharply the surface turns across each pixel, left to right and top to bottom; a
        // crease is where that peaks, so the line is one pixel wide rather than a band.
        let turn = 1 - cos(creaseDegrees * .pi / 180)
        let s = 3
        var across = [Float](repeating: 0, count: w * h)
        var down = [Float](repeating: 0, count: w * h)
        for y in s..<(h - s) {
            for x in s..<(w - s) {
                let i = y * w + x
                guard normals[i] != .zero else { continue }
                if normals[i - s] != .zero, normals[i + s] != .zero { across[i] = 1 - simd_dot(normals[i - s], normals[i + s]) }
                if normals[i - s * w] != .zero, normals[i + s * w] != .zero { down[i] = 1 - simd_dot(normals[i - s * w], normals[i + s * w]) }
            }
        }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                if across[i] > turn, across[i] >= across[i - 1], across[i] >= across[i + 1] { edge[i] = true }
                if down[i] > turn, down[i] >= down[i - w], down[i] >= down[i + w] { edge[i] = true }
            }
        }

        return (keepLarge(edge, width: w, height: h, minSize: 8), depth)
    }

    /// The photo's sharp edges near the LiDAR's edges, placed in 3D at the nearer depth beside
    /// them (an outline belongs to the thing in front), plus the LiDAR's edges where the photo
    /// has none.
    static func photoEdgePoints(edge: [Bool], depth: [Float], photo: [UInt8], camera: PinholeCamera) -> [SIMD3<Float>] {
        let w = camera.width
        let h = camera.height
        let f = photoScale
        let W = w * f
        let H = h * f
        func dilated(_ mask: [Bool], _ r: Int) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w where mask[y * w + x] {
                    for ny in max(0, y - r)...min(h - 1, y + r) {
                        for nx in max(0, x - r)...min(w - 1, x + r) { out[ny * w + nx] = true }
                    }
                }
            }
            return out
        }
        let reach = dilated(edge, photoReach)
        let work = dilated(edge, photoReach + 1)

        // Edge strength, Sobel on whichever colour changes most, only near the LiDAR's edges.
        var magnitude = [Float](repeating: 0, count: W * H)
        var gradX = [Float](repeating: 0, count: W * H)
        var gradY = [Float](repeating: 0, count: W * H)
        photo.withUnsafeBufferPointer { p in
            for Y in 1..<(H - 1) {
                for X in 1..<(W - 1) where work[(Y / f) * w + X / f] {
                    var best: Float = 0, bx: Float = 0, by: Float = 0
                    for c in 0..<3 {
                        func v(_ x: Int, _ y: Int) -> Float { Float(p[(y * W + x) * 4 + c]) }
                        let gx = (v(X + 1, Y - 1) + 2 * v(X + 1, Y) + v(X + 1, Y + 1)) - (v(X - 1, Y - 1) + 2 * v(X - 1, Y) + v(X - 1, Y + 1))
                        let gy = (v(X - 1, Y + 1) + 2 * v(X, Y + 1) + v(X + 1, Y + 1)) - (v(X - 1, Y - 1) + 2 * v(X, Y - 1) + v(X + 1, Y - 1))
                        let m = gx * gx + gy * gy
                        if m > best { best = m; bx = gx; by = gy }
                    }
                    let I = Y * W + X
                    magnitude[I] = best.squareRoot() / 255
                    gradX[I] = bx
                    gradY[I] = by
                }
            }
        }
        // Thin to the ridge across the edge, then keep weak ridges joined to strong ones.
        var ridge = [Bool](repeating: false, count: W * H)
        var stack: [Int] = []
        var kept = [Bool](repeating: false, count: W * H)
        for Y in 1..<(H - 1) {
            for X in 1..<(W - 1) where reach[(Y / f) * w + X / f] {
                let I = Y * W + X
                let m = magnitude[I]
                guard m > photoWeak else { continue }
                let gx = abs(gradX[I])
                let gy = abs(gradY[I])
                let step: Int
                if gx > 2.414 * gy { step = 1 }
                else if gy > 2.414 * gx { step = W }
                else { step = gradX[I] * gradY[I] > 0 ? W + 1 : W - 1 }
                guard m >= magnitude[I - step], m >= magnitude[I + step] else { continue }
                ridge[I] = true
                if m > photoStrong { kept[I] = true; stack.append(I) }
            }
        }
        while let I = stack.popLast() {
            for n in [I - W - 1, I - W, I - W + 1, I - 1, I + 1, I + W - 1, I + W, I + W + 1] where ridge[n] && !kept[n] {
                kept[n] = true
                stack.append(n)
            }
        }
        kept = keepLarge(kept, width: W, height: H, minSize: 4 * f)

        // Depth for a photo pixel: the nearest reading within two depth pixels.
        func nearDepth(_ x: Int, _ y: Int) -> Float? {
            var best = Float.infinity
            for ny in max(0, y - 2)...min(h - 1, y + 2) {
                for nx in max(0, x - 2)...min(w - 1, x + 2) {
                    let d = depth[ny * w + nx]
                    if d > 0.1, d < maxRange, d < best { best = d }
                }
            }
            return best.isFinite ? best : nil
        }
        var out: [SIMD3<Float>] = []
        var covered = [Bool](repeating: false, count: w * h)
        let scale = Float(f)
        for Y in 0..<H {
            for X in 0..<W where kept[Y * W + X] {
                let x = X / f
                let y = Y / f
                guard let d = nearDepth(x, y) else { continue }
                out.append(camera.unproject(u: (Float(X) + 0.5) / scale - 0.5, v: (Float(Y) + 0.5) / scale - 0.5, depth: d))
                for ny in max(0, y - 2)...min(h - 1, y + 2) {
                    for nx in max(0, x - 2)...min(w - 1, x + 2) { covered[ny * w + nx] = true }
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w where edge[y * w + x] && !covered[y * w + x] {
                out.append(camera.unproject(u: Float(x), v: Float(y), depth: depth[y * w + x]))
            }
        }
        return out
    }

    /// Depth with LiDAR noise smoothed out but edges kept: each reading becomes the median of
    /// its 3 x 3 neighbours, then the average of the 5 x 5 readings close to it in depth.
    static func smoothed(_ raw: [Float], width w: Int, height h: Int) -> [Float] {
        // First drop the LiDAR's smeared readings: one that sits between its neighbours on
        // opposite sides, close to neither, is half prop and half background, a point in mid-air.
        var depth = raw
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let z = raw[y * w + x]
                guard z > 0.1 else { continue }
                let near = 0.03 + 0.03 * z
                for (a, b) in [(raw[y * w + x - 1], raw[y * w + x + 1]), (raw[(y - 1) * w + x], raw[(y + 1) * w + x])] {
                    guard a > 0.1, b > 0.1 else { continue }
                    if abs(a - b) > 2 * near, abs(z - a) > near, abs(z - b) > near { depth[y * w + x] = 0; break }
                }
            }
        }
        var median = depth
        var window: [Float] = []
        window.reserveCapacity(9)
        for y in 0..<h {
            for x in 0..<w {
                window.removeAll(keepingCapacity: true)
                for dy in -1...1 where y + dy >= 0 && y + dy < h {
                    for dx in -1...1 where x + dx >= 0 && x + dx < w {
                        let d = depth[(y + dy) * w + x + dx]
                        if d > 0.1 { window.append(d) }
                    }
                }
                guard window.count >= 5 else { median[y * w + x] = 0; continue }
                window.sort()
                median[y * w + x] = window[window.count / 2]
            }
        }
        var out = median
        for y in 0..<h {
            for x in 0..<w {
                let z = median[y * w + x]
                guard z > 0.1 else { continue }
                var sum: Float = 0
                var count: Float = 0
                for dy in -2...2 where y + dy >= 0 && y + dy < h {
                    for dx in -2...2 where x + dx >= 0 && x + dx < w {
                        let d = median[(y + dy) * w + x + dx]
                        if d > 0.1, abs(d - z) < 0.03 + 0.02 * z { sum += d; count += 1 }
                    }
                }
                out[y * w + x] = sum / count
            }
        }
        return out
    }

    /// One reference view's edges, with where it was taken from.
    struct EdgeView {
        var cameraToWorld: simd_float4x4
        var edges: Cloud
    }

    /// One view's edge points as a cloud to draw.
    static func edgeView(_ points: [SIMD3<Float>], camera: PinholeCamera) -> EdgeView {
        var cloud = Cloud()
        cloud.positions = points
        cloud.colors = Array(repeating: outlineColor, count: points.count)
        return EdgeView(cameraToWorld: camera.cameraToWorld, edges: cloud)
    }

    /// The view whose edges to draw: the one taken nearest the live camera, metres plus 0.5 m
    /// per 30 degrees of turn. Edges are drawn from one view at a time because views drift a
    /// few centimetres apart, and drawing several doubles every line. Sticks with `current`
    /// unless another is clearly nearer, so the lines do not flick between views.
    static func nearestView(_ views: [EdgeView], to camera: simd_float4x4, current: Int?) -> Int? {
        func score(_ view: EdgeView) -> Float {
            let a = view.cameraToWorld
            let distance = simd_distance(SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z), SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z))
            let forward = simd_dot(-SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z), -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
            return distance + acos(min(1, max(-1, forward))) / (.pi / 6) * 0.5
        }
        guard let best = views.indices.filter({ !views[$0].edges.positions.isEmpty }).min(by: { score(views[$0]) < score(views[$1]) }) else { return nil }
        if let current, current < views.count, current != best, score(views[best]) > score(views[current]) * 0.8 - 0.02 {
            return current
        }
        return best
    }


    /// Each edge point is gone when most of the surface around it is gone.
    static func edgeStates(edges: [SIMD3<Float>], surfaceStates: [State], surfaceCells: [SIMD3<Int32>: Int32]) -> [State] {
        edges.map { point in
            let c = cell(point)
            var gone = 0
            var other = 0
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 {
                        guard let index = surfaceCells[c &+ SIMD3(dx, dy, dz)] else { continue }
                        if surfaceStates[Int(index)] == .gone { gone += 1 } else { other += 1 }
                    }
                }
            }
            return gone >= 3 && gone > other ? .gone : .unchecked
        }
    }

    // MARK: Drawing

    /// Draws the edges as the camera sees them, as thin clean lines with a dark rim so they read
    /// over any set: RGBA bytes, premultiplied, top row first, at the camera's size. Yellow for
    /// the props as they were, blue for edges of things that have gone. The surface cloud only
    /// hides edges that something stands in front of. With no edges, the surface points are
    /// drawn as small dots instead. `strength` is the ghost strength slider.
    static func render(surface: Cloud, edges: Cloud, states: [State]?, camera: PinholeCamera, strength: Float) -> [UInt8] {
        let W = camera.width
        let H = camera.height
        // What is in front, worked out at half size from the surface, gaps closed.
        let small = camera.scaled(by: 0.5)
        let w = small.width
        let h = small.height
        var near = [Float](repeating: .infinity, count: w * h)
        near.withUnsafeMutableBufferPointer { near in
            for point in surface.positions {
                guard let p = small.project(point) else { continue }
                let z = p.depth
                let r = Int(min(4, max(1, (small.fx * voxel * 0.5 / z).rounded())))
                let x0 = Int(p.u.rounded())
                let y0 = Int(p.v.rounded())
                guard x0 >= -r, x0 < w + r, y0 >= -r, y0 < h + r else { continue }
                for y in max(0, y0 - r)...min(h - 1, y0 + r) {
                    for x in max(0, x0 - r)...min(w - 1, x0 + r) where z < near[y * w + x] {
                        near[y * w + x] = z
                    }
                }
            }
        }
        let front = maxFilter(minFilter(near, width: w, height: h, radius: 2), width: w, height: h, radius: 2)

        let lines = edges.positions.isEmpty ? surface.positions : edges.positions
        let lineStates = edges.positions.isEmpty ? nil : states
        var yellow = [Bool](repeating: false, count: W * H)
        var blue = [Bool](repeating: false, count: W * H)
        for (index, point) in lines.enumerated() {
            guard let p = camera.project(point) else { continue }
            let z = p.depth
            let x0 = Int(p.u.rounded())
            let y0 = Int(p.v.rounded())
            guard x0 >= 0, x0 < W, y0 >= 0, y0 < H else { continue }
            // Hidden when the surface in front is clearly nearer, all round it.
            var hidden = true
            let sx = x0 / 2
            let sy = y0 / 2
            for dy in -1...1 where sy + dy >= 0 && sy + dy < h {
                for dx in -1...1 where sx + dx >= 0 && sx + dx < w {
                    let f = front[(sy + dy) * w + sx + dx]
                    if !f.isFinite || z <= f * 1.04 + 0.04 { hidden = false }
                }
            }
            if hidden { continue }
            let gone = lineStates?[index] == .gone
            // Dots wide enough to merge the scatter of an edge into one band for thinning.
            let r = Int(min(4, max(1, (camera.fx * 0.02 / z).rounded())))
            for y in max(0, y0 - r)...min(H - 1, y0 + r) {
                for x in max(0, x0 - r)...min(W - 1, x0 + r) {
                    if gone { blue[y * W + x] = true } else { yellow[y * W + x] = true }
                }
            }
        }
        // Many views' worth of edge points scatter a little either side of the true edge: thin
        // what they cover down to its centre line, then drop short bits, for clean lines.
        if !edges.positions.isEmpty {
            yellow = keepLarge(pruned(thinned(yellow, width: W, height: H), width: W, height: H), width: W, height: H, minSize: minLine / 2)
            blue = keepLarge(pruned(thinned(blue, width: W, height: H), width: W, height: H), width: W, height: H, minSize: minGoneLine / 2)
            // Back to a steady width of three pixels.
            yellow = widened(yellow, width: W, height: H)
            blue = widened(blue, width: W, height: H)
        }

        var out = [UInt8](repeating: 0, count: W * H * 4)
        let alpha = min(1, max(0.7, strength))
        func put(_ i: Int, _ color: SIMD3<Float>, _ a: Float) {
            let o = i * 4
            out[o] = UInt8(min(255, color.x * a * 255))
            out[o + 1] = UInt8(min(255, color.y * a * 255))
            out[o + 2] = UInt8(min(255, color.z * a * 255))
            out[o + 3] = UInt8(a * 255)
        }
        // A thin dark rim first, so the lines stand out on pale and dark sets alike.
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                guard yellow[i] || blue[i] else { continue }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                    let n = ny * W + nx
                    if !yellow[n], !blue[n] { put(n, .zero, 0.45) }
                }
            }
        }
        for i in 0..<(W * H) {
            if blue[i] { put(i, goneColor, 1) } else if yellow[i] { put(i, outlineColor, alpha) }
        }
        return out
    }

    /// The centre lines of a mask, one pixel wide (Zhang and Suen's thinning).
    static func thinned(_ mask: [Bool], width w: Int, height h: Int) -> [Bool] {
        var m = mask
        for x in 0..<w { m[x] = false; m[(h - 1) * w + x] = false }
        for y in 0..<h { m[y * w] = false; m[y * w + w - 1] = false }
        var candidates = (0..<(w * h)).filter { m[$0] }
        var remove: [Int] = []
        for _ in 0..<30 {
            var changed = false
            for pass in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                for i in candidates where m[i] {
                    // Neighbours clockwise from the top.
                    let p = [m[i - w], m[i - w + 1], m[i + 1], m[i + w + 1], m[i + w], m[i + w - 1], m[i - 1], m[i - w - 1]]
                    let count = p.reduce(0) { $0 + ($1 ? 1 : 0) }
                    guard count >= 2, count <= 6 else { continue }
                    var transitions = 0
                    for k in 0..<8 where !p[k] && p[(k + 1) % 8] { transitions += 1 }
                    guard transitions == 1 else { continue }
                    if pass == 0 {
                        guard !(p[0] && p[2] && p[4]), !(p[2] && p[4] && p[6]) else { continue }
                    } else {
                        guard !(p[0] && p[2] && p[6]), !(p[0] && p[4] && p[6]) else { continue }
                    }
                    remove.append(i)
                }
                for i in remove { m[i] = false }
                if !remove.isEmpty { changed = true }
            }
            candidates = candidates.filter { m[$0] }
            if !changed { break }
        }
        return m
    }

    /// Thinned lines with their short whiskers trimmed: line ends are eaten back `length`
    /// pixels, which takes off small side branches entirely, then the ends of the lines that
    /// are left grow back along where they were.
    static func pruned(_ mask: [Bool], width w: Int, height h: Int, length: Int = 6) -> [Bool] {
        var m = mask
        func around(_ i: Int) -> [Int] {
            let x = i % w, y = i / w
            var out: [Int] = []
            for dy in -1...1 where y + dy >= 0 && y + dy < h {
                for dx in -1...1 where (dx != 0 || dy != 0) && x + dx >= 0 && x + dx < w { out.append((y + dy) * w + x + dx) }
            }
            return out
        }
        var removed = Set<Int>()
        var live = (0..<(w * h)).filter { m[$0] }
        for _ in 0..<length {
            let ends = live.filter { i in around(i).filter { m[$0] }.count <= 1 }
            for i in ends { m[i] = false; removed.insert(i) }
            live = live.filter { m[$0] }
        }
        var frontier = live.filter { i in around(i).filter { m[$0] }.count <= 1 }
        for _ in 0..<length {
            var next: [Int] = []
            for i in frontier {
                for n in around(i) where removed.contains(n) && !m[n] {
                    m[n] = true
                    next.append(n)
                }
            }
            frontier = next
        }
        return m
    }

    /// Each set pixel and the four beside it.
    static func widened(_ mask: [Bool], width w: Int, height h: Int) -> [Bool] {
        var out = mask
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                if x > 0 { out[y * w + x - 1] = true }
                if x < w - 1 { out[y * w + x + 1] = true }
                if y > 0 { out[(y - 1) * w + x] = true }
                if y < h - 1 { out[(y + 1) * w + x] = true }
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
