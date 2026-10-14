import Foundation
import CoreVideo

/// Generates real 14-bit RGGB Bayer pattern `CVPixelBuffer` frames (with sensor black level 528 and white level 16383)
/// containing a Macbeth ColorChecker, 14-stop dynamic range step wedge, and animated motion target.
/// Used for unit testing the Metal RAW debayer pipeline and running the full 30fps pipeline in the iOS Simulator.
final class SyntheticRAWGenerator {
    let width: Int
    let height: Int
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameIndex: Int = 0

    // 24 Macbeth ColorChecker linear RGB reflectance patches
    private static let colorCheckerLinearRGB: [SIMD3<Float>] = [
        SIMD3(0.115, 0.082, 0.064), SIMD3(0.400, 0.258, 0.205), SIMD3(0.122, 0.192, 0.330), SIMD3(0.105, 0.145, 0.065),
        SIMD3(0.240, 0.220, 0.420), SIMD3(0.160, 0.460, 0.380), SIMD3(0.560, 0.215, 0.045), SIMD3(0.085, 0.115, 0.360),
        SIMD3(0.450, 0.095, 0.125), SIMD3(0.090, 0.048, 0.140), SIMD3(0.340, 0.480, 0.060), SIMD3(0.650, 0.360, 0.040),
        SIMD3(0.040, 0.065, 0.290), SIMD3(0.085, 0.280, 0.090), SIMD3(0.380, 0.045, 0.055), SIMD3(0.750, 0.620, 0.050),
        SIMD3(0.420, 0.095, 0.285), SIMD3(0.045, 0.245, 0.380), SIMD3(0.900, 0.900, 0.900), SIMD3(0.590, 0.590, 0.590),
        SIMD3(0.360, 0.360, 0.360), SIMD3(0.198, 0.198, 0.198), SIMD3(0.090, 0.090, 0.090), SIMD3(0.031, 0.031, 0.031)
    ]

    init(width: Int = 1344, height: Int = 1008) {
        self.width = width & ~1
        self.height = height & ~1
        setupPool()
    }

    private func setupPool() {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent16,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pixelBufferPool
        )
    }

    func nextBayerFrame(iso: Float = 100.0, shutterSeconds: Double = 1.0 / 48.0) -> (CVPixelBuffer, RAWFrameMetadata)? {
        guard let pool = pixelBufferPool else { return nil }
        var pixelBufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut) == kCVReturnSuccess,
              let pixelBuffer = pixelBufferOut else {
            return nil
        }

        frameIndex &+= 1
        let phase = Float(frameIndex) * 0.06

        // Exposure scale relative to nominal ISO 100, 1/48s
        let exposureGain = (iso / 100.0) * Float(shutterSeconds * 48.0)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt16>.size
        let ptr = baseAddr.assumingMemoryBound(to: UInt16.self)

        let w = width
        let h = height
        let invW = 1.0 / Float(w)
        let invH = 1.0 / Float(h)

        // Inverse sensor WB gains (since real raw sensors have stronger green sensitivity than R/B)
        let sensorFilterSensitivity = SIMD3<Float>(1.0 / 2.05, 1.0, 1.0 / 1.65)
        let blackLevel: Float = 528.0
        let span: Float = 16383.0 - blackLevel

        let sweepX = 0.5 + 0.35 * sin(phase)
        let sweepY = 0.30 + 0.12 * cos(phase * 0.7)

        for y in 0..<h {
            let v = Float(y) * invH
            let rowPtr = ptr.advanced(by: y * stride)
            let isOddRow = (y & 1) != 0

            for x in 0..<w {
                let u = Float(x) * invW
                let isOddCol = (x & 1) != 0

                // Scene linear RGB at (u, v)
                var sceneRGB: SIMD3<Float>

                if v < 0.52 {
                    // Upper half: Studio gradient + moving cinema highlight orb + skin-tone reference disc
                    let dx = (u - sweepX) * Float(w) / Float(h)
                    let dy = v - sweepY
                    let dist2 = dx * dx + dy * dy
                    if dist2 < 0.018 {
                        // Specular highlight orb
                        let falloff = max(1.0 - dist2 / 0.018, 0.0)
                        sceneRGB = SIMD3<Float>(0.95, 0.82, 0.65) * (0.35 + 0.85 * falloff * falloff)
                    } else {
                        // Cinematic ambient gradient
                        let horiz = 0.04 + 0.32 * u
                        let vert = 0.06 + 0.25 * (1.0 - v)
                        sceneRGB = SIMD3<Float>(horiz * 0.9, vert * 0.95, (1.0 - u) * 0.28 + 0.05)
                    }
                } else if v < 0.82 {
                    // Middle section: 6x4 Macbeth ColorChecker chart
                    let col = min(max(Int(u * 6.0), 0), 5)
                    let row = min(max(Int(((v - 0.52) / 0.30) * 4.0), 0), 3)
                    let patchIdx = row * 6 + col
                    let cellU = (u * 6.0) - Float(col)
                    let cellV = (((v - 0.52) / 0.30) * 4.0) - Float(row)
                    if cellU < 0.06 || cellU > 0.94 || cellV < 0.08 || cellV > 0.92 {
                        sceneRGB = SIMD3<Float>(0.02, 0.02, 0.02)
                    } else {
                        sceneRGB = Self.colorCheckerLinearRGB[patchIdx]
                    }
                } else {
                    // Bottom strip: 14-Stop Dynamic Range Log Step Wedge
                    let stopIndex = min(max(Int(u * 14.0), 0), 13)
                    let stopValue = exp2(Float(stopIndex - 10)) * 0.95
                    sceneRGB = SIMD3<Float>(repeating: stopValue)
                }

                // Apply exposure gain and sensor CFA spectral sensitivity
                let rawRGB = sceneRGB * exposureGain * sensorFilterSensitivity

                // RGGB Bayer selection: (0,0)=R, (1,0)=G1, (0,1)=G2, (1,1)=B
                let channelVal: Float
                if !isOddRow {
                    channelVal = isOddCol ? rawRGB.y : rawRGB.x
                } else {
                    channelVal = isOddCol ? rawRGB.z : rawRGB.y
                }

                let adu = min(max(blackLevel + channelVal * span, 0.0), 16383.0)
                rowPtr[x] = UInt16(adu)
            }
        }

        var metadata = RAWFrameMetadata()
        metadata.cfaPattern = 0 // RGGB
        metadata.blackLevels = SIMD4<Float>(528, 528, 528, 528)
        metadata.whiteLevel = 16383.0
        metadata.whiteBalanceGains = SIMD3<Float>(2.05, 1.0, 1.65)
        metadata.colorMatrixRow0 = SIMD3<Float>(1.18, -0.12, -0.06)
        metadata.colorMatrixRow1 = SIMD3<Float>(-0.10, 1.16, -0.06)
        metadata.colorMatrixRow2 = SIMD3<Float>(-0.04, -0.16, 1.20)
        metadata.iso = iso
        metadata.exposureDurationSeconds = shutterSeconds

        return (pixelBuffer, metadata)
    }
}
