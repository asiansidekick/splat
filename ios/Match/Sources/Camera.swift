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
    /// Set on the main thread and read on the frame queue, so kept behind a lock.
    var onFrame: ((CIImage, DepthGrid?) -> Void)? {
        get { frameLock.lock(); defer { frameLock.unlock() }; return frameHandler }
        set { frameLock.lock(); frameHandler = newValue; frameLock.unlock() }
    }
    private var frameHandler: ((CIImage, DepthGrid?) -> Void)?
    /// One-shot request for the next frame as a picture, for pausing. Behind the same lock.
    private var grabHandler: ((UIImage?) -> Void)?
    private static let stillContext = CIContext()
    private let frameLock = NSLock()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let depthLock = NSLock()
    private var latestDepth: DepthGrid?
    private var latestDepthTime: CFTimeInterval = 0
    private var lastDepth: CFTimeInterval = 0
    /// When a camera frame last arrived, to notice the LiDAR camera stalling.
    private var lastAnyFrame: CFTimeInterval = 0
    private var watchdog: Timer?
    /// The LiDAR camera stalled this session: stay on the ordinary camera until the app restarts.
    private var lidarFailed = false
    /// Close-ups (makeup detail) use the ordinary camera, which switches to its macro lens; the
    /// LiDAR camera is the main lens alone and can't focus that close.
    private var closeUp = false
    @Published private(set) var notice: String?
    /// This iPhone or iPad has a LiDAR camera, and whether it is being used now.
    @Published private(set) var hasLiDAR = false
    @Published private(set) var usingLiDAR = false
    /// This side's camera has a light (the back camera's flash, used as a torch).
    @Published private(set) var hasTorch = false
    /// The rear lens stops on offer (0.5, 1, 3…), as the Camera app shows them. Empty on the front.
    @Published private(set) var zoomStops: [Double] = []
    /// The zoom in use, in those same units.
    @Published private(set) var zoom: Double = 1
    private let zoomLock = NSLock()
    private var zoomWanted = 1.0
    private var zoomTarget: Double {
        get { zoomLock.lock(); defer { zoomLock.unlock() }; return zoomWanted }
        set { zoomLock.lock(); zoomWanted = newValue; zoomLock.unlock() }
    }
    /// How bright the torch should be (0 = off, up to 1). Kept so it comes back after a camera switch.
    private var torchLevel: Float = 0
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
                self?.queue.async { self?.applyTorch() }
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
                // Stopping the camera put the torch out.
                self.applyTorch()
            }
            await MainActor.run { self.startWatchdog() }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        queue.async { self.session.stopRunning() }
    }

    /// Some LiDAR setups stop sending frames after a few (reported by other developers). If frames
    /// stop for three seconds while the camera should be running, go back to the ordinary camera.
    private func startWatchdog() {
        watchdog?.invalidate()
        frameQueue.async { self.lastAnyFrame = CACurrentMediaTime() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.usingLiDAR, !self.paused, !self.lidarFailed else { return }
            let last = self.frameQueue.sync { self.lastAnyFrame }
            guard CACurrentMediaTime() - last > 3 else { return }
            self.lidarFailed = true
            self.notice = "The depth camera stopped responding, so Match switched to the ordinary camera."
            self.reconfigure()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.notice = nil }
        }
    }

    /// Close-ups use the ordinary camera (macro lens on Pro iPhones); other angles can use LiDAR.
    /// Picks a lens or zoom (0.5 = ultra wide, 1 = main, 3 = telephoto where there is one). The
    /// LiDAR camera is the main lens alone, so any other zoom uses the ordinary camera and depth
    /// goes quiet until back at 1.
    func setZoom(_ value: Double) {
        guard !isFront, value != zoom else { return }
        let wasPlain = zoom == 1
        zoomTarget = value
        zoom = value
        if hasLiDAR, Self.lidarWanted, wasPlain != (value == 1) {
            reconfigure()
        } else {
            queue.async { self.applyZoom() }
        }
    }

    /// Whether a zoom stop is one the LiDAR camera can't serve.
    private var zoomed: Bool { zoomTarget != 1 }

    /// On the session queue.
    private func applyZoom() {
        guard let device = input?.device else { return }
        let raw = min(max(zoomTarget * Self.zoomBase(device), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = raw
        } catch {
            // Zoom stays where it was.
        }
    }

    /// 2 on cameras that start at the ultra wide (zoom factor 1 is 0.5x), else 1.
    private static func zoomBase(_ device: AVCaptureDevice) -> Double {
        device.constituentDevices.first?.deviceType == .builtInUltraWideCamera ? 2 : 1
    }

    /// The rear stops: ultra wide if the phone has one, the main lens, then each telephoto, and a
    /// 2x crop on phones with nothing longer.
    private static func rearZoomStops() -> [Double] {
        guard let rear = Self.device(front: false) else { return [] }
        let device = rear
        let base = zoomBase(device)
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) / base }
        var stops: [Double] = base == 2 ? [0.5, 1] : [1]
        stops += base == 2 ? Array(switches.dropFirst()) : switches
        if !stops.contains(where: { $0 >= 2 }), device.maxAvailableVideoZoomFactor >= 2 * base { stops.append(2) }
        return Array(Set(stops.map { ($0 * 10).rounded() / 10 })).sorted()
    }

    /// How far the saved photos and frames are turned to sit upright (0, 90, 180 or 270).
    var uprightAngle: Double { Double(captureAngle) }

    /// The lens in use: the tangent of half its field of view along the sensor's long side, at the
    /// zoom in use, and that side over the short one. Lens distortion is already taken out by iOS
    /// (geometric distortion correction is on by default), so the lens behaves as a pinhole.
    var lensGeometry: (tanHalfLong: Double, sensorRatio: Double)? {
        guard let device = input?.device else { return nil }
        let fov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        guard fov > 0.05, fov < 3 else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let long = Double(max(dims.width, dims.height)), short = Double(min(dims.width, dims.height))
        guard short > 0 else { return nil }
        return (tan(fov / 2) / max(Double(device.videoZoomFactor), 1), long / short)
    }

    func setCloseUp(_ on: Bool) {
        guard on != closeUp else { return }
        closeUp = on
        if hasLiDAR, Self.lidarWanted, !isFront { reconfigure() }
        // The front camera has no macro lens, so nothing changes there.
    }

    /// Turns the torch on at this brightness (0...1), or off at 0. Does nothing without a torch.
    func setTorch(_ level: Float) {
        let level = max(0, min(1, level))
        queue.async {
            self.torchLevel = level
            self.applyTorch()
        }
    }

    /// On the session queue. Switching cameras turns the torch off, so this runs after each switch too.
    private func applyTorch() {
        guard let device = input?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if torchLevel > 0.01, device.isTorchAvailable {
                // Too low a level is refused; the hardware's own cap applies when the phone is hot.
                try device.setTorchModeOn(level: min(max(torchLevel, 0.02), AVCaptureDevice.maxAvailableTorchLevel))
            } else if device.torchMode != .off {
                device.torchMode = .off
            }
        } catch {
            // The torch is a nicety: if the phone refuses it (too hot, in use), carry on without it.
        }
    }

    func flip() {
        let front = !isFront
        let skipLiDAR = lidarFailed || closeUp || (!front && zoomed)
        queue.async { self.configure(front: front, skipLiDAR: skipLiDAR) }
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
        let skipLiDAR = lidarFailed || closeUp || (!front && zoomed)
        queue.async { self.configure(front: front, skipLiDAR: skipLiDAR) }
    }

    private func configure(front: Bool, skipLiDAR: Bool = false) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !configured, session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true  // keeps working in Split View on iPad
        }
        // LiDAR on the back of Pro phones; the Face ID (TrueDepth) camera on the front.
        let lidarExists = Self.depthDevice(front: front) != nil
        var depth = false
        var device: AVCaptureDevice?
        var newInput: AVCaptureDeviceInput?
        if let input { session.removeInput(input) }
        if session.outputs.contains(depthOutput) { session.removeOutput(depthOutput) }
        // The LiDAR camera first if wanted; if anything about it fails, the ordinary camera.
        // Apple's order: the format first, then the input, then the depth output.
        if lidarExists, Self.lidarWanted, !skipLiDAR, let lidar = Self.depthDevice(front: front), Self.chooseDepthFormat(lidar),
            let lidarInput = try? AVCaptureDeviceInput(device: lidar), session.canAddInput(lidarInput)
        {
            if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }
            session.addInput(lidarInput)
            if session.canAddOutput(depthOutput) {
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
        // Photos, live frames and depth all the right way round, front camera too: the guide
        // compares them with each other, and only the screen shows a mirror.
        for connection in [frames.connection(with: .video), output.connection(with: .video), depthOutput.connection(with: .depthData)] {
            guard let connection, connection.isVideoMirroringSupported else { continue }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        guard let device else { return }
        // After commitConfiguration (deferred above), on this queue: the new camera's torch.
        let torch = device.hasTorch
        let stops = front ? [] : Self.rearZoomStops()
        // Lenses change with the camera: the zoom asked for goes back on, or 1 if this side lacks it.
        if front || !stops.contains(zoomTarget) { zoomTarget = 1 }
        let zoomNow = zoomTarget
        queue.async {
            self.applyTorch()
            self.applyZoom()
        }
        // Runs after commitConfiguration (deferred above), once the preview connection exists.
        DispatchQueue.main.async {
            self.hasTorch = torch
            self.zoomStops = stops
            self.zoom = zoomNow
            self.isFront = front
            self.hasLiDAR = lidarExists
            self.usingLiDAR = depth
            self.makeCoordinator(for: device)
        }
    }

    /// The camera on this side that measures distance: LiDAR on the back, TrueDepth on the front.
    private static func depthDevice(front: Bool) -> AVCaptureDevice? {
        front ? AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            : AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
    }

    /// A 4:3 format with LiDAR depth, the sharpest up to 1920 wide for the live picture, and its
    /// finest depth map. False if there is none.
    private static func chooseDepthFormat(_ device: AVCaptureDevice) -> Bool {
        let candidates = device.formats.filter { format in
            let size = format.formatDescription.dimensions
            return !format.supportedDepthDataFormats.isEmpty && size.width <= 1920 && !format.isVideoBinned
                && format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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
        let now = CACurrentMediaTime()
        lastAnyFrame = now
        frameLock.lock()
        let grab = grabHandler
        grabHandler = nil
        frameLock.unlock()
        if let grab {
            var still: UIImage?
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let image = CIImage(cvPixelBuffer: buffer).oriented(upright)
                if let cg = Self.stillContext.createCGImage(image, from: image.extent) { still = UIImage(cgImage: cg) }
            }
            DispatchQueue.main.async { grab(still) }
        }
        guard let onFrame else { return }
        // Five checks a second; fewer when the phone is getting hot, so it doesn't overheat on a long day.
        let thermal = ProcessInfo.processInfo.thermalState
        let interval = thermal == .critical ? 1.0 : thermal == .serious ? 0.5 : 0.2
        guard now - lastFrame > interval, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        // Frames arrive in the sensor's layout; turn them the way photos are saved.
        onFrame(CIImage(cvPixelBuffer: buffer).oriented(upright), currentDepth())
    }

    /// How frames are turned to be upright like saved photos.
    private var upright: CGImagePropertyOrientation {
        switch Int(frameAngle.rounded()) {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }

    /// The next camera frame as an upright picture (nil if none arrives), to freeze the view.
    func grabFrame(_ completion: @escaping (UIImage?) -> Void) {
        frameLock.lock()
        grabHandler = completion
        frameLock.unlock()
        // No frame in a second (camera stopped): give up rather than leave the button waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let pending = self.grabHandler
            self.grabHandler = nil
            self.frameLock.unlock()
            pending?(nil)
        }
    }
}

extension Camera: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastDepth > 0.15 else { return }
        // Only true distances in metres; relative depth would give wrong centimetres.
        guard depthData.depthDataAccuracy == .absolute else { return }
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
    /// Older than a second counts as none, so a stalled depth stream never gives old distances.
    func currentDepth() -> DepthGrid? {
        depthLock.lock()
        defer { depthLock.unlock() }
        return CACurrentMediaTime() - latestDepthTime < 1 ? latestDepth : nil
    }

    fileprivate func setDepth(_ grid: DepthGrid?) {
        depthLock.lock()
        latestDepth = grid
        latestDepthTime = CACurrentMediaTime()
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
