import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Phil, 2026-11-18: "I want to airdrop objects". Models and cut-outs go out through the share sheet (AirDrop first)
/// under their own names, and arrive in Reset by AirDrop or "Open in Reset" in the 3D models menu.
enum AssetShare {
    /// Reset's own cut-out files (declared in project.yml).
    static let cutoutType = UTType(exportedAs: "com.asiansidekick.reset.cutout")

    /// A copy under the given name in a fresh temporary folder, so what is sent is called what the person sees.
    static func copy(_ url: URL, as name: String, ext: String) throws -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(clean.isEmpty ? "Object" : clean).\(ext)")
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Takes in a file opened in Reset (AirDrop, Files, Mail). Returns what to tell the person, or nil if it isn't ours.
    @MainActor static func receive(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let base = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "usdz":
            if base.hasPrefix("Scan ") {
                // A scan keeps its name (its photographed colours are shown unlit), so it goes in as a scan.
                var name = base
                var number = 2
                while FileManager.default.fileExists(atPath: ScanFolder.root.appendingPathComponent(name).path) {
                    name = "\(base) \(number)"
                    number += 1
                }
                let folder = ScanFolder.root.appendingPathComponent(name, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("\(name).usdz"))
                } catch {
                    Diagnostics.log("Received scan failed: \(error.localizedDescription)")
                    return "Couldn't take in that scan."
                }
                Diagnostics.log("Received scan: \(name)")
                return "\(name) added to 3D models."
            }
            var name = base
            var number = 2
            let existing = Set(ModelLibrary.all().map { $0.deletingPathExtension().lastPathComponent })
            while existing.contains(name) {
                name = "\(base) \(number)"
                number += 1
            }
            ModelLibrary.keep(url, name: name, replacing: false)
            Diagnostics.log("Received model: \(name)")
            return "\(name) added to 3D models."
        case Cutout.fileExtension:
            guard let data = try? Data(contentsOf: url), let package = try? JSONDecoder().decode(CutoutPackage.self, from: data) else {
                return "That cut-out file couldn't be read."
            }
            CutoutLibrary.save(package)
            Diagnostics.log("Received cut-out: \(package.name)")
            return "\(package.name) added to 3D models."
        default:
            return nil
        }
    }
}

struct SharedModel: Transferable {
    let url: URL
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .usdz) { item in
            SentTransferredFile(try AssetShare.copy(item.url, as: item.name, ext: "usdz"))
        }
    }
}

struct SharedCutout: Transferable {
    let url: URL
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: AssetShare.cutoutType) { item in
            SentTransferredFile(try AssetShare.copy(item.url, as: item.name, ext: Cutout.fileExtension))
        }
    }
}
