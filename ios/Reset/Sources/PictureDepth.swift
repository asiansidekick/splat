import ARKit
import CoreML
import Vision
import simd

/// Depth guessed from the camera picture by a small neural network (Apple's Core ML Depth Anything V2 Small,
/// Apache-2.0), for phones whose LiDAR gives nothing usable (Phil's iPhone 14 Pro, 2026-11-08). The network says
/// only which parts of the picture are nearer than which; the points ARKit tracks in the picture, whose distances
/// it knows, turn that into metres (one scale and shift, fitted so that outliers cannot pull it). The method is
/// Wofk et al. 2023, "Monocular visual-inertial depth estimation".
@MainActor
final class PictureDepth {
    static let shared = PictureDepth()

    private let model: VNCoreMLModel?
    /// The newest result: the network's map and the fit to metres, for the frame it was made from.
    private(set) var latest: Result?
    private var running = false
    private var lastRun: TimeInterval = 0
    private var lastLog = Date.distantPast

    struct Result {
        let values: [Float]
        let width: Int
        let height: Int
        /// 1 / metres = scale * value + shift; or, when the network gives depth rather than nearness (`direct`),
        /// metres = scale * value + shift.
        let direct: Bool
        let scale: Float
        let shift: Float
        let points: Int
        let error: Float
        let time: TimeInterval
        let worldToCamera: simd_float4x4
        let intrinsics: simd_float3x3
        let resolution: SIMD2<Float>

