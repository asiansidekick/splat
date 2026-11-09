import AVFoundation
import SwiftUI
import UIKit

/// Phil, 2026-11-09: snapshots on the other lenses. The room tracking only runs on the 1× camera, so for a 0.5× or
/// 3× snapshot it pauses, the photo is taken on that lens, and tracking carries on. The photo is a plain picture
/// (no room map), saved as a photo reference that can be the overlay.
enum LensCamera {
    struct Lens: Hashable {
        let zoom: Double
        let type: AVCaptureDevice.DeviceType
        var label: String { zoom == 0.5 ? "0.5×" : "\(Int(zoom))×" }
    }

    /// The back lenses this phone has, widest first.
    static let lenses: [Lens] = {
        var found: [Lens] = []
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            found.append(Lens(zoom: 0.5, type: .builtInUltraWideCamera))
        }
        found.append(Lens(zoom: 1, type: .builtInWideAngleCamera))
        if let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            // 2× on some phones, 3× or 5× on others: the telephoto's field of view against the wide's.
            let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.activeFormat.videoFieldOfView ?? 69
            let ratio = Double(tan(Double(wide) * .pi / 360) / tan(Double(tele.activeFormat.videoFieldOfView) * .pi / 360))
            found.append(Lens(zoom: max(2, ratio.rounded()), type: .builtInTelephotoCamera))
        }
        return found
    }()

    /// Takes one photo on `lens`, upright for how the phone is held. The AR session must be paused first.
    static func photo(_ lens: Lens) async -> Data? {
        guard let device = AVCaptureDevice.default(lens.type, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        let output = AVCapturePhotoOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
        let angle: CGFloat
        // The screen's turn: home side right is the sensor's own way up (0°).
        switch await MainActor.run(body: { Screen.orientation }) {
        case .landscapeRight: angle = 0
        case .landscapeLeft: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                done.resume()
            }
        }
        // A moment for focus and exposure to settle.
        try? await Task.sleep(for: .seconds(0.7))
        let catcher = PhotoCatcher()
        let data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            catcher.done = { done.resume(returning: $0) }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: catcher)
        }
        session.stopRunning()
        return data
    }

    private final class PhotoCatcher: NSObject, AVCapturePhotoCaptureDelegate {
        var done: ((Data?) -> Void)?
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error { Diagnostics.log("Lens photo failed: \(error)") }
            done?(photo.fileDataRepresentation())
            done = nil
        }
    }
}

/// The lens buttons above the shutter, like the Camera app's: 0.5×, 1×, 3×.
struct LensChooser: View {
    @Binding var zoom: Double

    var body: some View {
        if LensCamera.lenses.count > 1 {
            HStack(spacing: 4) {
                ForEach(LensCamera.lenses, id: \.self) { lens in
                    Button {
                        zoom = lens.zoom
                        Haptics.tap()
                    } label: {
                        Text(lens.label)
                            .font(Theme.font(size: 12, weight: .bold))
                            .frame(minWidth: 34, minHeight: 30)
                            .background(zoom == lens.zoom ? Theme.accent : Color.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(zoom == lens.zoom ? Theme.onAccent : Color.white)
                            .fixedSize()
                    }
                }
            }
        }
    }
}
