import AppKit
import Metal
import SceneKit
import simd

// Soft edges on cropped scans (SoftEdgeMath.swift, SoftEdge.swift): the sums on made-up meshes, then a cropped sheet
// rendered by SceneKit on a Mac over a blue background, hard and soft.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

/// A flat square sheet, `side` metres across, `n` points along each side, facing +Z. Optionally the right half has
/// its own copy of the middle column of points, as a scan repeats points along a seam of its photo.
func sheet(side: Float = 1, n: Int = 21, seam: Bool = false) -> (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], triangles: [UInt32]) {
    var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
    var index: [[UInt32]] = Array(repeating: Array(repeating: 0, count: n), count: n)
    var copy: [UInt32] = Array(repeating: 0, count: n)
    let middle = n / 2
    for j in 0..<n {
        for i in 0..<n {
            let u = Float(i) / Float(n - 1), v = Float(j) / Float(n - 1)
            index[j][i] = UInt32(positions.count)
            positions.append(SIMD3((u - 0.5) * side, (v - 0.5) * side, 0))
            uvs.append(SIMD2(u, v))
        }
    }
    if seam {
        for j in 0..<n {
            copy[j] = UInt32(positions.count)
            positions.append(positions[Int(index[j][middle])])
            uvs.append(uvs[Int(index[j][middle])])
        }
    }
    var triangles: [UInt32] = []
    for j in 0..<(n - 1) {
        for i in 0..<(n - 1) {
            func at(_ x: Int, _ y: Int) -> UInt32 { seam && x == middle && i >= middle ? copy[y] : index[y][x] }
            let a = at(i, j), b = at(i + 1, j), c = at(i + 1, j + 1), d = at(i, j + 1)
            triangles += [a, b, c, a, c, d]
        }
    }
    return (positions, uvs, triangles)
}

// MARK: The sums

let plain = sheet()
let found = SoftEdgeMath.distances(positions: plain.positions, triangles: [plain.triangles], limit: 10, tolerance: 1e-5)
check(found.openEdges == 80, "a cut sheet has its 80 border edges as cut edges (\(found.openEdges))")
let corner = found.distance[0], centre = found.distance[10 * 21 + 10]
check(corner == 0, "a border point is on a cut edge")
check(abs(centre - 0.5) < 0.001, String(format: "the middle is half a metre from the edge (%.3f)", centre))
check(abs(found.distance[1 * 21 + 1] - 0.05) < 0.001, "one row in is one row's width from the edge")

let seamed = sheet(seam: true)
let seamFound = SoftEdgeMath.distances(positions: seamed.positions, triangles: [seamed.triangles], limit: 10, tolerance: 1e-5)
check(seamFound.openEdges == 80, "a seam where the photo's pieces meet is not a cut edge (\(seamFound.openEdges))")
let copyOfMiddle = 21 * 21 + 10
check(abs(seamFound.distance[copyOfMiddle] - 0.5) < 0.001, "both copies of a seam point are as far from the edge as each other")

// A closed box whose six sides each have their own corner points (like a scan's seams): no cut edge at all.
var boxPoints: [SIMD3<Float>] = [], boxTriangles: [UInt32] = []
for axis in 0..<3 {
    for sign: Float in [-1, 1] {
        var quad: [SIMD3<Float>] = []
        for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            var p = SIMD3<Float>(repeating: 0)
            p[axis] = sign * 0.2
            p[(axis + 1) % 3] = a * 0.2
            p[(axis + 2) % 3] = b * 0.2
            quad.append(p)
        }
        let base = UInt32(boxPoints.count)
        boxPoints += quad
        boxTriangles += sign > 0 ? [base, base + 1, base + 2, base, base + 2, base + 3] : [base, base + 2, base + 1, base, base + 3, base + 2]
    }
}
let box = SoftEdgeMath.distances(positions: boxPoints, triangles: [boxTriangles], limit: 10, tolerance: 1e-5)
check(box.openEdges == 0, "a closed model has no cut edges, so nothing fades (\(box.openEdges))")
check(box.distance.allSatisfy { !$0.isFinite }, "every point of a closed model stays solid")

