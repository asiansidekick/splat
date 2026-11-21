import CoreGraphics
import Foundation

/// Phil, 2026-11-21: "cropping for different standard film aspect ratios". The film frame is drawn over the live
/// view (FilmFrame.swift) and photos are cropped to it. Plain maths, so the crop tests check it on a Mac.
enum FilmAspect: Double, CaseIterable, Identifiable {
    case full = 0
    case academy = 1.33
    case european = 1.66
    case hd = 1.78
    case flat = 1.85
    case univisium = 2.0
    case scope = 2.39

    var id: Double { rawValue }

    /// Width over height. 4:3 and 16:9 are exact, the rest as the film world rounds them.
    var ratio: CGFloat? {
        switch self {
        case .full: return nil
        case .academy: return 4.0 / 3.0
        case .hd: return 16.0 / 9.0
        default: return CGFloat(rawValue)
        }
    }

    /// The word on the screen, as a camera crew says it.
    var word: String {
        switch self {
        case .full: return "FULL"
        case .academy: return "4:3"
        case .european: return "1.66"
        case .hd: return "16:9"
        case .flat: return "1.85"
        case .univisium: return "2:1"
        case .scope: return "2.39"
        }
    }

    /// In the hold menu: the word and what it is.
    var menuName: String {
        switch self {
        case .full: return "Full picture (no frame)"
        case .academy: return "4:3 (1.33, TV and Academy)"
        case .european: return "1.66 (European widescreen)"
        case .hd: return "16:9 (1.78, HD)"
        case .flat: return "1.85 (flat widescreen)"
        case .univisium: return "2:1 (2.00)"
        case .scope: return "2.39 (scope)"
        }
    }

    /// The next one on a tap: narrow to wide, then back to the full picture.
    var next: FilmAspect {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The saved choice (UserDefaults "filmAspect"), FULL if it is anything else.
    init(saved: Double) {
        self = Self.allCases.first { abs($0.rawValue - saved) < 0.001 } ?? .full
    }
}

enum FilmFrameMath {
    /// The widest frame of `ratio` (width over height) that fits in `area`, centred in it. The frame keeps its own
    /// shape whichever way the phone is held: a 2.39 frame is a wide strip on an upright phone too.
    static func frame(ratio: CGFloat, in area: CGRect) -> CGRect {
        guard ratio > 0, area.width > 0, area.height > 0 else { return area }
        var size = CGSize(width: area.width, height: area.width / ratio)
        if size.height > area.height { size = CGSize(width: area.height * ratio, height: area.height) }
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The part of a picture that shows inside `frame`, when the picture fills a screen of `screen` size cut to fit
    /// (aspect fill, centred, as the camera views do). In the picture's own units; nil if the frame misses it.
    static func crop(frame: CGRect, screen: CGSize, picture: CGSize) -> CGRect? {
        guard screen.width > 0, screen.height > 0, picture.width > 0, picture.height > 0 else { return nil }
        let scale = max(screen.width / picture.width, screen.height / picture.height)
        let shown = CGSize(width: picture.width * scale, height: picture.height * scale)
        let offset = CGPoint(x: (screen.width - shown.width) / 2, y: (screen.height - shown.height) / 2)
        let rect = CGRect(
            x: (frame.minX - offset.x) / scale, y: (frame.minY - offset.y) / scale,
            width: frame.width / scale, height: frame.height / scale)
        let inside = rect.intersection(CGRect(origin: .zero, size: picture))
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return nil }
        return inside
    }
}
