import AppKit
import Metal
import SceneKit

// Each model's own light (ModelLightShader.swift), rendered by SceneKit on a Mac: a white ball lit by the default
// light, as Reset's live view lights models, then with the shader step and different settings.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

guard let device = MTLCreateSystemDefaultDevice() else {
    print("SKIP  no Metal device on this Mac: the light shader was not rendered")
    exit(0)
}

/// Average brightness (0-255, red, green, blue) of a small square of the picture at (x, y), as fractions across and down.
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
    for py in max(0, cy - 3)...min(height - 1, cy + 3) {
        for px in max(0, cx - 3)...min(width - 1, cx + 3) {
            let i = (py * width + px) * 4
            sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
            count += 1
        }
    }
    return sum / count
}

func render(tint: SIMD3<Float>? = nil, way: SIMD3<Float> = [0, 1, 0], side: Float = 0, constant: Bool = false) -> NSImage {
    let scene = SCNScene()
    let material = SCNMaterial()
    material.diffuse.contents = NSColor(white: 0.7, alpha: 1)
    material.lightingModel = constant ? .constant : .blinn
    if let tint {
        material.shaderModifiers = [.surface: ModelLightShader.source]
        material.setValue(NSValue(scnVector3: SCNVector3(tint.x, tint.y, tint.z)), forKey: "resetTint")
        material.setValue(NSValue(scnVector3: SCNVector3(way.x, way.y, way.z)), forKey: "resetLightWay")
        material.setValue(NSNumber(value: side), forKey: "resetSideLight")
    }
    let ball = SCNNode(geometry: SCNSphere(radius: 0.5))
    ball.geometry?.materials = [material]
    scene.rootNode.addChildNode(ball)
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = 40
    camera.position = SCNVector3(0, 0, 2.5)
    scene.rootNode.addChildNode(camera)
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    renderer.autoenablesDefaultLighting = true
    return renderer.snapshot(atTime: 0, with: CGSize(width: 200, height: 200), antialiasingMode: .none)
}

func grey(_ c: SIMD3<Double>) -> Double { (c.x + c.y + c.z) / 3 }

let plain = render()
let neutral = render(tint: [1, 1, 1])
let darker = render(tint: [0.5, 0.5, 0.5])
let brighter = render(tint: [1.6, 1.6, 1.6])
let warm = render(tint: [1, 0.86, 0.58])
let fromLeft = render(tint: [1, 1, 1], way: [-1, 0, 0], side: 1)
let fromRight = render(tint: [1, 1, 1], way: [1, 0, 0], side: 1)
let scanPlain = render(constant: true)
let scanDark = render(tint: [0.5, 0.5, 0.5], constant: true)

let middle = grey(colour(plain, 0.5, 0.5))
print(String(format: "INFO  ball middle %.0f, neutral %.0f, darker %.0f, brighter %.0f", middle, grey(colour(neutral, 0.5, 0.5)),
             grey(colour(darker, 0.5, 0.5)), grey(colour(brighter, 0.5, 0.5))))
check(middle > 40, "the ball is drawn and lit (\(Int(middle)))")
check(abs(grey(colour(neutral, 0.5, 0.5)) - middle) < 4, "the shader step at its normal setting changes nothing")
check(grey(colour(darker, 0.5, 0.5)) < middle * 0.75, "half brightness is clearly darker")
check(grey(colour(brighter, 0.5, 0.5)) > middle * 1.15, "1.6 brightness is clearly brighter")
let w = colour(warm, 0.5, 0.5)
check(w.x - w.z > 25, "warm tint: red well above blue (\(Int(w.x)) vs \(Int(w.z)))")
let leftOfLeft = grey(colour(fromLeft, 0.3, 0.5)), rightOfLeft = grey(colour(fromLeft, 0.7, 0.5))
print(String(format: "INFO  light from the left: left side %.0f, right side %.0f", leftOfLeft, rightOfLeft))
check(leftOfLeft > rightOfLeft + 25, "light from the left: the ball's left side is brighter")
check(grey(colour(fromRight, 0.7, 0.5)) > grey(colour(fromRight, 0.3, 0.5)) + 25, "light from the right: the ball's right side is brighter")
check(abs(grey(colour(fromLeft, 0.5, 0.5)) - grey(colour(fromRight, 0.5, 0.5))) < 12, "side light left or right: the middle matches")
let scanMiddle = grey(colour(scanPlain, 0.5, 0.5))
check(scanMiddle > 100 && grey(colour(scanDark, 0.5, 0.5)) < scanMiddle * 0.7, "an unlit scan darkens too (\(Int(scanMiddle)))")

if let folder = CommandLine.arguments.dropFirst().first {
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for (name, image) in [("plain", plain), ("darker", darker), ("brighter", brighter), ("warm", warm), ("from-left", fromLeft)] {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("light-\(name).png"))
        }
    }
}

print(failures == 0 ? "All light tests passed" : "\(failures) light test(s) failed")
exit(failures == 0 ? 0 : 1)