// A box with its top cut off: the cut runs round the top.
let topless = Array(boxTriangles[0..<18]) + Array(boxTriangles[24..<36])  // the top (+Y) is 18..<24
let cut = SoftEdgeMath.distances(positions: boxPoints, triangles: [topless], limit: 10, tolerance: 1e-5)
check(cut.openEdges == 4, "a box with its top cut off has the four edges round the top as cut edges (\(cut.openEdges))")

let near = SoftEdgeMath.distances(positions: plain.positions, triangles: [plain.triangles], limit: 0.2, tolerance: 1e-5)
check(!near.distance[10 * 21 + 10].isFinite, "points further in than the fade are left alone")
check(near.distance[3 * 21 + 10] <= 0.2, "points within the fade are reached")

check(SoftEdgeMath.fade(0, width: 0.3) == 0, "a cut edge is clear")
check(SoftEdgeMath.fade(0.3, width: 0.3) == 1 && SoftEdgeMath.fade(.infinity, width: 0.3) == 1, "past the fade is solid")
check(abs(SoftEdgeMath.fade(0.15, width: 0.3) - 0.5) < 0.001, "half way in is half see-through")
check(SoftEdgeMath.fade(0.1, width: 0) == 1, "hard edge: no fade at all")
check(SoftEdgeMath.width(step: 0, size: 1) == 0, "hard edge has no width")
check(abs(SoftEdgeMath.width(step: 1, size: 2) - 0.1) < 0.0001 && abs(SoftEdgeMath.width(step: 2, size: 2) - 0.24) < 0.0001, "soft and softer are shares of the model's size")
check(SoftEdgeMath.width(step: 1, size: 0.05) == 0.01, "a small model still fades over at least a centimetre")

// About the size of a real scan, to see it is quick enough to do as a model is placed.
let big = sheet(side: 2, n: 300)
let started = Date()
let bigFound = SoftEdgeMath.distances(positions: big.positions, triangles: [big.triangles], limit: 0.24, tolerance: 1e-5)
let took = Date().timeIntervalSince(started)
print(String(format: "INFO  %d points, %d triangles: %.2f s", big.positions.count, big.triangles.count / 3, took))
check(bigFound.openEdges == 4 * 299 && took < 3, "a 180,000 triangle scan is done in under 3 s")

// MARK: Rendered

guard let device = MTLCreateSystemDefaultDevice() else {
    print("SKIP  no Metal device on this Mac: the soft edge was not rendered")
    print(failures == 0 ? "All soft edge tests passed" : "\(failures) soft edge test(s) failed")
    exit(failures == 0 ? 0 : 1)
}

/// Average colour (0-255) of a small square at (x, y), as fractions across and down.
func colour(_ image: NSImage, _ x: CGFloat, _ y: CGFloat) -> SIMD3<Double> {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .zero }
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    let cx = Int(x * CGFloat(width)), cy = Int(y * CGFloat(height))
    var sum = SIMD3<Double>.zero
    var count = 0.0
    for py in max(0, cy - 2)...min(height - 1, cy + 2) {
        for px in max(0, cx - 2)...min(width - 1, cx + 2) {
            let i = (py * width + px) * 4
            sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
            count += 1
        }
    }
    return sum / count
}

/// The sheet, red, unlit like a scan (or lit), over a blue background, softened `width` metres in from its edges.
func render(width: Float, lit: Bool = false, tint: Float? = nil, textured: Bool = false) -> NSImage {
    let shape = sheet()
    var sources = [SCNGeometrySource(vertices: shape.positions.map { SCNVector3($0.x, $0.y, $0.z) }),
                   SCNGeometrySource(normals: shape.positions.map { _ in SCNVector3(0, 0, 1) })]
    if textured { sources.append(SCNGeometrySource(textureCoordinates: shape.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })) }
    let material = SCNMaterial()
    if textured {
        // A red picture, so the scan's own photo (picture coordinates channel 0) is still read right.
        let picture = NSImage(size: NSSize(width: 8, height: 8))
        picture.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        picture.unlockFocus()
        material.diffuse.contents = picture
    } else {
        material.diffuse.contents = NSColor.red
    }
    material.lightingModel = lit ? .blinn : .constant
    if let tint {
        material.shaderModifiers = [.fragment: ModelLightShader.source]
        material.setValue(NSValue(scnVector3: SCNVector3(tint, tint, tint)), forKey: "resetTint")
        material.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "resetLightWay")
        material.setValue(NSNumber(value: 0), forKey: "resetSideLight")
    }
    let geometry: SCNGeometry
    if width > 0 {
        let found = SoftEdgeMath.distances(positions: shape.positions, triangles: [shape.triangles], limit: width, tolerance: 1e-5)
        geometry = SoftEdge.softened(sources: sources, elements: [shape.triangles], materials: [material],
                                     fade: found.distance.map { SoftEdgeMath.fade($0, width: width) })
    } else {
        geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: shape.triangles, primitiveType: .triangles)])
        geometry.materials = [material]
    }
    let scene = SCNScene()
    scene.background.contents = NSColor.blue
    scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = 40
    camera.position = SCNVector3(0, 0, 2)
    scene.rootNode.addChildNode(camera)
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    renderer.autoenablesDefaultLighting = true
    return renderer.snapshot(atTime: 0, with: CGSize(width: 400, height: 400), antialiasingMode: .none)
}

