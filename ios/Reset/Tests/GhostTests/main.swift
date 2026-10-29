// Tests for the 3D ghost and depth reading, run on a Mac by CI:
//   swiftc -O Sources/DepthMap.swift Sources/GhostCore.swift Sources/ImageMatch.swift Tests/GhostTests/main.swift -o ghost-tests
//   ./ghost-tests out
// A synthetic room (a floor and a red box) is "captured" with depth maps like ARKit's, then the
// ghost is built, checked against live depth and drawn. Pictures of each step go to `out`.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS  " : "FAIL  ") + message)
    if !condition { failures += 1 }
}

// MARK: Scene

struct Box {
    var low: SIMD3<Float>
    var high: SIMD3<Float>
}

/// Floor at y = 0, a red box on it, and a back wall at z = -3.
struct Scene {
    var box = Box(low: SIMD3(-0.15, 0, -1.65), high: SIMD3(0.15, 0.3, -1.35))
    /// A table top for the noisy test: a big flat surface seen at a low angle.
    var table: Box?

    /// Distance along the ray to the first surface and its colour.
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (Float, SIMD3<Float>)? {
        var best: (Float, SIMD3<Float>)?
        func consider(_ t: Float, _ color: SIMD3<Float>) {
            if t > 0.01, best == nil || t < best!.0 { best = (t, color) }
        }
        if direction.y < -1e-5 {
            let t = -origin.y / direction.y
            let p = origin + direction * t
            let checker = (Int((p.x * 4).rounded(.down)) + Int((p.z * 4).rounded(.down))) & 1 == 0
            consider(t, checker ? SIMD3(0.55, 0.55, 0.55) : SIMD3(0.35, 0.35, 0.35))
        }
        if direction.z < -1e-5 {
            let t = (-3 - origin.z) / direction.z
            consider(t, SIMD3(0.3, 0.45, 0.3))
        }
        if let t = Scene.slab(box, origin: origin, direction: direction) { consider(t, SIMD3(0.9, 0.15, 0.1)) }
        if let table, let t = Scene.slab(table, origin: origin, direction: direction) { consider(t, SIMD3(0.5, 0.35, 0.2)) }
        return best
    }

    /// Where a ray first enters a box, if it does.
    static func slab(_ box: Box, origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        var tNear: Float = -.infinity
        var tFar: Float = .infinity
        for axis in 0..<3 {
            let o = origin[axis], d = direction[axis]
            if abs(d) < 1e-6 {
                if o < box.low[axis] || o > box.high[axis] { return nil }
            } else {
                var t1 = (box.low[axis] - o) / d
                var t2 = (box.high[axis] - o) / d
                if t1 > t2 { swap(&t1, &t2) }
                tNear = max(tNear, t1)
                tFar = min(tFar, t2)
            }
        }
        return tNear <= tFar && tFar > 0 ? tNear : nil
    }

    /// An ARKit-style depth map (metres along the view axis) and photo at the camera's size.
    func capture(_ camera: PinholeCamera) -> (depth: [Float], rgba: [UInt8]) {
        var depth = [Float](repeating: 0, count: camera.width * camera.height)
        var rgba = [UInt8](repeating: 0, count: camera.width * camera.height * 4)
        let origin = camera.cameraToWorld.columns.3
        let o3 = SIMD3(origin.x, origin.y, origin.z)
        for v in 0..<camera.height {
            for u in 0..<camera.width {
                let far = camera.unproject(u: Float(u), v: Float(v), depth: 1)
                let direction = simd_normalize(far - o3)
                guard let found = hit(origin: o3, direction: direction) else { continue }
                let (t, color) = found
                let p = o3 + direction * t
                // Depth along the view axis, as ARKit reports it.
                let forward = -SIMD3(camera.cameraToWorld.columns.2.x, camera.cameraToWorld.columns.2.y, camera.cameraToWorld.columns.2.z)
                let i = v * camera.width + u
                depth[i] = simd_dot(p - o3, forward)
                rgba[i * 4] = UInt8(color.x * 255)
                rgba[i * 4 + 1] = UInt8(color.y * 255)
                rgba[i * 4 + 2] = UInt8(color.z * 255)
                rgba[i * 4 + 3] = 255
            }
        }
        return (depth, rgba)
    }
}

/// A camera at `eye` looking at `target`, upright, with ARKit's axes.
func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
    let back = simd_normalize(eye - target)
    let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
    let up = simd_cross(back, right)
    return simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(eye, 1))
}

// iPhone-like camera: 1920 x 1440 image, depth at 256 x 192, as ARKit gives them. The sensor
// image is landscape; these tests hold the "phone" landscape so up is up.
let intrinsics = simd_float3x3(SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1))
func depthCamera(_ pose: simd_float4x4) -> PinholeCamera {
    PinholeCamera(cameraToWorld: pose, intrinsics: intrinsics, imageWidth: 1920, width: 256, height: 192)
}
func screenCamera(_ pose: simd_float4x4) -> PinholeCamera {
    PinholeCamera(cameraToWorld: pose, intrinsics: intrinsics, imageWidth: 1920, width: 640, height: 480)
}

