import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The back (or front) camera, for full resolution stills. Keeps the preview and the saved photos
/// upright in any orientation.
final class Camera: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var error: String?
    @Published var paused = false
    @Published private(set) var isFront = false
    /// How far (degrees clockwise) a saved photo must turn to sit on the live preview. Zero when the
    /// screen turns with the phone; 90 either way when rotation lock keeps the screen upright while
    /// the phone is on its side.
    @Published private(set) var photoToPreview: Double = 0
    private var previewAngle: CGFloat = 90
    private var captureAngle: CGFloat = 90

    private let output = AVCapturePhotoOutput()
    private let frames = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private var lastFrame: CFTimeInterval = 0
    private var frameAngle: CGFloat = 90
    /// Live frames for the guide, upright like saved photos, about five a second, on a background queue.
    var onFrame: ((CIImage) -> Void)?
    private let queue = DispatchQueue(label: "camera.session")
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var pending: [Int64: (Data?) -> Void] = [:]

    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                self?.paused = true
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                self?.paused = false
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard allowed else {
                await MainActor.run {
                    self.error = "Camera access is off. Turn it on in Settings, Match, Camera. You can still import photos."
                }
                return
            }
            queue.async {
                if !self.configured { self.configure(front: false) }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func flip() {
        let front = !isFront
        queue.async { self.configure(front: front) }
    }

    /// Called by the preview once its layer exists, so the preview can be kept level.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = input?.device { makeCoordinator(for: device) }
    }

    /// Re-applies the preview angle, for when the preview's connection appears after the coordinator.
    func levelPreview() {
        guard let coordinator, let connection = previewLayer?.connection else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /// Takes a photo and hands back its file data (HEIC or JPEG), or nil if it failed.
    func capture(_ completion: @escaping (Data?) -> Void) {
        queue.async {
            guard self.session.isRunning, self.output.connection(with: .video)?.isActive == true else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            self.pending[settings.uniqueID] = completion
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configure(front: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !configured {
            session.sessionPreset = .photo
            if session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true  // keeps working in Split View on iPad
            }
        }
        guard let device = Self.device(front: front), let newInput = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.error = "No camera available. You can still import photos." }
            return
        }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            return
        }
        session.addInput(newInput)
        input = newInput
        if !configured, session.canAddOutput(frames) {
            frames.alwaysDiscardsLateVideoFrames = true
            frames.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(frames)
        }
        if !configured, session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
            configured = true
        }
        // Runs after commitConfiguration (deferred above), once the preview connection exists.
        DispatchQueue.main.async {
            self.isFront = front
            self.makeCoordinator(for: device)
        }
    }

    /// The back camera that switches lenses by itself where there is one (close-ups on Pro phones),
    /// otherwise the plain wide camera.
    private static func device(front: Bool) -> AVCaptureDevice? {
        if front { return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        return types.lazy.compactMap { type in found.first { $0.deviceType == type } }.first
    }

    private func makeCoordinator(for device: AVCaptureDevice) {
        guard let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        self.coordinator = coordinator
        previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                self?.previewAngle = angle
                self?.updatePhotoToPreview()
                self?.levelPreview()
            }
        }
        // Kept up to date as the device turns, not set at the moment of capture: setting it then
        // makes the first photo after each rotation fail on some devices.
        captureObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            DispatchQueue.main.async {
                self?.captureAngle = angle
                self?.updatePhotoToPreview()
            }
            self?.frameQueue.async { self?.frameAngle = angle }
            self?.queue.async {
                guard let self, let connection = self.output.connection(with: .video),
                    connection.isVideoRotationAngleSupported(angle)
                else { return }
                connection.videoRotationAngle = angle
            }
        }
    }
}

extension Camera {
    private func updatePhotoToPreview() {
        var degrees = Double(previewAngle - captureAngle).truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees <= -180 { degrees += 360 }
        if photoToPreview != degrees { photoToPreview = degrees }
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onFrame else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrame > 0.2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        // Frames arrive in the sensor's layout; turn them the way photos are saved.
        let orientation: CGImagePropertyOrientation
        switch Int(frameAngle.rounded()) {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = .up
        }
        onFrame(CIImage(cvPixelBuffer: buffer).oriented(orientation))
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let id = photo.resolvedSettings.uniqueID
        queue.async {
            let completion = self.pending.removeValue(forKey: id)
            DispatchQueue.main.async { completion?(data) }
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The live camera filling the screen, as in Reset; the overlay is filled the same way so they line up.
struct CameraPreview: UIViewRepresentable {
    let camera: Camera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(view.previewLayer)
        view.onLayout = { [weak camera] in camera?.levelPreview() }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

/// Outlines of a photo, to show over the live camera instead of the whole photo.
enum Ghost {
    static func edges(of image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let scale = min(1, 1200 / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let edges = CIFilter.edges()
        edges.inputImage = small
        edges.intensity = 6
        let mono = CIFilter.colorControls()
        mono.inputImage = edges.outputImage
        mono.saturation = 0
        mono.contrast = 1.4
        guard let output = mono.outputImage,
            let cg = CIContext().createCGImage(output, from: small.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
