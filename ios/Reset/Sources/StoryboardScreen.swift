import CoreImage
import PhotosUI
import SwiftUI
import UIKit

/// Storyboard mode (Phil, 2026-11-18), opened from the ••• menu. Opens on the camera like the rest of the app:
/// frame the shot, the picture can show the drawing style live (Live style), the shutter makes a panel. Then
/// add bubbles, captions, sound effects, arrows and camera moves; pages export as a PDF.
struct StoryboardScreen: View {
    /// The ARKit camera's latest picture, as the sensor gives it (landscape).
    let liveFrame: () -> CVPixelBuffer?
    let referencePhoto: UIImage?
    @State var scene: String
    @State var shot: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoryboardStore.shared
    /// The Storyboard look over the whole app (StoryboardLook.swift).
    @ObservedObject private var look = StoryboardLook.shared
    @AppStorage("storyLive") private var liveStyled = true
    @AppStorage("storyAspect") private var aspect = "16:9"
    @AppStorage("storyStyleName") private var styleName = "Marker"
    @AppStorage("storyStyle") private var savedStyle = ""
    @State private var style = StylePreset.all[0].style
    @State private var element: DrawStyle.Element = .lines
    @State private var live: UIImage?
    @State private var loop: Task<Void, Never>?
    @State private var editing: StoryPanel?
    @State private var showingBoard = false
    @State private var picked: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var editingSlate = false
    @State private var busy = false
    @State private var flash: String?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if wide {
                    // On its side: shutter and sources down the left edge, the elements down the right (each fits
                    // the height without scrolling), the picture between.
                    HStack(spacing: 10) {
                        shutterRow(vertical: true)
                            .frame(width: 140)
                        VStack(spacing: 10) {
                            topBar
                            picture
                            StyleStrip(name: $styleName, choose: choosePreset)
                        }
                        ElementColumn(style: style, element: $element, step: stepElement)
                            .frame(width: 160)
                    }
                    .padding(.horizontal, 8)
                } else {
                    VStack(spacing: 10) {
                        topBar
                        picture
                        StyleStrip(name: $styleName, choose: choosePreset)
                        ElementGrid(style: style, element: $element, step: stepElement)
                        Spacer(minLength: 0)
                        shutterRow(vertical: false)
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
        .onDisappear { loop?.cancel() }
        .fullScreenCover(item: $editing) { panel in
            PanelEditor(panel: panel, close: { editing = nil })
        }
        .sheet(isPresented: $showingBoard) {
            StoryBoardSheet(open: { panel in
                showingBoard = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { editing = panel }
            })
            .themed()
        }
        .sheet(isPresented: $editingSlate) {
            SlateSheet(scene: $scene, shot: $shot).themed()
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    makePanel(from: image)
                } else {
                    say("That photo couldn't be opened")
                }
            }
        }
        .onChange(of: style) { _, value in
            if let data = try? JSONEncoder().encode(value) { savedStyle = String(decoding: data, as: UTF8.self) }
        }
    }

    // MARK: Parts

    private var topBar: some View {
        HStack(spacing: 8) {
            Button("Close") { dismiss() }
                .font(Theme.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Button { editingSlate = true } label: {
                Text("Next: Sc \(scene.isEmpty ? "–" : scene)\(shot.isEmpty ? "" : " · Shot \(shot)") · Panel \(store.nextNumber(scene: scene, shot: shot))")
                    .font(Theme.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 4)
            WordButton(title: "Frame \(aspect)", on: false) {
                let all = PanelAspect.all
                aspect = all[((all.firstIndex(of: aspect) ?? 0) + 1) % all.count]
            }
            WordButton(title: liveStyled ? "Live style: on" : "Live style: off", on: liveStyled) { liveStyled.toggle() }
        }
        .padding(.top, 4)
    }

    private var picture: some View {
        GeometryReader { geometry in
            let ratio = PanelAspect.ratio(aspect)
            let fit = fitted(ratio, in: geometry.size)
            ZStack {
                if let live {
                    Image(uiImage: live).resizable().frame(width: fit.width, height: fit.height)
                } else {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: fit.width, height: fit.height)
                        .overlay(Text("Starting the camera…").font(Theme.footnote).foregroundStyle(.white.opacity(0.7)))
                }
                if let flash {
                    Text(flash)
                        .font(Theme.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .transition(.opacity)
                }
                VStack {
                    Spacer()
                    Text("Drag up or down: \(element.hint). Swipe sideways: style.")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 4)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
                .frame(width: fit.width, height: fit.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(StyleDrag.gesture(element: element, step: stepElement, swipe: swipePreset))
        }
    }

    private func shutterRow(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            Button { showingBoard = true } label: {
                PanelThumb(panel: store.ordered.last).frame(width: 64, height: 44)
            }
            .accessibilityLabel("Panels")
            ShutterButton(style: .photo, busy: busy) { takePanel() }
            VStack(spacing: 8) {
                WordButton(title: "Photos", on: false) { choosingPhoto = true }
                // The same look on the recording and reset screens, models and all (StoryboardLook.swift).
                WordButton(title: look.on ? "Whole app: on" : "Whole app: off", on: look.on) { look.set(!look.on) }
                if let referencePhoto {
                    WordButton(title: "Reference", on: false) { makePanel(from: referencePhoto) }
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Actions

    private func start() {
        // The old Splatter ink style (before 1357) comes back as Scratchy ink, without the blots.
        if styleName == "Splatter ink" {
            styleName = "Scratchy ink"
            savedStyle = ""
        }
        if let data = savedStyle.data(using: .utf8), let saved = try? JSONDecoder().decode(DrawStyle.self, from: data) {
            style = saved
            style.splatter = 0
        } else if let preset = StylePreset.named(styleName) {
            style = preset.style
        }
        if !StoryboardRenderer.shared.ready { say("Drawing styles are missing from this build") }
        Diagnostics.log("Storyboard opened, style \(styleName)")
        loop?.cancel()
        loop = Task { await runLive() }
    }

    /// About ten pictures a second from the camera, drawn in the style when Live style is on.
    private func runLive() async {
        while !Task.isCancelled {
            if let buffer = liveFrame() {
                let box = FrameBox(buffer: buffer)
                let orientation = StoryboardScreen.sensorOrientation()
                let styled = liveStyled
                let current = style
                let shape = aspect
                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    let picture = PanelAspect.crop(CIImage(cvPixelBuffer: box.buffer).oriented(orientation), shape)
                    let renderer = StoryboardRenderer.shared
                    return styled ? renderer.render(picture, style: current, maxSide: 720) : renderer.photo(picture, maxSide: 720)
                }.value
                if let image { live = image }
            }
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    /// How the ARKit camera's picture turns to stand upright on screen.
    @MainActor static func sensorOrientation() -> CGImagePropertyOrientation {
        switch Screen.orientation {
        case .landscapeRight: return .up
        case .landscapeLeft: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }

    private func takePanel() {
        guard !busy, let buffer = liveFrame() else {
            say("No camera picture yet")
            return
        }
        busy = true
        let box = FrameBox(buffer: buffer)
        let orientation = StoryboardScreen.sensorOrientation()
        Task {
            let photo = await Task.detached(priority: .userInitiated) {
                StoryboardRenderer.shared.photo(CIImage(cvPixelBuffer: box.buffer).oriented(orientation), maxSide: 4032)
            }.value
            busy = false
            if let photo { makePanel(from: photo) } else { say("The picture couldn't be taken") }
        }
    }

    private func makePanel(from photo: UIImage) {
        let name = StylePreset.matching(style)?.name ?? "Custom"
        guard let panel = store.add(photo: photo, scene: scene, shot: shot, style: style, styleName: name, aspect: aspect) else {
            say("The panel couldn't be saved")
            return
        }
        Haptics.success()
        editing = panel
    }

    private func stepElement(_ element: DrawStyle.Element, _ by: Int) {
        let before = style[element]
        style[element] = before + by
        guard style[element] != before else { return }
        Haptics.tap()
        styleName = StylePreset.matching(style)?.name ?? "Custom"
        say("\(element.title): \(style.word(element))")
    }

    private func choosePreset(_ preset: StylePreset) {
        Haptics.tap()
        style = preset.style
        styleName = preset.name
        say(preset.name)
    }

    private func swipePreset(_ by: Int) {
        let all = StylePreset.all
        let index = all.firstIndex { $0.name == styleName } ?? -1
        let next = (index + by + all.count) % all.count
        choosePreset(all[next])
    }

    private func say(_ words: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = words }
        let shown = words
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if flash == shown { withAnimation(.easeIn(duration: 0.3)) { flash = nil } }
        }
    }
}

/// A camera picture handed to a background task. Only read, never changed.
struct FrameBox: @unchecked Sendable { let buffer: CVPixelBuffer }

func fitted(_ ratio: CGFloat, in box: CGSize) -> CGSize {
    guard box.width > 0, box.height > 0 else { return .zero }
    return box.width / box.height > ratio ? CGSize(width: box.height * ratio, height: box.height) : CGSize(width: box.width, height: box.width / ratio)
}

extension StoryboardRenderer {
    /// The picture as a plain photo, longest side at most `maxSide`.
    func photo(_ input: CIImage, maxSide: CGFloat) -> UIImage? {
        let scale = min(1, maxSide / max(input.extent.width, input.extent.height))
        let sized = scale < 1 ? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : input
        let moved = sized.transformed(by: CGAffineTransform(translationX: -sized.extent.minX, y: -sized.extent.minY))
        return plain(moved)
    }
}

// MARK: - Controls

/// Dragging up or down on the picture steps the chosen element; a sideways swipe changes the style.
enum StyleDrag {
    static func gesture(element: DrawStyle.Element, step: @escaping (DrawStyle.Element, Int) -> Void,
                        swipe: @escaping (Int) -> Void) -> some Gesture {
        let state = DragState()
        return DragGesture(minimumDistance: 14)
            .onChanged { drag in
                if state.axis == nil {
                    state.axis = abs(drag.translation.height) > abs(drag.translation.width) ? .vertical : .horizontal
                }
                guard state.axis == .vertical else { return }
                // One step for every 40 points; up is more.
                let steps = Int((-drag.translation.height / 40).rounded(.towardZero))
                if steps != state.applied {
                    step(element, steps - state.applied)
                    state.applied = steps
                }
            }
            .onEnded { drag in
                if state.axis == .horizontal, abs(drag.translation.width) > 50 {
                    swipe(drag.translation.width < 0 ? 1 : -1)
                }
                state.axis = nil
                state.applied = 0
            }
    }

    final class DragState {
        enum Axis { case vertical, horizontal }
        var axis: Axis?
        var applied = 0
    }
}

struct WordButton: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.footnote.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(on ? Theme.active : Color.white.opacity(0.14), in: Capsule())
                .foregroundStyle(on ? Color.black : Color.white)
        }
    }
}

struct StyleStrip: View {
    @Binding var name: String
    let choose: (StylePreset) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(StylePreset.all) { preset in
                        Button { choose(preset) } label: {
                            Text(preset.name.uppercased())
                                .font(Theme.footnote.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(preset.name == name ? Theme.active : Color.white)
                        }
                        .id(preset.name)
                    }
                    if StylePreset.named(name) == nil {
                        Text("CUSTOM").font(Theme.footnote.weight(.semibold)).foregroundStyle(Theme.active).id("Custom")
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 26)
            .onChange(of: name) { _, value in withAnimation { reader.scrollTo(value, anchor: .center) } }
            .onAppear { reader.scrollTo(name, anchor: .center) }
        }
    }
}

struct ElementButton: View {
    let element: DrawStyle.Element
    let style: DrawStyle
    let chosen: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Text(element.title).fontWeight(.semibold)
                Spacer(minLength: 2)
                Text(style.word(element)).opacity(0.85)
            }
            .font(Theme.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(chosen ? Theme.active : Color.white.opacity(0.14), in: Capsule())
            .foregroundStyle(chosen ? Color.black : Color.white)
        }
    }
}

