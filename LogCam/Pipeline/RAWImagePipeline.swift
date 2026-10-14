import Foundation
import Metal
import CoreVideo
import CoreMedia
import simd

/// Swift mirror of Metal's `PipelineUniforms` struct with identical 16-byte SIMD4 alignment
struct MetalPipelineUniforms {
    var cfaPattern: UInt32 = 0
    var logCurveIndex: UInt32 = 0
    var applyLUTToRecord: UInt32 = 0
    var applyLUTToMonitor: UInt32 = 0
    var rec709AssistEnabled: UInt32 = 0
    var zebrasEnabled: UInt32 = 0
    var falseColorEnabled: UInt32 = 0
    var rotate180: UInt32 = 0

    var blackLevels: SIMD4<Float> = SIMD4<Float>(528, 528, 528, 528)
    /// x = whiteLevel, y = exposureEV, z = vignetteStrength, w = denoiseStrength
    var sensorParams: SIMD4<Float> = SIMD4<Float>(16383.0, 0.0, 0.5, 0.28)
    /// xyz = wbGains, w = anamorphicStretch
    var wbAndAnamorphic: SIMD4<Float> = SIMD4<Float>(2.05, 1.0, 1.65, 1.0)
    /// xyz = colorMatrixRow0, w = zebraThreshold
    var colorMatrixRow0AndZebra: SIMD4<Float> = SIMD4<Float>(1.32, -0.24, -0.08, 0.90)
    /// xyz = colorMatrixRow1, w = framePhase
    var colorMatrixRow1AndPhase: SIMD4<Float> = SIMD4<Float>(-0.18, 1.28, -0.10, 0.0)
    /// xyz = colorMatrixRow2, w = lutIntensity
    var colorMatrixRow2AndLUT: SIMD4<Float> = SIMD4<Float>(-0.04, -0.31, 1.35, 1.0)
    /// xy = cropOrigin, zw = cropSize
    var cropRect: SIMD4<UInt32> = SIMD4<UInt32>(0, 0, 4032, 3024)
}

struct PipelineRenderConfiguration {
    var gateMode: CaptureGateMode = .openGate
    var logCurve: LogGammaCurve = .appleLog
    var lutMode: LUTApplicationMode = .off
    var lutIntensity: Float = 1.0
    var rec709GammaAssist: Bool = false
    var zebrasEnabled: Bool = false
    var zebraThreshold: Float = 0.90
    var falseColorEnabled: Bool = false
    var vignetteCorrectionEnabled: Bool = true
    var noiseReduction: NoiseReductionLevel = .low
    var anamorphicDesqueeze: AnamorphicDesqueeze = .none
    var rotate180ForDoF: Bool = false
    var captureOrientation: SensorCaptureOrientation = .portrait
    var exposureTrimEV: Float = 0.0
    var manualWhiteBalanceKelvin: Float = 5600.0
    var manualWhiteBalanceTint: Float = 0.0
    var useManualWhiteBalance: Bool = false
}

final class RAWImagePipeline {
    static let sharedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static var cachedLibrary: MTLLibrary?

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let lutLoader: CubeLUTLoader

    private var textureCache: CVMetalTextureCache?
    private let debayerPipeline: MTLComputePipelineState
    private let liveVideoPipeline: MTLComputePipelineState
    private let monitorAssistPipeline: MTLComputePipelineState
    private let ycbcr10EncodePipeline: MTLComputePipelineState

    private var identityLUTTexture: MTLTexture
    private var activeLUTTexture: MTLTexture?

    private var cleanLogTexture: MTLTexture?
    private var monitorTextureRing: [MTLTexture] = []
    private var monitorRingIndex: Int = 0
    private var frameCounter: UInt64 = 0
    private let lock = NSLock()
    private let renderLock = NSLock()

