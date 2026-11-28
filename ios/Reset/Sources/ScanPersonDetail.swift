import Foundation
import RealityKit
import os
import SceneKit
import simd

/// Phil, 2026-11-20: "Facial feature accuracy is important". The phone's model builder makes every model from about
/// 25,000 triangles. A scan from Reset's own camera covers the whole area round the person, so the person gets only a
/// few thousand of them, too few for a face. Building again from the same photos, kept to a box round the person,
/// puts them all on the person: about four times the detail, with no new scan. The scan itself is not changed; the
/// person's own model is kept beside it and used for making a posable person.
enum ScanPersonDetail {
    static func file(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("\(folder.name) person detail.usdz") }
    private static func skippedFile(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("person-detail-skipped") }

    static func has(_ folder: ScanFolder) -> Bool { FileManager.default.fileExists(atPath: file(folder).path) }

    /// Photos from Reset's own camera, the whole area built, the room fit known, and not built or skipped before.
    static func canRebuild(_ folder: ScanFolder) -> Bool {
        let manager = FileManager.default
        return PhotogrammetrySession.isSupported && folder.cameras != nil && folder.fit != nil && folder.hasFull && folder.imageCount >= 10
            && !has(folder) && !manager.fileExists(atPath: skippedFile(folder).path)
    }

    static func skip(_ folder: ScanFolder) {
        try? Data().write(to: skippedFile(folder))
    }

    private static func runningFile(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("person-detail-running") }

    /// A build that was running when the app last stopped: it is not tried again on its own.
    static func crashedLastTime(_ folder: ScanFolder) -> Bool {
        guard FileManager.default.fileExists(atPath: runningFile(folder).path) else { return false }
        try? FileManager.default.removeItem(at: runningFile(folder))
        skip(folder)
        Diagnostics.log("Scan person: the last build in more detail didn't finish (the app stopped), not tried again")
        return true
    }

