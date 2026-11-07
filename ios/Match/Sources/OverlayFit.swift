import CoreGraphics
import Foundation

/// How an imported photo (a QTake screenshot, a photo from another camera) is sized and placed to
/// sit on the live camera: scaled about its middle, then moved. Worked out once from the live
/// view and kept with the photo. Offsets are shares of the whole photo's width and height, so the
/// fit holds however the screen crops it.
struct OverlayFit: Codable, Equatable, Hashable {
    var scale: Double
    var x: Double
    var y: Double

    static let none = OverlayFit(scale: 1, x: 0, y: 0)

    var isSensible: Bool {
        scale.isFinite && x.isFinite && y.isFinite && scale > 0.2 && scale < 5 && abs(x) < 1 && abs(y) < 1
    }

    /// Where a point of the photo (0...1 across and down) shows once fitted.
    func place(_ p: CGPoint) -> CGPoint {
        CGPoint(x: 0.5 + CGFloat(scale) * (p.x - 0.5) + CGFloat(x), y: 0.5 + CGFloat(scale) * (p.y - 0.5) + CGFloat(y))
    }

    /// From two points of the photo (an actor's eyes or shoulders) and where they are live, both
    /// 0...1 across and down pictures of the same shape (`aspect`, width over height).
    static func from(reference: (CGPoint, CGPoint), live: (CGPoint, CGPoint), aspect: CGFloat) -> OverlayFit? {
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot((b.x - a.x) * aspect, b.y - a.y) }
        let before = length(reference.0, reference.1)
        guard before > 1e-4 else { return nil }
        let s = length(live.0, live.1) / before
        let from = CGPoint(x: (reference.0.x + reference.1.x) / 2, y: (reference.0.y + reference.1.y) / 2)
        let to = CGPoint(x: (live.0.x + live.1.x) / 2, y: (live.0.y + live.1.y) / 2)
        let fit = OverlayFit(scale: Double(s), x: Double(to.x - 0.5 - s * (from.x - 0.5)), y: Double(to.y - 0.5 - s * (from.y - 0.5)))
        return fit.isSensible ? fit : nil
    }

    /// The share of the whole photo that a centred crop to `crop` (width over height) keeps.
    static func cropShare(photo: CGFloat, crop: CGFloat?) -> CGSize {
        guard let crop, crop > 0, photo > 0 else { return CGSize(width: 1, height: 1) }
        return photo > crop ? CGSize(width: crop / photo, height: 1) : CGSize(width: 1, height: photo / crop)
    }

    /// The same fit counted in a centred crop's own units (the crop the screen and guide use).
    func inCrop(_ share: CGSize) -> OverlayFit {
        OverlayFit(scale: scale, x: x / Double(share.width), y: y / Double(share.height))
    }

    /// A fit worked out in a crop's units, back to the whole photo's.
    func fromCrop(_ share: CGSize) -> OverlayFit {
        OverlayFit(scale: scale, x: x * Double(share.width), y: y * Double(share.height))
    }

    /// Two fits close enough to count as the same answer, so one odd frame isn't kept.
    func agrees(with other: OverlayFit) -> Bool {
        abs(scale / other.scale - 1) < 0.06 && abs(x - other.x) < 0.04 && abs(y - other.y) < 0.04
    }

    func averaged(with other: OverlayFit) -> OverlayFit {
        OverlayFit(scale: (scale + other.scale) / 2, x: (x + other.x) / 2, y: (y + other.y) / 2)
    }
}

/// Black bars round an imported picture (letterboxing on a QTake screenshot, a phone's black
/// edges), found so they can be cut off before the photo is used as an overlay.
enum BorderTrim {
    /// The part of a picture inside any plain dark bars, in pixels (y down, as CGImage cropping). The whole picture if
    /// there are none, or if trimming would leave too little.
    static func content(of image: CGImage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Read small and grey: fast, and fine detail doesn't matter here.
        let scale = min(1, 256 / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        var grey = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(data: &grey, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return full }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A bar line is dark all along: nothing brighter than a dim grey.
        func rowDark(_ y: Int) -> Bool { (0..<w).allSatisfy { grey[y * w + $0] < 28 } }
        func columnDark(_ x: Int) -> Bool { (0..<h).allSatisfy { grey[$0 * w + x] < 28 } }
        var top = 0, bottom = h - 1, left = 0, right = w - 1
        while top < bottom && rowDark(top) { top += 1 }
        while bottom > top && rowDark(bottom) { bottom -= 1 }
        while left < right && columnDark(left) { left += 1 }
        while right > left && columnDark(right) { right -= 1 }
        // The context's memory runs from the picture's top row down, so these are y-down already.
        let kept = CGRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(right - left + 1), height: CGFloat(bottom - top + 1))
        guard kept.width >= CGFloat(w) * 0.4, kept.height >= CGFloat(h) * 0.4 else { return full }
        // Bars thinner than about 1% are just a dark edge in the picture.
        guard kept.width < CGFloat(w) * 0.985 || kept.height < CGFloat(h) * 0.985 else { return full }
        // Back to full size, a pixel inside so no dark edge is left.
        let r = CGRect(x: kept.minX / scale, y: kept.minY / scale, width: kept.width / scale, height: kept.height / scale)
        return r.insetBy(dx: 1 / scale, dy: 1 / scale).integral.intersection(full)
    }
}
