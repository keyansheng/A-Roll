import Foundation
import CoreMotion
import Combine

/// Captures 200Hz IMU Gyroscope + Accelerometer samples into a Gyroflow v1.3 `.gcsv` sidecar file
/// and publishes live roll/pitch angles for the Horizon Level overlay.
final class GyroflowLogger: ObservableObject {
    @Published var rollDegrees: Double = 0.0
    @Published var pitchDegrees: Double = 0.0
    @Published var loggedSampleCount: Int = 0
    @Published var captureOrientation: SensorCaptureOrientation = .portrait

    private let orientationLock = NSLock()
    nonisolated(unsafe) private var _currentCaptureOrientation: SensorCaptureOrientation = .portrait
    nonisolated var currentCaptureOrientation: SensorCaptureOrientation {
        orientationLock.lock()
        let val = _currentCaptureOrientation
        orientationLock.unlock()
        return val
    }

    var onOrientationChanged: ((SensorCaptureOrientation) -> Void)?

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.logcam.gyroflow.imu"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private var fileHandle: FileHandle?
    private var recordingStartTimestamp: TimeInterval?
    private var isLoggingGCSV = false
    private var simulationTimer: Timer?

    init() {
        startHorizonMonitoring()
    }

    deinit {
        stopLogging()
        motionManager.stopDeviceMotionUpdates()
        simulationTimer?.invalidate()
    }

    func startHorizonMonitoring() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                let gravity = motion.gravity

                // Determine physical sensor orientation from gravity when phone isn't lying flat
                let xyMag = sqrt(gravity.x * gravity.x + gravity.y * gravity.y)
                var detected = self.currentCaptureOrientation
                if xyMag > 0.45 {
                    if abs(gravity.x) > abs(gravity.y) + 0.15 {
                        detected = (gravity.x < 0) ? .landscapeLeft : .landscapeRight
                    } else if abs(gravity.y) > abs(gravity.x) + 0.15 {
                        detected = (gravity.y < 0) ? .portrait : .portraitUpsideDown
                    }
                }

                let previous = self.currentCaptureOrientation
                if detected != previous {
                    self.orientationLock.lock()
                    self._currentCaptureOrientation = detected
                    self.orientationLock.unlock()
                }

                // Compute roll & pitch relative to the active physical orientation
                let roll: Double
                switch detected {
                case .portrait:
                    roll = atan2(gravity.x, -gravity.y) * 180.0 / .pi
                case .portraitUpsideDown:
                    roll = atan2(-gravity.x, gravity.y) * 180.0 / .pi
                case .landscapeLeft:
                    roll = atan2(-gravity.y, -gravity.x) * 180.0 / .pi
                case .landscapeRight:
                    roll = atan2(gravity.y, gravity.x) * 180.0 / .pi
                }
                let pitch = atan2(gravity.z, max(xyMag, 0.001)) * 180.0 / .pi

                DispatchQueue.main.async {
                    self.rollDegrees = roll
                    self.pitchDegrees = pitch
                    if self.captureOrientation != detected {
                        self.captureOrientation = detected
                        self.onOrientationChanged?(detected)
                    }
                }

                if self.isLoggingGCSV {
                    self.appendSample(
                        timestamp: motion.timestamp,
                        rotationRate: motion.rotationRate,
                        acceleration: motion.userAcceleration,
                        gravity: motion.gravity
                    )
                }
            }
        } else {
            // Simulator fallback so Horizon Indicator and GCSV logger work in iOS Simulator
            var phase: Double = 0.0
            simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                phase += 1.0 / 60.0
                let simRoll = sin(phase * 0.7) * 1.4
                let simPitch = cos(phase * 0.5) * 0.9
                self.rollDegrees = simRoll
                self.pitchDegrees = simPitch

                if self.isLoggingGCSV {
                    let rot = CMRotationRate(
                        x: cos(phase * 0.5) * 0.02,
                        y: sin(phase * 0.7) * 0.02,
                        z: sin(phase * 0.3) * 0.01
                    )
                    let acc = CMAcceleration(x: 0.0, y: -1.0, z: 0.0)
                    self.appendSample(
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        rotationRate: rot,
                        acceleration: acc,
                        gravity: CMAcceleration(x: 0, y: 0, z: 0)
                    )
                }
            }
        }
    }

    /// Starts writing a Gyroflow `.gcsv` v1.3 log adjacent to `videoURL`
    func startLogging(forVideoURL videoURL: URL, lensName: String) -> URL? {
        let gcsvURL = videoURL.deletingPathExtension().appendingPathExtension("gcsv")

        let header = """
        GYROFLOW IMU LOG
        version,1.3
        id,iPhone_LogCam_OpenGate
        orientation,YxZ
        note,LogCam_RAW_Bayer_30fps_\(lensName)
        fwversion,iOS_LogCam_1.0
        timestamp,\(Int(Date().timeIntervalSince1970))
        vendor,apple
        videofilename,\(videoURL.lastPathComponent)
        lensprofile,Apple/iPhone_Wide_\(lensName)
        tscale,0.001
        gscale,1.0
        ascale,1.0
        t,gx,gy,gz,ax,ay,az

        """

        do {
            try header.write(to: gcsvURL, atomically: true, encoding: .utf8)
            fileHandle = try FileHandle(forWritingTo: gcsvURL)
            fileHandle?.seekToEndOfFile()
            recordingStartTimestamp = nil
            loggedSampleCount = 0
            isLoggingGCSV = true
            return gcsvURL
        } catch {
            return nil
        }
    }

    func stopLogging() {
        motionQueue.addOperation { [weak self] in
            guard let self else { return }
            self.isLoggingGCSV = false
            try? self.fileHandle?.close()
            self.fileHandle = nil
            self.recordingStartTimestamp = nil
        }
    }

    private func appendSample(
        timestamp: TimeInterval,
        rotationRate: CMRotationRate,
        acceleration: CMAcceleration,
        gravity: CMAcceleration
    ) {
        guard isLoggingGCSV, let fh = fileHandle else { return }
        if recordingStartTimestamp == nil {
            recordingStartTimestamp = timestamp
        }
        let elapsedMs = Int(((timestamp - (recordingStartTimestamp ?? timestamp)) * 1000.0).rounded())
        let ax = acceleration.x + gravity.x
        let ay = acceleration.y + gravity.y
        let az = acceleration.z + gravity.z

        let line = String(
            format: "%d,%.6f,%.6f,%.6f,%.5f,%.5f,%.5f\n",
            elapsedMs,
            rotationRate.x,
            rotationRate.y,
            rotationRate.z,
            ax,
            ay,
            az
        )
        if let data = line.data(using: .utf8) {
            try? fh.write(contentsOf: data)
            DispatchQueue.main.async {
                self.loggedSampleCount += 1
            }
        }
    }
}