    /// The box round the person (in the model's metres, as Reset shows it) in the builder's own space, where the
    /// builder needs it: the turn and size ScanBake gave the model are taken back off.
    static func builderBox(_ folder: ScanFolder, low: SIMD3<Float>, high: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard let fit = folder.fit, fit.scale > 0, let shift = bakedShift(folder) else { return nil }
        let back = fit.quaternion.inverse
        var outLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude), outHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in 0..<8 {
            let p = SIMD3<Float>(corner & 1 == 0 ? low.x : high.x, corner & 2 == 0 ? low.y : high.y, corner & 4 == 0 ? low.z : high.z)
            let q = back.act((p - shift) / fit.scale)
            outLow = simd_min(outLow, q)
            outHigh = simd_max(outHigh, q)
        }
        return (outLow, outHigh)
    }

    /// How far ScanBake moved the turned, sized model to stand it on y = 0 and centre it.
    private static func bakedShift(_ folder: ScanFolder) -> SIMD3<Float>? {
        guard let fit = folder.fit, let scene = try? SCNScene(url: folder.full, options: nil) else { return nil }
        // The same steps as ScanBake.bake, to find where it stood the model.
        let turned = SCNNode()
        for child in scene.rootNode.childNodes { turned.addChildNode(child) }
        turned.simdOrientation = fit.quaternion
        turned.simdScale = SIMD3(repeating: fit.scale)
        let holder = SCNNode()
        holder.addChildNode(turned)
        let (bl, bh) = holder.boundingBox
        return SIMD3<Float>(-(Float(bl.x) + Float(bh.x)) / 2, -Float(bl.y), -(Float(bl.z) + Float(bh.z)) / 2)
    }

    /// "Scan a person": the box round the person in a scan of the whole area (the model's metres, as Reset shows it),
    /// found from where the photos were taken (they walked round the person) and the model's points. Slow (reads the
    /// model): call off the main thread.
    static func personBox(_ folder: ScanFolder) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard let fit = folder.fit, fit.translation.count == 3, let cameras = folder.cameras, let shift = bakedShift(folder),
              let (mesh, _) = ScanCharacterMaker.read(folder.model) else { return nil }
        // ARKit's places, moved the way the bake moved the model: model = room - fit's shift + bake's shift.
        let move = shift - SIMD3(fit.translation[0], fit.translation[1], fit.translation[2])
        let places = cameras.values.filter { $0.count == 3 }.map { SIMD3($0[0], $0[1], $0[2]) + move }
        guard let box = ScanRig.personColumn(points: mesh.positions, cameras: places) else {
            Diagnostics.log("Scan person: no person found standing in the middle of the scan (\(places.count) photos, \(mesh.positions.count) points)")
            return nil
        }
        Diagnostics.log(String(format: "Scan person: person found, box %.2f x %.2f x %.2f m, floor at %.2f m", box.high.x - box.low.x, box.high.y - box.low.y, box.high.z - box.low.z, box.low.y + 0.01))
        return (box.low, box.high)
    }

    /// Builds the person again inside the box. `progress` gets 0 to 1. Throws on failure; cancelling the task stops it.
    static func rebuild(_ folder: ScanFolder, box: (SIMD3<Float>, SIMD3<Float>), progress: @escaping @Sendable (Double) -> Void) async throws {
        let started = Date()
        try? Data().write(to: runningFile(folder))
        defer { try? FileManager.default.removeItem(at: runningFile(folder)) }
        Diagnostics.log(String(format: "Scan person: memory before building, %.0f MB free", Double(os_proc_available_memory()) / 1_000_000))
        var config = PhotogrammetrySession.Configuration()
        // A fresh start, as the first build that worked: reusing the first build's half-made files stopped the app
        // twice about 30 s in (Phil's log, 2026-11-20). Slower (a few minutes), but the known-good way.
        let fresh = folder.url.appendingPathComponent("person-detail-checkpoint", isDirectory: true)
        try? FileManager.default.removeItem(at: fresh)
        try? FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fresh) }
        config.checkpointDirectory = fresh
        let session = try PhotogrammetrySession(input: folder.images, configuration: config)
        let raw = folder.url.appendingPathComponent("person-detail-raw.usdz")
        try? FileManager.default.removeItem(at: raw)
        let geometry = PhotogrammetrySession.Request.Geometry(bounds: BoundingBox(min: box.0, max: box.1))
        Diagnostics.log("Scan person: building the person in more detail, box \(box.0) to \(box.1)")
        var logged = 0
        try await withTaskCancellationHandler {
            try session.process(requests: [.modelFile(url: raw, detail: .reduced, geometry: geometry)])
            outputs: for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress(fraction)
                    let tenth = Int(fraction * 10)
                    if tenth > logged {
                        logged = tenth
                        Diagnostics.log(String(format: "Scan person: building %d %%, %.0f MB free", tenth * 10, Double(os_proc_available_memory()) / 1_000_000))
                    }
                case .requestError(_, let error): throw error
                case .processingComplete: break outputs
                case .processingCancelled: throw CancellationError()
                default: break
                }
            }
        } onCancel: {
            session.cancel()
        }
        guard FileManager.default.fileExists(atPath: raw.path) else {
            throw NSError(domain: "ScanPersonDetail", code: 1, userInfo: [NSLocalizedDescriptionKey: "The builder wrote no model."])
        }
        let fit = folder.fit
        let target = file(folder)
        let ok = await MainActor.run { ScanBake.bake(raw, to: target, fit: fit) }
        try? FileManager.default.removeItem(at: raw)
        guard ok else { throw NSError(domain: "ScanPersonDetail", code: 2, userInfo: [NSLocalizedDescriptionKey: "The model couldn't be saved."]) }
        Diagnostics.log(String(format: "Scan person: person built in more detail in %.0f s", Date().timeIntervalSince(started)))
    }
}
