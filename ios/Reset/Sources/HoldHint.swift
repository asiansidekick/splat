import SwiftUI

/// Short animated "press and hold" hints (Phil, 2026-11-05): a finger presses and a ring grows, with
/// two or three words, the first few times a hold-only function is on screen. Nobody reads help,
/// so the function shows itself. Stops for good after three showings or once the hold is used.
enum HintStore {
    static let limit = 3
    private static func key(_ id: String) -> String { "hint.\(id)" }
    static func shouldShow(_ id: String) -> Bool { UserDefaults.standard.integer(forKey: key(id)) < limit }
    static func shown(_ id: String) { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key(id)) + 1, forKey: key(id)) }
    /// Brings every hint and one-time tip back ("Show tips again").
    static func resetAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hint.") || key.hasPrefix("tip.") {
            defaults.removeObject(forKey: key)
        }
    }
    static func learned(_ id: String) { UserDefaults.standard.set(limit, forKey: key(id)) }
}

struct HoldHintBubble: View {
    let label: String
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: 34, height: 34)
                    .scaleEffect(pressed ? 1.5 : 0.5)
                    .opacity(pressed ? 0.15 : 0.9)
                Image(systemName: "hand.point.up.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .scaleEffect(pressed ? 0.82 : 1)
                    .offset(y: pressed ? 4 : 0)
            }
            .frame(width: 52, height: 52)
            Text(label)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .fixedSize()
        }
        .shadow(color: .black.opacity(0.9), radius: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .hiddenInScreenshots()
        .onAppear {
            guard !reduceMotion else { pressed = true; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { pressed = true }
        }
    }
}

/// Shows `HoldHintBubble` beside a control for a few seconds, a limited number of times.
struct HoldHint: ViewModifier {
    let id: String
    let label: String
    var above = false
    var delay = 1.5
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: above ? .top : .bottom) {
                if visible {
                    HoldHintBubble(label: label)
                        .fixedSize()
                        .offset(y: above ? -64 : 64)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                HintStore.learned(id)
                withAnimation { visible = false }
            })
            .task {
                guard HintStore.shouldShow(id) else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, HintStore.shouldShow(id) else { return }
                HintStore.shown(id)
                withAnimation { visible = true }
                try? await Task.sleep(for: .seconds(5))
                withAnimation { visible = false }
            }
    }
}

extension View {
    /// Animated "hold" hint for a control, shown the first few times it appears.
    func holdHint(_ id: String, _ label: String, above: Bool = false, delay: Double = 1.5) -> some View {
        modifier(HoldHint(id: id, label: label, above: above, delay: delay))
    }
}
