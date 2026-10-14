import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import Metal
import Combine
import UIKit

@MainActor
final class RAWCaptureSessionManager: NSObject, ObservableObject {
    // MARK: - Published Cinema Camera State

    @Published var gateMode: CaptureGateMode = .openGate {
        didSet {
            syncCachedRenderConfig()
            updateSessionFormatIfNeeded()
        }
    }
    @Published var frameRate: CaptureFrameRate = .fps30 {
        didSet {
            syncCachedRenderConfig()
            updateFrameRateTiming()
        }
    }
    @Published var codec: VideoCodecOption = .hevc10Bit422Or444Default
    @Published var hevcBitrate: HEVCBitrateOption = .mbps300
    @Published var logCurve: LogGammaCurve = .appleLog {
        didSet { syncCachedRenderConfig() }
    }
    @Published var lutMode: LUTApplicationMode = .off {
        didSet { syncCachedRenderConfig() }
    }
    @Published var selectedLUT: LUTDescriptor? {
        didSet { imagePipeline?.setActiveLUT(descriptor: selectedLUT) }
    }
    @Published var availableLUTs: [LUTDescriptor] = []
    @Published var lutIntensity: Float = 1.0 {
        didSet { syncCachedRenderConfig() }
    }

    // Video Assists
    @Published var rec709GammaAssist: Bool = false {
        didSet { syncCachedRenderConfig() }
    }
    @Published var zebrasEnabled: Bool = false {
        didSet { syncCachedRenderConfig() }
    }
    @Published var zebraThreshold: Float = 0.90 {
        didSet { syncCachedRenderConfig() }
    }
    @Published var falseColorEnabled: Bool = false {
        didSet { syncCachedRenderConfig() }
    }
    @Published var showGridOverlay: Bool = true
    @Published var showHorizonOverlay: Bool = true
    @Published var anamorphicDesqueeze: AnamorphicDesqueeze = .none {
        didSet { syncCachedRenderConfig() }
    }
    @Published var rotate180ForDoF: Bool = false {
        didSet { syncCachedRenderConfig() }
    }

    // Image Pipeline Controls
    @Published var vignetteCorrectionEnabled: Bool = true {
        didSet { syncCachedRenderConfig() }
    }
    @Published var noiseReduction: NoiseReductionLevel = .low {
        didSet { syncCachedRenderConfig() }
    }
    @Published var opticalStabilizationEnabled: Bool = true {
        didSet { applyOpticalStabilizationSetting() }
    }
    @Published var gyroflowLoggingEnabled: Bool = true

    // Exposure, Focus & White Balance
    @Published var selectedLens: CameraLensType = .wide {
        didSet { reconfigureCameraDevice() }
    }
    @Published var exposureMode: ExposureControlMode = .shutterPriority {
        didSet { applyExposureSettings() }
    }
    @Published var lockExposureAtStart: Bool = true
    @Published var selectedShutterPreset: ShutterSpeedPreset = ShutterSpeedPreset(denominator: 60) {
        didSet { applyExposureSettings() }
    }
    @Published var manualISO: Float = 100.0 {
        didSet { applyExposureSettings() }
    }
    @Published var minSupportedISO: Float = 32.0
    @Published var maxSupportedISO: Float = 3200.0
    @Published var liveSensorISO: Float = 100.0
    @Published var liveShutterDenominator: Int = 60
    @Published var exposureTrimEV: Float = 0.0 {
        didSet { syncCachedRenderConfig() }
    }

    @Published var isManualFocusEnabled: Bool = false {
        didSet { applyFocusSettings() }
    }
    @Published var manualFocusLensPosition: Float = 0.5 {
        didSet {
            if isManualFocusEnabled && !videoRecorder.isRecording {
                applyFocusSettings()
            }
        }
    }

    @Published var whiteBalanceMode: WhiteBalanceControlMode = .auto {
        didSet {
            syncCachedRenderConfig()
            applyWhiteBalanceSettings()
        }
    }
    @Published var lockWhiteBalanceAtStart: Bool = true
    @Published var manualWhiteBalanceKelvin: Float = 5600.0 {
        didSet {
            syncCachedRenderConfig()
            applyWhiteBalanceSettings()
        }
    }
    @Published var manualWhiteBalanceTint: Float = 0.0 {
        didSet {
            syncCachedRenderConfig()
            applyWhiteBalanceSettings()
        }
    }

    // Live Telemetry & Output
    @Published var latestMonitorTexture: MTLTexture?
    @Published var activeCaptureOrientation: SensorCaptureOrientation = .portrait {
        didSet { syncCachedRenderConfig() }
    }
    @Published var measuredRAWFPS: Double = 0.0
    @Published var isSimulatorSyntheticMode: Bool = false
    @Published var activeSensorFormatDescription: String = "4032×3024 · 14-Bit Bayer RGGB"
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var batteryLevel: Float = 1.0
    @Published var statusBannerMessage: String?