        /// Metres straight ahead at a place in the picture (0 to 1, sensor layout), from the 3 x 3 readings round it.
        func metres(at n: CGPoint) -> Float? {
            let x = Int(Float(n.x) * Float(width)), y = Int(Float(n.y) * Float(height))
            var readings: [Float] = []
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < width, yy < height else { continue }
                    let raw = scale * values[yy * width + xx] + shift
                    let m = direct ? raw : (raw > 0 ? 1 / raw : -1)
                    if m > 0.1, m < 8 { readings.append(m) }
                }
            }
            guard readings.count >= 5 else { return nil }
            return readings.sorted()[readings.count / 2]
        }
    }

    private init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        if let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc"),
           let ml = try? MLModel(contentsOf: url, configuration: configuration),
           let vision = try? VNCoreMLModel(for: ml) {
            model = vision
            Diagnostics.log("Picture depth: model loaded")
        } else {
            model = nil
            Diagnostics.log("Picture depth: model missing from the app")
        }
    }

    var available: Bool { model != nil }

    /// Runs the network on this frame (at most five times a second, never two at once) and fits it to metres with
    /// the tracked points given (world positions). The result arrives in `latest` a moment later.
    func update(_ frame: ARFrame, points: [SIMD3<Float>]) {
        guard let model, !running, frame.timestamp - lastRun > 0.2, case .normal = frame.camera.trackingState else { return }
        running = true
        lastRun = frame.timestamp
        let image = frame.capturedImage
        let toCamera = frame.camera.transform.inverse
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let resolution = SIMD2(Float(size.width), Float(size.height))
        let time = frame.timestamp
        // Where each tracked point falls in this picture, and how far ahead it is.
        var seen: [(u: Float, v: Float, z: Float)] = []
        for p in points {
            let c = toCamera * SIMD4(p, 1)
            let z = -c.z
            guard z > 0.1, z < 8 else { continue }
            let u = (k[0][0] * c.x / z + k[2][0]) / resolution.x
            let v = (-k[1][1] * c.y / z + k[2][1]) / resolution.y
            if u > 0.02, v > 0.02, u < 0.98, v < 0.98 { seen.append((u, v, z)) }
        }
        Task.detached(priority: .userInitiated) {
            let map = PictureDepth.run(model, on: image)
            await MainActor.run {
                self.running = false
                guard let map else { return }
                self.fit(map, seen: seen, time: time, toCamera: toCamera, k: k, resolution: resolution)
            }
        }
    }

    nonisolated private static func run(_ model: VNCoreMLModel, on image: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        let request = VNCoreMLRequest(model: model)
        // Stretched to the network's size, so a place in its map is the same 0 to 1 place in the camera picture.
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cvPixelBuffer: image, orientation: .up).perform([request])
        } catch {
            return nil
        }
        if let observation = request.results?.first as? VNPixelBufferObservation {
            return floats(observation.pixelBuffer)
        }
        if let observation = request.results?.first as? VNCoreMLFeatureValueObservation, let array = observation.featureValue.multiArrayValue {
            let shape = array.shape.map(\.intValue)
            guard shape.count >= 2 else { return nil }
            let height = shape[shape.count - 2], width = shape[shape.count - 1]
            var values = [Float](repeating: 0, count: width * height)
            for i in 0..<min(values.count, array.count) { values[i] = array[i].floatValue }
            return (values, width, height)
        }
        return nil
    }

    /// A one-channel map (16-bit half or 32-bit float) as floats.
    nonisolated private static func floats(_ buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            for y in 0..<height {
                let line = (base + y * row).assumingMemoryBound(to: Float16.self)
                for x in 0..<width { values[y * width + x] = Float(line[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            for y in 0..<height {
                let line = (base + y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = line[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let line = (base + y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(line[x]) }
            }
        default:
            return nil
        }
        return (values, width, height)
    }

    /// The scale and shift that turn the network's values into 1 / metres at the tracked points: random pairs
    /// first, the one most points agree with (within 6 %), then a straight-line fit through those.
    private func fit(_ map: (values: [Float], width: Int, height: Int), seen: [(u: Float, v: Float, z: Float)],
                     time: TimeInterval, toCamera: simd_float4x4, k: simd_float3x3, resolution: SIMD2<Float>) {
        var pairs: [(d: Float, inverse: Float, z: Float)] = []
        for s in seen {
            let x = min(Int(s.u * Float(map.width)), map.width - 1), y = min(Int(s.v * Float(map.height)), map.height - 1)
            let d = map.values[y * map.width + x]
            if d.isFinite { pairs.append((d, 1 / s.z, s.z)) }
        }
        func log(_ text: String) {
            if Date().timeIntervalSince(lastLog) > 3 {
                lastLog = Date()
                Diagnostics.log("Picture depth: " + text)
            }
        }
        guard pairs.count >= 20 else {
            log("only \(pairs.count) tracked points in view, not used")
            return
        }
        // Depth Anything gives nearness (bigger is closer); should a build give depth instead, fit metres directly.
        let meanD = pairs.reduce(0) { $0 + $1.d } / Float(pairs.count), meanZ = pairs.reduce(0) { $0 + $1.z } / Float(pairs.count)
        let direct = pairs.reduce(0) { $0 + ($1.d - meanD) * ($1.z - meanZ) } > 0
        if direct { pairs = pairs.map { ($0.d, $0.z, $0.z) } }
        func metres(_ value: Float) -> Float { direct ? value : (value > 0 ? 1 / value : -1) }
        var best: (scale: Float, shift: Float, inliers: [Int]) = (0, 0, [])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<120 {
            let i = Int.random(in: 0..<pairs.count, using: &generator), j = Int.random(in: 0..<pairs.count, using: &generator)
            let a = pairs[i], b = pairs[j]
            guard abs(a.d - b.d) > 1e-4 else { continue }
            let scale = (a.inverse - b.inverse) / (a.d - b.d)
            let shift = a.inverse - scale * a.d
            var inliers: [Int] = []
            for (n, p) in pairs.enumerated() {
                let m = metres(scale * p.d + shift)
                guard m > 0 else { continue }
                if abs(m - p.z) / p.z < 0.06 { inliers.append(n) }
            }
            if inliers.count > best.inliers.count { best = (scale, shift, inliers) }
        }
        let share = Float(best.inliers.count) / Float(pairs.count)
        guard best.inliers.count >= 15, share >= 0.4 else {
            log(String(format: "fit refused: %ld of %ld points agree", best.inliers.count, pairs.count))
            return
        }
        // Least squares through the agreeing points.
        let n = Float(best.inliers.count)
        var sx: Float = 0, sy: Float = 0, sxx: Float = 0, sxy: Float = 0
        for i in best.inliers {
            let p = pairs[i]
            sx += p.d; sy += p.inverse; sxx += p.d * p.d; sxy += p.d * p.inverse
        }
        let denominator = n * sxx - sx * sx
        var scale = best.scale, shift = best.shift
        if abs(denominator) > 1e-9 {
            scale = (n * sxy - sx * sy) / denominator
            shift = (sy - scale * sx) / n
        }
        var errors: [Float] = []
        for i in best.inliers {
            let p = pairs[i]
            let m = metres(scale * p.d + shift)
            if m > 0 { errors.append(abs(m - p.z) / p.z) }
        }
        let error = errors.isEmpty ? 1 : errors.sorted()[errors.count / 2]
        latest = Result(values: map.values, width: map.width, height: map.height, direct: direct, scale: scale, shift: shift,
                        points: best.inliers.count, error: error, time: time, worldToCamera: toCamera, intrinsics: k, resolution: resolution)
        log(String(format: "fitted to %ld of %ld points (%@), middle error %.1f %%", best.inliers.count, pairs.count, direct ? "depth" : "nearness", error * 100))
    }

    /// Where the line of sight through a place in the current picture meets the surface, from the newest fitted
    /// map if it is fresh (under 0.6 s old): the map's place for that point is found by projecting the ray into
    /// the frame the map came from, so a slightly older map still lines up.
    func point(in frame: ARFrame, normalized n: CGPoint) -> SIMD3<Float>? {
        guard let result = latest, frame.timestamp - result.time < 0.6, result.error < 0.08 else { return nil }
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let t = frame.camera.transform
        let local = SIMD4((Float(n.x) * Float(res.width) - k[2][0]) / k[0][0], -(Float(n.y) * Float(res.height) - k[2][1]) / k[1][1], -1, 0)
        let w = t * local
        let origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let direction = simd_normalize(SIMD3(w.x, w.y, w.z))
        // Walk the ray; where it passes the map's surface (as seen from the map's frame) is the point.
        var previous: Float?
        var distance: Float = 0.15
        while distance < 6 {
            let p = origin + direction * distance
            let c = result.worldToCamera * SIMD4(p, 1)
            let z = -c.z
            if z > 0.1 {
                let u = (result.intrinsics[0][0] * c.x / z + result.intrinsics[2][0]) / result.resolution.x
                let v = (-result.intrinsics[1][1] * c.y / z + result.intrinsics[2][1]) / result.resolution.y
                if u > 0, v > 0, u < 1, v < 1, let surface = result.metres(at: CGPoint(x: Double(u), y: Double(v))) {
                    let gap = surface - z
                    if let previous, previous > 0, gap <= 0 { return p }
                    previous = gap
                }
            }
            distance += 0.005
        }
        return nil
    }
}
