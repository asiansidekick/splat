import AVKit
import SwiftUI
import UIKit

/// The edge guides' numbers, kept apart from the rest of the screen so updating them every frame
/// redraws only the guides. Smoothed (low-pass), with the seating and its haptics.
@MainActor
final class EdgeGuideState: ObservableObject {
    @Published private(set) var alignment: GhostAlignment?
    @Published private(set) var seated = [Bool](repeating: false, count: EdgeGuide.Edge.allCases.count)
    /// +1 step in, -1 step back, 0 the size is right.
    @Published private(set) var step = 0
    /// Set by the overlay: the screen and the part of it clear of the controls.
    var layout: EdgeGuide.Layout?
    private var seater = EdgeGuide.Seater()
    private var smoothed: GhostAlignment?
    private var lastTime: TimeInterval?
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let success = UINotificationFeedbackGenerator()

    var all: Bool { seated.allSatisfy { $0 } }

    /// One frame's measurement (nil when there is none), at the frame's time in seconds. Strokes
    /// are drawn either way but seat only when `canSeat`.
    func update(_ measured: GhostAlignment?, canSeat: Bool, time: TimeInterval) {
        defer { lastTime = measured == nil ? nil : time }
        guard let measured, let layout else {
            smoothed = nil
            if alignment != nil { alignment = nil }
            seater.reset()
            if seated != seater.seated { seated = seater.seated }
            if step != 0 { step = 0 }
            return
        }
        if let previous = smoothed, let lastTime {
            smoothed = previous.blended(toward: measured, alpha: EdgeGuide.alpha(dt: time - lastTime))
        } else {
            smoothed = measured
        }
        guard let smoothed else { return }
        let wasAll = seater.all
        let newly = seater.update(canSeat ? smoothed : nil, layout: layout)
        if seater.all && !wasAll {
            success.notificationOccurred(.success)
        } else if !newly.isEmpty {
            impact.impactOccurred()
        }
        if seated != seater.seated { seated = seater.seated }
        let nextStep = EdgeGuide.step(smoothed, was: step)
        if step != nextStep { step = nextStep }
        // Redraw only for a visible change.
        if let shown = alignment, hypot(shown.centre.x - smoothed.centre.x, shown.centre.y - smoothed.centre.y) < 0.3,
            abs(shown.roll - smoothed.roll) < 0.0005, abs(shown.scale - smoothed.scale) < 0.0005
        { return }
        alignment = smoothed
    }
}

/// The reference crosshair, shown only where it crosses the four edges of the picture: a white
/// stroke beside a fixed hollow slot on each edge. A stroke turns green in its slot; with all four
/// in, the slots go and a green border shows.
struct EdgeGuideOverlay: View {
    @ObservedObject var state: EdgeGuideState
    @Environment(\.chromeInsets) private var insets

    var body: some View {
        GeometryReader { geometry in
            let layout = EdgeGuide.Layout(
                size: geometry.size,
                clear: CGRect(
                    x: insets.leading, y: insets.top,
                    width: max(1, geometry.size.width - insets.leading - insets.trailing),
                    height: max(1, geometry.size.height - insets.top - insets.bottom)))
            ZStack {
                if !state.all {
                    ForEach(EdgeGuide.Edge.allCases, id: \.rawValue) { edge in
                        Capsule()
                            .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                            .frame(width: EdgeGuide.slotLength + 6, height: EdgeGuide.strokeWidth + 6)
                            .rotationEffect(.degrees(edge.isSide ? 0 : 90))
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .position(layout.slot(edge))
                    }
                }
                if state.step != 0, !state.all {
                    // In or out, which the strokes' length alone did not make clear.
                    Label(state.step > 0 ? "STEP IN" : "STEP BACK", systemImage: state.step > 0 ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .position(x: layout.slot(.top).x, y: layout.slot(.top).y + 40)
                        .transition(.opacity)
                }
                if let alignment = state.alignment {
                    ForEach(EdgeGuide.Edge.allCases, id: \.rawValue) { edge in
                        let green = state.seated[edge.rawValue]
                        Capsule()
                            .fill(green ? Color.green : Color.white)
                            .frame(width: EdgeGuide.slotLength * CGFloat(min(max(alignment.scale, 0.3), 3)), height: EdgeGuide.strokeWidth)
                            .rotationEffect(.radians(alignment.roll + (edge.isSide ? 0 : .pi / 2)))
                            .shadow(color: .black.opacity(0.8), radius: 2.5)
                            .position(layout.stroke(edge, alignment))
                    }
                }
            }
            .onAppear { state.layout = layout }
            .onChange(of: layout) { _, value in state.layout = value }
        }
        .allowsHitTesting(false)
    }
}

/// Watches taps on the whole window without taking them. On device, taps on the Pause button
/// in landscape never reached it although it showed (something above swallowed them), so a tap
/// inside a watched control's frame runs its action from here too and logs what was on top.
/// Actions given here must ignore a second call that comes straight after the first.
final class WindowTapCatcher: NSObject, UIGestureRecognizerDelegate {
    /// Watched controls, in window coordinates (SwiftUI's global space). No action: just logged.
    var targets: [String: (frame: CGRect, action: (() -> Void)?)] = [:]
    private var recognizer: UITapGestureRecognizer?
    private weak var window: UIWindow?

    @MainActor func install() {
        guard recognizer == nil else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap
        self.window = window
    }