// MARK: Output pictures

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Saves the ghost over the scene's photo, like it looks on the phone.
func save(_ name: String, ghost: [UInt8], background: [UInt8], width: Int, height: Int) {
    var pixels = background
    for i in 0..<(width * height) {
        let a = Float(ghost[i * 4 + 3]) / 255
        for c in 0..<3 {
            let under = Float(background[i * 4 + c]) * 0.6  // camera feed, a little darker
            pixels[i * 4 + c] = UInt8(min(255, Float(ghost[i * 4 + c]) + under * (1 - a)))
        }
        pixels[i * 4 + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = outDir.appendingPathComponent(name + ".png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("      wrote \(url.path)")
}

func pixel(_ rgba: [UInt8], _ camera: PinholeCamera, at point: SIMD3<Float>) -> (r: Int, g: Int, b: Int, a: Int) {
    let p = camera.project(point)!
    let i = (Int(p.v.rounded()) * camera.width + Int(p.u.rounded())) * 4
    return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
}

// MARK: Depth buffers

/// Float to IEEE half for normal values (the Float16 type is missing on Intel Macs).
func floatToHalf(_ value: Float) -> UInt16 {
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
    let mantissa = UInt16((bits >> 13) & 0x3FF)
    return sign | UInt16(exponent << 10) | mantissa
}

func testDepthBuffers() {
    print("Depth buffers")
    let width = 256, height = 192
    for (name, format) in [
        ("Float32", kCVPixelFormatType_DepthFloat32), ("Float16", kCVPixelFormatType_DepthFloat16),
        ("Disparity32", kCVPixelFormatType_DisparityFloat32),
    ] {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            expect(false, "\(name): could not make a buffer (\(status))")
            continue
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func value(_ x: Int, _ y: Int) -> Float { 0.5 + Float(x) / Float(width) + Float(y) / Float(height) }
        for y in 0..<height {
            let line = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                let metres = value(x, y)
                switch format {
                case kCVPixelFormatType_DepthFloat16:
                    line.assumingMemoryBound(to: UInt16.self)[x] = floatToHalf(metres)
                case kCVPixelFormatType_DisparityFloat32:
                    line.assumingMemoryBound(to: Float.self)[x] = 1 / metres
                default:
                    line.assumingMemoryBound(to: Float.self)[x] = metres
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let read = DepthMap.floats(DepthMap.copy(buffer))
        var worst: Float = 0
        for y in 0..<height {
            for x in 0..<width { worst = max(worst, abs(read[y * width + x] - value(x, y))) }
        }
        expect(read.count == width * height && worst < 0.003, "\(name) (\(DepthMap.describe(buffer))): read back within \(worst) m")
    }

    // Confidence: low readings dropped, medium and high kept.
    var depth: CVPixelBuffer?
    var confidence: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 1, kCVPixelFormatType_DepthFloat32, nil, &depth)
    CVPixelBufferCreate(nil, 4, 1, kCVPixelFormatType_OneComponent8, nil, &confidence)
    CVPixelBufferLockBaseAddress(depth!, [])
    CVPixelBufferLockBaseAddress(confidence!, [])
    let d = CVPixelBufferGetBaseAddress(depth!)!.assumingMemoryBound(to: Float.self)
    let c = CVPixelBufferGetBaseAddress(confidence!)!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<4 { d[i] = 1 + Float(i); c[i] = UInt8(min(i, 2)) }
    CVPixelBufferUnlockBaseAddress(depth!, [])
    CVPixelBufferUnlockBaseAddress(confidence!, [])
    let kept = DepthMap.floats(DepthMap.copy(depth!, keepingOnly: confidence!))
    expect(kept == [0, 2, 3, 4], "confidence: low dropped, medium and high kept (\(kept))")
    // Seen on device: every reading rated low while the depth was good. Then it is ignored.
    CVPixelBufferLockBaseAddress(confidence!, [])
    for i in 0..<4 { c[i] = 0 }
    CVPixelBufferUnlockBaseAddress(confidence!, [])
    let allLow = DepthMap.floats(DepthMap.copy(depth!, keepingOnly: confidence!))
    expect(allLow == [1, 2, 3, 4], "confidence all low: ignored, depth kept (\(allLow))")
    print("      " + DepthMap.stats(kept, confidence: DepthMap.bytes(confidence!)))
}

// MARK: Ghost

/// The ghost built the way the app builds it: surfaces from all depth views, edges per view.
struct Built {
    var surface = GhostCore.Cloud()
    var views: [GhostCore.EdgeView] = []
    var readings = 0

    /// The edges the app draws for a camera here: the nearest reference view's.
    func edges(for pose: simd_float4x4) -> GhostCore.Cloud {
        GhostCore.nearestView(views, to: pose, current: nil).map { views[$0].edges } ?? GhostCore.Cloud()
    }

    var allEdges: [SIMD3<Float>] { views.flatMap(\.edges.positions) }
}

func build(
    _ scene: Scene, poses: [simd_float4x4], random: UnsafeMutablePointer<Random>? = nil, drift: (metres: Float, degrees: Float) = (0.01, 0.4),
    usePhoto: Bool = true
) -> Built {
    var built = Built()
    var filled = [SIMD3<Int32>: Int32]()
    for pose in poses {
        let truth = depthCamera(pose)
        let shot = scene.capture(truth)
        var depth = shot.depth
        var camera = truth
        if let random {
            depth = lidar(depth, width: truth.width, height: truth.height, random: &random.pointee)
            camera = depthCamera(drifted(pose, random: &random.pointee, metres: drift.metres, degrees: drift.degrees))
        }
        built.readings += GhostCore.add(depth: depth, rgba: shot.rgba, camera: camera, maxPoints: 300_000, to: &built.surface, filled: &filled)
        // The photo the app reads for sharp outlines, a little grainy like a real one.
        var photo: [UInt8]?
        if usePhoto {
            var rgba = scene.capture(truth.scaled(by: Float(GhostCore.photoScale))).rgba
            if random != nil {
                // Its own random numbers, so the LiDAR noise and drift stay as before.
                var grain = Random(state: 1000 + UInt64(built.views.count))
                for i in rgba.indices where i % 4 != 3 {
                    rgba[i] = UInt8(max(0, min(255, Float(rgba[i]) + grain.normal() * 3)))
                }
            }
            photo = rgba
        }
        built.views.append(GhostCore.edgeView(GhostCore.edgePoints(depth: depth, camera: camera, photo: photo), camera: camera))
    }
    return built
}

func isYellow(_ rgba: [UInt8], _ i: Int) -> Bool { rgba[i * 4] > 150 && rgba[i * 4 + 1] > 100 && rgba[i * 4 + 2] < 60 }
func isBlue(_ rgba: [UInt8], _ i: Int) -> Bool { rgba[i * 4 + 2] > 150 && rgba[i * 4] < 100 }

/// The real edges of the scene in 3D: the boxes' twelve edges and where the floor meets the wall.
func edgeSegments(_ scene: Scene) -> [(SIMD3<Float>, SIMD3<Float>)] {
    var segments: [(SIMD3<Float>, SIMD3<Float>)] = [(SIMD3(-20, 0, -3), SIMD3(20, 0, -3))]
    for box in [scene.box] + (scene.table.map { [$0] } ?? []) {
        let l = box.low, h = box.high
        let corners = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? l.x : h.x, i & 2 == 0 ? l.y : h.y, i & 4 == 0 ? l.z : h.z) }
        for i in 0..<8 {
            for bit in [1, 2, 4] where i & bit == 0 { segments.append((corners[i], corners[i | bit])) }
        }
    }
    return segments
}

func distance(_ p: SIMD3<Float>, _ segment: (SIMD3<Float>, SIMD3<Float>)) -> Float {
    let (a, b) = segment
    let t = max(0, min(1, simd_dot(p - a, b - a) / max(simd_length_squared(b - a), 1e-9)))
    return simd_length(p - (a + (b - a) * t))
}

/// Line pixels in all, and those nowhere near a real edge of the scene (clutter).
func strayLines(_ ghost: [UInt8], scene: Scene, camera: PinholeCamera) -> (lines: Int, stray: Int) {
    let depth = scene.capture(camera).depth
    let segments = edgeSegments(scene)
    let w = camera.width, h = camera.height
    var lines = 0, stray = 0
    for i in 0..<(w * h) where isYellow(ghost, i) {
        lines += 1
        let x = i % w, y = i / w
        var near = false
        search: for dy in stride(from: -10, through: 10, by: 2) where y + dy >= 0 && y + dy < h {
            for dx in stride(from: -10, through: 10, by: 2) where x + dx >= 0 && x + dx < w {
                let d = depth[(y + dy) * w + x + dx]
                guard d > 0 else { continue }
                let p = camera.unproject(u: Float(x + dx), v: Float(y + dy), depth: d)
                if segments.contains(where: { distance(p, $0) < 0.06 }) { near = true; break search }
            }
        }
        if !near { stray += 1 }
    }
    return (lines, stray)
}

func testGhost() {
    print("3D ghost")
    let scene = Scene()
    let boxCentre = SIMD3<Float>(0, 0.15, -1.5)
    // The reference: a few views from in front, like a short walk round.
    let eyes: [SIMD3<Float>] = [SIMD3(0, 1, 0), SIMD3(-0.4, 1, -0.1), SIMD3(0.4, 1, -0.1), SIMD3(0, 0.6, -0.5)]
    let built = build(scene, poses: eyes.map { lookAt(eye: $0, target: boxCentre) })
    let cloud = built.surface
    expect(cloud.positions.count > 5_000, "built \(cloud.positions.count) points from \(built.readings) readings")
    expect(built.allEdges.count > 200, "found \(built.allEdges.count) edge points")

    // Every point lies on a surface of the scene, and every edge point on a real edge.
    var worst: Float = 0
    for p in cloud.positions {
        let onFloor = abs(p.y)
        let onWall = abs(p.z + 3)
        let b = scene.box
        let outside = simd_length(simd_max(simd_max(b.low - p, p - b.high), SIMD3(repeating: 0)))
        let inside = p.x > b.low.x && p.x < b.high.x && p.y > b.low.y && p.y < b.high.y && p.z > b.low.z && p.z < b.high.z
        let onBox = inside ? 0 : outside
        worst = max(worst, min(onFloor, onWall, onBox))
    }
    expect(worst < 0.01, "points sit on the scene's surfaces (worst \(worst) m)")
    let segments = edgeSegments(scene)
    let offEdge = built.allEdges.filter { p in !segments.contains { distance(p, $0) < 0.08 } }.count
    expect(offEdge < built.allEdges.count / 10, "edge points off the real edges: \(offEdge) of \(built.allEdges.count)")

    // Drawn from the first reference view: lines round the box, no clutter.
    let frontPose = lookAt(eye: SIMD3(0, 1, 0), target: boxCentre)
    let front = screenCamera(frontPose)
    let frontGhost = GhostCore.render(surface: cloud, edges: built.edges(for: frontPose), states: nil, camera: front, strength: 0.8)
    let (frontLines, frontStray) = strayLines(frontGhost, scene: scene, camera: front)
    expect(frontLines > 300, "front view: \(frontLines) line pixels")
    expect(frontStray < 40, "front view: \(frontStray) line pixels away from real edges")
    let boxAt = front.project(boxCentre)!
    let roundBox = (0..<(front.width * front.height)).filter { i in
        hypot(Float(i % front.width) - boxAt.u, Float(i / front.width) - boxAt.v) < 120 && isYellow(frontGhost, i)
    }.count
    expect(roundBox > 200, "front view: \(roundBox) line pixels round the box")
    let covered = stride(from: 3, to: frontGhost.count, by: 4).filter { frontGhost[$0] > 0 }.count
    expect(covered < front.width * front.height / 12, "front view: lines only, \(covered) pixels drawn")
    save("1-front-unchecked", ghost: frontGhost, background: scene.capture(front).rgba, width: front.width, height: front.height)

    // From the side, somewhere the reference never stood: the lines still sit round the box.
    let sidePose = lookAt(eye: SIMD3(1.2, 0.9, -0.7), target: boxCentre)
    let side = screenCamera(sidePose)
    let sideEdges = built.edges(for: sidePose)
    let sideGhost = GhostCore.render(surface: cloud, edges: sideEdges, states: nil, camera: side, strength: 0.8)
    let sideBox = side.project(boxCentre)!
    let nearBox = (0..<(side.width * side.height)).filter { i in
        hypot(Float(i % side.width) - sideBox.u, Float(i / side.width) - sideBox.v) < 140 && isYellow(sideGhost, i)
    }.count
    expect(nearBox > 150, "side view: \(nearBox) line pixels round the box")
    let (_, sideStray) = strayLines(sideGhost, scene: scene, camera: side)
    expect(sideStray < 40, "side view: \(sideStray) line pixels away from real edges")
    save("2-side-unchecked", ghost: sideGhost, background: scene.capture(side).rgba, width: side.width, height: side.height)

    let cells = GhostCore.cells(of: cloud.positions)
    func boxPoints(_ states: [GhostCore.State], _ state: GhostCore.State) -> (Int, Int) {
        var total = 0, matching = 0
        for (i, p) in cloud.positions.enumerated() where p.y > 0.02 && p.z > -1.7 && p.z < -1.3 && abs(p.x) < 0.2 {
            total += 1
            if states[i] == state { matching += 1 }
        }
        return (matching, total)
    }

    // Nothing moved: after a few live checks from the side, nothing is gone.
    var scores = [Int8](repeating: 0, count: cloud.positions.count)
    let sideDepth = depthCamera(sidePose)
    let same = scene.capture(sideDepth)
    for _ in 0..<4 {
        GhostCore.check(positions: cloud.positions, scores: &scores, depth: same.depth, confidence: nil, camera: sideDepth, window: 2)
    }
    var states = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
    let goneWhenSame = states.filter { $0 == .gone }.count
    let matched = states.filter { $0 == .matched }.count
    expect(goneWhenSame == 0, "unchanged set: \(goneWhenSame) points gone")
    expect(matched > cloud.positions.count / 4, "unchanged set: \(matched) of \(cloud.positions.count) points matched")
    var edgeStates = GhostCore.edgeStates(edges: sideEdges.positions, surfaceStates: states, surfaceCells: cells)
    let sameGhost = GhostCore.render(surface: cloud, edges: sideEdges, states: edgeStates, camera: side, strength: 0.8)
    let blueSame = (0..<(side.width * side.height)).filter { isBlue(sameGhost, $0) }.count
    expect(blueSame == 0, "unchanged set: \(blueSame) blue pixels")
    save("3-side-nothing-moved", ghost: sameGhost, background: scene.capture(side).rgba, width: side.width, height: side.height)

    // The box moved 40 cm to the left, away from the side camera: its old place shows gone.
    var moved = Scene()
    moved.box.low.x -= 0.4
    moved.box.high.x -= 0.4
    scores = [Int8](repeating: 0, count: cloud.positions.count)
    let movedDepth = moved.capture(sideDepth)
    for _ in 0..<4 {
        GhostCore.check(positions: cloud.positions, scores: &scores, depth: movedDepth.depth, confidence: nil, camera: sideDepth, window: 2)
    }
    states = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
    let (goneOnBox, boxTotal) = boxPoints(states, .gone)
    let goneTotal = states.filter { $0 == .gone }.count
    expect(goneOnBox > boxTotal / 4, "box moved: \(goneOnBox) of \(boxTotal) old box points gone")
    expect(goneTotal - goneOnBox < goneOnBox / 5, "box moved: only \(goneTotal - goneOnBox) gone points away from the box")
    edgeStates = GhostCore.edgeStates(edges: sideEdges.positions, surfaceStates: states, surfaceCells: cells)
    let movedGhost = GhostCore.render(surface: cloud, edges: sideEdges, states: edgeStates, camera: side, strength: 0.8)
    let blue = (0..<(side.width * side.height)).filter { isBlue(movedGhost, $0) }.count
    expect(blue > 100, "box moved: \(blue) blue line pixels where it was")
    save("4-side-box-moved", ghost: movedGhost, background: moved.capture(side).rgba, width: side.width, height: side.height)

    // Speed: a full-size cloud draws fast enough to follow the phone.
    var big = GhostCore.Cloud()
    for i in 0..<300_000 {
        big.positions.append(SIMD3(Float(i % 600) * 0.003 - 0.9, Float((i / 600) % 500) * 0.002, -1.5 - Float(i % 7) * 0.01))
        big.colors.append(SIMD3(0.5, 0.5, 0.5))
    }
    var bigEdges = GhostCore.Cloud()
    bigEdges.positions = Array(big.positions.prefix(60_000))
    bigEdges.colors = Array(big.colors.prefix(60_000))
    let start = Date()
    _ = GhostCore.render(surface: big, edges: bigEdges, states: nil, camera: front, strength: 0.8)
    let seconds = Date().timeIntervalSince(start)
    expect(seconds < 0.5, String(format: "300,000 points and 60,000 edge points drawn in %.3f s on the test Mac", seconds))
    let depth = scene.capture(depthCamera(frontPose)).depth
    let photo = scene.capture(depthCamera(frontPose).scaled(by: Float(GhostCore.photoScale))).rgba
    let photoStart = Date()
    for _ in 0..<10 { _ = GhostCore.edgePoints(depth: depth, camera: depthCamera(frontPose), photo: photo) }
    expect(Date().timeIntervalSince(photoStart) < 3, String(format: "edges of 10 depth views with photos found in %.2f s", Date().timeIntervalSince(photoStart)))
}

// MARK: Real-world depth

/// Repeatable random numbers.
struct Random {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
    /// Roughly normal, mean 0, spread 1.
    mutating func normal() -> Float {
        let a = max(next(), 1e-6), b = next()
        return sqrt(-2 * log(a)) * cos(2 * .pi * b)
    }
}

/// Depth the way the LiDAR really gives it: noise growing with distance, missing readings, and
/// smeared readings halfway across the edges of things.
func lidar(_ depth: [Float], width: Int, height: Int, random: inout Random) -> [Float] {
    var out = depth
    for y in 0..<height {
        for x in 0..<width {
            let i = y * width + x
            let d = depth[i]
            guard d > 0 else { continue }
            if random.next() < 0.04 { out[i] = 0; continue }
            if x + 1 < width, depth[i + 1] > 0, abs(depth[i + 1] - d) > 0.1, random.next() < 0.5 {
                out[i] = (d + depth[i + 1]) / 2
                continue
            }
            out[i] = d + random.normal() * (0.006 + 0.006 * d)
        }
    }
    return out
}

/// A pose knocked slightly off, the way ARKit's tracking drifts between keyframes.
func drifted(_ pose: simd_float4x4, random: inout Random, metres: Float = 0.01, degrees: Float = 0.4) -> simd_float4x4 {
    let axis = simd_normalize(SIMD3(random.normal(), random.normal(), random.normal()) + SIMD3(repeating: 0.001))
    let turn = simd_float4x4(simd_quatf(angle: random.normal() * degrees * .pi / 180, axis: axis))
    var out = pose * turn
    out.columns.3 += SIMD4(random.normal() * metres, random.normal() * metres, random.normal() * metres, 0)
    return out
}

func testNoisyGhost() {
    print("3D ghost with real-world depth (noise, gaps, drift)")
    var scene = Scene()
    scene.table = Box(low: SIMD3(-1.1, 0.7, -2.4), high: SIMD3(-0.4, 0.74, -1.7))
    let centre = SIMD3<Float>(-0.2, 0.3, -1.7)
    var random = Random(state: 7)
    // A walk round like Phil's: about 20 views, each with its own small drift.
    let poses = (0..<20).map { k -> simd_float4x4 in
        let angle = Float(k) / 19 * 1.2 - 0.6
        let eye = SIMD3<Float>(sin(angle) * 1.4 - 0.2, 0.9 + Float(k % 3) * 0.15, cos(angle) * 1.4 - 1.7)
        return lookAt(eye: eye, target: centre)
    }
    let built = withUnsafeMutablePointer(to: &random) { build(scene, poses: poses, random: $0) }
    let cloud = built.surface
    expect(cloud.positions.count > 20_000, "noisy: built \(cloud.positions.count) points, \(built.allEdges.count) edge points")
    let segments = edgeSegments(scene)
    let offEdge = built.allEdges.filter { p in !segments.contains { distance(p, $0) < 0.08 } }.count
    expect(offEdge < built.allEdges.count / 8, "noisy: edge points off the real edges: \(offEdge) of \(built.allEdges.count)")
    // The photo's sharp edges put the lines closer to the real edges than LiDAR alone.
    var sameRandom = Random(state: 7)
    let depthOnly = withUnsafeMutablePointer(to: &sameRandom) { build(scene, poses: poses, random: $0, usePhoto: false) }
    func meanDistance(_ points: [SIMD3<Float>]) -> Float {
        let near = points.map { p in segments.map { distance(p, $0) }.min() ?? 1 }.filter { $0 < 0.08 }
        return near.reduce(0, +) / Float(max(near.count, 1))
    }
    let withPhoto = meanDistance(built.allEdges)
    let withoutPhoto = meanDistance(depthOnly.allEdges)
    expect(withPhoto < withoutPhoto, String(format: "noisy: lines sit %.1f mm from the real edges with the photo, %.1f mm with LiDAR alone", withPhoto * 1000, withoutPhoto * 1000))
    let cells = GhostCore.cells(of: cloud.positions)

    for (name, eye) in [("front", SIMD3<Float>(-0.2, 1.1, -0.3)), ("close", SIMD3<Float>(0.3, 0.8, -0.9))] {
        let pose = lookAt(eye: eye, target: centre)
        let camera = screenCamera(pose)
        let edges = built.edges(for: pose)
        let ghost = GhostCore.render(surface: cloud, edges: edges, states: nil, camera: camera, strength: 0.8)
        let total = camera.width * camera.height
        let (lines, stray) = strayLines(ghost, scene: scene, camera: camera)
        expect(lines > 400, "noisy \(name): \(lines) line pixels on the props' edges")
        expect(stray < lines / 20, "noisy \(name): \(stray) line pixels away from real edges (clutter)")
        let photo = scene.capture(camera).rgba
        save("5-noisy-\(name)", ghost: ghost, background: photo, width: camera.width, height: camera.height)

        // Nothing moved, but live depth is noisy and tracking has drifted: no blue at all.
        var scores = [Int8](repeating: 0, count: cloud.positions.count)
        let liveTruth = depthCamera(pose)
        for _ in 0..<10 {
            let live = lidar(scene.capture(liveTruth).depth, width: liveTruth.width, height: liveTruth.height, random: &random)
            GhostCore.check(
                positions: cloud.positions, scores: &scores, depth: live, confidence: nil,
                camera: depthCamera(drifted(pose, random: &random, metres: 0.02)), window: 2)
        }
        var states = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
        var edgeStates = GhostCore.edgeStates(edges: edges.positions, surfaceStates: states, surfaceCells: cells)
        let checked = GhostCore.render(surface: cloud, edges: edges, states: edgeStates, camera: camera, strength: 0.8)
        let falseBlue = (0..<total).filter { isBlue(checked, $0) }.count
        expect(falseBlue == 0, "noisy \(name), nothing moved: \(falseBlue) blue pixels")
        if name == "front" {
            save("6-noisy-front-nothing-moved", ghost: checked, background: photo, width: camera.width, height: camera.height)
            // The box taken away: a blue outline where it stood.
            var gone = scene
            gone.box = Box(low: SIMD3(5, 0, 5), high: SIMD3(5.1, 0.1, 5.1))
            scores = [Int8](repeating: 0, count: cloud.positions.count)
            for _ in 0..<10 {
                let live = lidar(gone.capture(liveTruth).depth, width: liveTruth.width, height: liveTruth.height, random: &random)
                GhostCore.check(
                    positions: cloud.positions, scores: &scores, depth: live, confidence: nil,
                    camera: depthCamera(drifted(pose, random: &random)), window: 2)
            }
            states = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
            edgeStates = GhostCore.edgeStates(edges: edges.positions, surfaceStates: states, surfaceCells: cells)
            let goneGhost = GhostCore.render(surface: cloud, edges: edges, states: edgeStates, camera: camera, strength: 0.8)
            let shown = (0..<total).filter { isBlue(goneGhost, $0) }.count
            expect(shown > 100, "noisy front, box taken away: \(shown) blue line pixels where it stood")
            save("7-noisy-box-gone", ghost: goneGhost, background: gone.capture(camera).rgba, width: camera.width, height: camera.height)
        }
    }
}

func testHardCases() {
    print("3D ghost, hard cases")
    var scene = Scene()
    scene.table = Box(low: SIMD3(-1.1, 0.7, -2.4), high: SIMD3(-0.4, 0.74, -1.7))
    let centre = SIMD3<Float>(-0.2, 0.3, -1.7)
    var random = Random(state: 11)
    let poses = (0..<20).map { k -> simd_float4x4 in
        let angle = Float(k) / 19 * 1.2 - 0.6
        return lookAt(eye: SIMD3(sin(angle) * 1.4 - 0.2, 0.9 + Float(k % 3) * 0.15, cos(angle) * 1.4 - 1.7), target: centre)
    }
    let view = lookAt(eye: SIMD3(-0.2, 1.1, -0.3), target: centre)
    let camera = screenCamera(view)

    // Tracking drifting 3 cm and a degree between views, worse than the noisy test: the edges
    // must still agree and draw.
    let drifty = withUnsafeMutablePointer(to: &random) { build(scene, poses: poses, random: $0, drift: (0.03, 1.0)) }
    let ghost = GhostCore.render(surface: drifty.surface, edges: drifty.edges(for: view), states: nil, camera: camera, strength: 0.8)
    let (lines, stray) = strayLines(ghost, scene: scene, camera: camera)
    expect(lines > 400, "3 cm drift: \(lines) line pixels drawn (\(drifty.edges(for: view).positions.count) edge points)")
    expect(stray < lines / 10, "3 cm drift: \(stray) line pixels away from real edges")
    save("8-drift-3cm", ghost: ghost, background: scene.capture(camera).rgba, width: camera.width, height: camera.height)

    // A one-shot reference (the shutter): a single depth view still draws the props' edges.
    let single = withUnsafeMutablePointer(to: &random) { build(scene, poses: [view], random: $0) }
    let one = GhostCore.render(surface: single.surface, edges: single.edges(for: view), states: nil, camera: camera, strength: 0.8)
    let (oneLines, oneStray) = strayLines(one, scene: scene, camera: camera)
    expect(oneLines > 300, "one view: \(oneLines) line pixels drawn (\(single.edges(for: view).positions.count) edge points)")
    expect(oneStray < oneLines / 10, "one view: \(oneStray) line pixels away from real edges")
    save("9-one-view", ghost: one, background: scene.capture(camera).rgba, width: camera.width, height: camera.height)

    // Small props on a table: a 6 cm tall box must still be outlined.
    var small = Scene()
    small.box = Box(low: SIMD3(-0.1, 0, -1.3), high: SIMD3(0.1, 0.06, -1.15))
    let smallView = lookAt(eye: SIMD3(0, 0.8, -0.5), target: SIMD3(0, 0.03, -1.22))
    let smallBuilt = withUnsafeMutablePointer(to: &random) { build(small, poses: [smallView], random: $0) }
    let smallCamera = screenCamera(smallView)
    let smallGhost = GhostCore.render(surface: smallBuilt.surface, edges: smallBuilt.edges(for: smallView), states: nil, camera: smallCamera, strength: 0.8)
    let at = smallCamera.project(SIMD3(0, 0.03, -1.22))!
    let round = (0..<(smallCamera.width * smallCamera.height)).filter { i in
        hypot(Float(i % smallCamera.width) - at.u, Float(i / smallCamera.width) - at.v) < 120 && isYellow(smallGhost, i)
    }.count
    expect(round > 150, "6 cm box: \(round) line pixels round it")
    save("10-small-box", ghost: smallGhost, background: small.capture(smallCamera).rgba, width: smallCamera.width, height: smallCamera.height)
}

// MARK: Picture match

func ciImage(_ rgba: [UInt8], width: Int, height: Int) -> CIImage {
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return CIImage(cgImage: image)
}

func testImageMatch() {
    print("Picture match")
    // A busier room than the ghost test, so there is texture to pair up, like a real set.
    let scene = Scene()
    let target = SIMD3<Float>(0, 0.15, -1.5)
    func photo(_ eye: SIMD3<Float>) -> CIImage {
        let camera = screenCamera(lookAt(eye: eye, target: target))
        return ciImage(scene.capture(camera).rgba, width: camera.width, height: camera.height)
    }
    let reference = photo(SIMD3(0, 1, 0))
    let cases: [(String, SIMD3<Float>, Bool)] = [
        ("same place", SIMD3(0, 1, 0), true),
        ("1 cm to the side", SIMD3(0.01, 1, 0), true),
        ("15 cm to the side", SIMD3(0.15, 1, 0), false),
        ("20 cm back", SIMD3(0, 1.08, 0.18), false),
    ]
    for (name, eye, expected) in cases {
        guard let result = ImageMatch.compare(live: photo(eye), reference: reference) else {
            expect(false, "\(name): pictures could not be paired")
            continue
        }
        expect(result.aligned == expected, String(format: "%@: corner error %.3f of the width, %@", name, result.error, result.aligned ? "lined up" : "not lined up"))
    }
    // Where the reference's middle shows live, for the guide balls: turn the phone a little
    // right and down, with no step, so the answer is exact wherever things are in the room.
    let referenceCamera = screenCamera(lookAt(eye: SIMD3(0, 1, 0), target: target))
    let ahead = referenceCamera.cameraToWorld * SIMD4<Float>(0, 0, -50, 1)
    for (name, aim) in [("turned right and down", SIMD3<Float>(0.05, 0.12, -1.5)), ("turned left and up", SIMD3<Float>(-0.04, 0.2, -1.5))] {
        let liveCamera = screenCamera(lookAt(eye: SIMD3(0, 1, 0), target: aim))
        guard let expected = liveCamera.project(SIMD3(ahead.x, ahead.y, ahead.z)),
            let result = ImageMatch.compare(
                live: ciImage(scene.capture(liveCamera).rgba, width: liveCamera.width, height: liveCamera.height),
                reference: reference),
            let centre = result.centre
        else {
            expect(false, "\(name): no middle found")
            continue
        }
        let x = CGFloat(expected.u) / CGFloat(liveCamera.width)
        let y = CGFloat(expected.v) / CGFloat(liveCamera.height)
        expect(
            abs(centre.x - x) < 0.01 && abs(centre.y - y) < 0.01,
            String(format: "%@: reference middle shows at %.3f, %.3f (should be %.3f, %.3f)", name, centre.x, centre.y, x, y))
    }
    // The photo is stored smaller than the live picture: sizes must not matter.
    let small = reference.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
    if let result = ImageMatch.compare(live: photo(SIMD3(0, 1, 0)), reference: small) {
        expect(result.aligned, String(format: "different sizes: corner error %.3f", result.error))
    } else {
        expect(false, "different sizes: pictures could not be paired")
    }
}

func testDots() {
    print("Dots (3D ghost and the scan)")
    let scene = Scene()
    let centre = SIMD3<Float>(0, 0.15, -1.5)
    let poses = (0..<8).map { k -> simd_float4x4 in
        let angle = Float(k) / 7 * 1.0 - 0.5
        return lookAt(eye: SIMD3(sin(angle) * 1.4, 1, cos(angle) * 1.4 - 1.5), target: centre)
    }
    let built = build(scene, poses: poses, usePhoto: false)
    let camera = screenCamera(lookAt(eye: SIMD3(0.1, 1.05, 0), target: centre))
    let total = camera.width * camera.height
    func shown(_ rgba: [UInt8]) -> Int { (0..<total).filter { rgba[$0 * 4 + 3] > 0 }.count }
    let dots = GhostCore.renderDots(surface: built.surface, states: nil, camera: camera, strength: 0.8)
    let covered = shown(dots)
    expect(covered > total / 3, "3D ghost dots cover \(covered) of \(total) pixels")
    expect(covered < total, "3D ghost dots leave the set showing between them")
    save("11-dots", ghost: dots, background: scene.capture(camera).rgba, width: camera.width, height: camera.height)
    // Gone points draw blue.
    var states = [GhostCore.State](repeating: .matched, count: built.surface.positions.count)
    for (i, p) in built.surface.positions.enumerated() where p.y > 0.02 && abs(p.x) < 0.2 && p.z > -1.7 && p.z < -1.3 { states[i] = .gone }
    let gone = GhostCore.renderDots(surface: built.surface, states: states, camera: camera, strength: 0.8)
    let blue = (0..<total).filter { isBlue(gone, $0) }.count
    expect(blue > 300, "box gone: \(blue) blue dot pixels")
    // The scan's small dots: many separate dots, not a solid sheet.
    let scan = GhostCore.renderDots(surface: built.surface, states: nil, camera: camera.scaled(by: 1.5), strength: 0.9, size: 0.0015)
    let scanShown = shown(scan)
    let scanTotal = camera.scaled(by: 1.5).width * camera.scaled(by: 1.5).height
    expect(scanShown > scanTotal / 50 && scanShown < scanTotal / 2, "scan dots: \(scanShown) of \(scanTotal) pixels, spaced out")
    let big = camera.scaled(by: 1.5)
    save("12-scan-dots", ghost: scan, background: scene.capture(big).rgba, width: big.width, height: big.height)
}

testDepthBuffers()
testGhost()
testNoisyGhost()
testHardCases()
testImageMatch()
testDots()
print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
