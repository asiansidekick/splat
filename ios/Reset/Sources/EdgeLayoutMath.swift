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
        // The rest along the bottom, from the corner toward the middle; what the bottom has no room for goes along the
        // top the same way (the ring), and only past that do any run on into the middle of the bottom.
        let rest = Array(sizes.dropFirst(onSide).map(\.width))
        if !rest.isEmpty {
            let room = max(0, width - column - middle)
            var bottom: [CGFloat] = [], topRow: [CGFloat] = [], over: [CGFloat] = []
            for w in rest {
                if over.isEmpty, topRow.isEmpty, bottom.reduce(0, +) + w <= room { bottom.append(w) }
                else if over.isEmpty, topRow.reduce(0, +) + w <= room { topRow.append(w) }
                else { over.append(w) }
            }
            func row(_ widths: [CGFloat], y: CGFloat, spread: Bool) -> [CGPoint] {
                let gap = spread && !widths.isEmpty ? max(0, min(maxGap, (room - widths.reduce(0, +)) / CGFloat(widths.count))) : 0
                var along = column
                var placed: [CGPoint] = []
                for w in widths {
                    along += gap
                    let centre = along + w / 2
                    placed.append(CGPoint(x: leading ? centre : width - centre, y: y))
                    along += w
                }
                return placed
            }
            // Still more: a second column just inside the first, between the bottom and top rows, from the bottom up.
            let inner = min(over.count, max(0, onSide - 2))
            let innerWidth = over.prefix(inner).max() ?? 0
            let innerX = column + 6 + innerWidth / 2
            var innerPoints: [CGPoint] = []
            for i in 0..<inner {
                let y = height - cell / 2 - CGFloat(i + 1) * (cell + gap)
                innerPoints.append(CGPoint(x: leading ? innerX : width - innerX, y: y))
            }
            let last = Array(over.dropFirst(inner))
            // In the tools' own order: the bottom row, the top row, the inner column, then any that run on along the bottom.
            let along = row(bottom + last, y: height - cell / 2, spread: last.isEmpty)
            points += along.prefix(bottom.count)
            points += row(topRow, y: height - cell / 2 - CGFloat(onSide - 1) * (cell + gap), spread: true)
            points += innerPoints
            points += along.dropFirst(bottom.count)
        }
        return points
    }
}
