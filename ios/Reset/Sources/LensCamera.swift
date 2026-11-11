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
        let angle = await MainActor.run(body: { LensCamera.angle })
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

    /// How far the picture turns to stand upright on the screen: home side right is the sensor's own way up (0°).
    @MainActor static var angle: CGFloat {
        switch Screen.orientation {
        case .landscapeRight: return 0
        case .landscapeLeft: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    fileprivate final class PhotoCatcher: NSObject, AVCapturePhotoCaptureDelegate {
        var done: ((Data?) -> Void)?
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error { Diagnostics.log("Lens photo failed: \(error)") }
            done?(photo.fileDataRepresentation())
            done = nil
        }
    }
}

/// Phil, 2026-11-11: picking 0.5× or 3× must show the view through that lens, not just use it for the photo.
/// The room tracking steps aside while another lens is live (it only runs on 1×) and comes back at 1×.
@MainActor
final class LensLive: ObservableObject {
    @Published private(set) var lens: LensCamera.Lens?
    @Published private(set) var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var observer: NSObjectProtocol?
    /// Something else took the camera (the app went to the background, for one).
    var onInterrupted: (() -> Void)?
    /// One after another: a lens is fully stopped before the next starts.
    private static let queue = DispatchQueue(label: "reset.lens.live", qos: .userInitiated)

    /// False if the lens could not be opened.
    func start(_ lens: LensCamera.Lens) -> Bool {
        stop()
        guard let device = AVCaptureDevice.default(lens.type, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        let output = AVCapturePhotoOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        self.output = output
        self.lens = lens
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The room camera letting go can interrupt it for a moment as it starts: only a lasting one counts.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.session === session, session.isInterrupted else { return }
                        Diagnostics.log("Lens view interrupted")
                        self.onInterrupted?()
                    }
                }
            }
        }
        Self.queue.async { session.startRunning() }
        return true
    }

    /// Stops the lens; `then` runs once the camera is free again.
    func stop(then: (() -> Void)? = nil) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let old = session
        session = nil
        output = nil
        lens = nil
        guard let old else {
            then?()
            return
        }
        Self.queue.async {
            old.stopRunning()
            DispatchQueue.main.async { then?() }
        }
    }

    /// A photo through the live lens, upright for how the phone is held.
    func photo() async -> Data? {
        guard let output, session != nil else { return nil }
        let angle = LensCamera.angle
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let catcher = LensCamera.PhotoCatcher()
        return await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            catcher.done = { done.resume(returning: $0) }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: catcher)
        }
    }
}

/// The live picture from another lens, filling the screen as the room camera does.
struct LensPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class Holder: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            turn()
        }

        func turn() {
            let angle = LensCamera.angle
            if let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
                connection.videoRotationAngle = angle
            }
        }
    }

    func makeUIView(context: Context) -> Holder {
        let view = Holder()
        view.backgroundColor = .black
        view.preview?.videoGravity = .resizeAspectFill
        view.preview?.session = session
        view.turn()
        return view
    }

    func updateUIView(_ view: Holder, context: Context) {
        if view.preview?.session !== session { view.preview?.session = session }
        view.turn()
    }
}

/// The lens buttons above the shutter, like the Camera app's: 0.5×, 1×, 3×.
struct LensChooser: View {
    @Binding var zoom: Double
    var vertical = false

    var body: some View {
        if LensCamera.lenses.count > 1 {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
            layout {
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
                    // On its side the window's tap watcher has each button too (taps there can go astray), and lets go
                    // of it when the buttons leave: left behind, its spot kept switching lenses under the model tools.
                    .caughtTap("Lens \(lens.label)", enabled: vertical) { zoom = lens.zoom }
                }
            }
        }
    }
}
