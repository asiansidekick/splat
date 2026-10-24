import ARKit
import CoreImage
import ImageIO
import Foundation

/// Records a reference: walk around the set and the recorder keeps a photo (plus LiDAR depth when
/// switched on) every time the camera has moved a little, then saves ARKit's map of the room so
/// the reference can be found again later, offline.
@MainActor
final class Recorder: NSObject, ObservableObject, ARSessionDelegate {
    @Published var keyframeCount = 0
    @Published var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published var trackingNormal = false
    @Published var saving = false
    @Published var error: String?

    let session = ARSession()
    private var reference: Reference?
    private var lastSaved: (position: SIMD3<Float>, forward: SIMD3<Float>)?
    private let writeQueue = DispatchQueue(label: "keyframe-writer")
    private let ciContext = CIContext()
    private var pendingWrites = 0

    /// A new keyframe is kept after the camera moves this far or turns this much.
    private let minMove: Float = 0.2  // metres
    private let minTurn: Float = 12 * .pi / 180
    private let maxKeyframes = 400

    nonisolated static var lidarAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start(scene: String, setup: String, name: String, useLiDAR: Bool) {
        let id = UUID()
        do {
            try FileManager.default.createDirectory(at: ReferenceStore.folder(for: id), withIntermediateDirectories: true)
        } catch {
            self.error = error.localizedDescription
            return
        }
        reference = Reference(id: id, scene: scene, setup: setup, name: name, created: Date(), keyframes: [])
        lastSaved = nil
        keyframeCount = 0

        let config = ARWorldTrackingConfiguration()
        if useLiDAR && Recorder.lidarAvailable {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Saves the room map and the keyframe list. Returns the finished reference.
    func finish() async -> Reference? {
        guard var reference else { return nil }
        saving = true
        defer { saving = false }
        // Let queued photo writes finish first.
        await withCheckedContinuation { continuation in writeQueue.async { continuation.resume() } }
        do {
            let map: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
                session.getCurrentWorldMap { map, error in
                    if let map {
                        continuation.resume(returning: map)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    }
                }
            }
            try ReferenceStore.saveWorldMap(map, for: reference.id)
            reference.keyframes = self.reference?.keyframes ?? []
            try ReferenceStore.save(reference)
            session.pause()
            return reference
        } catch {
            self.error = "Could not save the room map: \(error.localizedDescription). Keep moving slowly until the status says Mapped, then try again."
            return nil
        }
    }

    func cancel() {
        session.pause()
        if let reference { ReferenceStore.delete(reference) }
        reference = nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // The session delivers frames on the main queue (no delegateQueue is set).
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        let isNormal: Bool
        if case .normal = frame.camera.trackingState { isNormal = true } else { isNormal = false }
        if trackingNormal != isNormal { trackingNormal = isNormal }
        if mappingStatus != frame.worldMappingStatus { mappingStatus = frame.worldMappingStatus }
        guard isNormal, var reference, reference.keyframes.count < maxKeyframes, pendingWrites < 3 else { return }

        let transform = frame.camera.transform
        let position = transform.columns.3.xyz
        let forward = -transform.columns.2.xyz
        if let last = lastSaved {
            let moved = simd_distance(position, last.position)
            let turned = acos(min(1, max(-1, simd_dot(forward, last.forward))))
            if moved < minMove && turned < minTurn { return }
        }
        lastSaved = (position, forward)
        // Copy what the keyframe needs now; never keep the frame itself.
        let snapshot = FrameSnapshot(frame)

        let index = reference.keyframes.count
        let imageFile = String(format: "frame_%04d.jpg", index)
        let depthFile = snapshot.depth == nil ? nil : String(format: "depth_%04d.bin", index)
        let keyframe = Keyframe(
            imageFile: imageFile,
            depthFile: depthFile,
            transform: flatten(transform),
            intrinsics: flatten(snapshot.intrinsics),
            imageWidth: snapshot.imageWidth,
            imageHeight: snapshot.imageHeight,
            depthWidth: snapshot.depthWidth,
            depthHeight: snapshot.depthHeight)
        reference.keyframes.append(keyframe)
        self.reference = reference
        keyframeCount = reference.keyframes.count

        let folder = ReferenceStore.folder(for: reference.id)
        let context = ciContext
        pendingWrites += 1
        writeQueue.async {
            if let jpeg = context.jpegRepresentation(
                of: snapshot.image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
            {
                try? jpeg.write(to: folder.appendingPathComponent(imageFile))
            }
            if let depthFile, let depth = snapshot.depth {
                try? depth.write(to: folder.appendingPathComponent(depthFile))
            }
            Task { @MainActor in self.pendingWrites -= 1 }
        }
    }
}

/// The parts of an ARFrame a keyframe needs, copied out so the frame can be released.
struct FrameSnapshot: @unchecked Sendable {
    let image: CIImage
    let intrinsics: simd_float3x3
    let imageWidth: Int
    let imageHeight: Int
    let depth: Data?
    let depthWidth: Int
    let depthHeight: Int

    init(_ frame: ARFrame) {
        let pixels = frame.capturedImage
        // Copy the camera image so ARKit can reuse its buffer.
        image = CIImage(cvPixelBuffer: pixels).copyRendered()
        intrinsics = frame.camera.intrinsics
        imageWidth = CVPixelBufferGetWidth(pixels)
        imageHeight = CVPixelBufferGetHeight(pixels)
        if let depthMap = frame.sceneDepth?.depthMap {
            depth = DepthMap.copy(depthMap)
            depthWidth = CVPixelBufferGetWidth(depthMap)
            depthHeight = CVPixelBufferGetHeight(depthMap)
        } else {
            depth = nil
            depthWidth = 0
            depthHeight = 0
        }
    }
}

private let snapshotContext = CIContext()

extension CIImage {
    /// Renders the image into a new bitmap-backed CIImage, detaching it from the source buffer.
    func copyRendered() -> CIImage {
        guard let cg = snapshotContext.createCGImage(self, from: extent) else { return self }
        return CIImage(cgImage: cg)
    }
}

enum DepthMap {
    /// Copies a Float32 depth buffer (metres) into tightly packed Data.
    static func copy(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        var data = Data(capacity: width * height * 4)
        for row in 0..<height {
            data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return data
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
