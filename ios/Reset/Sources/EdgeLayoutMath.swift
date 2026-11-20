import CoreGraphics

/// Where the picked model's tools stand round the edges of the picture (EdgeColumn in Models.swift; Phil, 2026-11-20:
/// fill the edges, keep the middle clear). Kept apart from SwiftUI so the tests can check it on the Mac.
enum EdgeLayoutMath {
    /// Where each tool's middle goes, from the top-left of `bounds`.
    static func places(sizes: [CGSize], width: CGFloat, height: CGFloat, leading: Bool, top: CGFloat, middle: CGFloat, maxGap: CGFloat) -> [CGPoint] {
        guard !sizes.isEmpty else { return [] }
        let cell = sizes.map(\.height).max() ?? 0
        let side = max(cell, height - top)
        let onSide = min(sizes.count, max(1, Int(side / max(cell, 1))))
        let column = sizes.prefix(onSide).map(\.width).max() ?? 0
        let gap = onSide > 1 ? max(0, min(maxGap, (side - CGFloat(onSide) * cell) / CGFloat(onSide - 1))) : 0
        let x = leading ? column / 2 : width - column / 2
        var points: [CGPoint] = []
        for i in 0..<onSide {
            let y = height - cell / 2 - CGFloat(onSide - 1 - i) * (cell + gap)
            points.append(CGPoint(x: x, y: y))
        }
        // The rest along the bottom, from the corner toward the middle.
        let rest = sizes.dropFirst(onSide).map(\.width)
        if !rest.isEmpty {
            let room = width - column - middle
            let rowGap = rest.count > 0 ? max(0, min(maxGap, (room - rest.reduce(0, +)) / CGFloat(rest.count))) : 0
            var along = column
            for w in rest {
                along += rowGap
                let centre = along + w / 2
                points.append(CGPoint(x: leading ? centre : width - centre, y: height - cell / 2))
                along += w
            }
        }
        return points
    }
}
