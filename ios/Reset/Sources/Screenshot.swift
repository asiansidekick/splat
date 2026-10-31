import ARKit
import SwiftUI
import UIKit

/// A screenshot of the live view, saved straight to Photos (Phil, 2026-10-30): the camera, the
/// ghost, guides, models and measurements, as they are on the screen right now.
enum Screenshot {
    /// The whole screen as it looks. The camera is a Metal view, which some captures of a window
    /// leave black; if its part comes out black, the camera view's own picture (camera, models and
    /// measurements, without the overlays) is used instead.
    @MainActor static func capture(camera: ARSCNView?) -> UIImage? {
        guard let window = keyWindow else { return camera?.snapshot() }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let camera, camera.window != nil, isBlack(image, in: camera.convert(camera.bounds, to: window)) {
            Diagnostics.log("Screenshot: window capture was black, using the camera view's own picture")
            return camera.snapshot()
        }
        return image
    }

    @MainActor private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    /// Whether the part of the picture in `rect` (in points) is all but black.
    static func isBlack(_ image: UIImage, in rect: CGRect) -> Bool {
        guard let cg = image.cgImage, rect.width > 1, rect.height > 1 else { return false }
        let scale = image.scale
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixels.isEmpty, let part = cg.cropping(to: pixels) else { return false }
        // Squashed to 8 by 8 grey pixels: their average is the brightness of the whole area.
        var grey = [UInt8](repeating: 0, count: 64)
        guard let context = CGContext(
            data: &grey, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        context.interpolationQuality = .medium
        context.draw(part, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        return grey.reduce(0) { $0 + Int($1) } / 64 < 4
    }
}

/// While a screenshot is being taken the controls, banners and guides are hidden, so the picture
/// holds only what the camera sees: the ghost, 3D models, dimensions and notes (Phil, 2026-10-30).
final class ScreenshotMode: ObservableObject {
    static let shared = ScreenshotMode()
    @Published var clean = false
}

/// Hides a control or overlay while a screenshot is being taken.
struct HiddenInScreenshots: ViewModifier {
    @ObservedObject private var mode = ScreenshotMode.shared

    func body(content: Content) -> some View {
        content
            .opacity(mode.clean ? 0 : 1)
            .animation(nil, value: mode.clean)
    }
}

extension View {
    func hiddenInScreenshots() -> some View { modifier(HiddenInScreenshots()) }
}

private struct ChromeVerticalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for controls in the landscape side column, where they stack instead of sitting side by side.
    var chromeVertical: Bool {
        get { self[ChromeVerticalKey.self] }
        set { self[ChromeVerticalKey.self] = newValue }
    }
}

/// The screenshot button beside the control it sits with in the main row: to its left in portrait,
/// above it in the landscape column. One tap saves a clean picture of the live view to Photos.
struct WithScreenshot<Content: View>: View {
    let camera: () -> ARSCNView?
    let toast: (String) -> Void
    /// Diameter of the screenshot button (the capture screen makes it as big as the shutter).
    var size: CGFloat = 40
    @ViewBuilder let content: () -> Content
    @Environment(\.chromeVertical) private var vertical

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            ScreenshotButton(camera: camera, toast: toast, size: size)
            content()
        }
    }
}

/// One tap saves what the camera shows, without the controls, to Photos.
struct ScreenshotButton: View {
    let camera: () -> ARSCNView?
    let toast: (String) -> Void
    var size: CGFloat = 40

    var body: some View {
        Button {
            Task { @MainActor in
                // Hide the controls, give the screen a moment to redraw, take the picture, bring them back.
                ScreenshotMode.shared.clean = true
                try? await Task.sleep(for: .milliseconds(180))
                let image = Screenshot.capture(camera: camera())
                ScreenshotMode.shared.clean = false
                guard let image else {
                    toast("Could not take the screenshot")
                    return
                }
                Haptics.success()
                let saved = await PhotoLibrary.save([image])
                toast(saved ? "Screenshot saved to Photos" : "Allow Photos in Settings, Reset, Photos to save there")
            }
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.2), in: Circle())
                .shadow(color: .black.opacity(0.6), radius: 3)
        }
        .hiddenInScreenshots()
        .accessibilityLabel("Screenshot to Photos")
    }
}