    @MainActor func remove() {
        if let recognizer { window?.removeGestureRecognizer(recognizer) }
        recognizer = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @MainActor @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let window else { return }
        let point = gesture.location(in: window)
        for (name, target) in targets where target.frame.insetBy(dx: -6, dy: -6).contains(point) {
            let top = window.hitTest(point, with: nil).map { String(describing: type(of: $0)) } ?? "nothing"
            Diagnostics.log("Tap on \(name) (\(Screen.orientation.isLandscape ? "landscape" : "portrait")), top view \(top)")
            target.action?()
        }
    }
}

/// Reports a view's frame in window coordinates as it changes.
struct WindowFrame: ViewModifier {
    let changed: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear
                .onAppear { changed(geometry.frame(in: .global)) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in changed(frame) }
        })
    }
}

/// Pause and play, the same size and in the same spot.
struct PauseButton: View {
    let paused: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Diagnostics.log("Pause button tapped (\(paused ? "paused" : "live"))")
            Haptics.tap()
            action()
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(paused ? Color.orange : Color.white)
                .frame(width: 66, height: 66)
                .overlay(Circle().stroke(paused ? Color.orange : Color.white, lineWidth: 3))
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.6), radius: 3)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(paused ? "Back to live" : "Pause and compare")
    }
}

/// Paused: the frozen live picture and the reference stretched onto it. The whole screen is the
/// scrubber: drag across to fade (or wipe) between them, tap to jump to the other end. The
/// slider along the bottom does the same.
struct HeldCompare: View {
    let held: HeldFrame?
    /// For a reference with no photo to stretch: drawn filling the screen as it is.
    let plainReference: UIImage?
    /// 0 shows the reference, 1 the live picture.
    @Binding var toNow: Double
    let wipe: Bool
    @State private var dragStart: Double?
    private let selection = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black
                if let held {
                    Image(uiImage: held.now).resizable().frame(width: size.width, height: size.height)
                    reference(size)
                        .opacity(wipe ? 1 : 1 - toNow)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: wipe ? size.width * (1 - toNow) : size.width)
                        }
                    if wipe {
                        // A crisp line with a handle to drag.
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: size.height)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                            .position(x: size.width * (1 - toNow), y: size.height / 2)
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 34, height: 34)
                            .background(Color.white, in: Circle())
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .position(x: size.width * (1 - toNow), y: size.height / 2)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                selection.selectionChanged()
                withAnimation(.snappy(duration: 0.2)) { toNow = toNow < 0.5 ? 1 : 0 }
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag in
                        let start = dragStart ?? toNow
                        if dragStart == nil { dragStart = start }
                        // In a wipe the line follows the finger.
                        let share = Double(drag.translation.width / max(size.width, 1))
                        toNow = min(1, max(0, start + (wipe ? -share : share)))
                    }
                    .onEnded { _ in dragStart = nil })
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func reference(_ size: CGSize) -> some View {
        if let image = held?.reference {
            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
        } else if let plainReference {
            Image(uiImage: plainReference).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
        }
    }
}

/// A small cursor showing where a screen swipe has got to: a thin line with a dot and a word at
/// each end. Only for showing; the swipe itself is on the whole screen.
struct ScrubCursor: View {
    let value: Double
    let start: String
    let end: String

    var body: some View {
        HStack(spacing: 8) {
            Text(start)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.45)).frame(width: 120, height: 2)
                Circle().fill(Color.white).frame(width: 10, height: 10)
                    .offset(x: (120 - 10) * CGFloat(min(1, max(0, value))))
            }
            .frame(width: 120)
            Text(end)
        }
        .font(.caption2.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.3), in: Capsule())
        .shadow(color: .black.opacity(0.5), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// THEN on the left edge and NOW on the right, each as bright as the view leans its way.
struct SwipeTags: View {
    /// 0 is all then, 1 all now.
    let value: Double

    var body: some View {
        HStack {
            tag("THEN", weight: 1 - value)
            Spacer()
            tag("NOW", weight: value)
        }
        .padding(.horizontal, 6)
        // A little above the middle, clear of the side edge guides.
        .offset(y: -48)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tag(_ text: String, weight: Double) -> some View {
        let w = min(1, max(0, weight))
        return Text(text)
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color(white: 1 - w * 0.9).opacity(0.6 + 0.4 * w))
            .background(
                ZStack {
                    Capsule().fill(Color.black.opacity(0.35))
                    Capsule().fill(Color.white.opacity(w))
                })
            .scaleEffect(1 + 0.12 * w)
    }
}

/// Swiping left or right anywhere sets a value from 0 to 1, a screen width for the full range.
struct HorizontalSwipe: ViewModifier {
    @Binding var value: Double
    /// Called on each change, and with false when the finger lifts.
    var active: (Bool) -> Void
    @State private var start: Double?

    init(value: Binding<Double>, active: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.active = active
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { drag in
                            if start == nil {
                                // Only sideways swipes.
                                guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                                start = value
                            }
                            guard let start else { return }
                            value = min(1, max(0, start + Double(drag.translation.width / max(geometry.size.width, 1))))
                            active(true)
                        }
                        .onEnded { _ in
                            start = nil
                            active(false)
                        })
        }
    }
}

/// The volume buttons (and Camera Control) pause and play, on iOS 18 and later.
struct CaptureButtonAction: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended {
                    Diagnostics.log("Capture button pressed")
                    action()
                }
            }
        } else {
            content
        }
    }
}

/// A hand sliding between THEN and NOW, shown briefly when a reference loads to say how to fade the ghost.
struct SwipeHint: View {
    @State private var slid = false

    var body: some View {
        HStack(spacing: 8) {
            Text("THEN").font(.caption2.weight(.heavy))
            Image(systemName: "chevron.left").font(.caption.weight(.bold))
            Image(systemName: "hand.point.up.fill")
                .font(.title2)
                .offset(x: slid ? 28 : -28)
            Image(systemName: "chevron.right").font(.caption.weight(.bold))
            Text("NOW").font(.caption2.weight(.heavy))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 3)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .hiddenInScreenshots()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { slid = true }
        }
    }
}
