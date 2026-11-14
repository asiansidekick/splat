import SwiftUI

/// A number whose digits flip over in 3D as it counts up: the old digit tips away on a horizontal hinge
/// and the new one tips in behind it (like a split-flap board or a turning drum).
struct RollingNumber: View {
    let value: Int
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: size * 0.02) {
            ForEach(Array(String(max(value, 0)).enumerated()), id: \.offset) { _, digit in
                RollingDigit(digit: digit, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value)")
    }
}

private struct RollingDigit: View {
    let digit: Character
    let size: CGFloat

    var body: some View {
        ZStack {
            Text(String(digit))
                .id(digit)
                .transition(.flip)
        }
        .font(Theme.font(size: size, weight: .heavy))
        .monospacedDigit()
        .frame(width: size * 0.56, height: size * 1.1)
        .clipped()
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: digit)
    }
}

private struct FlipEffect: ViewModifier {
    let angle: Double
    let opacity: Double
    let offset: CGFloat

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .offset(y: offset)
            .opacity(opacity)
    }
}

private extension AnyTransition {
    /// In from above, out to below, turning about the horizontal axis.
    static var flip: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: FlipEffect(angle: -100, opacity: 0, offset: -14), identity: FlipEffect(angle: 0, opacity: 1, offset: 0)),
            removal: .modifier(active: FlipEffect(angle: 100, opacity: 0, offset: 14), identity: FlipEffect(angle: 0, opacity: 1, offset: 0)))
    }
}

/// The views counter on the capture screen: a big flipping number with its label.
struct ViewsCounter: View {
    let count: Int

    var body: some View {
        VStack(spacing: -2) {
            RollingNumber(value: count, size: 44)
                .foregroundStyle(Theme.accent)
                .shadow(color: .black.opacity(0.6), radius: 3)
            Text(count == 1 ? "VIEW" : "VIEWS")
                .font(Theme.font(size: 17, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
        }
        .fixedSize()
    }
}
