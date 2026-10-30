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
    /// Live frames for the guide, upright like saved photos, about five a second, on a background
    /// queue, with the latest LiDAR depth when there is one.
    var onFrame: ((CIImage, DepthGrid?) -> Void)?
    private let depthOutput = AVCaptureDepthDataOutput()
    private let depthLock = NSLock()
    private var latestDepth: DepthGrid?
    private var lastDepth: CFTimeInterval = 0
    /// This iPhone or iPad has a LiDAR camera, and whether it is being used now.
    @Published private(set) var hasLiDAR = false
    @Published private(set) var usingLiDAR = false
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
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            self.pending[settings.uniqueID] = completion
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Whether to use the LiDAR camera where there is one (Settings in the ••• menu). On by default.
    static var lidarWanted: Bool { UserDefaults.standard.object(forKey: "useLiDAR") as? Bool ?? true }

    /// Picks the LiDAR camera again (or not) after the setting changes.
    func reconfigure() {
        let front = isFront
        queue.async { self.configure(front: front) }
    }

    private func configure(front: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !configured, session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true  // keeps working in Split View on iPad
        }
        let lidarExists = !front && Self.lidarDevice() != nil
        var depth = false
        var device: AVCaptureDevice?
        var newInput: AVCaptureDeviceInput?
        if let input { session.removeInput(input) }
        if session.outputs.contains(depthOutput) { session.removeOutput(depthOutput) }
        // The LiDAR camera first if wanted; if anything about it fails, the ordinary camera.
        if lidarExists, Self.lidarWanted, let lidar = Self.lidarDevice(), let lidarInput = try? AVCaptureDeviceInput(device: lidar),
            session.canAddInput(lidarInput)
        {
            session.addInput(lidarInput)
            if Self.chooseDepthFormat(lidar), session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                depthOutput.isFilteringEnabled = true
                depthOutput.alwaysDiscardsLateDepthData = true
                depthOutput.setDelegate(self, callbackQueue: frameQueue)
                device = lidar
                newInput = lidarInput
                depth = true
            } else {
                session.removeInput(lidarInput)
            }
        }
        if newInput == nil {
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            guard let plain = Self.device(front: front), let plainInput = try? AVCaptureDeviceInput(device: plain),
                session.canAddInput(plainInput)
            else {
                if let input, session.canAddInput(input) { session.addInput(input) }
                DispatchQueue.main.async { self.error = "No camera available. You can still import photos." }
                return
            }
            session.addInput(plainInput)
            device = plain
            newInput = plainInput
        }
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
        // Full size photos from whichever camera and format is in use.
        if let device, session.outputs.contains(output), let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            output.maxPhotoDimensions = largest
        }
        if !depth { setDepth(nil) }
        guard let device else { return }
        // Runs after commitConfiguration (deferred above), once the preview connection exists.
        DispatchQueue.main.async {
            self.isFront = front
            self.hasLiDAR = lidarExists
            self.usingLiDAR = depth
            self.makeCoordinator(for: device)
        }
    }

    private static func lidarDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
    }

    /// A 4:3 format with LiDAR depth, the sharpest up to 1920 wide for the live picture, and its
    /// finest depth map. False if there is none.
    private static func chooseDepthFormat(_ device: AVCaptureDevice) -> Bool {
        let candidates = device.formats.filter { format in
            let size = format.formatDescription.dimensions
            return !format.supportedDepthDataFormats.isEmpty && size.width <= 1920
                && abs(Double(size.width) / Double(max(size.height, 1)) - 4.0 / 3.0) < 0.01
        }
        func photoPixels(_ format: AVCaptureDevice.Format) -> Int32 {
            format.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
        }
        guard let format = candidates.max(by: { a, b in
            let pa = photoPixels(a), pb = photoPixels(b)
            return pa != pb ? pa < pb : a.formatDescription.dimensions.width < b.formatDescription.dimensions.width
        }) else { return false }
        let depthFormats = format.supportedDepthDataFormats.filter {
            let type = $0.formatDescription.mediaSubType.rawValue
            return type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DepthFloat16
        }
        guard let depthFormat = depthFormats.max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }),
            (try? device.lockForConfiguration()) != nil
        else { return false }
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        device.unlockForConfiguration()
        return true
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
        onFrame(CIImage(cvPixelBuffer: buffer).oriented(orientation), currentDepth())
    }
}

extension Camera: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastDepth > 0.15 else { return }
        lastDepth = now
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map), width > 0, height > 0 else { return }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { values[y * width + x] = row[x] }
        }
        // Sensor-sideways like the frames; turned upright the same way.
        let turns = Int((frameAngle / 90).rounded())
        setDepth(DepthGrid(width: width, height: height, values: values).rotated(quarterTurns: turns))
    }
}

extension Camera {
    /// The latest LiDAR depth, upright like saved photos; nil without LiDAR.
    func currentDepth() -> DepthGrid? {
        depthLock.lock()
        defer { depthLock.unlock() }
        return latestDepth
    }

    fileprivate func setDepth(_ grid: DepthGrid?) {
        depthLock.lock()
        latestDepth = grid
        depthLock.unlock()
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