    // UI Presentation State
    @Published var activeDrawer: ActiveControlDrawer? = nil
    @Published var showingSettingsSheet: Bool = false
    @Published var showingRecordingsSheet: Bool = false
    @Published var isImportingCubeFile: Bool = false

    // Subsystems
    nonisolated let imagePipeline = RAWImagePipeline()
    nonisolated let videoRecorder = VideoRecorder()
    let gyroflowLogger = GyroflowLogger()
    nonisolated let audioMonitor = AudioMonitor()

    // MARK: - Private AVFoundation Pipeline State

    nonisolated(unsafe) private let captureSession = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioDataOutput = AVCaptureAudioDataOutput()
    nonisolated(unsafe) private var activeVideoDevice: AVCaptureDevice?
    nonisolated(unsafe) private var activeRawPixelFormat: OSType = 0

    private let sessionQueue = DispatchQueue(label: "com.logcam.session.queue", qos: .userInteractive)
    private let rawBurstQueue = DispatchQueue(label: "com.logcam.rawburst.queue", qos: .userInteractive)
    private let videoSampleQueue = DispatchQueue(label: "com.logcam.videosample.queue", qos: .userInteractive)
    private let audioSampleQueue = DispatchQueue(label: "com.logcam.audiosample.queue", qos: .userInitiated)

    private var rawBurstTimer: DispatchSourceTimer?
    private let inFlightLock = NSLock()
    nonisolated(unsafe) private var inFlightRAWPhotoCount: Int = 0
    private let maxInFlightRAWPhotos: Int = 4
    nonisolated(unsafe) private var activePhotoDelegates: [Int64: RAWPhotoCaptureDelegateProxy] = [:]

    private let configLock = NSLock()
    nonisolated(unsafe) private var cachedRenderConfig = PipelineRenderConfiguration()
    nonisolated(unsafe) private var cachedFrameDuration: CMTime = CMTime(value: 1, timescale: 30)
    nonisolated(unsafe) private var lastRAWPhotoFrameTime: CFTimeInterval = 0

    private let syntheticGenerator = SyntheticRAWGenerator(width: 1344, height: 1008)
    nonisolated(unsafe) private var latestMetadata = RAWFrameMetadata()

    // FPS Measurement
    private var fpsFrameTimestamps: [CFTimeInterval] = []

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = max(UIDevice.current.batteryLevel, 0.85)
        thermalState = ProcessInfo.processInfo.thermalState

        gyroflowLogger.onOrientationChanged = { [weak self] newOrientation in
            guard let self else { return }
            // Keep capture dimensions locked while actively recording a clip
            if !self.videoRecorder.isRecording {
                self.activeCaptureOrientation = newOrientation
            }
        }

