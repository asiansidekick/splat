import SwiftUI
import UIKit

// Shared with the Reset app (copied from ios/Reset/Sources/Views.swift), so both apps look and
// work the same and Match can later fold into Reset.

// MARK: - Layout

/// The Camera app's layout: the preview fills the whole screen, with the top bar and the shutter
/// controls floating over it, along the bottom when upright or down the side when the phone is
/// turned. The preview stays the same view whichever way the phone is held, so turning it does
/// not restart the camera. Things drawn over the preview keep clear of the controls with
/// `chromeInsets`.
struct CameraLayout<Top: View, Preview: View, Modes: View, Leading: View, Shutter: View, Trailing: View>: View {
    @ViewBuilder let top: () -> Top
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let modes: (_ vertical: Bool) -> Modes
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let shutter: () -> Shutter
    @ViewBuilder let trailing: () -> Trailing

    static var topHeight: CGFloat { 44 }
    static var bottomHeight: CGFloat { 140 }
    static var sideWidth: CGFloat { 100 }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let safe = geometry.safeAreaInsets
            let insets = landscape
                ? EdgeInsets(top: safe.top + Self.topHeight, leading: safe.leading, bottom: safe.bottom, trailing: max(safe.trailing, Self.sideWidth))
                : EdgeInsets(top: safe.top + Self.topHeight, leading: safe.leading, bottom: safe.bottom + Self.bottomHeight, trailing: safe.trailing)
            ZStack {
                VStack(spacing: 0) {
                    top()
                        .frame(height: Self.topHeight)
                        .background(Color.black.opacity(0.35).ignoresSafeArea(edges: .top))
                    Spacer(minLength: 0)
                    if !landscape {
                        VStack(spacing: 10) {
                            modes(false)
                            HStack {
                                leading().frame(width: 84)
                                Spacer()
                                shutter()
                                Spacer()
                                trailing().frame(width: 84)
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, minHeight: Self.bottomHeight)
                        .background(Color.black.opacity(0.35).ignoresSafeArea(edges: .bottom))
                    }
                }
                .padding(.trailing, landscape ? max(0, Self.sideWidth - safe.trailing) : 0)
                if landscape {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 14) {
                            trailing()
                            Spacer(minLength: 0)
                            modes(true)
                            shutter()
                            Spacer(minLength: 0)
                            leading()
                        }
                        .padding(.vertical, 8)
                        .frame(width: Self.sideWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color.black.opacity(0.35).ignoresSafeArea(edges: [.top, .bottom]))
                    }
                    // Right against the edge of the screen, like the Camera app, not inset by the
                    // safe area, which only leaves an empty strip.
                    .ignoresSafeArea(edges: .trailing)
                }
            }
            .background {
                preview()
                    .environment(\.chromeInsets, insets)
                    .clipped()
                    .ignoresSafeArea()
            }
        }
        .background(Color.black)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)  // big accessibility text would push the controls off screen
    }
}

/// Keeps things drawn over the full-screen preview clear of the floating controls.
struct ClearOfControls: ViewModifier {
    @Environment(\.chromeInsets) private var insets

    func body(content: Content) -> some View {
        content.padding(insets)
    }
}

extension View {
    func clearOfControls() -> some View { modifier(ClearOfControls()) }
}

private struct ChromeInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    /// How far the floating controls reach in from each edge of the full-screen preview.
    var chromeInsets: EdgeInsets {
        get { self[ChromeInsetsKey.self] }
        set { self[ChromeInsetsKey.self] = newValue }
    }
}

/// The mode names above the shutter: tap one, or swipe across them.
struct ModePicker<Mode: Hashable>: View {
    let modes: [Mode]
    let label: (Mode) -> String
    @Binding var selection: Mode
    var vertical = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 24))
        layout {
            ForEach(modes, id: \.self) { mode in
                Button {
                    choose(mode)
                } label: {
                    Text(label(mode))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selection == mode ? Color.yellow : Color.white)
                }
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
            let distance = vertical ? drag.translation.height : drag.translation.width
            guard abs(distance) > 30, let index = modes.firstIndex(of: selection) else { return }
            let next = index + (distance < 0 ? 1 : -1)
            if modes.indices.contains(next) { choose(modes[next]) }
        })
    }

    private func choose(_ mode: Mode) {
        guard mode != selection else { return }
        Haptics.tap()
        withAnimation(.snappy) { selection = mode }
    }
}

struct ShutterButton: View {
    enum Style { case photo, record, stop }
    let style: Style
    var busy = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                switch style {
                case .photo: Circle().fill(Color.white).frame(width: 60, height: 60)
                case .record: Circle().fill(Color.red).frame(width: 60, height: 60)
                case .stop: RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                }
                if busy { ProgressView().tint(style == .photo ? .black : .white) }
            }
        }
        .buttonStyle(PressScale())
    }
}

/// A round button beside the shutter, with a word under it.
struct SideButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.15), in: Circle())
                Text(title).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A small pill in the top bar.
struct TopPill: View {
    let text: String
    var systemImage: String?
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(text).lineLimit(1)
            }
            .font(.subheadline.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(highlighted ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(highlighted ? Color.black : Color.white)
        }
    }
}

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// A status line over the camera.
struct Banner: View {
    let text: String
    var tint: Color = .black

    var body: some View {
        Text(text)
            .font(.subheadline.bold())
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 480)
            .background(tint.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
    }
}
