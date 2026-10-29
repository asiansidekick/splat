// Tests for the 3D ghost and depth reading, run on a Mac by CI:
//   swiftc -O Sources/DepthMap.swift Sources/GhostCore.swift Tests/GhostTests/main.swift -o ghost-tests
//   ./ghost-tests out
// A synthetic room (a floor and a red box) is "captured" with depth maps like ARKit's, then the
// ghost is built, checked against live depth and drawn. Pictures of each step go to `out`.

import CoreGraphics
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
        // Slab test for the box.
        var tNear: Float = -.infinity
        var tFar: Float = .infinity
        var inside = true
        for axis in 0..<3 {
            let o = origin[axis], d = direction[axis]
            if abs(d) < 1e-6 {
                if o < box.low[axis] || o > box.high[axis] { inside = false }
            } else {
                var t1 = (box.low[axis] - o) / d
                var t2 = (box.high[axis] - o) / d
                if t1 > t2 { swap(&t1, &t2) }
                tNear = max(tNear, t1)
                tFar = min(tFar, t2)
            }
        }
        if inside, tNear <= tFar, tFar > 0 { consider(tNear, SIMD3(0.9, 0.15, 0.1)) }
        return best
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
    print("      " + DepthMap.stats(kept, confidence: DepthMap.bytes(confidence!)))
}

// MARK: Ghost

func testGhost() {
    print("3D ghost")
    let scene = Scene()
    let boxCentre = SIMD3<Float>(0, 0.15, -1.5)
    // The reference: a few views from in front, like a short walk round.
    var cloud = GhostCore.Cloud()
    var filled = Set<SIMD3<Int32>>()
    let eyes: [SIMD3<Float>] = [SIMD3(0, 1, 0), SIMD3(-0.4, 1, -0.1), SIMD3(0.4, 1, -0.1), SIMD3(0, 0.6, -0.5)]
    var readings = 0
    for eye in eyes {
        let camera = depthCamera(lookAt(eye: eye, target: boxCentre))
        let shot = scene.capture(camera)
        readings += GhostCore.add(depth: shot.depth, rgba: shot.rgba, camera: camera, maxPoints: 300_000, to: &cloud, filled: &filled)
    }
    expect(cloud.positions.count > 5_000, "built \(cloud.positions.count) points from \(readings) readings")

    // Every point lies on a surface of the scene.
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

    // Drawn from the first reference view: the box is red where it was photographed.
    let frontPose = lookAt(eye: SIMD3(0, 1, 0), target: boxCentre)
    let front = screenCamera(frontPose)
    let frontGhost = GhostCore.render(cloud: cloud, states: nil, camera: front, strength: 0.8)
    let frontPhoto = scene.capture(front).rgba
    let middle = pixel(frontGhost, front, at: SIMD3(0, 0.3, -1.5))
    expect(middle.r > middle.g * 2 && middle.a > 150, "front view: box top drawn red at the box (\(middle))")
    let covered = stride(from: 3, to: frontGhost.count, by: 4).filter { frontGhost[$0] > 0 }.count
    expect(covered > front.width * front.height / 2, "front view: ghost covers \(covered) of \(front.width * front.height) pixels")
    let outline = (0..<(front.width * front.height)).filter { frontGhost[$0 * 4] > 200 && frontGhost[$0 * 4 + 1] > 150 && frontGhost[$0 * 4 + 2] < 60 }.count
    expect(outline > 100, "front view: yellow outline round the box (\(outline) pixels)")
    save("1-front-unchecked", ghost: frontGhost, background: frontPhoto, width: front.width, height: front.height)

    // From the side, somewhere the reference never stood: the box still lands on the box.
    let sidePose = lookAt(eye: SIMD3(1.2, 0.9, -0.7), target: boxCentre)
    let side = screenCamera(sidePose)
    let sideGhost = GhostCore.render(cloud: cloud, states: nil, camera: side, strength: 0.8)
    let sideBox = pixel(sideGhost, side, at: SIMD3(0, 0.3, -1.5))
    expect(sideBox.r > sideBox.g * 2, "side view: box top drawn red at the box (\(sideBox))")
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
        GhostCore.check(positions: cloud.positions, scores: &scores, depth: same.depth, confidence: nil, camera: sideDepth)
    }
    var states = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
    let goneWhenSame = states.filter { $0 == .gone }.count
    let matched = states.filter { $0 == .matched }.count
    expect(goneWhenSame == 0, "unchanged set: \(goneWhenSame) points gone")
    expect(matched > cloud.positions.count / 4, "unchanged set: \(matched) of \(cloud.positions.count) points matched")
    let sameGhost = GhostCore.render(cloud: cloud, states: states, camera: side, strength: 0.8)
    save("3-side-nothing-moved", ghost: sameGhost, background: scene.capture(side).rgba, width: side.width, height: side.height)

    // The box moved 40 cm to the left, away from the side camera: its old place shows gone.
    var moved = Scene()
    moved.box.low.x -= 0.4
    moved.box.high.x -= 0.4
    scores = [Int8](repeating: 0, count: cloud.positions.count)
    let movedDepth = moved.capture(sideDepth)
    for _ in 0..<4 {
        GhostCore.check(positions: cloud.positions, scores: &scores, depth: movedDepth.depth, confidence: nil, camera: sideDepth)
    }
    states = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
    let (goneOnBox, boxTotal) = boxPoints(states, .gone)
    let goneTotal = states.filter { $0 == .gone }.count
    expect(goneOnBox > boxTotal / 3, "box moved: \(goneOnBox) of \(boxTotal) old box points gone")
    expect(goneTotal - goneOnBox < goneOnBox / 5, "box moved: only \(goneTotal - goneOnBox) gone points away from the box")
    let movedGhost = GhostCore.render(cloud: cloud, states: states, camera: side, strength: 0.8)
    let blue = (0..<(side.width * side.height)).filter { movedGhost[$0 * 4 + 2] > 150 && movedGhost[$0 * 4] < 150 }.count
    expect(blue > 200, "box moved: \(blue) blue pixels where it was")
    save("4-side-box-moved", ghost: movedGhost, background: moved.capture(side).rgba, width: side.width, height: side.height)

    // Speed: a full-size cloud draws fast enough to follow the phone.
    var big = GhostCore.Cloud()
    for i in 0..<300_000 {
        big.positions.append(SIMD3(Float(i % 600) * 0.003 - 0.9, Float((i / 600) % 500) * 0.002, -1.5 - Float(i % 7) * 0.01))
        big.colors.append(SIMD3(0.5, 0.5, 0.5))
    }
    let start = Date()
    _ = GhostCore.render(cloud: big, states: nil, camera: front, strength: 0.8)
    let seconds = Date().timeIntervalSince(start)
    expect(seconds < 0.5, String(format: "300,000 points drawn in %.3f s on the test Mac", seconds))
}

testDepthBuffers()
testGhost()
print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
