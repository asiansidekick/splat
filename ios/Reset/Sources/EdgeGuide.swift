import CoreGraphics
import Foundation

/// Where the reference photo's crosshair lies on the screen right now: where its middle shows,
/// how far it is turned and how big it shows against the live picture. Lined up, the middle is
/// the middle of the screen, the turn is 0 and the size is 1.
struct GhostAlignment: Equatable {
    /// Where the reference's middle shows, in screen points.
    var centre: CGPoint
    /// How far the reference's level line is turned on screen, radians, clockwise positive.
    var roll: Double
    /// How big the reference shows against the live picture: under 1 means step closer.
    var scale: Double

    init(centre: CGPoint, roll: Double, scale: Double) {
        self.centre = centre
        self.roll = roll
        self.scale = scale
    }

    /// From where three points of the reference land on screen: its middle and the ends of a
    /// level arm either side, each `arm` points from the middle when lined up.
    init?(centre: CGPoint, left: CGPoint, right: CGPoint, arm: CGFloat) {
        let dx = right.x - left.x
        let dy = right.y - left.y
        let length = hypot(dx, dy)
        guard arm > 0, length > 1, dx > 0 else { return nil }
        self.init(centre: centre, roll: Double(atan2(dy, dx)), scale: Double(length / (arm * 2)))
    }

    /// A step of the low-pass filter towards `next`: `alpha` of the way there.
    func blended(toward next: GhostAlignment, alpha: Double) -> GhostAlignment {
        let a = CGFloat(alpha)
        var turn = next.roll - roll
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        return GhostAlignment(
            centre: CGPoint(x: centre.x + (next.centre.x - centre.x) * a, y: centre.y + (next.centre.y - centre.y) * a),
            roll: roll + turn * alpha,
            scale: scale + (next.scale - scale) * alpha)
    }
}

/// The edge guides: the reference crosshair drawn only where it crosses the four edges of the
/// picture clear of the controls, each beside a fixed slot. Lined up, every stroke sits in its
/// slot, level and the slot's length. Kept free of UIKit so the tests run it on a Mac.
enum EdgeGuide {
    enum Edge: Int, CaseIterable {
        case left, right, top, bottom
        var isSide: Bool { self == .left || self == .right }
    }

    static let slotLength: CGFloat = 36
    static let strokeWidth: CGFloat = 5
    /// How far in from its edge each slot's middle sits.
    static let inset: CGFloat = 28
    /// Seated within these; let go only past 1.6 times them, so a stroke on the line does not flicker.
    static let offsetTolerance: CGFloat = 7
    static let rollTolerance = 1.2 * Double.pi / 180
    static let scaleTolerance = 0.025
    static let release = 1.6
    /// The low-pass filter's share per 1/30 s.
    static let smoothing = 0.3

    /// The screen and the part of it clear of the controls, in points.
    struct Layout: Equatable {
        var size: CGSize
        var clear: CGRect

        /// The fixed slot: where the crosshair crosses this edge when lined up. The camera's
        /// middle is the middle of the screen, so the side slots sit at half height and the top
        /// and bottom ones half way across.
        func slot(_ edge: Edge) -> CGPoint {
            switch edge {
            case .left: return CGPoint(x: clear.minX + EdgeGuide.inset, y: size.height / 2)
            case .right: return CGPoint(x: clear.maxX - EdgeGuide.inset, y: size.height / 2)
            case .top: return CGPoint(x: size.width / 2, y: clear.minY + EdgeGuide.inset)
            case .bottom: return CGPoint(x: size.width / 2, y: clear.maxY - EdgeGuide.inset)
            }
        }

        /// Where the reference crosshair crosses this edge (on the slot's line), unclamped.
        func crossing(_ edge: Edge, _ a: GhostAlignment) -> CGPoint {
            let slot = slot(edge)
            let t = CGFloat(tan(a.roll))
            if edge.isSide {
                // The level line through the middle, turned by the roll.
                return CGPoint(x: slot.x, y: a.centre.y + t * (slot.x - a.centre.x))
            }
            // The upright line, turned the same way.
            return CGPoint(x: a.centre.x - t * (slot.y - a.centre.y), y: slot.y)
        }

        /// Where to draw the stroke: the crossing, kept on screen along its edge.
        func stroke(_ edge: Edge, _ a: GhostAlignment) -> CGPoint {
            let p = crossing(edge, a)
            let margin = EdgeGuide.slotLength / 2 + 6
            if edge.isSide {
                return CGPoint(x: p.x, y: min(max(p.y, clear.minY + margin), clear.maxY - margin))
            }
            return CGPoint(x: min(max(p.x, clear.minX + margin), clear.maxX - margin), y: p.y)
        }

        /// How far the stroke is from its slot along the edge, in points.
        func offset(_ edge: Edge, _ a: GhostAlignment) -> CGFloat {
            let p = crossing(edge, a)
            let s = slot(edge)
            return edge.isSide ? p.y - s.y : p.x - s.x
        }
    }

    /// Whether one stroke counts as in its slot, `slack` times the tolerances.
    static func fits(_ edge: Edge, _ a: GhostAlignment, layout: Layout, slack: Double = 1) -> Bool {
        abs(layout.offset(edge, a)) < offsetTolerance * CGFloat(slack)
            && abs(a.roll) < rollTolerance * slack
            && abs(a.scale - 1) < scaleTolerance * slack
    }

    /// Which strokes are seated, with the hysteresis: a stroke seats inside the tolerances and
    /// stays seated until it goes past 1.6 times them.
    struct Seater {
        private(set) var seated = [Bool](repeating: false, count: Edge.allCases.count)
        var all: Bool { seated.allSatisfy { $0 } }

        /// Updates from the latest alignment (nil when there is none: nothing is seated) and
        /// returns the edges that have just seated.
        mutating func update(_ a: GhostAlignment?, layout: Layout) -> [Edge] {
            var newly: [Edge] = []
            for edge in Edge.allCases {
                let was = seated[edge.rawValue]
                let now = a.map { EdgeGuide.fits(edge, $0, layout: layout, slack: was ? EdgeGuide.release : 1) } ?? false
                if now && !was { newly.append(edge) }
                seated[edge.rawValue] = now
            }
            return newly
        }

        mutating func reset() {
            seated = [Bool](repeating: false, count: Edge.allCases.count)
        }
    }

    /// The filter's share for a step of `dt` seconds, so it smooths the same at any frame rate.
    static func alpha(dt: Double) -> Double {
        1 - pow(1 - smoothing, max(0, min(dt, 1)) * 30)
    }
}