    init?() {
        guard let mtlDevice = Self.sharedDevice ?? MTLCreateSystemDefaultDevice(),
              let queue = mtlDevice.makeCommandQueue(),
              let library = Self.loadMetalLibrary(device: mtlDevice) else {
            return nil
        }

        self.device = mtlDevice
        self.commandQueue = queue
        self.lutLoader = CubeLUTLoader(device: mtlDevice)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &cache)
        self.textureCache = cache

        guard let debayerFn = library.makeFunction(name: "debayer_raw_bayer_kernel"),
              let liveVideoFn = library.makeFunction(name: "process_live_video_frame_kernel"),
              let monitorFn = library.makeFunction(name: "monitoring_assist_kernel"),
              let ycbcr10Fn = library.makeFunction(name: "rgb_to_ycbcr10_biplanar_kernel"),
              let debayerPSO = try? mtlDevice.makeComputePipelineState(function: debayerFn),
              let liveVideoPSO = try? mtlDevice.makeComputePipelineState(function: liveVideoFn),
              let monitorPSO = try? mtlDevice.makeComputePipelineState(function: monitorFn),
              let ycbcr10PSO = try? mtlDevice.makeComputePipelineState(function: ycbcr10Fn),
              let identityLUT = lutLoader.makeIdentityLUTTexture(size: 17) else {
            return nil
        }

