import SwiftUI
import UIKit

/// Phil, 2026-11-21: "cropping for different standard film aspect ratios". A film frame (4:3, 1.66, 16:9, 1.85,
/// 2:1, 2.39) over the live view, the picture outside it dimmed, and every snapshot and screenshot cropped to it.
/// The saved reference itself keeps the whole picture, so the overlay still lines up from any frame.
@MainActor
enum FilmFrame {
    static let key = "filmAspect"

    /// Where the frame is on the screen now (window points), and the screen's size, set by the matte on show.
    static var shownFrame: CGRect?
    static var screen: CGSize = .zero

    static var aspect: FilmAspect { FilmAspect(saved: UserDefaults.standard.double(forKey: key)) }

    /// The photo cut to the frame shown now, or as it is when no frame is on. The photo fills the screen as the
    /// camera does (cut to fit), so a lens photo of another shape is cropped where the frame sat over it.
    static func crop(_ image: UIImage) -> UIImage {
        guard aspect != .full, let frame = shownFrame, screen.width > 0 else { return image }
        let upright = uprighted(image)
        guard let cg = upright.cgImage else { return image }
        let pixels = CGSize(width: cg.width, height: cg.height)
        guard let part = FilmFrameMath.crop(frame: frame, screen: screen, picture: pixels),
              let cropped = cg.cropping(to: part.integral) else { return image }
        Diagnostics.log(String(format: "Film frame %@: photo %.0fx%.0f cropped to %dx%d", aspect.word, pixels.width, pixels.height, cropped.width, cropped.height))
        return UIImage(cgImage: cropped, scale: upright.scale, orientation: .up)
    }

    /// The same photo with its pixels the right way up, so a crop in screen terms lands where it should.
    private static func uprighted(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }
}

/// The frame over the live view: outside it dimmed, a thin line round it. Stays on in the clean view (it is the
/// framing), never takes a touch. Lay it over the whole picture, like the other overlays.
struct FilmFrameMatte: View {
    @AppStorage(FilmFrame.key) private var saved = 0.0
    @Environment(\.chromeInsets) private var insets

    var body: some View {
        GeometryReader { geometry in
            let aspect = FilmAspect(saved: saved)
            let area = CGRect(origin: .zero, size: geometry.size)
                .inset(by: UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing))
            let frame = aspect.ratio.map { FilmFrameMath.frame(ratio: $0, in: area) }
            let global = geometry.frame(in: .global)
            ZStack {
                Color.clear
                if let frame {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(frame)
                    }
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    // Just outside the frame, so a cropped photo never carries it.
                    Path { $0.addRect(frame.insetBy(dx: -1, dy: -1)) }
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                }
            }
            .onAppear { remember(frame, global) }
            .onChange(of: frame) { _, new in remember(new, global) }
            .onChange(of: global) { _, new in remember(frame, new) }
            .onDisappear { FilmFrame.shownFrame = nil }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.25), value: saved)
    }

    private func remember(_ frame: CGRect?, _ global: CGRect) {
        FilmFrame.shownFrame = frame?.offsetBy(dx: global.minX, dy: global.minY)
        // The matte covers the whole window, so its size is the screen's.
        FilmFrame.screen = CGSize(width: global.maxX, height: global.maxY)
    }
}

/// The word that picks the frame, in the picture's bottom corner: FRAME FULL ›, FRAME 1.85 › … A tap moves on to the
/// next shape, a hold lists them all. Yellow while a frame is on.
struct FilmFrameWord: View {
    @AppStorage(FilmFrame.key) private var saved = 0.0
    var showToast: ((String) -> Void)? = nil
    @State private var listing = false
    /// A hold opens the list; the button's own tap when the finger lifts must not then move on as well.
    @MainActor private static var heldAt = Date.distantPast

    private var aspect: FilmAspect { FilmAspect(saved: saved) }

    var body: some View {
        Button { TapGate.run("Film frame", step) } label: {
            Text("FRAME \(aspect.word) ›")
                .font(Theme.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(aspect == .full ? Color.white : Theme.active)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .frame(minHeight: 40)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in hold() })
        .caughtTap("Film frame", hold: hold, perform: step)
        .confirmationDialog("Film frame", isPresented: $listing, titleVisibility: .visible) {
            ForEach(FilmAspect.allCases) { choice in
                Button(choice == aspect ? "\(choice.menuName) ✓" : choice.menuName) { pick(choice) }
            }
        } message: {
            Text("Snapshots and screenshots are cropped to the frame.")
        }
        .accessibilityLabel(aspect == .full ? "Film frame off" : "Film frame \(aspect.word)")
    }

    private func hold() {
        guard !listing else { return }
        Self.heldAt = Date()
        Haptics.tap()
        listing = true
    }

    private func step() {
        guard Date().timeIntervalSince(Self.heldAt) > 1.2, !listing else { return }
        pick(aspect.next)
    }

    private func pick(_ choice: FilmAspect) {
        Haptics.tap()
        saved = choice.rawValue
        Diagnostics.log("Film frame: \(choice.word)")
        if choice != .full, HintStore.shouldShow("filmFrameTip") {
            HintStore.shown("filmFrameTip")
            showToast?("Photos are cropped to the frame. Tap FRAME for the next shape, hold it for the list")
        }
    }
}
