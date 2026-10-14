import Foundation
import Metal

struct LUTDescriptor: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let fileURL: URL?
    let isBuiltIn: Bool
}

final class CubeLUTLoader {
    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        Self.ensureLUTsDirectoryExistsAndSeedDefaults()
    }

    /// Returns the `_LUTs` directory inside the user's Documents folder (accessible via the iOS Files app)
    static var lutsDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("_LUTs", isDirectory: true)
    }

    /// Creates `Documents/_LUTs` and seeds default cinema `.cube` LUTs so users can inspect or add their own in Files app
    static func ensureLUTsDirectoryExistsAndSeedDefaults() {
        let fm = FileManager.default
        let dir = lutsDirectoryURL
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let sampleLUTs: [(filename: String, title: String, preset: BuiltInStyle)] = [
            ("LogToRec709_ARRI_Classic.cube", "ARRI 709 Classic", .arri709),
            ("Kodak_2383_Print_Film.cube", "Kodak 2383 Print", .kodak2383),
            ("Cinema_Teal_Orange.cube", "Teal & Orange", .tealOrange),
            ("Bleach_Bypass_Noir.cube", "Bleach Bypass", .bleachBypass)
        ]

        for sample in sampleLUTs {
            let fileURL = dir.appendingPathComponent(sample.filename)
            if !fm.fileExists(atPath: fileURL.path) {
                let cubeContent = generateCubeFileString(title: sample.title, size: 17, style: sample.preset)
                try? cubeContent.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    enum BuiltInStyle {
        case identity
        case arri709
        case kodak2383
        case tealOrange
        case bleachBypass
    }

    /// Discovers all `.cube` files in `Documents/_LUTs`
    func availableLUTs() -> [LUTDescriptor] {
        Self.ensureLUTsDirectoryExistsAndSeedDefaults()
        let dir = Self.lutsDirectoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let display = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                return LUTDescriptor(
                    id: url.lastPathComponent,
                    name: display,
                    fileURL: url,
                    isBuiltIn: false
                )
            }
    }

    /// Creates an identity 3D LUT texture (17x17x17)
    func makeIdentityLUTTexture(size: Int = 17) -> MTLTexture? {
        var floats = [Float]()
        floats.reserveCapacity(size * size * size * 4)

        let denom = Float(max(size - 1, 1))
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    floats.append(Float(r) / denom)
                    floats.append(Float(g) / denom)
                    floats.append(Float(b) / denom)
                    floats.append(1.0)
                }
            }
        }
        return build3DTexture(size: size, rgbaFloats: floats)
    }

    /// Parses a `.cube` file from disk into a Metal 3D texture
    func loadCubeLUT(from url: URL) throws -> MTLTexture {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        return try parseCubeString(content)
    }

    func parseCubeString(_ content: String) throws -> MTLTexture {
        var lutSize = 0
        var rgbaFloats = [Float]()

        let lines = content.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN_") {
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, let parsedSize = Int(parts[1]), parsedSize >= 2 && parsedSize <= 128 {
                    lutSize = parsedSize
                    rgbaFloats.reserveCapacity(lutSize * lutSize * lutSize * 4)
                }
                continue
            }

            let tokens = line.split(whereSeparator: \.isWhitespace)
            if tokens.count >= 3,
               let r = Float(tokens[0]),
               let g = Float(tokens[1]),
               let b = Float(tokens[2]) {
                rgbaFloats.append(r)
                rgbaFloats.append(g)
                rgbaFloats.append(b)
                rgbaFloats.append(1.0)
            }
        }

        guard lutSize >= 2, rgbaFloats.count == lutSize * lutSize * lutSize * 4 else {
            throw NSError(
                domain: "CubeLUTLoader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid .cube LUT dimensions or data count"]
            )
        }

        guard let texture = build3DTexture(size: lutSize, rgbaFloats: rgbaFloats) else {
            throw NSError(
                domain: "CubeLUTLoader",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate Metal 3D LUT texture"]
            )
        }
        return texture
    }

    private func build3DTexture(size: Int, rgbaFloats: [Float]) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            return nil
        }

        let bytesPerRow = size * 4 * MemoryLayout<Float>.size
        let bytesPerImage = bytesPerRow * size

        rgbaFloats.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return texture
    }

    // MARK: - Procedural Cinema .cube Generator for Default _LUTs Folder

    static func generateCubeFileString(title: String, size: Int, style: BuiltInStyle) -> String {
        var lines = [String]()
        lines.append("TITLE \"\(title)\"")
        lines.append("# Generated by Log Cam Open Gate Pipeline")
        lines.append("LUT_3D_SIZE \(size)")
        lines.append("DOMAIN_MIN 0.0 0.0 0.0")
        lines.append("DOMAIN_MAX 1.0 1.0 1.0")

        let denom = Float(max(size - 1, 1))
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rf = Float(r) / denom
                    let gf = Float(g) / denom
                    let bf = Float(b) / denom
                    let (outR, outG, outB) = transformColor(r: rf, g: gf, b: bf, style: style)
                    lines.append(String(format: "%.6f %.6f %.6f", outR, outG, outB))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func transformColor(r: Float, g: Float, b: Float, style: BuiltInStyle) -> (Float, Float, Float) {
        // Normalize flat Log to filmic S-curve first
        func sCurve(_ x: Float) -> Float {
            let t = min(max((x - 0.12) / 0.78, 0.0), 1.0)
            return t * t * (3.0 - 2.0 * t)
        }

        let sr = sCurve(r)
        let sg = sCurve(g)
        let sb = sCurve(b)
        let luma = 0.2126 * sr + 0.7152 * sg + 0.0722 * sb

        switch style {
        case .identity:
            return (r, g, b)
        case .arri709:
            // Natural cinema contrast with gentle highlight rolloff
            let cr = min(max(luma + (sr - luma) * 1.18, 0.0), 1.0)
            let cg = min(max(luma + (sg - luma) * 1.18, 0.0), 1.0)
            let cb = min(max(luma + (sb - luma) * 1.15, 0.0), 1.0)
            return (cr, cg, cb)
        case .kodak2383:
            // Warm golden highlights, rich dense blacks, slight cyan-blue in deep shadows
            let shadowWeight = max(1.0 - luma * 1.6, 0.0)
            let highlightWeight = max((luma - 0.45) * 1.4, 0.0)
            let kr = min(max(sr * 1.04 + highlightWeight * 0.05 - shadowWeight * 0.03, 0.0), 1.0)
            let kg = min(max(sg * 1.01 + highlightWeight * 0.02, 0.0), 1.0)
            let kb = min(max(sb * 0.94 + shadowWeight * 0.05 - highlightWeight * 0.04, 0.0), 1.0)
            return (kr, kg, kb)
        case .tealOrange:
            // Push shadows toward teal and skin/highlights toward warm amber
            let shadow = max(1.0 - luma * 1.4, 0.0)
            let hi = max(luma - 0.35, 0.0)
            let tr = min(max(sr + hi * 0.09 - shadow * 0.05, 0.0), 1.0)
            let tg = min(max(sg + shadow * 0.02, 0.0), 1.0)
            let tb = min(max(sb + shadow * 0.09 - hi * 0.06, 0.0), 1.0)
            return (tr, tg, tb)
        case .bleachBypass:
            // High metallic contrast, desaturated silver retention
            let desatR = luma + (sr - luma) * 0.45
            let desatG = luma + (sg - luma) * 0.45
            let desatB = luma + (sb - luma) * 0.50
            return (min(max(desatR, 0.0), 1.0), min(max(desatG, 0.0), 1.0), min(max(desatB, 0.0), 1.0))
        }
    }
}
