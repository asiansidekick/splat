import SwiftUI

/// Night and mint: deep green-black chips over the camera picture, a mint accent, white-green text.
/// The type is Georgia (`georgia(_:)` below) for text; icons and the big guide labels stay in the system font.
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
    /// Beyond the text styles below, this is the design for anything not set in Georgia.
    static let fontDesign: Font.Design = .default

    /// Georgia at the size of a system text style, growing with the phone's text size setting.
    static func georgia(_ style: Font.TextStyle) -> Font {
        let base: CGFloat
        switch style {
        case .largeTitle: base = 34
        case .title: base = 28
        case .title2: base = 22
        case .title3: base = 20
        case .headline: base = 17
        case .subheadline: base = 15
        case .body: base = 17
        case .callout: base = 16
        case .footnote: base = 13
        case .caption: base = 12
        case .caption2: base = 11
        @unknown default: base = 17
        }
        let font = Font.custom("Georgia", size: base, relativeTo: style)
        return style == .headline ? font.weight(.semibold) : font
    }
}
