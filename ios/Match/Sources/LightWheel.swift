import SwiftUI
import UIKit

/// The light's brightness on a scroll wheel, like the Camera app's zoom dial: a ruler of ticks
/// slid sideways under a fixed marker. Drag left for brighter, right for dimmer, with a click at
/// every tenth.
struct LightWheel: View {
    @Binding var level: Double
    /// "LIGHT" for the torch, "SCREEN LIGHT" for the front camera's glow.
    var title: String
    /// Called on every change, so the wheel can stay up while it's used.
    var onTouch: () -> Void = {}

    @State private var dragStart: Double?
    private let width: CGFloat = 220

    var body: some View {
        VStack(spacing: 4) {
            Text("\(title) \(Int((level * 100).rounded()))%")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.yellow)
            Canvas { context, size in
                let mid = size.width / 2
                for step in 0...LightScrub.steps {
                    let value = Double(step) / Double(LightScrub.steps)
                    let x = mid + CGFloat(value - level) * LightScrub.pointsPerFull
                    guard x > -2, x < size.width + 2 else { continue }
                    let major = step % 5 == 0
                    let height: CGFloat = major ? 16 : 9
                    let tick = Path(CGRect(x: x - 0.75, y: size.height - height - 4, width: 1.5, height: height))
                    context.fill(tick, with: .color(.white.opacity(major ? 0.95 : 0.6)))
                }
                // The fixed marker: the level under it is the one in use.
                let marker = Path(roundedRect: CGRect(x: mid - 1.5, y: 2, width: 3, height: size.height - 4), cornerRadius: 1.5)
                context.fill(marker, with: .color(.yellow))
            }
            .frame(width: width, height: 28)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.45), in: Capsule())
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let start = dragStart ?? level
            dragStart = start
            LightScrub.set(&level, from: start, by: drag.translation.width)
            onTouch()
        }.onEnded { _ in dragStart = nil })
        .accessibilityElement()
        .accessibilityLabel(title.capitalized)
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let change = direction == .increment ? 0.1 : -0.1
            level = LightScrub.clamped(level + change)
            onTouch()
        }
    }
}

/// The maths shared by the wheel and a drag on the light button.
enum LightScrub {
    /// Ticks every 2%.
    static let steps = 50
    /// How far the ruler slides from 0% to 100%.
    static let pointsPerFull: CGFloat = 420
    /// Never quite off: the button turns the light off.
    static let lowest = 0.05

    static func clamped(_ value: Double) -> Double { min(1, max(lowest, value)) }

    /// Sliding the ruler left brings brighter ticks under the marker. Clicks at each tenth passed.
    static func set(_ level: inout Double, from start: Double, by dragX: CGFloat) {
        let new = clamped(start - Double(dragX / pointsPerFull))
        if Int((new * 10).rounded(.down)) != Int((level * 10).rounded(.down)) || (new != level && (new == 1 || new == lowest)) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        level = new
    }
}

/// The front camera has no torch, so the screen lights the face instead: a white glow round the
/// edges, wider and brighter as the level goes up, like a ring light.
struct RingLight: View {
    var level: Double

    var body: some View {
        let width = 24 + 110 * level
        Rectangle()
            .strokeBorder(Color.white.opacity(0.7 + 0.3 * level), lineWidth: width)
            .blur(radius: 6)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}