        syncCachedRenderConfig()
        refreshLUTList()
        setupThermalAndBatteryObservers()
    }

    func refreshLUTList() {
        guard let loader = imagePipeline?.lutLoader else { return }
        let list = loader.availableLUTs()
        availableLUTs = list
        if selectedLUT == nil, let first = list.first {
            selectedLUT = first
        }
    }

    func importLUTFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let destDir = CubeLUTLoader.lutsDirectoryURL
        let destURL = destDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destURL)
        try? FileManager.default.copyItem(at: url, to: destURL)
        refreshLUTList()
        if let imported = availableLUTs.first(where: { $0.fileURL?.lastPathComponent == url.lastPathComponent }) {
            selectedLUT = imported
            if lutMode == .off {
                lutMode = .monitoringOnly
            }
        }
    }

    // MARK: - Start / Stop Camera Pipeline

    func startPipeline() {
        #if targetEnvironment(simulator)
        startSyntheticRAWLoop()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureHardwareSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.configureHardwareSession()
                    } else {
                        self?.startSyntheticRAWLoop()
                    }
                }
            }
        default:
            startSyntheticRAWLoop()
        }
        #endif
    }

    func stopPipeline() {
        stopRAWBurstTimer()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    // MARK: - Hardware AVFoundation Setup (Open Gate 4032x3024 Bayer RAW @ 30fps)

    private func configureHardwareSession() {
        let selectedDeviceType = selectedLens.deviceType
        let wantsStabilization = opticalStabilizationEnabled

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .inputPriority

            // Remove existing inputs/outputs
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }

            guard let device = AVCaptureDevice.default(
                selectedDeviceType,
                for: .video,
                position: .back
            ) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let videoInput = try? AVCaptureDeviceInput(device: device),
            self.captureSession.canAddInput(videoInput) else {
                self.captureSession.commitConfiguration()
                Task { @MainActor in
                    self.startSyntheticRAWLoop()
                }
                return
            }

            self.captureSession.addInput(videoInput)
            self.activeVideoDevice = device

            // Add Audio Input & Output only if microphone access is already authorized
            let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if audioStatus == .authorized {
                if let audioDevice = AVCaptureDevice.default(for: .audio),
                   let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   self.captureSession.canAddInput(audioInput) {
                    self.captureSession.addInput(audioInput)
                }
                self.audioDataOutput.setSampleBufferDelegate(self, queue: self.audioSampleQueue)
                if self.captureSession.canAddOutput(self.audioDataOutput) {
                    self.captureSession.addOutput(self.audioDataOutput)
                }
            }

            // Add AVCaptureVideoDataOutput for live 30fps Log preview & exposure metering
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoSampleQueue)
            if self.captureSession.canAddOutput(self.videoDataOutput) {
                self.captureSession.addOutput(self.videoDataOutput)
            }

            // Add AVCapturePhotoOutput for 30fps 14-Bit Bayer RAW capture
            if self.captureSession.canAddOutput(self.photoOutput) {
                self.captureSession.addOutput(self.photoOutput)
            }

            // Select optimal 4:3 Open Gate (4032x3024) 30fps Bayer RAW format
            let formatInfo = self.selectBestRAWOpenGateFormat(for: device)

            // Configure PhotoOutput safely (avoid .speed prioritization which conflicts with 12MP/48MP RAW on iOS)
            self.photoOutput.maxPhotoQualityPrioritization = .balanced
            if #available(iOS 17.0, *) {
                if self.photoOutput.isZeroShutterLagSupported {
                    self.photoOutput.isZeroShutterLagEnabled = true
                }
                if self.photoOutput.isAutoDeferredPhotoDeliverySupported {
                    self.photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
                }
            }

            if let rawType = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                self.activeRawPixelFormat = rawType
            } else {
                self.activeRawPixelFormat = 0
            }

            // Keep videoDataOutput connection in native 0-degree sensor orientation (4032x3024 landscape-left)
            // so both videoDataOutput and photoOutput share identical sensor coordinates and are rotated on the GPU.
            if let connection = self.videoDataOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(0) {
                        connection.videoRotationAngle = 0
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = wantsStabilization ? .standard : .off
                }
            }

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()

            // Request microphone access asynchronously if not determined yet
            if audioStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard granted, let self else { return }
                    self.sessionQueue.async {
                        self.captureSession.beginConfiguration()
                        if let audioDevice = AVCaptureDevice.default(for: .audio),
                           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                           self.captureSession.canAddInput(audioInput) {
                            self.captureSession.addInput(audioInput)
                        }
                        self.audioDataOutput.setSampleBufferDelegate(self, queue: self.audioSampleQueue)
                        if self.captureSession.canAddOutput(self.audioDataOutput) {
                            self.captureSession.addOutput(self.audioDataOutput)
                        }
                        self.captureSession.commitConfiguration()
                    }
                }
            }

            let minISO = device.activeFormat.minISO
            let maxISO = min(device.activeFormat.maxISO, 6400.0)

            Task { @MainActor in
                self.isSimulatorSyntheticMode = false
                self.minSupportedISO = minISO
                self.maxSupportedISO = maxISO
                self.manualISO = min(max(self.manualISO, minISO), maxISO)
                self.activeSensorFormatDescription = formatInfo
                self.applyExposureSettings()
                self.applyFocusSettings()
                self.applyWhiteBalanceSettings()
            }
        }
    }

    /// Finds the best 4:3 Open Gate (4032x3024) 8-bit 420v/420f format supporting 30fps and 12MP Bayer RAW photo capture
    private nonisolated func selectBestRAWOpenGateFormat(for device: AVCaptureDevice) -> String {
        var openGateCandidates: [AVCaptureDevice.Format] = []

        for format in device.formats {
            let desc = format.formatDescription
            let subType = CMFormatDescriptionGetMediaSubType(desc)
            guard subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                continue
            }

            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let supports30FPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30.0 && $0.maxFrameRate >= 30.0
            }
            guard supports30FPS, dims.width <= 4032 else { continue }

            let isOpenGateAspect = abs((Double(dims.width) / Double(max(dims.height, 1))) - (4.0 / 3.0)) < 0.08
            if isOpenGateAspect {
                openGateCandidates.append(format)
            }
        }

        // Sort candidates by highest video resolution first, prioritizing formats that support 4032x3024 12MP photo dimensions
        openGateCandidates.sort { a, b in
            let dimsA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let dimsB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pixelsA = dimsA.width * dimsA.height
            let pixelsB = dimsB.width * dimsB.height
            if pixelsA != pixelsB {
                return pixelsA > pixelsB
            }
            if #available(iOS 16.0, *) {
                let has12MPA = a.supportedMaxPhotoDimensions.contains { $0.width == 4032 && $0.height == 3024 }
                let has12MPB = b.supportedMaxPhotoDimensions.contains { $0.width == 4032 && $0.height == 3024 }
                if has12MPA != has12MPB {
                    return has12MPA
                }
            }
            return false
        }

        var chosenFormat: AVCaptureDevice.Format? = openGateCandidates.first
        if chosenFormat == nil {
            chosenFormat = device.formats.last { format in
                let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let isStandardYUV = (subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                                     subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return isStandardYUV && dims.width <= 4032 && format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 30.0 && $0.maxFrameRate >= 30.0
                }
            }
        }

        guard let fallbackFormat = chosenFormat else {
            return "Standard Video Format"
        }

        var finalFormat = fallbackFormat

        do {
            try device.lockForConfiguration()

            // Probe top 4:3 candidates to pick one that exposes Bayer RAW photo pixel formats on photoOutput
            for candidate in openGateCandidates {
                device.activeFormat = candidate
                if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
                    finalFormat = candidate
                    break
                }
            }

            device.activeFormat = finalFormat

            let desiredDuration = CMTime(value: 1, timescale: 30)
            if let range = finalFormat.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= 30.0 && $0.maxFrameRate >= 30.0
            }) ?? finalFormat.videoSupportedFrameRateRanges.first {
                let clampedDur = CMTimeMinimum(CMTimeMaximum(desiredDuration, range.minFrameDuration), range.maxFrameDuration)
                device.activeVideoMinFrameDuration = clampedDur
                device.activeVideoMaxFrameDuration = clampedDur
            }

            if #available(iOS 16.0, *) {
                let twelveMPDims = finalFormat.supportedMaxPhotoDimensions.filter { $0.width <= 4032 }
                if let maxDims = twelveMPDims.last ?? finalFormat.supportedMaxPhotoDimensions.first {
                    photoOutput.maxPhotoDimensions = maxDims
                }
            }
            device.unlockForConfiguration()
        } catch {
            // Ignore configuration lock error
        }

        let dims = CMVideoFormatDescriptionGetDimensions(finalFormat.formatDescription)
        return "\(dims.width)×\(dims.height) · 14-Bit Bayer RAW"
    }

    private func reconfigureCameraDevice() {
        guard !videoRecorder.isRecording else { return }
        if !isSimulatorSyntheticMode {
            configureHardwareSession()
        }
    }

    private func updateSessionFormatIfNeeded() {
        // Crop origin & size update dynamically in the Metal shader without interrupting the session
    }

    private func updateFrameRateTiming() {
        let rate = frameRate
        if isSimulatorSyntheticMode || videoRecorder.isRecording {
            restartRAWBurstTimer(fps: rate.rawValue)
        }
        guard let device = activeVideoDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let desiredDur = rate.frameDuration
                let targetFPS = Double(rate.rawValue)
                if let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
                    $0.minFrameRate <= targetFPS && $0.maxFrameRate >= targetFPS
                }) ?? device.activeFormat.videoSupportedFrameRateRanges.first {
                    let clampedDur = CMTimeMinimum(CMTimeMaximum(desiredDur, range.minFrameDuration), range.maxFrameDuration)
                    device.activeVideoMinFrameDuration = clampedDur
                    device.activeVideoMaxFrameDuration = clampedDur
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - 30fps RAW Photo API Burst Engine

    /// Starts the high-precision timer that fires `AVCapturePhotoOutput.capturePhoto` up to 30 times a second
    private func startRAWBurstTimer(fps: Int) {
        stopRAWBurstTimer()

        let useSynthetic = isSimulatorSyntheticMode
        let rawPixelFormat = activeRawPixelFormat

        // Never start a synthetic placeholder timer on physical hardware; if RAW photo isn't exposed on the current lens,
        // videoDataOutput cleanly drives 100% of preview and recording.
        if !useSynthetic && rawPixelFormat == 0 {
            return
        }

        let intervalNanoseconds = Int(1_000_000_000.0 / Double(max(fps, 1)))
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: rawBurstQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(intervalNanoseconds),
            leeway: .nanoseconds(0)
        )

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if useSynthetic {
                self.stepSyntheticRAWFrame()
            } else {
                self.fireSingleZeroShutterLagRAWPhoto(rawPixelFormat: rawPixelFormat)
            }
        }

        rawBurstTimer = timer
        timer.resume()
    }

    private func restartRAWBurstTimer(fps: Int) {
        if rawBurstTimer != nil {
            startRAWBurstTimer(fps: fps)
        }
    }

    private func stopRAWBurstTimer() {
        rawBurstTimer?.cancel()
        rawBurstTimer = nil
    }

    /// Triggers a single Zero-Shutter-Lag (ZSL) uncompressed 14-bit Bayer RAW capture via `AVCapturePhotoOutput`
    private nonisolated func fireSingleZeroShutterLagRAWPhoto(rawPixelFormat: OSType) {
        guard rawPixelFormat != 0,
              photoOutput.availableRawPhotoPixelFormatTypes.contains(rawPixelFormat) else {
            return
        }

        inFlightLock.lock()
        if inFlightRAWPhotoCount >= maxInFlightRAWPhotos {
            inFlightLock.unlock()
            return
        }
        inFlightRAWPhotoCount += 1
        inFlightLock.unlock()

        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawPixelFormat)
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }

        let uid = settings.uniqueID
        let proxy = RAWPhotoCaptureDelegateProxy(uid: uid) { [weak self] uid, photo, error in
            guard let self else { return }
            self.inFlightLock.lock()
            self.inFlightRAWPhotoCount = max(0, self.inFlightRAWPhotoCount - 1)
            self.activePhotoDelegates.removeValue(forKey: uid)
            self.inFlightLock.unlock()

            if let photo, error == nil {
                self.handleCapturedRAWPhoto(photo)
            }
        }

        inFlightLock.lock()
        activePhotoDelegates[uid] = proxy
        inFlightLock.unlock()

        photoOutput.capturePhoto(with: settings, delegate: proxy)
    }

    /// Processes a captured `AVCapturePhoto` containing a 14-bit Bayer `CVPixelBuffer` directly in GPU memory
    private nonisolated func handleCapturedRAWPhoto(_ photo: AVCapturePhoto) {
        guard let rawPixelBuffer = photo.pixelBuffer else { return }
        let meta = Self.extractDNGMetadata(from: photo.metadata, pixelFormat: CVPixelBufferGetPixelFormatType(rawPixelBuffer))
        let pts = photo.timestamp

        let (config, frameDur) = snapshotRenderConfig()
        latestMetadata = meta
        lastRAWPhotoFrameTime = CACurrentMediaTime()

        let isRec = videoRecorder.isActivelyRecording
        let destBuffer = isRec ? videoRecorder.dequeueRecordPixelBuffer() : nil

        let monitorTex = imagePipeline?.processRAWBayerFrame(
            rawPixelBuffer: rawPixelBuffer,
            metadata: meta,
            config: config,
            destinationRecordPixelBuffer: destBuffer
        )

        if isRec, let destBuffer {
            videoRecorder.appendVideoPixelBuffer(
                destBuffer,
                presentationTime: pts,
                frameDuration: frameDur
            )
        }

        Task { @MainActor in
            self.liveSensorISO = meta.iso
            self.liveShutterDenominator = max(Int((1.0 / max(meta.exposureDurationSeconds, 0.0001)).rounded()), 1)
            self.recordFrameTimestampForFPS()
            if let monitorTex {
                self.latestMonitorTexture = monitorTex
            }
        }
    }

    /// Extracts sensor `BlackLevel`, `WhiteLevel`, `AsShotNeutral`, `ColorMatrix1/2`, and CFA pattern from `{DNG}` metadata
    nonisolated static func extractDNGMetadata(from metadataDict: [String: Any], pixelFormat: OSType) -> RAWFrameMetadata {
        var meta = RAWFrameMetadata()

        switch pixelFormat {
        case kCVPixelFormatType_14Bayer_RGGB: meta.cfaPattern = 0
        case kCVPixelFormatType_14Bayer_BGGR: meta.cfaPattern = 1
        case kCVPixelFormatType_14Bayer_GRBG: meta.cfaPattern = 2
        case kCVPixelFormatType_14Bayer_GBRG: meta.cfaPattern = 3
        default: meta.cfaPattern = 0
        }

        if let dng = metadataDict["{DNG}"] as? [String: Any] {
            if let blackArray = dng["BlackLevel"] as? [NSNumber], blackArray.count >= 4 {
                meta.blackLevels = SIMD4<Float>(
                    blackArray[0].floatValue,
                    blackArray[1].floatValue,
                    blackArray[2].floatValue,
                    blackArray[3].floatValue
                )
            } else if let blackScalar = dng["BlackLevel"] as? NSNumber {
                let v = blackScalar.floatValue
                meta.blackLevels = SIMD4<Float>(v, v, v, v)
            }

            if let whiteScalar = dng["WhiteLevel"] as? NSNumber {
                meta.whiteLevel = whiteScalar.floatValue
            } else if let whiteArray = dng["WhiteLevel"] as? [NSNumber], let first = whiteArray.first {
                meta.whiteLevel = first.floatValue
            }

            if let neutral = dng["AsShotNeutral"] as? [NSNumber], neutral.count >= 3 {
                let rN = max(neutral[0].floatValue, 0.01)
                let gN = max(neutral[1].floatValue, 0.01)
                let bN = max(neutral[2].floatValue, 0.01)
                meta.whiteBalanceGains = SIMD3<Float>(gN / rN, 1.0, gN / bN)
            }

            if let baseline = dng["BaselineExposure"] as? NSNumber {
                meta.baselineExposureEV = baseline.floatValue
            }

            if let cm2 = dng["ColorMatrix2"] as? [NSNumber], cm2.count >= 9 {
                // Invert or normalize DNG ColorMatrix2 for linear RGB -> Working Gamut
                meta.colorMatrixRow0 = SIMD3<Float>(cm2[0].floatValue, cm2[1].floatValue, cm2[2].floatValue)
                meta.colorMatrixRow1 = SIMD3<Float>(cm2[3].floatValue, cm2[4].floatValue, cm2[5].floatValue)
                meta.colorMatrixRow2 = SIMD3<Float>(cm2[6].floatValue, cm2[7].floatValue, cm2[8].floatValue)
                // Ensure rows sum reasonably close to 1.0
                let sum0 = max(meta.colorMatrixRow0.x + meta.colorMatrixRow0.y + meta.colorMatrixRow0.z, 0.1)
                let sum1 = max(meta.colorMatrixRow1.x + meta.colorMatrixRow1.y + meta.colorMatrixRow1.z, 0.1)
                let sum2 = max(meta.colorMatrixRow2.x + meta.colorMatrixRow2.y + meta.colorMatrixRow2.z, 0.1)
                meta.colorMatrixRow0 /= sum0
                meta.colorMatrixRow1 /= sum1
                meta.colorMatrixRow2 /= sum2
            }
        }

        if let exif = metadataDict["{Exif}"] as? [String: Any] {
            if let isoArr = exif["ISOSpeedRatings"] as? [NSNumber], let firstISO = isoArr.first {
                meta.iso = firstISO.floatValue
            }
            if let expTime = exif["ExposureTime"] as? NSNumber {
                meta.exposureDurationSeconds = expTime.doubleValue
            }
        }

        return meta
    }

    // MARK: - Synthetic 14-Bit Bayer RAW Loop (Simulator & Fallback)

    private func startSyntheticRAWLoop() {
        isSimulatorSyntheticMode = true
        activeSensorFormatDescription = "4032×3024 · 14-Bit Bayer RGGB (Sim)"
        startRAWBurstTimer(fps: frameRate.rawValue)
    }

    private nonisolated func stepSyntheticRAWFrame() {
        Task { @MainActor in
            let currentISO = (self.exposureMode == .auto) ? 160.0 : self.manualISO
            let shutterSec = self.selectedShutterPreset.duration.seconds
            self.liveSensorISO = currentISO
            self.liveShutterDenominator = self.selectedShutterPreset.denominator

            guard let (rawBuffer, meta) = self.syntheticGenerator.nextBayerFrame(
                iso: currentISO,
                shutterSeconds: shutterSec
            ) else { return }

            self.latestMetadata = meta
            self.recordFrameTimestampForFPS()
            self.audioMonitor.updateSimulatedMeters(isRecording: self.videoRecorder.isRecording)

            let config = self.buildCurrentRenderConfiguration()
            let destBuffer = self.videoRecorder.isRecording ? self.videoRecorder.dequeueRecordPixelBuffer() : nil

            if let monitorTex = self.imagePipeline?.processRAWBayerFrame(
                rawPixelBuffer: rawBuffer,
                metadata: meta,
                config: config,
                destinationRecordPixelBuffer: destBuffer
            ) {
                self.latestMonitorTexture = monitorTex
            }

            if self.videoRecorder.isRecording, let destBuffer {
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                self.videoRecorder.appendVideoPixelBuffer(
                    destBuffer,
                    presentationTime: pts,
                    frameDuration: self.frameRate.frameDuration
                )
            }
        }
    }

    // MARK: - Recording Start / Stop Workflow

    func toggleRecording() {
        if videoRecorder.isRecording {
            stopRecordingSession()
        } else {
            startRecordingSession()
        }
    }

    func startRecordingSession() {
        guard !videoRecorder.isRecording else { return }

        // Lock orientation to the physical sensor orientation at recording start
        activeCaptureOrientation = gyroflowLogger.currentCaptureOrientation
        syncCachedRenderConfig()

        // 1. Lock Focus before recording (per Log Cam specification: prevents lens hunting during 30fps RAW burst)
        lockFocusAndExposureForRecordingStart()

        do {
            let clipURL = try videoRecorder.startRecording(
                gateMode: gateMode,
                orientation: activeCaptureOrientation,
                frameRate: frameRate,
                codec: codec,
                hevcBitrate: hevcBitrate,
                logCurve: logCurve
            )

            if gyroflowLoggingEnabled {
                _ = gyroflowLogger.startLogging(forVideoURL: clipURL, lensName: selectedLens.focalLengthEquivalent)
            }

            // Start 30fps Zero-Shutter-Lag RAW Photo burst loop on hardware
            if !isSimulatorSyntheticMode {
                startRAWBurstTimer(fps: frameRate.rawValue)
            }

            let orientTag = activeCaptureOrientation.isPortrait ? "VERT" : "HORIZ"
            statusBannerMessage = "REC · \(gateMode.shortLabel) \(orientTag) · \(frameRate.rawValue) FPS RAW"
        } catch {
            statusBannerMessage = "Recording Error: \(error.localizedDescription)"
        }
    }

    func stopRecordingSession() {
        guard videoRecorder.isRecording else { return }

        if !isSimulatorSyntheticMode {
            stopRAWBurstTimer()
        }
        gyroflowLogger.stopLogging()

        videoRecorder.stopRecording { [weak self] savedURL in
            guard let self else { return }
            Task { @MainActor in
                self.activeCaptureOrientation = self.gyroflowLogger.currentCaptureOrientation
                self.restoreFocusAndExposureAfterRecordingStop()
                if let url = savedURL {
                    self.statusBannerMessage = "Saved \(url.lastPathComponent)"
                }
            }
        }
    }

    // MARK: - Exposure, Shutter-Priority, Focus & White Balance Hardware Control

    private func lockFocusAndExposureForRecordingStart() {
        guard let device = activeVideoDevice else { return }
        let shouldLockExp = (exposureMode == .auto || exposureMode == .shutterPriority) && lockExposureAtStart
        let shouldLockWB = (whiteBalanceMode == .auto) && lockWhiteBalanceAtStart

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if shouldLockExp && device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                if shouldLockWB && device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func restoreFocusAndExposureAfterRecordingStop() {
        applyFocusSettings()
        applyExposureSettings()
        applyWhiteBalanceSettings()
    }

    func applyExposureSettings() {
        guard let device = activeVideoDevice else { return }
        let mode = exposureMode
        let requestedDuration = selectedShutterPreset.duration
        let userISO = manualISO

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let minDur = device.activeFormat.minExposureDuration
                let maxDur = device.activeFormat.maxExposureDuration
                let clampedDuration = CMTimeMinimum(CMTimeMaximum(requestedDuration, minDur), maxDur)
                let minISO = device.activeFormat.minISO
                let maxISO = device.activeFormat.maxISO
                let targetISO = min(max(userISO, minISO), maxISO)

                switch mode {
                case .auto:
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                case .shutterPriority:
                    // In Shutter-Priority mode, lock shutter speed to chosen preset and adjust ISO dynamically
                    if device.isExposureModeSupported(.custom) {
                        let currentISO = min(max(device.iso, minISO), maxISO)
                        device.setExposureModeCustom(duration: clampedDuration, iso: currentISO, completionHandler: nil)
                    }
                case .manual:
                    if device.isExposureModeSupported(.custom) {
                        device.setExposureModeCustom(duration: clampedDuration, iso: targetISO, completionHandler: nil)
                    }
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Dynamically updates ISO in Shutter-Priority mode using `device.exposureTargetOffset`
    private nonisolated func stepShutterPriorityAutoISO(device: AVCaptureDevice) {
        let offset = device.exposureTargetOffset // EV difference from ideal exposure
        guard abs(offset) > 0.15 else { return }

        let currentISO = device.iso
        let factor = pow(2.0, Float(offset) * 0.35)

        Task { @MainActor in
            guard self.exposureMode == .shutterPriority else { return }
            if self.videoRecorder.isRecording && self.lockExposureAtStart { return }
            let shutterDur = self.selectedShutterPreset.duration
            self.sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    let minDur = device.activeFormat.minExposureDuration
                    let maxDur = device.activeFormat.maxExposureDuration
                    let clampedDur = CMTimeMinimum(CMTimeMaximum(shutterDur, minDur), maxDur)
                    let newISO = min(max(currentISO * factor, device.activeFormat.minISO), min(device.activeFormat.maxISO, 3200.0))
                    if device.isExposureModeSupported(.custom) {
                        device.setExposureModeCustom(duration: clampedDur, iso: newISO, completionHandler: nil)
                    }
                    device.unlockForConfiguration()
                } catch {}
            }
        }
    }

    func applyFocusSettings() {
        // Manual focus can only be changed before recording (locked during recording)
        guard !videoRecorder.isRecording, let device = activeVideoDevice else { return }
        let manual = isManualFocusEnabled
        let pos = min(max(manualFocusLensPosition, 0.0), 1.0)

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if manual && device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func applyWhiteBalanceSettings() {
        guard let device = activeVideoDevice else { return }
        let mode = whiteBalanceMode
        let kelvin = manualWhiteBalanceKelvin
        let tint = manualWhiteBalanceTint

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                switch mode {
                case .auto:
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                case .manual:
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                            temperature: kelvin,
                            tint: tint
                        )
                        var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                        let maxGain = device.maxWhiteBalanceGain
                        gains.redGain = min(max(gains.redGain, 1.0), maxGain)
                        gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
                        gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    }
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func applyOpticalStabilizationSetting() {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            // Use optical / standard hardware stabilization without heavy cinematic EIS crop
            connection.preferredVideoStabilizationMode = opticalStabilizationEnabled ? .standard : .off
        }
    }

    // MARK: - Helpers

    func syncCachedRenderConfig() {
        let cfg = buildCurrentRenderConfiguration()
        let dur = frameRate.frameDuration
        configLock.lock()
        cachedRenderConfig = cfg
        cachedFrameDuration = dur
        configLock.unlock()
    }

    nonisolated func snapshotRenderConfig() -> (PipelineRenderConfiguration, CMTime) {
        configLock.lock()
        let cfg = cachedRenderConfig
        let dur = cachedFrameDuration
        configLock.unlock()
        return (cfg, dur)
    }

    func buildCurrentRenderConfiguration() -> PipelineRenderConfiguration {
        PipelineRenderConfiguration(
            gateMode: gateMode,
            logCurve: logCurve,
            lutMode: lutMode,
            lutIntensity: lutIntensity,
            rec709GammaAssist: rec709GammaAssist,
            zebrasEnabled: zebrasEnabled,
            zebraThreshold: zebraThreshold,
            falseColorEnabled: falseColorEnabled,
            vignetteCorrectionEnabled: vignetteCorrectionEnabled,
            noiseReduction: noiseReduction,
            anamorphicDesqueeze: anamorphicDesqueeze,
            rotate180ForDoF: rotate180ForDoF,
            captureOrientation: activeCaptureOrientation,
            exposureTrimEV: exposureTrimEV,
            manualWhiteBalanceKelvin: manualWhiteBalanceKelvin,
            manualWhiteBalanceTint: manualWhiteBalanceTint,
            useManualWhiteBalance: whiteBalanceMode == .manual
        )
    }

    private func recordFrameTimestampForFPS() {
        let now = CACurrentMediaTime()
        fpsFrameTimestamps.append(now)
        fpsFrameTimestamps.removeAll { now - $0 > 1.0 }
        measuredRAWFPS = Double(fpsFrameTimestamps.count)
    }

    private func setupThermalAndBatteryObservers() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.batteryLevel = max(UIDevice.current.batteryLevel, 0.0)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & Audio Delegate

extension RAWCaptureSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioDataOutput {
            audioMonitor.updateMeters(from: sampleBuffer)
            videoRecorder.appendAudioSampleBuffer(sampleBuffer)
            return
        }

        // Live video feed (and fallback if 30fps RAW photo burst hasn't delivered a frame in the last 350ms)
        guard output === videoDataOutput else { return }
        if let device = activeVideoDevice {
            stepShutterPriorityAutoISO(device: device)
        }

        let isRec = videoRecorder.isActivelyRecording
        if isRec && lastRAWPhotoFrameTime > 0 && (CACurrentMediaTime() - lastRAWPhotoFrameTime) < 0.35 {
            // 30fps RAW photo burst is actively driving the preview and recorder
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let currentISO = activeVideoDevice?.iso ?? 100.0
        let currentDur = activeVideoDevice?.exposureDuration.seconds ?? (1.0 / 60.0)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let (config, frameDur) = snapshotRenderConfig()
        let destBuffer = isRec ? videoRecorder.dequeueRecordPixelBuffer() : nil

        let monitorTex = imagePipeline?.processLiveVideoPreviewFrame(
            bgraPixelBuffer: pixelBuffer,
            metadata: latestMetadata,
            config: config,
            destinationRecordPixelBuffer: destBuffer
        )

        if isRec, let destBuffer {
            videoRecorder.appendVideoPixelBuffer(
                destBuffer,
                presentationTime: pts,
                frameDuration: frameDur
            )
        }

        Task { @MainActor in
            self.liveSensorISO = currentISO
            self.liveShutterDenominator = max(Int((1.0 / max(currentDur, 0.0001)).rounded()), 1)
            self.recordFrameTimestampForFPS()
            if let monitorTex {
                self.latestMonitorTexture = monitorTex
            }
        }
    }
}

// MARK: - Per-Shot Zero-Shutter-Lag RAW Photo Capture Delegate Proxy

private final class RAWPhotoCaptureDelegateProxy: NSObject, AVCapturePhotoCaptureDelegate {
    let uid: Int64
    let completion: (Int64, AVCapturePhoto?, Error?) -> Void

    init(uid: Int64, completion: @escaping (Int64, AVCapturePhoto?, Error?) -> Void) {
        self.uid = uid
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        completion(uid, photo, error)
    }
}

extension VideoCodecOption {
    static var hevc10Bit422Or444Default: VideoCodecOption {
        .hevc10Bit444
    }
}
