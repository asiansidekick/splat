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
    /// The screen size it was laid out for: turning the phone lays it out again.
    let viewport: CGSize

    /// The reference in the live picture's sensor layout, the live picture's size, turned by the
    /// phone's attitude like the live ghost (no picture matching: Phil found it snapped).
    static func place(live: CIImage, reference: CIImage?, fallback: Restorer.Warp?) -> (image: CIImage?, registered: Bool) {
        guard let reference else { return (nil, false) }
        return (fallback?.apply(to: reference), false)
    }

    /// Both pictures laid out like the live camera, for the screen as it is held now.
    static func render(
        live: CIImage, placed: CIImage?, registered: Bool, placement: Restorer.Placement, context: CIContext
    ) -> HeldFrame {
        let now = Restorer.render(live, placement: placement, context: context) ?? UIImage()
        let image = placed.flatMap { Restorer.render($0, placement: placement, context: context) }
        return HeldFrame(now: now, reference: image, registered: registered && image != nil, viewport: placement.viewport)
    }
}
