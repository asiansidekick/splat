import CoreVideo
import Foundation

/// Reading ARKit's LiDAR buffers into plain arrays. Kept free of ARKit so the tests can run it on
/// a Mac.
enum DepthMap {
    /// Lowest ARKit confidence kept when saving depth (0 low, 1 medium, 2 high). Keeping only high
    /// dropped nearly every reading on device, leaving the 3D ghost with a handful of dots.
    static let minConfidence: UInt8 = 1

    /// ARKit's confidence levels, or nil when they cannot be trusted: on an iPhone 14 Pro with
    /// iOS 26 every reading came back "low" while the depth itself was good, so trusting it threw
    /// all the depth away. Confidence that rates nearly everything low is ignored.
    static func confidence(_ buffer: CVPixelBuffer?) -> [UInt8]? {
        guard let buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        return usable(bytes(buffer))
    }

    /// The levels if at least 5% are medium or high, else nil.
    static func usable(_ levels: [UInt8]) -> [UInt8]? {
        let sure = levels.reduce(0) { $0 + ($1 >= minConfidence ? 1 : 0) }
        return levels.isEmpty || sure * 20 < levels.count ? nil : levels
    }

    /// Copies depth, setting readings below `minConfidence` to 0 (no reading) when the
    /// confidence can be trusted.
    static func copy(_ buffer: CVPixelBuffer, keepingOnly confidence: CVPixelBuffer?) -> Data {
        var data = copy(buffer)
        guard let levels = self.confidence(confidence) else { return data }
        data.withUnsafeMutableBytes { raw in
            let depth = raw.bindMemory(to: Float.self)
            guard depth.count == levels.count else { return }
            for i in 0..<depth.count where levels[i] < minConfidence { depth[i] = 0 }
        }
        return data
    }

