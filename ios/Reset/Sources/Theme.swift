import SwiftUI
import UIKit

/// Reset's look: Night and mint colours with Avenir Next Condensed (Phil, 2026-11-07), shared with Match.
enum Theme {
    /// Phil, 2026-11-07: Reset hung and crashed after the Avenir change and no log said why, so the typeface is
    /// switched off (system font, same sizes) until it is proven safe. Turn on to bring Avenir back.
    static let useAvenir = false

    /// Mint, the one accent colour (#5EEAD4), and the dark text that sits on it.
    static let accent = Color(red: 0.369, green: 0.918, blue: 0.831)
    static let onAccent = Color(red: 0.016, green: 0.125, blue: 0.11)
    static let accentUI = UIColor(red: 0.369, green: 0.918, blue: 0.831, alpha: 1)

    private static func name(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light, .regular: return "AvenirNextCondensed-Regular"
        case .medium: return "AvenirNextCondensed-Medium"
        case .semibold: return "AvenirNextCondensed-DemiBold"
        case .bold: return "AvenirNextCondensed-Bold"
        default: return "AvenirNextCondensed-Heavy"
        }
    }

    /// A fixed-size font, for places that were `.system(size:)`. `design` is ignored: one family everywhere.
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        useAvenir ? .custom(name(weight), fixedSize: size) : .system(size: size, weight: weight)
    }

    private static func styled(_ weight: Font.Weight, _ size: CGFloat, _ style: Font.TextStyle) -> Font {
        useAvenir ? .custom(name(weight), size: size, relativeTo: style) : .system(style).weight(weight)
    }

    // The same names as the system text styles, so `.font(.footnote)` becomes `.font(Theme.footnote)`.
    // Avenir Next Condensed sets small, so each is a point or two above the system size.
    static var largeTitle: Font { styled(.bold, 36, .largeTitle) }
    static var title: Font { styled(.bold, 30, .title) }
    static var title2: Font { styled(.bold, 24, .title2) }
    static var title3: Font { styled(.semibold, 22, .title3) }
    static var headline: Font { styled(.semibold, 19, .headline) }
    static var body: Font { styled(.medium, 19, .body) }
    static var callout: Font { styled(.medium, 18, .callout) }
    static var subheadline: Font { styled(.medium, 17, .subheadline) }
    static var footnote: Font { styled(.medium, 15, .footnote) }
    static var caption: Font { styled(.medium, 14, .caption) }
    static var caption2: Font { styled(.medium, 13, .caption2) }

    /// A UIFont in the same family, for text drawn into pictures and PDFs.
    static func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let name: String
        switch weight {
        case .heavy, .black: name = "AvenirNextCondensed-Heavy"
        case .bold: name = "AvenirNextCondensed-Bold"
        case .semibold: name = "AvenirNextCondensed-DemiBold"
        case .medium: name = "AvenirNextCondensed-Medium"
        default: name = "AvenirNextCondensed-Regular"
        }
        if !useAvenir { return UIFont.systemFont(ofSize: size, weight: weight) }
        return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
    }

    /// Navigation bars and other UIKit text, once at launch.
    @MainActor static func installAppearance() {
        let bar = UINavigationBarAppearance()
        bar.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().tintColor = accentUI
    }
}

extension View {
    /// The look every screen and sheet carries: the font and the mint accent. Sheets are given it again
    /// because some do not take it from the screen that opened them.
    func themed() -> some View { font(Theme.body).tint(Theme.accent) }
}