        self.debayerPipeline = debayerPSO
        self.liveVideoPipeline = liveVideoPSO
        self.monitorAssistPipeline = monitorPSO
        self.ycbcr10EncodePipeline = ycbcr10PSO
        self.identityLUTTexture = identityLUT
        self.activeLUTTexture = identityLUT
    }

    func setActiveLUT(descriptor: LUTDescriptor?) {
        lock.lock()
        defer { lock.unlock() }

        guard let descriptor, let url = descriptor.fileURL else {
            activeLUTTexture = identityLUTTexture
            return
        }
        if let loaded = try? lutLoader.loadCubeLUT(from: url) {
            activeLUTTexture = loaded
        } else {
            activeLUTTexture = identityLUTTexture
        }
    }

    /// Converts Kelvin (2000K..10000K) & Tint (-150..+150) to RGB White Balance multipliers
    static func kelvinAndTintToRGBGains(kelvin: Float, tint: Float) -> SIMD3<Float> {
        let clampedK = min(max(kelvin, 2000.0), 10000.0)
        // Approximate Planckian locus shift relative to D55 (5500K)
        let normK = (clampedK - 5500.0) / 4500.0
        let rGain = 2.05 + normK * 0.68
        let bGain = 1.65 - normK * 0.62
        let gGain = 1.00 - (tint / 150.0) * 0.18
        return SIMD3<Float>(max(rGain, 0.5), max(gGain, 0.5), max(bGain, 0.5))
    }

    /// Processes a true 14-bit/16-bit single-channel Bayer RAW `CVPixelBuffer` (from `AVCapturePhoto.pixelBuffer`)
    /// Returns the live monitor `MTLTexture` and optionally encodes into `destinationRecordPixelBuffer`
    func processRAWBayerFrame(
        rawPixelBuffer: CVPixelBuffer,
        metadata: RAWFrameMetadata,
        config: PipelineRenderConfiguration,
        destinationRecordPixelBuffer: CVPixelBuffer?
    ) -> MTLTexture? {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let cache = textureCache else { return nil }

        let rawWidth = CVPixelBufferGetWidth(rawPixelBuffer)
        let rawHeight = CVPixelBufferGetHeight(rawPixelBuffer)

        var cvRawTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            rawPixelBuffer,
            nil,
            .r16Uint,
            rawWidth,
            rawHeight,
            0,
            &cvRawTex
        )

        guard status == kCVReturnSuccess,
              let cvRawTex,
              let rawMTLTexture = CVMetalTextureGetTexture(cvRawTex) else {
            return nil
        }

        let outWidth: Int
        let outHeight: Int
        if let destBuffer = destinationRecordPixelBuffer {
            outWidth = CVPixelBufferGetWidth(destBuffer)
            outHeight = CVPixelBufferGetHeight(destBuffer)
        } else {
            let targetDims = config.gateMode.dimensions(for: config.captureOrientation)
            let scale = 1920.0 / Double(max(targetDims.width, targetDims.height, 1))
            outWidth = max(Int((Double(targetDims.width) * scale).rounded()) & ~1, 480)
            outHeight = max(Int((Double(targetDims.height) * scale).rounded()) & ~1, 480)
        }

        ensureIntermediateTextures(width: outWidth, height: outHeight)
        guard let cleanTex = cleanLogTexture,
              let monitorTex = nextMonitorTexture(),
              let cmdBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        var uniforms = buildUniforms(
            rawWidth: rawWidth,
            rawHeight: rawHeight,
            metadata: metadata,
            config: config
        )

        lock.lock()
        let lutTex = activeLUTTexture ?? identityLUTTexture
        lock.unlock()

        // Pass 1: 14-bit Bayer RAW Demosaic + Vignette + Denoise + White Balance + CCM + Log Gamma + Optional Baked LUT
        if let encoder = cmdBuffer.makeComputeCommandEncoder() {
            encoder.label = "RAW Bayer Demosaic & Log Encode"
            encoder.setComputePipelineState(debayerPipeline)
            encoder.setTexture(rawMTLTexture, index: 0)
            encoder.setTexture(lutTex, index: 1)
            encoder.setTexture(cleanTex, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<MetalPipelineUniforms>.stride, index: 0)
            dispatchThreads(encoder: encoder, pipeline: debayerPipeline, width: outWidth, height: outHeight)
            encoder.endEncoding()
        }

        // Pass 2: If recording, encode Clean Log Texture into 10-bit YCbCr Bi-Planar or BGRA `destinationRecordPixelBuffer`
        if let destBuffer = destinationRecordPixelBuffer {
            encodeToRecordPixelBuffer(
                cleanLogTexture: cleanTex,
                destinationPixelBuffer: destBuffer,
                commandBuffer: cmdBuffer
            )
        }

        // Pass 3: Live Monitor Assists (Monitoring LUT, Rec.709 Gamma Assist, False Color, Zebras)
        if let encoder = cmdBuffer.makeComputeCommandEncoder() {
            encoder.label = "Live Monitor Video Assists"
            encoder.setComputePipelineState(monitorAssistPipeline)
            encoder.setTexture(cleanTex, index: 0)
            encoder.setTexture(lutTex, index: 1)
            encoder.setTexture(monitorTex, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<MetalPipelineUniforms>.stride, index: 0)
            dispatchThreads(
                encoder: encoder,
                pipeline: monitorAssistPipeline,
                width: monitorTex.width,
                height: monitorTex.height
            )
            encoder.endEncoding()
        }

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        return monitorTex
    }

    /// Processes a live BGRA camera preview `CVPixelBuffer` (used during standby framing and fallback recording)
    func processLiveVideoPreviewFrame(
        bgraPixelBuffer: CVPixelBuffer,
        metadata: RAWFrameMetadata,
        config: PipelineRenderConfiguration,
        destinationRecordPixelBuffer: CVPixelBuffer? = nil
    ) -> MTLTexture? {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let cache = textureCache else { return nil }

        let srcW = CVPixelBufferGetWidth(bgraPixelBuffer)
        let srcH = CVPixelBufferGetHeight(bgraPixelBuffer)

        var cvSrcTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            bgraPixelBuffer,
            nil,
            .bgra8Unorm,
            srcW,
            srcH,
            0,
            &cvSrcTex
        )

        guard status == kCVReturnSuccess,
              let cvSrcTex,
              let srcMTLTexture = CVMetalTextureGetTexture(cvSrcTex) else {
            return nil
        }

        let outWidth: Int
        let outHeight: Int
        if let destBuffer = destinationRecordPixelBuffer {
            outWidth = CVPixelBufferGetWidth(destBuffer)
            outHeight = CVPixelBufferGetHeight(destBuffer)
        } else {
            let targetDims = config.gateMode.dimensions(for: config.captureOrientation)
            let scale = 1920.0 / Double(max(targetDims.width, targetDims.height, 1))
            outWidth = max(Int((Double(targetDims.width) * scale).rounded()) & ~1, 480)
            outHeight = max(Int((Double(targetDims.height) * scale).rounded()) & ~1, 480)
        }

        ensureIntermediateTextures(width: outWidth, height: outHeight)
        guard let cleanTex = cleanLogTexture,
              let monitorTex = nextMonitorTexture(),
              let cmdBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        var uniforms = buildUniforms(
            rawWidth: srcW,
            rawHeight: srcH,
            metadata: metadata,
            config: config
        )

        lock.lock()
        let lutTex = activeLUTTexture ?? identityLUTTexture
        lock.unlock()

        if let encoder = cmdBuffer.makeComputeCommandEncoder() {
            encoder.label = "Live Preview Log Pipeline"
            encoder.setComputePipelineState(liveVideoPipeline)
            encoder.setTexture(srcMTLTexture, index: 0)
            encoder.setTexture(lutTex, index: 1)
            encoder.setTexture(cleanTex, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<MetalPipelineUniforms>.stride, index: 0)
            dispatchThreads(encoder: encoder, pipeline: liveVideoPipeline, width: cleanTex.width, height: cleanTex.height)
            encoder.endEncoding()
        }

        if let destBuffer = destinationRecordPixelBuffer {
            encodeToRecordPixelBuffer(
                cleanLogTexture: cleanTex,
                destinationPixelBuffer: destBuffer,
                commandBuffer: cmdBuffer
            )
        }

        if let encoder = cmdBuffer.makeComputeCommandEncoder() {
            encoder.label = "Live Monitor Assists"
            encoder.setComputePipelineState(monitorAssistPipeline)
            encoder.setTexture(cleanTex, index: 0)
            encoder.setTexture(lutTex, index: 1)
            encoder.setTexture(monitorTex, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<MetalPipelineUniforms>.stride, index: 0)
            dispatchThreads(encoder: encoder, pipeline: monitorAssistPipeline, width: monitorTex.width, height: monitorTex.height)
            encoder.endEncoding()
        }

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        return monitorTex
    }

    // MARK: - Private Helpers

    private func buildUniforms(
        rawWidth: Int,
        rawHeight: Int,
        metadata: RAWFrameMetadata,
        config: PipelineRenderConfiguration
    ) -> MetalPipelineUniforms {
        frameCounter &+= 1

        // Compute active sensor crop in native landscape sensor coordinates (long axis × short axis)
        let targetAspect = Float(config.gateMode.aspectRatio)
        let sensorAspect = Float(rawWidth) / Float(max(rawHeight, 1))

        var cropW = rawWidth
        var cropH = rawHeight
        if targetAspect > sensorAspect {
            cropH = Int(Float(rawWidth) / targetAspect) & ~1
        } else {
            cropW = Int(Float(rawHeight) * targetAspect) & ~1
        }
        // Keep even alignment so 2x2 Bayer phase stays consistent
        let cropX = ((rawWidth - cropW) / 2) & ~1
        let cropY = ((rawHeight - cropH) / 2) & ~1

        let wbGains = config.useManualWhiteBalance
            ? Self.kelvinAndTintToRGBGains(kelvin: config.manualWhiteBalanceKelvin, tint: config.manualWhiteBalanceTint)
            : metadata.whiteBalanceGains

        var u = MetalPipelineUniforms()
        u.cfaPattern = metadata.cfaPattern
        u.logCurveIndex = UInt32(config.logCurve.rawValue)
        u.applyLUTToRecord = (config.lutMode == .bakedIn) ? 1 : 0
        u.applyLUTToMonitor = (config.lutMode == .monitoringOnly) ? 1 : 0
        u.rec709AssistEnabled = config.rec709GammaAssist ? 1 : 0
        u.zebrasEnabled = config.zebrasEnabled ? 1 : 0
        u.falseColorEnabled = config.falseColorEnabled ? 1 : 0
        var rotFlags: UInt32 = config.rotate180ForDoF ? 1 : 0
        rotFlags |= ((config.captureOrientation.rawValue & 3) << 1)
        u.rotate180 = rotFlags

        u.blackLevels = metadata.blackLevels
        u.sensorParams = SIMD4<Float>(
            metadata.whiteLevel,
            metadata.baselineExposureEV + config.exposureTrimEV,
            config.vignetteCorrectionEnabled ? 0.65 : 0.0,
            config.noiseReduction.shaderStrength
        )
        u.wbAndAnamorphic = SIMD4<Float>(
            wbGains.x,
            wbGains.y,
            wbGains.z,
            config.anamorphicDesqueeze.rawValue
        )
        u.colorMatrixRow0AndZebra = SIMD4<Float>(
            metadata.colorMatrixRow0.x,
            metadata.colorMatrixRow0.y,
            metadata.colorMatrixRow0.z,
            config.zebraThreshold
        )
        u.colorMatrixRow1AndPhase = SIMD4<Float>(
            metadata.colorMatrixRow1.x,
            metadata.colorMatrixRow1.y,
            metadata.colorMatrixRow1.z,
            Float(frameCounter % 600) * 0.05
        )
        u.colorMatrixRow2AndLUT = SIMD4<Float>(
            metadata.colorMatrixRow2.x,
            metadata.colorMatrixRow2.y,
            metadata.colorMatrixRow2.z,
            config.lutIntensity
        )
        u.cropRect = SIMD4<UInt32>(
            UInt32(max(cropX, 0)),
            UInt32(max(cropY, 0)),
            UInt32(max(cropW, 2)),
            UInt32(max(cropH, 2))
        )
        return u
    }

    private func encodeToRecordPixelBuffer(
        cleanLogTexture: MTLTexture,
        destinationPixelBuffer: CVPixelBuffer,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let cache = textureCache else { return }
        let pixelFormat = CVPixelBufferGetPixelFormatType(destinationPixelBuffer)
        let width = CVPixelBufferGetWidth(destinationPixelBuffer)
        let height = CVPixelBufferGetHeight(destinationPixelBuffer)

        if CVPixelBufferIsPlanar(destinationPixelBuffer) && CVPixelBufferGetPlaneCount(destinationPixelBuffer) >= 2 {
            // 10-bit YCbCr Bi-Planar (4:2:0 P010, 4:2:2 P210, or 4:4:4 P410)
            let lumaW = CVPixelBufferGetWidthOfPlane(destinationPixelBuffer, 0)
            let lumaH = CVPixelBufferGetHeightOfPlane(destinationPixelBuffer, 0)
            let chromaW = CVPixelBufferGetWidthOfPlane(destinationPixelBuffer, 1)
            let chromaH = CVPixelBufferGetHeightOfPlane(destinationPixelBuffer, 1)

            var cvLuma: CVMetalTexture?
            var cvChroma: CVMetalTexture?

            let s0 = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, destinationPixelBuffer, nil,
                .r16Uint, lumaW, lumaH, 0, &cvLuma
            )
            let s1 = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, destinationPixelBuffer, nil,
                .rg16Uint, chromaW, chromaH, 1, &cvChroma
            )

            if s0 == kCVReturnSuccess, s1 == kCVReturnSuccess,
                let cvLuma, let cvChroma,
                let lumaTex = CVMetalTextureGetTexture(cvLuma),
                let chromaTex = CVMetalTextureGetTexture(cvChroma),
                let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "10-Bit YCbCr Bi-Planar Encode"
                encoder.setComputePipelineState(ycbcr10EncodePipeline)
                encoder.setTexture(cleanLogTexture, index: 0)
                encoder.setTexture(lumaTex, index: 1)
                encoder.setTexture(chromaTex, index: 2)
                dispatchThreads(encoder: encoder, pipeline: ycbcr10EncodePipeline, width: lumaW, height: lumaH)
                encoder.endEncoding()
            }
        } else {
            // Single-plane RGBA16Float or BGRA8 fallback
            let mtlFormat: MTLPixelFormat = (pixelFormat == kCVPixelFormatType_64RGBAHalf) ? .rgba16Float : .bgra8Unorm
            var cvDest: CVMetalTexture?
            let s = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, destinationPixelBuffer, nil,
                mtlFormat, width, height, 0, &cvDest
            )
            if s == kCVReturnSuccess,
               let cvDest,
               let destTex = CVMetalTextureGetTexture(cvDest),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                let copyW = min(cleanLogTexture.width, destTex.width)
                let copyH = min(cleanLogTexture.height, destTex.height)
                if cleanLogTexture.pixelFormat == destTex.pixelFormat {
                    blit.copy(
                        from: cleanLogTexture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                        to: destTex,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                }
                blit.endEncoding()
            }
        }
    }

    private func nextMonitorTexture() -> MTLTexture? {
        guard !monitorTextureRing.isEmpty else { return nil }
        let tex = monitorTextureRing[monitorRingIndex % monitorTextureRing.count]
        monitorRingIndex = (monitorRingIndex + 1) % monitorTextureRing.count
        return tex
    }

    private func ensureIntermediateTextures(width: Int, height: Int) {
        let portraitW = min(width, height)
        let portraitH = max(width, height)
        // Monitor output scaled to 1920h max in portrait-locked screen coordinates for 60Hz UI rendering
        let monitorScale = min(1.0, 1920.0 / Double(max(portraitH, 1)))
        let monW = max(Int(Double(portraitW) * monitorScale), 480)
        let monH = max(Int(Double(portraitH) * monitorScale), 640)

        if let clean = cleanLogTexture,
           clean.width == width,
           clean.height == height,
           monitorTextureRing.count == 3,
           monitorTextureRing[0].width == monW,
           monitorTextureRing[0].height == monH {
            return
        }

        let cleanDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        cleanDesc.usage = [.shaderRead, .shaderWrite]
        cleanDesc.storageMode = .private
        cleanLogTexture = device.makeTexture(descriptor: cleanDesc)

        let monDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: monW,
            height: monH,
            mipmapped: false
        )
        monDesc.usage = [.shaderRead, .shaderWrite]
        monDesc.storageMode = .private

        var ring: [MTLTexture] = []
        for _ in 0..<3 {
            if let tex = device.makeTexture(descriptor: monDesc) {
                ring.append(tex)
            }
        }
        monitorTextureRing = ring
        monitorRingIndex = 0
    }

    private func dispatchThreads(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let w = pipeline.threadExecutionWidth
        let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    static func loadMetalLibrary(device: MTLDevice) -> MTLLibrary? {
        if let cached = cachedLibrary {
            return cached
        }
        if let defaultLib = device.makeDefaultLibrary(),
           defaultLib.makeFunction(name: "debayer_raw_bayer_kernel") != nil {
            cachedLibrary = defaultLib
            return defaultLib
        }

        let candidateURLs: [URL?] = [
            Bundle.main.url(forResource: "RAWShaders", withExtension: "metal"),
            Bundle(for: RAWImagePipeline.self).url(forResource: "RAWShaders", withExtension: "metal"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("RAWShaders.metal")
        ]

        for case let url? in candidateURLs {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                let options = MTLCompileOptions()
                if #available(iOS 18.0, *) {
                    options.mathMode = .fast
                }
                if let compiled = try? device.makeLibrary(source: source, options: options) {
                    cachedLibrary = compiled
                    return compiled
                }
            }
        }
        return nil
    }
}