    /// Copies a depth buffer into tightly packed Float32 metres, whatever format it comes in:
    /// 32 or 16 bit, depth or disparity (1 / metres).
    static func copy(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        let half = format == kCVPixelFormatType_DepthFloat16 || format == kCVPixelFormatType_DisparityFloat16
            || format == kCVPixelFormatType_OneComponent16Half
        let disparity = format == kCVPixelFormatType_DisparityFloat16 || format == kCVPixelFormatType_DisparityFloat32
        var out = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes)
            for column in 0..<width {
                var value: Float
                if half {
                    value = halfToFloat(line.assumingMemoryBound(to: UInt16.self)[column])
                } else {
                    value = line.assumingMemoryBound(to: Float.self)[column]
                }
                if disparity { value = value > 0 ? 1 / value : 0 }
                out[row * width + column] = value.isFinite ? value : 0
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Copies an 8-bit buffer, such as ARKit's depth confidence map, row by row.
    static func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        var out = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width { out[row * width + column] = source[column] }
        }
        return out
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The depth at the middle of a map, in metres: the median of the real readings (between
    /// `range`) within `radius` pixels of the centre. Nil with fewer than 5 of the 9 around the middle.
    static func middle(_ depth: [Float], width: Int, height: Int, radius: Int = 1, range: ClosedRange<Float> = 0.05...6) -> Float? {
        sample(depth, width: width, height: height, x: width / 2, y: height / 2, radius: radius, range: range)
    }

    /// The depth around pixel (`x`, `y`) (kept inside the map): the median of the real readings
    /// within `radius` pixels. Nil with fewer than half of them real.
    static func sample(_ depth: [Float], width: Int, height: Int, x centreX: Int, y centreY: Int, radius: Int = 1, range: ClosedRange<Float> = 0.05...6) -> Float? {
        guard width > 0, height > 0, depth.count == width * height else { return nil }
        let cx = min(max(centreX, 0), width - 1)
        let cy = min(max(centreY, 0), height - 1)
        var readings: [Float] = []
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = cx + dx
                let y = cy + dy
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let value = depth[y * width + x]
                if value.isFinite && range.contains(value) { readings.append(value) }
            }
        }
        let needed = (2 * radius + 1) * (2 * radius + 1) / 2 + 1
        guard readings.count >= needed else { return nil }
        return readings.sorted()[readings.count / 2]
    }

    /// The depth at a place between depth pixels, from a plane fitted to the readings round it.
    /// A plane's distance changes smoothly (its inverse is a straight function of the pixel), so
    /// this reads a flat thing more steadily than one pixel or a median, and readings from another
    /// surface behind or in front (the edge of a sheet of paper) are dropped as outliers.
    /// `x` and `y` are in depth pixels, with 0.5 the middle of the first one.
    static func planeDepth(_ depth: [Float], width: Int, height: Int, x: Float, y: Float, radius: Int = 3, range: ClosedRange<Float> = 0.05...6) -> Float? {
        guard width > 0, height > 0, depth.count == width * height else { return nil }
        let cx = Int(x.rounded(.down)), cy = Int(y.rounded(.down))
        var points: [(dx: Double, dy: Double, inverse: Double)] = []
        for j in -radius...radius {
            for i in -radius...radius {
                let px = cx + i, py = cy + j
                guard px >= 0, py >= 0, px < width, py < height else { continue }
                let value = depth[py * width + px]
                guard value.isFinite, range.contains(value) else { continue }
                points.append((Double(px) + 0.5 - Double(x), Double(py) + 0.5 - Double(y), 1 / Double(value)))
            }
        }
        guard points.count >= 8 else { return nil }
        // The plane most readings agree with, found by trying every plane through three of a dozen
        // of them (always the same ones, so the answer is steady). In inverse metres a limit of
        // 0.012 is about 1 cm at 1 m, the LiDAR's own noise.
        let limit = 0.012
        let step = max(1, Int((Double(points.count) / 12).rounded(.up)))
        let sample = stride(from: 0, to: points.count, by: step).map { points[$0] }
        var best: [(dx: Double, dy: Double, inverse: Double)] = []
        for i in 0..<sample.count {
            for j in (i + 1)..<sample.count {
                for k in (j + 1)..<sample.count {
                    guard let plane = fitPlane([sample[i], sample[j], sample[k]]) else { continue }
                    let agree = points.filter { abs(plane.a * $0.dx + plane.b * $0.dy + plane.c - $0.inverse) <= limit }
                    if agree.count > best.count { best = agree }
                }
            }
        }
        guard best.count >= 6, let fit = fitPlane(best), fit.c > 0 else { return nil }
        let metres = Float(1 / fit.c)
        return range.contains(metres) ? metres : nil
    }

    /// Least squares for inverse = a * dx + b * dy + c.
    private static func fitPlane(_ points: [(dx: Double, dy: Double, inverse: Double)]) -> (a: Double, b: Double, c: Double)? {
        var sxx = 0.0, sxy = 0.0, sx = 0.0, syy = 0.0, sy = 0.0, n = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        for p in points {
            sxx += p.dx * p.dx; sxy += p.dx * p.dy; sx += p.dx
            syy += p.dy * p.dy; sy += p.dy; n += 1
            sxz += p.dx * p.inverse; syz += p.dy * p.inverse; sz += p.inverse
        }
        // Solve [[sxx sxy sx] [sxy syy sy] [sx sy n]] * [a b c] = [sxz syz sz] by Cramer's rule.
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let matrix = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        let d = det(matrix)
        guard abs(d) > 1e-9 else { return nil }
        let rhs = [sxz, syz, sz]
        func replaced(_ column: Int) -> [[Double]] {
            var m = matrix
            for row in 0..<3 { m[row][column] = rhs[row] }
            return m
        }
        return (det(replaced(0)) / d, det(replaced(1)) / d, det(replaced(2)) / d)
    }

    /// IEEE half precision to Float, without relying on the Float16 type.
    static func halfToFloat(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            // Zero or subnormal.
            let value = Float(mantissa) / 1024 * pow(2, -14)
            return sign == 0 ? value : -value
        }
        if exponent == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | (UInt32(exponent - 15 + 127) << 23) | (mantissa << 13))
    }

    /// The buffer's format and size, for the feedback log.
    static func describe(_ buffer: CVPixelBuffer) -> String {
        let code = CVPixelBufferGetPixelFormatType(buffer)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> UInt32($0)) & 0xFF))) }
        return "'\(String(chars))' \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) row \(CVPixelBufferGetBytesPerRow(buffer))"
    }

    /// How many readings are usable and what range they cover, for the feedback log.
    static func stats(_ depth: [Float], confidence: [UInt8]?) -> String {
        let usable = depth.filter { $0 > 0.1 && $0 < 5 }
        var text = "\(usable.count)/\(depth.count) usable"
        if let low = usable.min(), let high = usable.max() { text += String(format: ", %.2f-%.2f m", low, high) }
        if let confidence {
            let counts = (0...2).map { level in confidence.filter { $0 == level }.count }
            text += ", confidence low \(counts[0]) medium \(counts[1]) high \(counts[2])"
        }
        return text
    }
}
