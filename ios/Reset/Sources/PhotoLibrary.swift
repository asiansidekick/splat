import Foundation
import ImageIO
import Photos
import UIKit
import simd

/// Saving to and importing from the iPhone's Photos library.
enum PhotoLibrary {
    /// Adds the images to Photos. Asks for permission the first time; returns false if refused.
    static func save(_ images: [UIImage]) async -> Bool {
        guard !images.isEmpty else { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Diagnostics.log("Photos: no permission to add (\(status.rawValue))")
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images { PHAssetChangeRequest.creationRequestForAsset(from: image) }
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
