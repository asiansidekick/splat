import Foundation
import ImageIO
import Photos
import UIKit
import simd

/// Saving to and importing from the iPhone's Photos library.
enum PhotoLibrary {
    /// Adds the images to Photos. Asks for permission the first time; returns false if refused.
    /// With `stamp`, and the Help switch on, each photo carries the slate details in its metadata.
    static func save(_ images: [UIImage], stamp: PhotoStamp? = nil) async -> Bool {
        guard !images.isEmpty else { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Diagnostics.log("Photos: no permission to add (\(status.rawValue))")
            await MainActor.run { SettingsPrompt.photos() }
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images {
                    if let stamp, PhotoMetadata.enabled, let data = PhotoMetadata.stamped(image, with: stamp) {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: nil)
                    } else {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }
            }
            return true
        } catch {
            Diagnostics.log("Photos save failed: \(error)")
            return false
        }
    }

    /// A reference's first photo and all its snapshots, upright, for saving to Photos.
    static func images(of reference: Reference) -> [UIImage] {
        let folder = ReferenceStore.folder(for: reference.id)
        let frames = Array(reference.keyframes.prefix(1)) + reference.snapshots.map(\.frame)
        return frames.compactMap { frame in
            guard let cg = UIImage(contentsOfFile: folder.appendingPathComponent(frame.imageFile).path)?.cgImage else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: frame.uprightOrientation)
        }
    }

    /// Phil, 2026-11-13: any saved frame as a plain see-through overlay for a different place, where the reference's
    /// own room cannot be found. It becomes a photo-only reference (hand-aligned over the live camera, with the live
    /// LiDAR there for measuring). Asking again for the same frame gives the one already made.
    static func makeOverlay(from reference: Reference, frame: Keyframe, number: Int) throws -> Reference {
        let key = "overlay.\(reference.id.uuidString).\(frame.imageFile)"
        if let text = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: text),
           let existing = try? ReferenceStore.load(metaURL: ReferenceStore.folder(for: id).appendingPathComponent("reference.json")) {
            return existing
        }
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(frame.imageFile)
        guard let cg = UIImage(contentsOfFile: url.path)?.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let upright = UIImage(cgImage: cg, scale: 1, orientation: frame.uprightOrientation)
        guard let data = upright.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        var overlay = try makeReference(from: data, scene: reference.scene, setup: reference.setup)
        overlay.shot = reference.shot
        overlay.name = "Overlay of view \(number)"
        overlay.group = reference.group
        try ReferenceStore.save(overlay)
        UserDefaults.standard.set(overlay.id.uuidString, forKey: key)
        return overlay
    }

    /// Makes a photo-only reference from an imported photo: the photo becomes its ghost.
    static func makeReference(from data: Data, scene: String, setup: String) throws -> Reference {
        guard let source = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        // Stored upright and at most 1920 pixels on the long side.
        let longest = max(source.size.width, source.size.height)
        let scale = min(1, 1920 / max(longest, 1))
        let size = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = upright.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }

        let id = UUID()
        let folder = ReferenceStore.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "frame_0000.jpg"
        try jpeg.write(to: folder.appendingPathComponent(file))
        let width = Float(size.width)
        let height = Float(size.height)
        // No camera pose is known: an upright identity pose and a plausible lens.
        let intrinsics = simd_float3x3(SIMD3(width, 0, 0), SIMD3(0, width, 0), SIMD3(width / 2, height / 2, 1))
        let keyframe = Keyframe(
            imageFile: file, depthFile: nil, transform: flatten(matrix_identity_float4x4),
            intrinsics: flatten(intrinsics), imageWidth: Int(size.width), imageHeight: Int(size.height),
            depthWidth: 0, depthHeight: 0)
        var reference = Reference(
            id: id, scene: scene, setup: setup, name: "Photo", created: takenDate(data) ?? Date(), keyframes: [keyframe])
        reference.photoOnly = true
        try ReferenceStore.save(reference)
        return reference
    }

    /// When the photo was taken, from its EXIF data.
    private static func takenDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
