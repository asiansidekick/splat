import Foundation
import ImageIO

// Shared by Match and Reset (copy this file unchanged into the other app).

/// Photos leave the phone without location, camera, lens, serial number or time-taken details.
enum PhotoPrivacy {
    /// The picture with its longest side at most `maxPixels`, upright, with no details. Nil if it
    /// is already that small (send it as it is) or isn't a picture.
    static func smaller(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
            max(width, height) > maxPixels
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// The picture as it is if it carries nothing private, otherwise re-saved without the details.
    /// Photos the app takes are already clean, so they go untouched and lose no quality.
    static func cleaned(_ data: Data) -> Data? {
        isClean(data) ? data : stripped(data)
    }

    /// True for a picture with no location, camera, lens, serial number, time taken or caption.
    /// Nil-safe: anything that isn't a readable picture is not clean.
    static func isClean(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyIPTCDictionary] != nil
            || properties[kCGImagePropertyMakerAppleDictionary] != nil { return false }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFSoftware,
             kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFHostComputer].contains(where: { tiff[$0] != nil }) { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifLensModel,
             kCGImagePropertyExifLensMake, kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
             kCGImagePropertyExifUserComment, kCGImagePropertyExifSubjectArea].contains(where: { exif[$0] != nil }) { return false }
        return true
    }

    /// The same picture with no location, camera, date or other details: only the pixels and
    /// which way up they go. Nil if it isn't a picture.
    static func stripped(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var keep: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] { keep[kCGImagePropertyOrientation] = orientation }
        keep[kCGImageDestinationLossyCompressionQuality] = 0.9
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, keep as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
