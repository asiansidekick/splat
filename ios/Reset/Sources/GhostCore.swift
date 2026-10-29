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
    static let minNeighbours = 3

    struct Cloud {
        var positions: [SIMD3<Float>] = []
        /// RGB, 0 to 1.
        var colors: [SIMD3<Float>] = []
    }

    enum State: UInt8 {
        case unchecked = 0, matched = 1, gone = 2
    }

    static func cell(_ point: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((point.x / voxel).rounded(.down)), Int32((point.y / voxel).rounded(.down)), Int32((point.z / voxel).rounded(.down)))
    }

    /// Adds one depth view to the cloud, one point per voxel. `depth` is row major at the camera's
    /// size; `rgba` is the photo at the same size, top row first. Returns the usable readings.
    @discardableResult
    static func add(
        depth: [Float], rgba: [UInt8]?, camera: PinholeCamera, step: Int = 2, maxPoints: Int,
        to cloud: inout Cloud, filled: inout Set<SIMD3<Int32>>
    ) -> Int {
        let w = camera.width
        let h = camera.height
        guard depth.count == w * h else { return 0 }
        var readings = 0
        for v in stride(from: 0, to: h, by: step) {
            for u in stride(from: 0, to: w, by: step) {
                guard cloud.positions.count < maxPoints else { return readings }
                let d = depth[v * w + u]
                guard d > 0.1, d < maxRange else { continue }
                readings += 1
                let point = camera.unproject(u: Float(u), v: Float(v), depth: d)
                guard filled.insert(cell(point)).inserted else { continue }
                var color = SIMD3<Float>(0.8, 0.8, 0.8)
                if let rgba, rgba.count == w * h * 4 {
                    let o = (v * w + u) * 4
                    color = SIMD3(Float(rgba[o]), Float(rgba[o + 1]), Float(rgba[o + 2])) / 255
                }
                cloud.positions.append(point)
                cloud.colors.append(color)
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
        var states = scores.map { $0 >= 2 ? State.gone : ($0 < 0 ? State.matched : State.unchecked) }
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

    /// Draws the cloud as the camera sees it: RGBA bytes, premultiplied, top row first, at the
    /// camera's size. Dots grow nearer the camera and the nearest dot wins each pixel. Edges where
    /// the cloud steps back (the outline of a prop against what is behind it) are drawn in yellow,
    /// and the edge of anything gone in blue. `strength` is the ghost strength slider.
    static func render(cloud: Cloud, states: [State]?, camera: PinholeCamera, strength: Float) -> [UInt8] {
        let w = camera.width
        let h = camera.height
        var near = [Float](repeating: .infinity, count: w * h)
        var owner = [Int32](repeating: -1, count: w * h)
        near.withUnsafeMutableBufferPointer { near in
            owner.withUnsafeMutableBufferPointer { owner in
                for index in cloud.positions.indices {
                    guard let p = camera.project(cloud.positions[index]) else { continue }
                    let z = p.depth
                    let r = Int(min(3, max(1, camera.fx * voxel * 0.6 / z)).rounded())
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

        var out = [UInt8](repeating: 0, count: w * h * 4)
        let outlineAlpha = max(0.7, strength)
        func put(_ i: Int, _ color: SIMD3<Float>, _ alpha: Float) {
            let a = min(1, max(0, alpha))
            let o = i * 4
            out[o] = UInt8(min(255, color.x * a * 255))
            out[o + 1] = UInt8(min(255, color.y * a * 255))
            out[o + 2] = UInt8(min(255, color.z * a * 255))
            out[o + 3] = UInt8(a * 255)
        }
        // 1 outline, 2 edge of something gone; drawn after the dots, a pixel wider each way.
        var edges = [UInt8](repeating: 0, count: w * h)
        func state(_ i: Int) -> State {
            guard let states, owner[i] >= 0 else { return .unchecked }
            return states[Int(owner[i])]
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let index = Int(owner[i])
                guard index >= 0 else { continue }
                let z = near[i]
                let s = state(i)
                // Outlines: a neighbour much further back, or (for gone parts) not gone.
                var steps = false
                var goneEdge = false
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let n = ny * w + nx
                    if owner[n] >= 0, near[n] > z + 0.04 + 0.03 * z { steps = true }
                    if s == .gone, owner[n] < 0 || state(n) != .gone { goneEdge = true }
                }
                if goneEdge {
                    edges[i] = 2
                } else if steps {
                    edges[i] = 1
                }
                do {
                    let color = cloud.colors[index]
                    switch s {
                    case .unchecked: put(i, color, strength)
                    case .matched: put(i, color, strength * 0.45)
                    case .gone: put(i, color * 0.4 + goneColor * 0.6, 1)
                    }
                }
            }
        }
        // Thick enough to see at arm's length: each edge pixel also paints its four neighbours.
        for y in 0..<h {
            for x in 0..<w {
                let kind = edges[y * w + x]
                guard kind > 0 else { continue }
                for (dx, dy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let n = ny * w + nx
                    // A gone edge wins over an outline where they meet.
                    if kind == 2 || edges[n] != 2 {
                        put(n, kind == 2 ? goneColor : outlineColor, kind == 2 ? 1 : outlineAlpha)
                    }
                }
            }
        }
        return out
    }
}