// The sheet covers the middle 68.7% of the picture (1 m at 2 m with a 40 degree view): u across the sheet is at
// 0.156 + 0.687 u across the picture.
func at(_ u: CGFloat) -> CGFloat { 0.156 + 0.687 * u }
func describe(_ c: SIMD3<Double>) -> String { String(format: "r %.0f g %.0f b %.0f", c.x, c.y, c.z) }

let hard = render(width: 0)
let soft = render(width: 0.3)
let hardEdge = colour(hard, at(0.03), 0.5), hardMiddle = colour(hard, 0.5, 0.5)
let softEdge = colour(soft, at(0.03), 0.5), softHalf = colour(soft, at(0.15), 0.5), softMiddle = colour(soft, 0.5, 0.5)
print("INFO  hard: edge \(describe(hardEdge)), middle \(describe(hardMiddle))")
print("INFO  soft: edge \(describe(softEdge)), half way \(describe(softHalf)), middle \(describe(softMiddle))")
check(hardEdge.x > 200 && hardEdge.z < 40, "hard edge: the sheet is solid red right to its edge")
check(softMiddle.x > 200 && softMiddle.z < 40, "soft edge: the middle stays solid red")
check(softEdge.z > 180 && softEdge.x < 110, "soft edge: by the cut, the background shows through")
check(softHalf.x > 70 && softHalf.z > 70, "soft edge: half way in, red and blue mix")
let corner2 = colour(soft, at(0.03), at(0.03))
check(corner2.z > 180, "soft edge: the corners fade too")
let outside = colour(soft, 0.05, 0.5)
check(outside.z > 240 && outside.x < 20, "nothing is drawn outside the sheet")

let softLit = render(width: 0.3, lit: true)
let litEdge = colour(softLit, at(0.03), 0.5), litMiddle = colour(softLit, 0.5, 0.5)
print("INFO  soft lit: edge \(describe(litEdge)), middle \(describe(litMiddle))")
check(litEdge.z > 180 && litMiddle.x > 100, "a lit model fades the same way")

let softTinted = render(width: 0.3, tint: 0.5)
let tintEdge = colour(softTinted, at(0.03), 0.5), tintMiddle = colour(softTinted, 0.5, 0.5)
print("INFO  soft with the model's own light at half: edge \(describe(tintEdge)), middle \(describe(tintMiddle))")
check(tintEdge.z > 180 && tintMiddle.x > 100 && tintMiddle.x < softMiddle.x - 20, "with the model's own light step: darker, and still fades")

let softTextured = render(width: 0.3, textured: true)
let texEdge = colour(softTextured, at(0.03), 0.5), texMiddle = colour(softTextured, 0.5, 0.5)
print("INFO  soft with a photo: edge \(describe(texEdge)), middle \(describe(texMiddle))")
check(texMiddle.x > 200 && texMiddle.z < 40 && texEdge.z > 180, "a scan's photo still shows, and fades at the cut")

if let folder = CommandLine.arguments.dropFirst().first {
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for (name, image) in [("hard", hard), ("soft", soft), ("soft-lit", softLit), ("soft-photo", softTextured)] {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("soft-edge-\(name).png"))
        }
    }
}

print(failures == 0 ? "All soft edge tests passed" : "\(failures) soft edge test(s) failed")
exit(failures == 0 ? 0 : 1)
