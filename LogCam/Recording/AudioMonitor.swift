import Foundation
import AVFoundation
import Combine

struct AudioInputDeviceOption: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let portType: AVAudioSession.Port
    let portDescription: AVAudioSessionPortDescription?
}

final class AudioMonitor: ObservableObject {
    @Published var availableMicrophones: [AudioInputDeviceOption] = []
    @Published var selectedMicrophoneID: String = "builtin"
    @Published var leftChannelDBFS: Float = -60.0
    @Published var rightChannelDBFS: Float = -60.0

    init() {
        configureAudioSession()
        refreshAvailableMicrophones()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowAirPlay]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch {
            // Audio session may be unavailable in headless tests
        }
    }

    @objc private func handleRouteChange() {
        DispatchQueue.main.async {
            self.refreshAvailableMicrophones()
        }
    }

    func refreshAvailableMicrophones() {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs, !inputs.isEmpty else {
            availableMicrophones = [
                AudioInputDeviceOption(
                    id: "builtin",
                    name: "Built-In Stereo Mic",
                    portType: .builtInMic,
                    portDescription: nil
                )
            ]
            return
        }

        availableMicrophones = inputs.map { port in
            AudioInputDeviceOption(
                id: port.uid,
                name: port.portName,
                portType: port.portType,
                portDescription: port
            )
        }

        if let current = session.currentRoute.inputs.first {
            selectedMicrophoneID = current.uid
        } else if let first = availableMicrophones.first {
            selectedMicrophoneID = first.id
        }
    }

    func selectMicrophone(_ option: AudioInputDeviceOption) {
        selectedMicrophoneID = option.id
        guard let portDesc = option.portDescription else { return }
        try? AVAudioSession.sharedInstance().setPreferredInput(portDesc)
    }

    /// Processes an incoming audio `CMSampleBuffer` to update the live L/R dBFS meters
    func updateMeters(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length >= 4 else { return }

        let sampleCount = length / MemoryLayout<Int16>.size
        let samples = UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: sampleCount)

        var sumLeft: Float = 0.0
        var sumRight: Float = 0.0
        let strideStep = max(sampleCount / 128, 2)
        var count = 0

        var idx = 0
        while idx + 1 < sampleCount {
            let l = Float(samples[idx]) / 32768.0
            let r = Float(samples[idx + 1]) / 32768.0
            sumLeft += l * l
            sumRight += r * r
            count += 1
            idx += strideStep
        }

        guard count > 0 else { return }
        let rmsL = sqrt(sumLeft / Float(count))
        let rmsR = sqrt(sumRight / Float(count))
        let dbL = max(20.0 * log10(max(rmsL, 0.0001)), -60.0)
        let dbR = max(20.0 * log10(max(rmsR, 0.0001)), -60.0)

        DispatchQueue.main.async {
            self.leftChannelDBFS = dbL
            self.rightChannelDBFS = dbR
        }
    }

    func updateSimulatedMeters(isRecording: Bool) {
        let base: Float = isRecording ? -18.0 : -34.0
        let jitterL = Float.random(in: -4.5...4.5)
        let jitterR = Float.random(in: -4.5...4.5)
        DispatchQueue.main.async {
            self.leftChannelDBFS = min(max(base + jitterL, -60.0), -1.0)
            self.rightChannelDBFS = min(max(base + jitterR, -60.0), -1.0)
        }
    }
}
