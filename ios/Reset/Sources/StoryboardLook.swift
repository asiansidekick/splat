import ARKit
import SceneKit
import SwiftUI

/// The Storyboard look over the whole app (Phil, 2026-11-18: "think of storyboard mode as an overlay of the whole
/// Reset app"). The recording and reset screens' 3D views (camera picture plus every model, mannequin and cut-out)
/// are drawn in the storyboard style by a SceneKit technique (StoryboardLook.metal). Everything else works as
/// usual: tracking, placing, measuring and the buttons, which sit on top and stay sharp.
@MainActor
final class StoryboardLook: ObservableObject {
    static let shared = StoryboardLook()

    @Published private(set) var on: Bool
    @Published private(set) var styleName: String
    private var views = NSHashTable<ARSCNView>.weakObjects()
    private var loggedFrames = false
    private var checked = false

    private init() {
        on = UserDefaults.standard.bool(forKey: "storyLookOn")
        styleName = UserDefaults.standard.string(forKey: "storyStyleName") ?? "Marker"
    }

    /// The style Storyboard uses: the same keys as StoryboardScreen's, so the two always match.
    var style: DrawStyle {
        if let text = UserDefaults.standard.string(forKey: "storyStyle"), !text.isEmpty,
           let data = text.data(using: .utf8), var saved = try? JSONDecoder().decode(DrawStyle.self, from: data) {
            saved.splatter = 0
            return saved
        }
        return StylePreset.named(styleName)?.style ?? StylePreset.all[0].style
    }

    /// A live 3D view to draw in the look whenever it is on.
    func attach(_ view: ARSCNView) {
        views.add(view)
        apply(view)
    }

    func set(_ value: Bool) {
        on = value
        checked = false
        UserDefaults.standard.set(value, forKey: "storyLookOn")
        Diagnostics.log("Storyboard look \(value ? "on" : "off"), \(styleName)")
        refresh()
    }

    /// The next ready-made style, for the style pill.
    func nextStyle() {
        let all = StylePreset.all.filter { $0.name != "Photo" }
        let index = all.firstIndex { $0.name == styleName } ?? -1
        let preset = all[(index + 1) % all.count]
        styleName = preset.name
        UserDefaults.standard.set(preset.name, forKey: "storyStyleName")
        if let data = try? JSONEncoder().encode(preset.style) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "storyStyle")
        }
        refresh()
    }

    /// After Storyboard changed the style.
    func refresh() {
        styleName = UserDefaults.standard.string(forKey: "storyStyleName") ?? styleName
        for view in views.allObjects { apply(view) }
    }

    private func apply(_ view: ARSCNView) {
        guard on else {
            if view.technique != nil { view.technique = nil }
            return
        }
        let s = style
        // A new technique for each style: the style is built into it (see makeTechnique).
        guard let technique = Self.makeTechnique(s) else {
            Diagnostics.log("Storyboard look: technique could not be made")
            return
        }
        view.technique = technique
        if !loggedFrames {
            loggedFrames = true
            Diagnostics.log("Storyboard look drawing, preferred \(view.preferredFramesPerSecond) fps")
        }
        check(view)
    }

    /// Once, a second after the look goes on: compares the screen with the plain picture, so the log says whether
    /// the look really draws (build 1360 switched on but drew nothing, and the log could not tell).
    private func check(_ view: ARSCNView) {
        guard !checked else { return }
        checked = true
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            guard let view, self.on, view.window != nil else { self.checked = false; return }
            let drawn = view.snapshot()
            let plain = self.plainPhoto(of: view)
            let change = Self.difference(drawn, plain)
            Diagnostics.log(String(format: "Storyboard look check: screen differs from the plain picture by %.1f%%", change * 100))
        }
    }

    /// Average difference of two pictures, 0 to 1, from small grey copies.
    private static func difference(_ a: UIImage, _ b: UIImage) -> Double {
        func grey(_ image: UIImage) -> [UInt8] {
            let w = 32, h = 32
            var pixels = [UInt8](repeating: 0, count: w * h)
            guard let cg = image.cgImage, let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                                                 bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return pixels
        }
        let x = grey(a), y = grey(b)
        let total = zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(x.count * 255)
    }

    /// Three passes: a tiny one whose size carries the style, the style at half size, then that drawn over the
    /// whole screen. No symbols: values set on a technique never reached the shader on Phil's phone (build 1360).
    static func makeTechnique(_ s: DrawStyle) -> SCNTechnique? {
        func step(_ v: Int, _ top: Int) -> Int { min(max(v, 0), top) }
        let width = 1 + step(s.lines, 4) + 5 * step(s.detail, 3) + 20 * step(s.shadows, 3) + 80 * step(s.brightness, 4)
        let height = 1 + step(s.greys, 6) + 7 * step(s.colour, 4) + 35 * step(s.dots, 4) + 175 * step(s.paper, 3)
        let definition: [String: Any] = [
            "passes": [
                "storyLookCode": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "storyLookVertex",
                    "metalFragmentShader": "storyLookCode",
                    "inputs": [String: Any](),
                    "outputs": ["color": "storyLookCode"],
                ],
                "storyLookStyle": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "storyLookVertex",
                    "metalFragmentShader": "storyLookFragment",
                    "inputs": ["colorSampler": "COLOR", "styleCode": "storyLookCode"],
                    "outputs": ["color": "storyLookHalf"],
                ],
                "storyLookShow": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "storyLookVertex",
                    "metalFragmentShader": "storyLookShow",
                    "inputs": ["colorSampler": "storyLookHalf"],
                    "outputs": ["color": "COLOR"],
                ],
            ],
            "sequence": ["storyLookCode", "storyLookStyle", "storyLookShow"],
            "targets": [
                "storyLookCode": ["type": "color", "size": "\(width)x\(height)"],
                "storyLookHalf": ["type": "color", "scaleFactor": 0.5],
            ],
        ]
        return SCNTechnique(dictionary: definition)
    }

    /// The view as a plain photo (with its models), for a storyboard panel: the look is lifted for the moment it
    /// takes, so the panel can be drawn in any style later.
    func plainPhoto(of view: ARSCNView) -> UIImage {
        let technique = view.technique
        view.technique = nil
        let image = view.snapshot()
        view.technique = technique
        return image
    }
}

