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

/// The top-bar button: one tap saves what is on the screen to Photos.
struct ScreenshotButton: View {
    let camera: () -> ARSCNView?
    let toast: (String) -> Void

    var body: some View {
        Button {
            guard let image = Screenshot.capture(camera: camera()) else {
                toast("Could not take the screenshot")
                return
            }
            Haptics.success()
            Task {
                let saved = await PhotoLibrary.save([image])
                toast(saved ? "Screenshot saved to Photos" : "Allow Photos in Settings, Reset, Photos to save there")
            }
        } label: {
            Image(systemName: "camera.viewfinder").font(.title3)
        }
        .accessibilityLabel("Screenshot to Photos")
    }
}
