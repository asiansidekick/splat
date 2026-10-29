import CoreImage
import Foundation
import UIKit

/// A paused moment: the live picture frozen, and the reference stretched onto that very frame,
/// so fading or wiping between them shows only what has really changed.
struct HeldFrame {
    let now: UIImage
    /// Nil for a reference with no photo to stretch (it is drawn as it is instead).
    let reference: UIImage?
    /// Whether the pictures were paired (Vision's homography) rather than turned by the phone.
    let registered: Bool
    let since: Date

    /// Builds both pictures laid out like the live camera. `fallback` turns the reference by the
    /// phone's attitude when the pictures cannot be paired.
    static func build(
        live: CIImage, reference: CIImage?, fallback: Restorer.Warp?, placement: Restorer.Placement,
        context: CIContext, since: Date
    ) -> HeldFrame {
        let now = Restorer.render(live, placement: placement, context: context) ?? UIImage()
        guard let reference else { return HeldFrame(now: now, reference: nil, registered: false, since: since) }
        let size = live.extent.size
        var placed: CIImage?
        var registered = false
        if let match = ImageMatch.compare(live: live, reference: reference), match.error < ImageMatch.guideLimit,
            let stretched = match.snapped(reference, live: size)
        {
            placed = stretched
            registered = true
        } else {
            placed = fallback?.apply(to: reference)
        }
        let image = placed.flatMap { Restorer.render($0, placement: placement, context: context) }
        return HeldFrame(now: now, reference: image, registered: registered && image != nil, since: since)
    }
}
