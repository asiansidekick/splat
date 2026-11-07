import CoreGraphics
import Foundation

/// A small LiDAR depth map (metres, about 256 x 192), upright the way photos are saved. Kept live
/// from the camera, and saved beside each photo taken with LiDAR so the reference knows how far
/// away the actor was.
struct DepthGrid: Equatable {
    var width: Int
    var height: Int
    /// Row by row from the top left. Zero or not finite: no reading.
    var values: [Float]

    var aspect: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }

    func value(_ x: Int, _ y: Int) -> Float { values[y * width + x] }

    /// Turned clockwise by quarter turns, as the camera's sensor-sideways maps are made upright.
    func rotated(quarterTurns: Int) -> DepthGrid {
        var grid = self
        for _ in 0..<((quarterTurns % 4 + 4) % 4) {
            var turned = [Float](repeating: 0, count: grid.values.count)
            let w = grid.width, h = grid.height
            // The new picture is h wide and w tall; its (x, y) was the old (y, h - 1 - x).
            for y in 0..<w {
                for x in 0..<h {
                    turned[y * h + x] = grid.values[(h - 1 - x) * w + y]
                }
            }
            grid = DepthGrid(width: h, height: w, values: turned)
        }
        return grid
    }

    /// The middle part at the given width over height, as photos are cropped to what the screen shows.
    func cropped(aspect target: CGFloat?) -> DepthGrid {
        guard let target, target > 0 else { return self }
        let rect = Self.centredRect(width: width, height: height, aspect: target)
        var out = [Float]()
        out.reserveCapacity(rect.width * rect.height)
        for y in rect.y..<(rect.y + rect.height) {
            out.append(contentsOf: values[(y * width + rect.x)..<(y * width + rect.x + rect.width)])
        }
        return DepthGrid(width: rect.width, height: rect.height, values: out)
    }

    private static func centredRect(width: Int, height: Int, aspect: CGFloat) -> (x: Int, y: Int, width: Int, height: Int) {
        var w = CGFloat(width), h = CGFloat(height)
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        let cw = max(1, min(width, Int(w.rounded()))), ch = max(1, min(height, Int(h.rounded())))
        return ((width - cw) / 2, (height - ch) / 2, cw, ch)
    }

    /// The typical distance round a point (0...1 across and down of a picture cropped from this map
    /// to `aspect`), from the readings within `radius` of the picture's width. Nil with too few.
    func distance(at point: CGPoint, aspect: CGFloat? = nil, radius: CGFloat = 0.03) -> Float? {
        guard width > 0, height > 0 else { return nil }
        let rect = aspect.map { Self.centredRect(width: width, height: height, aspect: $0) } ?? (x: 0, y: 0, width: width, height: height)
        let cx = CGFloat(rect.x) + point.x * CGFloat(rect.width)
        let cy = CGFloat(rect.y) + point.y * CGFloat(rect.height)
        let r = max(1, Int((radius * CGFloat(rect.width)).rounded()))
        var found: [Float] = []
        for y in (Int(cy) - r)...(Int(cy) + r) where y >= 0 && y < height {
            for x in (Int(cx) - r)...(Int(cx) + r) where x >= 0 && x < width {
                let v = value(x, y)
                if v.isFinite, v > 0.05, v < 20 { found.append(v) }
            }
        }
        guard found.count >= 3 else { return nil }
        found.sort()
        return found[found.count / 2]
    }

    // MARK: Saving

    private static let magic: UInt32 = 0x4450_5448  // "DPTH"

    var data: Data {
        var out = Data()
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(Self.magic)
        put(UInt32(width))
        put(UInt32(height))
        for v in values { put(v.bitPattern) }
        return out
    }

    init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// Nil for anything that isn't a whole saved map.
    init?(data: Data) {
        let bytes = [UInt8](data)
        func word(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        guard bytes.count >= 12, word(0) == Self.magic else { return nil }
        let w = Int(word(4)), h = Int(word(8))
        guard w > 0, h > 0, w * h <= 4_000_000, bytes.count == 12 + w * h * 4 else { return nil }
        width = w
        height = h
        values = (0..<(w * h)).map { Float(bitPattern: word(12 + $0 * 4)) }
    }
}

/// Where the set has changed since the reference, read from the two LiDAR depth maps once the
/// camera is lined up on the reference: red where something is now nearer than it was (added or
/// moved in), blue where the reference's surface is now farther or missing. Same tolerance as
/// Reset, so both apps agree on what counts as a change.
enum DepthChange {
    /// Changes smaller than this (plus 2 cm per metre of distance) are LiDAR noise.
    static let threshold: Float = 0.06
    static let perMetre: Float = 0.02
    /// A flagged cell needs this many flagged neighbours (of 8) to count, so only solid areas show.
    static let minNeighbours = 6
    static let maxRange: Float = 5

    /// +1 where the live scene is nearer, -1 where it is farther, 0 unchanged or unknown, on the
    /// live map's grid. Both maps must show the same view (cropped to the same shape).
    static func flags(live: DepthGrid, reference: DepthGrid) -> (width: Int, height: Int, flags: [Int8]) {
        let w = live.width, h = live.height
        var raw = [Int8](repeating: 0, count: w * h)
        guard w > 0, h > 0, reference.width > 0, reference.height > 0, live.values.count == w * h,
              reference.values.count == reference.width * reference.height else { return (w, h, raw) }
        for y in 0..<h {
            let ry = min(reference.height - 1, y * reference.height / h)
            for x in 0..<w {
                let rx = min(reference.width - 1, x * reference.width / w)
                let now = live.values[y * w + x], then = reference.values[ry * reference.width + rx]
                guard now.isFinite, then.isFinite, now > 0.1, then > 0.1, now < maxRange, then < maxRange else { continue }
                let limit = threshold + perMetre * then
                if then - now > limit { raw[y * w + x] = 1 } else if now - then > limit { raw[y * w + x] = -1 }
            }
        }
        var kept = raw
        for y in 0..<h {
            for x in 0..<w where raw[y * w + x] != 0 {
                var same = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, nx < w, ny >= 0, ny < h, raw[ny * w + nx] == raw[y * w + x] { same += 1 }
                    }
                }
                if same < minNeighbours { kept[y * w + x] = 0 }
            }
        }
        return (w, h, kept)
    }

    /// A see-through red and blue picture of the changes, or nil when nothing changed.
    static func mask(live: DepthGrid, reference: DepthGrid, aspect: CGFloat?) -> CGImage? {
        let (w, h, flags) = Self.flags(live: live.cropped(aspect: aspect), reference: reference.cropped(aspect: aspect))
        guard w > 0, h > 0, flags.contains(where: { $0 != 0 }) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where flags[i] != 0 {
            // Premultiplied alpha, about 45% strong.
            let alpha: UInt8 = 115
            if flags[i] > 0 {
                pixels[i * 4] = alpha
            } else {
                pixels[i * 4 + 2] = alpha
            }
            pixels[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