/// The elements down the right edge (landscape). Tap one to choose it; tap it again for its next step.
struct ElementColumn: View {
    let style: DrawStyle
    @Binding var element: DrawStyle.Element
    let step: (DrawStyle.Element, Int) -> Void

    var body: some View {
        VStack(spacing: 5) {
            ForEach(DrawStyle.Element.allCases) { item in
                ElementButton(element: item, style: style, chosen: item == element) { tap(item) }
            }
        }
    }

    private func tap(_ item: DrawStyle.Element) {
        if item == element {
            // Round and round: after the last step, back to the first.
            let last = item.steps.count - 1
            step(item, style[item] == last ? -last : 1)
        } else {
            Haptics.tap()
            element = item
        }
    }
}

/// The same, as a grid under the picture (portrait).
struct ElementGrid: View {
    let style: DrawStyle
    @Binding var element: DrawStyle.Element
    let step: (DrawStyle.Element, Int) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(DrawStyle.Element.allCases) { item in
                ElementButton(element: item, style: style, chosen: item == element) {
                    if item == element {
                        let last = item.steps.count - 1
                        step(item, style[item] == last ? -last : 1)
                    } else {
                        Haptics.tap()
                        element = item
                    }
                }
            }
        }
    }
}

struct PanelThumb: View {
    let panel: StoryPanel?
    @ObservedObject private var store = StoryboardStore.shared
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if panel == nil {
                Text("Panels").font(Theme.caption2.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
        .task(id: panel.map { "\($0.id)\($0.marks.count)\(String(describing: $0.style))\($0.aspect)" } ?? "none") {
            guard let panel else { image = nil; return }
            image = store.finished(panel, maxSide: 400)
        }
    }
}

/// Scene and shot for the next panels.
struct SlateSheet: View {
    @Binding var scene: String
    @Binding var shot: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Scene", text: $scene).keyboardType(.numbersAndPunctuation)
                TextField("Shot (letter, can be empty)", text: $shot).textInputAutocapitalization(.characters)
            }
            .navigationTitle("Next panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Panel editor

struct PanelEditor: View {
    @State var panel: StoryPanel
    let close: () -> Void
    @ObservedObject private var store = StoryboardStore.shared
    @State private var drawn: UIImage?
    @State private var element: DrawStyle.Element = .lines
    @State private var selected: UUID?
    @State private var choosingMove = false
    @State private var editingWords = false
    @State private var words = ""
    @State private var editingNotes = false
    @State private var sharing: [Any]?
    @State private var flash: String?
    @State private var touch = EditorTouch()
    @State private var pinchStart: (scale: CGFloat, angle: Double)?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if wide {
                    HStack(spacing: 8) {
                        AddColumn(add: add)
                            .frame(width: 128)
                        VStack(spacing: 8) {
                            editorBar
                            canvas
                            StyleStrip(name: $panel.styleName, choose: choosePreset)
                        }
                        ElementColumn(style: panel.style, element: $element, step: stepElement)
                            .frame(width: 150)
                    }
                    .padding(.horizontal, 8)
                } else {
                    VStack(spacing: 10) {
                        editorBar
                        canvas
                        StyleStrip(name: $panel.styleName, choose: choosePreset)
                        ElementGrid(style: panel.style, element: $element, step: stepElement)
                        AddGrid(add: add)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(String(describing: panel.style))\(panel.aspect)") { await redraw() }
        .onChange(of: panel) { _, value in store.update(value) }
        .sheet(isPresented: $choosingMove) {
            MovePicker { move in
                choosingMove = false
                var mark = StoryMark.new(.move, move: move)
                mark.center = CGPoint(x: 0.5, y: 0.5)
                panel.marks.append(mark)
                selected = mark.id
                if panel.camera.isEmpty { panel.camera = move.title }
            }
            .themed()
        }
        .sheet(isPresented: $editingNotes) { NotesSheet(panel: $panel).themed() }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            ShareSheet(items: sharing ?? [])
        }
        .alert("Words", isPresented: $editingWords) {
            TextField("Words", text: $words, axis: .vertical)
            Button("Done") { setWords() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var editorBar: some View {
        HStack(spacing: 8) {
            Button("Done") { store.update(panel); close() }
                .font(Theme.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Button { editingNotes = true } label: {
                Text(panel.slate)
                    .font(Theme.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 4)
            if let mark = selectedMark {
                if mark.kind.hasWords { WordButton(title: "Edit words", on: false) { startWords(mark) } }
                WordButton(title: "Delete", on: false) {
                    panel.marks.removeAll { $0.id == mark.id }
                    selected = nil
                }
            } else {
                WordButton(title: "Notes", on: false) { editingNotes = true }
                WordButton(title: "Share", on: false) { share() }
            }
        }
        .padding(.top, 4)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let size = fitted(PanelAspect.ratio(panel.aspect), in: geometry.size)
            ZStack {
                ZStack {
                    if let drawn {
                        Image(uiImage: drawn).resizable()
                    } else {
                        Rectangle().fill(Color.white.opacity(0.06))
                        ProgressView()
                    }
                    MarksCanvas(marks: panel.marks, selected: selected)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(editGesture(size))
                .simultaneousGesture(pinchGesture)
                if let flash {
                    Text(flash)
                        .font(Theme.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .allowsHitTesting(false)
                }
                if panel.marks.isEmpty {
                    VStack {
                        Spacer()
                        Text("Add bubbles and camera moves from the buttons. Drag up or down on the picture: \(element.hint).")
                            .font(Theme.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 4)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(8)
                    }
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var selectedMark: StoryMark? { panel.marks.first { $0.id == selected } }

    // MARK: Touch

    /// One finger: on a mark it moves the mark (or its tail, from the round handle); on the picture it steps the
    /// style like the camera; a tap picks a mark, a tap on the picked one edits its words.
    private func editGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if touch.target == nil { touch.target = target(at: drag.startLocation, size: size) }
                guard let target = touch.target else { return }
                let moved = hypot(drag.translation.width, drag.translation.height)
                if moved > 6 { touch.moved = true }
                switch target {
                case .tail(let id, let start):
                    update(id) { $0.tail = clampPoint(CGPoint(x: start.x + drag.translation.width / size.width, y: start.y + drag.translation.height / size.height)) }
                case .mark(let id, let start, let tail):
                    guard touch.moved else { return }
                    selected = id
                    let dx = drag.translation.width / size.width, dy = drag.translation.height / size.height
                    update(id) { mark in
                        mark.center = clampPoint(CGPoint(x: start.x + dx, y: start.y + dy))
                        if mark.kind == .arrow { mark.tail = clampPoint(CGPoint(x: tail.x + dx, y: tail.y + dy)) }
                    }
                case .picture:
                    guard touch.moved else { return }
                    if touch.axis == nil {
                        touch.axis = abs(drag.translation.height) > abs(drag.translation.width) ? .vertical : .horizontal
                    }
                    guard touch.axis == .vertical else { return }
                    let steps = Int((-drag.translation.height / 40).rounded(.towardZero))
                    if steps != touch.applied {
                        stepElement(element, steps - touch.applied)
                        touch.applied = steps
                    }
                }
            }
            .onEnded { drag in
                defer { touch = EditorTouch() }
                guard let target = touch.target else { return }
                switch target {
                case .mark(let id, _, _):
                    if !touch.moved {
                        if selected == id, let mark = selectedMark, mark.kind.hasWords { startWords(mark) } else { selected = id }
                        Haptics.tap()
                    }
                case .tail: break
                case .picture:
                    if !touch.moved { selected = nil }
                    if touch.axis == .horizontal, abs(drag.translation.width) > 50 { swipePreset(drag.translation.width < 0 ? 1 : -1) }
                }
            }
    }

    /// Two fingers: pinch sizes the picked mark, twist turns it.
    private var pinchGesture: some Gesture {
        SimultaneousGesture(MagnifyGesture(), RotateGesture())
            .onChanged { value in
                guard let id = selected, let mark = selectedMark else { return }
                if pinchStart == nil { pinchStart = (mark.scale, mark.angle) }
                guard let start = pinchStart else { return }
                touch.target = nil
                update(id) { mark in
                    if let magnify = value.first?.magnification {
                        mark.scale = min(max(start.scale * magnify, mark.kind == .move ? 0.15 : 0.4), mark.kind == .move ? 2.5 : 4)
                    }
                    if let rotation = value.second?.rotation, mark.kind == .sound || (mark.kind == .move && mark.move?.drawsEndFrame == false) || mark.kind == .caption {
                        mark.angle = start.angle + rotation.radians
                    }
                }
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func target(at point: CGPoint, size: CGSize) -> EditorTouch.Target {
        if let mark = selectedMark, mark.kind.hasTail {
            let tip = MarkLayout.point(mark.tail, size)
            if hypot(point.x - tip.x, point.y - tip.y) < 34 { return .tail(mark.id, mark.tail) }
        }
        // The picked mark first, then the newest on top.
        let order = panel.marks.filter { $0.id == selected } + panel.marks.reversed().filter { $0.id != selected }
        for mark in order where MarkLayout.hitRect(mark, in: size).contains(point) {
            return .mark(mark.id, mark.center, mark.tail)
        }
        return .picture
    }

    private func update(_ id: UUID, _ change: (inout StoryMark) -> Void) {
        guard let i = panel.marks.firstIndex(where: { $0.id == id }) else { return }
        change(&panel.marks[i])
    }

    private func clampPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }

    // MARK: Actions

    private func add(_ kind: StoryMark.Kind) {
        Haptics.tap()
        if kind == .move {
            choosingMove = true
            return
        }
        let mark = StoryMark.new(kind)
        panel.marks.append(mark)
        selected = mark.id
        if kind.hasWords { startWords(mark) }
    }

    private func startWords(_ mark: StoryMark) {
        selected = mark.id
        words = mark.text
        editingWords = true
    }

    private func setWords() {
        guard let id = selected else { return }
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.text = text.isEmpty ? $0.text : text }
    }

    private func stepElement(_ element: DrawStyle.Element, _ by: Int) {
        let before = panel.style[element]
        panel.style[element] = before + by
        guard panel.style[element] != before else { return }
        Haptics.tap()
        panel.styleName = StylePreset.matching(panel.style)?.name ?? "Custom"
        say("\(element.title): \(panel.style.word(element))")
    }

    private func choosePreset(_ preset: StylePreset) {
        Haptics.tap()
        panel.style = preset.style
        panel.styleName = preset.name
        say(preset.name)
    }

    private func swipePreset(_ by: Int) {
        let all = StylePreset.all
        let index = all.firstIndex { $0.name == panel.styleName } ?? -1
        choosePreset(all[(index + by + all.count) % all.count])
    }

    private func redraw() async {
        let current = panel
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let photo = await MainActor.run(body: { StoryboardStore.shared.photo(current) }),
                  let upright = StoryboardRenderer.upright(photo) else { return nil }
            return StoryboardRenderer.shared.render(PanelAspect.crop(upright, current.aspect), style: current.style, maxSide: 1600)
        }.value
        if !Task.isCancelled, let image { drawn = image }
    }

    private func share() {
        store.update(panel)
        guard let image = store.finished(panel, maxSide: 2400) else { return }
        sharing = [image]
    }

    private func say(_ words: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = words }
        let shown = words
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if flash == shown { withAnimation(.easeIn(duration: 0.3)) { flash = nil } }
        }
    }
}

struct EditorTouch {
    enum Target {
        case mark(UUID, CGPoint, CGPoint)
        case tail(UUID, CGPoint)
        case picture
    }
    enum Axis { case vertical, horizontal }
    var target: Target?
    var moved = false
    var axis: Axis?
    var applied = 0
}

/// What can be added to a panel, as plain words.
struct AddColumn: View {
    let add: (StoryMark.Kind) -> Void

    var body: some View {
        VStack(spacing: 5) {
            ForEach(StoryMark.Kind.allCases) { kind in
                AddButton(kind: kind, add: add)
            }
        }
    }
}

struct AddGrid: View {
    let add: (StoryMark.Kind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(StoryMark.Kind.allCases) { kind in AddButton(kind: kind, add: add) }
        }
    }
}

struct AddButton: View {
    let kind: StoryMark.Kind
    let add: (StoryMark.Kind) -> Void

    var body: some View {
        Button { add(kind) } label: {
            Text("+ " + kind.title)
                .font(Theme.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

/// The camera move symbols to choose from, all on one sheet.
struct MovePicker: View {
    let choose: (CameraMove) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                ForEach(CameraMove.allCases) { move in
                    Button { choose(move) } label: {
                        VStack(spacing: 6) {
                            Canvas { context, size in
                                MoveIcon.draw(move, in: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 6), context: &context,
                                              colour: Theme.accent, outline: nil, frameColour: Color(white: 0.8))
                            }
                            .frame(height: 64)
                            Text(move.title).font(Theme.footnote.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }
}

/// The panel's slate, notes and frame shape.
struct NotesSheet: View {
    @Binding var panel: StoryPanel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Slate") {
                    TextField("Scene", text: $panel.scene)
                    TextField("Shot", text: $panel.shot).textInputAutocapitalization(.characters)
                    Stepper("Panel \(panel.number)", value: $panel.number, in: 1...999)
                }
                Section("Notes") {
                    TextField("Action", text: $panel.action, axis: .vertical)
                    TextField("Camera", text: $panel.camera, axis: .vertical)
                    TextField("Sound", text: $panel.sound, axis: .vertical)
                }
                Section("Frame") {
                    Picker("Frame", selection: $panel.aspect) {
                        ForEach(PanelAspect.all, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(panel.slate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Board

/// All panels in story order. Tap to open; hold for Delete. PDF pages and pictures to share.
struct StoryBoardSheet: View {
    let open: (StoryPanel) -> Void
    @ObservedObject private var store = StoryboardStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: [Any]?
    @State private var deleting: StoryPanel?
    @State private var making = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.panels.isEmpty {
                    Text("No panels yet. Take one with the shutter, or pick a photo.")
                        .font(Theme.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 14) {
                    ForEach(store.ordered) { panel in
                        Button { open(panel) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                PanelThumb(panel: panel)
                                    .aspectRatio(PanelAspect.ratio(panel.aspect), contentMode: .fit)
                                Text(panel.slate).font(Theme.caption.weight(.semibold)).foregroundStyle(.white)
                                Text(panel.styleName + (panel.moves.isEmpty ? "" : " · " + panel.moves))
                                    .font(Theme.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button("Delete panel", role: .destructive) { deleting = panel }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Panels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(StoryboardPDF.Layout.allCases) { layout in
                            Button("PDF: " + layout.rawValue) { makePDF(layout) }
                        }
                        Button("Pictures") { sharePictures() }
                    } label: {
                        Text(making ? "Making…" : "Share")
                    }
                    .disabled(store.panels.isEmpty || making)
                }
            }
            .confirmationDialog("Delete \(deleting?.slate ?? "panel")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete panel", role: .destructive) {
                    if let deleting { store.delete(deleting) }
                    deleting = nil
                }
            }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                ShareSheet(items: sharing ?? [])
            }
        }
        .preferredColorScheme(.dark)
    }

    private func makePDF(_ layout: StoryboardPDF.Layout) {
        making = true
        // A moment for "Making…" to show before the pages are drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let url = StoryboardPDF.make(store.ordered, layout: layout, store: store)
            making = false
            if let url { sharing = [url] }
            Diagnostics.log("Storyboard PDF \(layout.rawValue): \(url != nil ? "made" : "failed"), \(store.panels.count) panels")
        }
    }

    private func sharePictures() {
        making = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let images = store.ordered.compactMap { store.finished($0, maxSide: 2400) }
            making = false
            if !images.isEmpty { sharing = images }
        }
    }
}