/// While the look is on: two small pills down the right edge, the style (tap for the next one) and Panel. Phil,
/// 2026-11-19: the old three-button row took too much room and showed in screenshots, so it is left out of them,
/// and Look off is in the menus (and on holding the style pill).
struct StoryboardLookBar: View {
    @ObservedObject private var look = StoryboardLook.shared
    let makePanel: () -> Void

    var body: some View {
        if look.on {
            VStack(alignment: .trailing, spacing: 6) {
                lookButton(look.styleName + " ›", name: "Look style", on: true) { look.nextStyle() }
                    .contextMenu {
                        Button { makePanel() } label: { Label("Make panel", systemImage: "rectangle.split.3x1") }
                        Button { look.set(false) } label: { Label("Look off", systemImage: "paintbrush.pointed") }
                    }
                lookButton("Panel", name: "Look panel", on: false) { makePanel() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
            .hiddenInScreenshots()
            .transition(.opacity)
        }
    }

    private func lookButton(_ title: String, name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { TapGate.run(name) { Haptics.tap(); action() } } label: {
            Text(title)
                .font(Theme.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(on ? Theme.active.opacity(0.85) : Color.black.opacity(0.4), in: Capsule())
                .foregroundStyle(on ? Color.black : Color.white)
        }
        .caughtTap(name) { Haptics.tap(); action() }
    }
}

/// A panel made from the live view: drawn in the current style, then opened for bubbles and camera moves.
struct LookPanel: Identifiable {
    let panel: StoryPanel
    var id: UUID { panel.id }

    @MainActor static func make(from view: ARSCNView?, scene: String, shot: String) -> LookPanel? {
        guard let view else { return nil }
        let look = StoryboardLook.shared
        let photo = look.plainPhoto(of: view)
        let store = StoryboardStore.shared
        let style = look.style
        let name = StylePreset.matching(style)?.name ?? "Custom"
        let aspect = UserDefaults.standard.string(forKey: "storyAspect") ?? "16:9"
        guard let panel = store.add(photo: photo, scene: scene, shot: shot, style: style, styleName: name, aspect: aspect) else { return nil }
        Haptics.success()
        return LookPanel(panel: panel)
    }
}
