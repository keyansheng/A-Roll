import XCTest
import CoreVideo
import CoreMedia
import Metal
@testable import LogCam

final class LogCamPipelineTests: XCTestCase {

    func testSynthetic14BitBayerGeneration() throws {
        let width = 640
        let height = 480
        let generator = SyntheticRAWGenerator(width: width, height: height)
        let (rawBuffer, metadata) = try XCTUnwrap(
            generator.nextBayerFrame(iso: 200.0, shutterSeconds: 1.0 / 48.0)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(rawBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(rawBuffer), height)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(rawBuffer), kCVPixelFormatType_OneComponent16)
        XCTAssertEqual(metadata.whiteLevel, 16383.0)

        CVPixelBufferLockBaseAddress(rawBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rawBuffer, .readOnly) }

        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(rawBuffer)?.assumingMemoryBound(to: UInt16.self))
        let midValue = base[(height / 2) * (CVPixelBufferGetBytesPerRow(rawBuffer) / 2) + (width / 2)]
        XCTAssertGreaterThan(midValue, 528, "Center photosite should exceed the 528 black level")
        XCTAssertLessThanOrEqual(midValue, 16383, "14-bit photosite must be within 0...16383")
    }

    func testMetalDebayeringAnd10BitYCbCrPipelineAcrossLogCurves() throws {
        let pipeline = try XCTUnwrap(RAWImagePipeline())
        let generator = SyntheticRAWGenerator(width: 960, height: 720)
        let (rawBuffer, metadata) = try XCTUnwrap(
            generator.nextBayerFrame(iso: 200.0, shutterSeconds: 1.0 / 48.0)
        )

        var config = PipelineRenderConfiguration()
        config.gateMode = .openGate
        config.vignetteCorrectionEnabled = true
        config.noiseReduction = .low
        config.falseColorEnabled = true
        config.zebrasEnabled = true

        for curve in LogGammaCurve.allCases {
            config.logCurve = curve
            let monitorTex = try XCTUnwrap(
                pipeline.processRAWBayerFrame(
                    rawPixelBuffer: rawBuffer,
                    metadata: metadata,
                    config: config,
                    destinationRecordPixelBuffer: nil
                ),
                "Pipeline should succeed for curve \(curve.name)"
            )

            XCTAssertGreaterThan(monitorTex.width, 0)
            XCTAssertGreaterThan(monitorTex.height, 0)
        }
    }

    func testCubeLUTLoaderSeedsAndLoads3DTexture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let loader = CubeLUTLoader(device: device)

        let luts = loader.availableLUTs()
        XCTAssertGreaterThanOrEqual(luts.count, 4, "Should seed 4 built-in .cube LUTs")
        let firstURL = try XCTUnwrap(luts.first?.fileURL)

        let texture3D = try loader.loadCubeLUT(from: firstURL)
        XCTAssertEqual(texture3D.textureType, .type3D)
        XCTAssertEqual(texture3D.width, 17)
        XCTAssertEqual(texture3D.height, 17)
        XCTAssertEqual(texture3D.depth, 17)
    }

    func testTenBitHEVCRecordingFromDebayeredRAW() throws {
        let pipeline = try XCTUnwrap(RAWImagePipeline())
        let recorder = VideoRecorder()
        let generator = SyntheticRAWGenerator(width: 960, height: 720)

        let clipURL = try recorder.startRecording(
            gateMode: .uhd4K,
            frameRate: .fps24,
            codec: .hevc10Bit420,
            hevcBitrate: .mbps100,
            logCurve: .appleLog
        )

        var config = PipelineRenderConfiguration()
        config.gateMode = .uhd4K
        config.logCurve = .appleLog

        for frameIdx in 0..<6 {
            let (rawBuffer, metadata) = try XCTUnwrap(generator.nextBayerFrame())
            let recordBuffer = try XCTUnwrap(recorder.dequeueRecordPixelBuffer())
            let monitorTex = pipeline.processRAWBayerFrame(
                rawPixelBuffer: rawBuffer,
                metadata: metadata,
                config: config,
                destinationRecordPixelBuffer: recordBuffer
            )
            XCTAssertNotNil(monitorTex)

            let pts = CMTime(value: CMTimeValue(frameIdx), timescale: 24)
            recorder.appendVideoPixelBuffer(
                recordBuffer,
                presentationTime: pts,
                frameDuration: CaptureFrameRate.fps24.frameDuration
            )
        }

        let finishedExpectation = expectation(description: "Finish recording 10-bit HEVC .mov")
        recorder.stopRecording { url in
            XCTAssertNotNil(url)
            finishedExpectation.fulfill()
        }

        wait(for: [finishedExpectation], timeout: 10.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: clipURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 1024, "Recorded 10-bit Log .mov file should be non-empty")
        try? FileManager.default.removeItem(at: clipURL)
    }
}
