import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import Combine

struct RecordedClipItem: Identifiable, Equatable {
    let id: String
    let videoURL: URL
    let gcsvURL: URL?
    let createdAt: Date
    let fileSizeMB: Double
    let durationSeconds: Double
}

final class VideoRecorder: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var recordedFrameCount: Int = 0
    @Published var droppedFrameCount: Int = 0
    @Published var recordingElapsedSeconds: Double = 0.0
    @Published var externalDriveURL: URL?
    @Published var useExternalStorage: Bool = false
    @Published var recentClips: [RecordedClipItem] = []
    @Published var freeStorageGB: Double = 0.0
    @Published var showingFolderPicker: Bool = false
    @Published var selectedClip: RecordedClipItem? = nil

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var activeSourceBufferAttributes: [String: Any] = [:]
    private var activeRecordWidth: Int = 0
    private var activeRecordHeight: Int = 0
    private var activeRecordPixelFormat: OSType = 0

    private let writerQueue = DispatchQueue(label: "com.logcam.assetwriter.queue", qos: .userInitiated)
    private var sessionStartPTS: CMTime?
    private var lastAppendedPTS: CMTime = .invalid
    private var activeClipURL: URL?

    private static let externalBookmarkKey = "LogCam.ExternalStorageBookmark"

    init() {
        Self.ensureInternalRecordingsDirectory()
        restoreExternalDriveBookmark()
        refreshStorageAndClips()
    }

    static var internalRecordingsDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func ensureInternalRecordingsDirectory() {
        let dir = internalRecordingsDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var activeStorageDirectoryURL: URL {
        if useExternalStorage, let ext = externalDriveURL {
            return ext
        }
        Self.ensureInternalRecordingsDirectory()
        return Self.internalRecordingsDirectoryURL
    }

    func setExternalStorageDirectory(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.externalBookmarkKey)
        }
        externalDriveURL = url
        useExternalStorage = true
        refreshStorageAndClips()
    }

    private func restoreExternalDriveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.externalBookmarkKey) else { return }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) {
            externalDriveURL = url
        }
    }

    func refreshStorageAndClips() {
        let dir = activeStorageDirectoryURL
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            freeStorageGB = Double(bytes) / 1_073_741_824.0
        }

        let accessed = dir.startAccessingSecurityScopedResource()
        defer {
            if accessed { dir.stopAccessingSecurityScopedResource() }
        }

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let movURLs = urls
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        var items = [RecordedClipItem]()
        for movURL in movURLs {
            let res = try? movURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let created = res?.creationDate ?? Date()
            let sizeMB = Double(res?.fileSize ?? 0) / 1_048_576.0
            let candidateGCSV = movURL.deletingPathExtension().appendingPathExtension("gcsv")
            let hasGCSV = FileManager.default.fileExists(atPath: candidateGCSV.path)
            let asset = AVURLAsset(url: movURL)
            let dur = CMTimeGetSeconds(asset.duration)
            items.append(
                RecordedClipItem(
                    id: movURL.lastPathComponent,
                    videoURL: movURL,
                    gcsvURL: hasGCSV ? candidateGCSV : nil,
                    createdAt: created,
                    fileSizeMB: sizeMB,
                    durationSeconds: dur.isFinite ? max(dur, 0.0) : 0.0
                )
            )
        }

        DispatchQueue.main.async {
            self.recentClips = items
        }
    }

    /// Starts a new `.mov` recording session with the configured codec, bitrate, gate dimensions, orientation, and Log profile
    func startRecording(
        gateMode: CaptureGateMode,
        orientation: SensorCaptureOrientation = .portrait,
        frameRate: CaptureFrameRate,
        codec: VideoCodecOption,
        hevcBitrate: HEVCBitrateOption,
        logCurve: LogGammaCurve
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestampStr = formatter.string(from: Date())
        let filename = "LOGCAM_\(gateMode.shortLabel.replacingOccurrences(of: " ", with: ""))_\(logCurve.shortLabel.replacingOccurrences(of: ".", with: ""))_\(timestampStr).mov"

        let dir = activeStorageDirectoryURL
        let fileURL = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
        let dims = gateMode.dimensions(for: orientation)
        let width = Int(dims.width)
        let height = Int(dims.height)

        var compressionProps: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
            AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue
        ]

        if codec.isHEVC {
            compressionProps[AVVideoAverageBitRateKey] = hevcBitrate.bitsPerSecond
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        // Fallback to standard HEVC if ProRes or specific profile is unsupported on Simulator
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
        }

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        // Configure 10-bit bi-planar YCbCr pixel buffer pool
        let sourceBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(codec.pixelFormatType),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourceBufferAttrs
        )

        if writer.canAdd(vInput) {
            writer.add(vInput)
        }

        // Uncompressed 48kHz 24-bit Linear PCM or AAC Stereo Audio Track
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) {
            writer.add(aInput)
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "VideoRecorder",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start writing"]
            )
        }

        writerQueue.sync {
            self.assetWriter = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.pixelBufferAdaptor = adaptor
            self.activeSourceBufferAttributes = sourceBufferAttrs
            self.activeRecordWidth = width
            self.activeRecordHeight = height
            self.activeRecordPixelFormat = codec.pixelFormatType
            self.sessionStartPTS = nil
            self.lastAppendedPTS = .invalid
            self.activeClipURL = fileURL
        }

        let updateMainState = {
            self.recordedFrameCount = 0
            self.droppedFrameCount = 0
            self.recordingElapsedSeconds = 0.0
            self.isRecording = true
        }
        if Thread.isMainThread {
            updateMainState()
        } else {
            DispatchQueue.main.async(execute: updateMainState)
        }

        return fileURL
    }

    var isActivelyRecording: Bool {
        writerQueue.sync {
            guard let writer = assetWriter else { return false }
            return writer.status == .writing
        }
    }

    /// Allocates a destination 10-bit `CVPixelBuffer` from the `AVAssetWriterInputPixelBufferAdaptor` pool (or directly before `startSession` is called)
    func dequeueRecordPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        writerQueue.sync {
            if let pool = pixelBufferAdaptor?.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            }
            if buffer == nil, activeRecordWidth > 0, activeRecordHeight > 0 {
                CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    activeRecordWidth,
                    activeRecordHeight,
                    activeRecordPixelFormat,
                    activeSourceBufferAttributes as CFDictionary,
                    &buffer
                )
            }
        }
        return buffer
    }

    /// Appends a processed 10-bit Log `CVPixelBuffer` at the given presentation timestamp
    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, frameDuration: CMTime) {
        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  writer.status == .writing,
                  let vInput = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor else {
                return
            }

            if self.sessionStartPTS == nil {
                self.sessionStartPTS = presentationTime
                writer.startSession(atSourceTime: presentationTime)
            }

            // Ensure strictly monotonically increasing PTS for variable-latency RAW photo callbacks
            var targetPTS = presentationTime
            if self.lastAppendedPTS.isValid && CMTimeCompare(targetPTS, self.lastAppendedPTS) <= 0 {
                targetPTS = CMTimeAdd(self.lastAppendedPTS, frameDuration)
            }

            guard vInput.isReadyForMoreMediaData else {
                DispatchQueue.main.async {
                    self.droppedFrameCount += 1
                }
                return
            }

            if adaptor.append(pixelBuffer, withPresentationTime: targetPTS) {
                self.lastAppendedPTS = targetPTS
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(targetPTS, self.sessionStartPTS ?? targetPTS))
                DispatchQueue.main.async {
                    self.recordedFrameCount += 1
                    self.recordingElapsedSeconds = max(elapsed, 0.0)
                }
            }
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  writer.status == .writing,
                  self.sessionStartPTS != nil,
                  let aInput = self.audioInput,
                  aInput.isReadyForMoreMediaData else {
                return
            }
            aInput.append(sampleBuffer)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let finishedURL = self.activeClipURL
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()

            writer.finishWriting {
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.pixelBufferAdaptor = nil
                self.sessionStartPTS = nil
                self.lastAppendedPTS = .invalid

                DispatchQueue.main.async {
                    self.isRecording = false
                    self.refreshStorageAndClips()
                    completion(finishedURL)
                }
            }
        }
    }
}
