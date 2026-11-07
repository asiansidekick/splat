import SwiftUI

/// Night and mint: deep green-black chips over the camera picture, a mint accent, white-green text.
/// The type is the system font; its design is `fontDesign` below, applied on the camera screen.
enum Theme {
    /// Buttons that are on, selected borders, the Next take button.
    static let accent = Color(red: 0.369, green: 0.918, blue: 0.831)      // #5EEAD4
    /// Text and icons drawn on the accent.
    static let onAccent = Color(red: 0.016, green: 0.125, blue: 0.110)    // #04201C
    /// Pills, round buttons and the slider capsule over the picture.
    static let chip = Color(red: 0.031, green: 0.078, blue: 0.071).opacity(0.62)
    /// The strip behind the top row of icons, and the side column on its side.
    static let band = Color(red: 0.031, green: 0.078, blue: 0.071).opacity(0.55)
    static let text = Color(red: 0.918, green: 0.965, blue: 0.945)        // #EAF6F1
    /// The one font design for the whole app: change it here.
    static let fontDesign: Font.Design = .default
}
