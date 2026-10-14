import SwiftUI
import UniformTypeIdentifiers

struct PipelineSettingsSheet: View {
    @ObservedObject var camera: RAWCaptureSessionManager
    @ObservedObject var recorder: VideoRecorder
    @ObservedObject var audioMonitor: AudioMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Sensor Gate & Frame Rate
                Section {
                    Picker("Sensor Gate & Resolution", selection: $camera.gateMode) {
                        ForEach(CaptureGateMode.allCases) { mode in
                            let dims = mode.dimensions
                            Text("\(mode.rawValue) (\(dims.width)×\(dims.height))")
                                .tag(mode)
                        }
                    }

                    Picker("RAW Burst Frame Rate", selection: $camera.frameRate) {
                        ForEach(CaptureFrameRate.allCases) { fps in
                            Text(fps.label).tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Open Gate & Sensor Timing")
                } footer: {
                    Text("Uses AVCapturePhotoOutput 14-bit Bayer RAW with Zero-Shutter-Lag at \(camera.frameRate.rawValue) photos/sec to bypass Apple's video ISP sharpening and temporal noise reduction.")
                }

                // MARK: - Codec & Bitrate
                Section {
                    Picker("Recording Codec", selection: $camera.codec) {
                        ForEach(VideoCodecOption.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }

                    if camera.codec.isHEVC {
                        Picker("HEVC Target Bitrate", selection: $camera.hevcBitrate) {
                            ForEach(HEVCBitrateOption.allCases) { rate in
                                Text(rate.label).tag(rate)
                            }
                        }
                    }
                } header: {
                    Text("Codec & Bitrate")
                } footer: {
                    if !camera.codec.isHEVC {
                        Text("Apple ProRes encodes variable-bitrate intra-frame 10-bit 4:2:2 directly from the Metal debayered texture.")
                    } else {
                        Text("10-bit HEVC supports up to 300 Mbps and 4:4:4 chroma subsampling without chroma loss.")
                    }
                }

                // MARK: - RAW Debayer & Optical Pipeline
                Section("RAW Debayer & Optical Pipeline") {
                    Toggle("Lens Vignette Compensation", isOn: $camera.vignetteCorrectionEnabled)

                    Picker("Spatial Noise Reduction", selection: $camera.noiseReduction) {
                        ForEach(NoiseReductionLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }

                    Toggle("Optical Image Stabilization (OIS)", isOn: $camera.opticalStabilizationEnabled)

                    Picker("Anamorphic Desqueeze", selection: $camera.anamorphicDesqueeze) {
                        ForEach(AnamorphicDesqueeze.allCases) { factor in
                            Text(factor.label).tag(factor)
                        }
                    }

                    Toggle("Flip 180° (DoF / Cinema Lens Adapter)", isOn: $camera.rotate180ForDoF)
                }

                // MARK: - Gyroflow Stabilization Sidecar
                Section {
                    Toggle("Record Gyroflow (.gcsv) IMU Sidecar", isOn: $camera.gyroflowLoggingEnabled)
                } header: {
                    Text("Motion & Gyroflow")
                } footer: {
                    Text("Logs high-frequency 6-axis gyroscope and accelerometer samples into a companion .gcsv v1.3 file alongside each .mov clip for post-production stabilization in Gyroflow.")
                }

                // MARK: - Audio Input
                Section("Audio & External Microphone") {
                    if !audioMonitor.availableMicrophones.isEmpty {
                        Picker("Microphone Input", selection: Binding(
                            get: { audioMonitor.selectedMicrophoneID },
                            set: { newID in
                                if let option = audioMonitor.availableMicrophones.first(where: { $0.id == newID }) {
                                    audioMonitor.selectMicrophone(option)
                                }
                            }
                        )) {
                            ForEach(audioMonitor.availableMicrophones) { input in
                                Text(input.name).tag(input.id)
                            }
                        }
                    } else {
                        Text("Built-In Stereo Microphone")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Storage Destination
                Section {
                    Toggle("Record to External USB-C Drive", isOn: $recorder.useExternalStorage)

                    if recorder.useExternalStorage {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("External Folder")
                                    .font(.subheadline)
                                Text(recorder.externalDriveURL?.lastPathComponent ?? "No external folder selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Select Drive Folder") {
                                recorder.showingFolderPicker = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                } header: {
                    Text("Storage Location")
                } footer: {
                    Text("Internal recordings are saved in Documents/Recordings and accessible via the iOS Files app. External storage records directly onto a connected USB-C SSD.")
                }
            }
            .navigationTitle("RAW Pipeline Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .fileImporter(
                isPresented: $recorder.showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let folderURL = urls.first {
                    recorder.setExternalStorageDirectory(folderURL)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
