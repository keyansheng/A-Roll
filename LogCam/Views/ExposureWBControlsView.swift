import SwiftUI
import UniformTypeIdentifiers

enum ActiveControlDrawer: String, CaseIterable, Identifiable {
    case exposure = "EXP"
    case focus = "FOCUS"
    case whiteBalance = "WB"
    case colorLUT = "LOG / LUT"

    var id: String { rawValue }
}

struct ExposureWBControlsView: View {
    @ObservedObject var camera: RAWCaptureSessionManager
    let activeDrawer: ActiveControlDrawer

    var body: some View {
        VStack(spacing: 10) {
            switch activeDrawer {
            case .exposure:
                exposureControlPanel
            case .focus:
                focusControlPanel
            case .whiteBalance:
                whiteBalanceControlPanel
            case .colorLUT:
                colorAndLUTControlPanel
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.10).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .fileImporter(
            isPresented: $camera.isImportingCubeFile,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                camera.importLUTFile(from: first)
            }
        }
    }

    // MARK: - 1. Exposure Panel (Auto, Shutter Priority, Manual + Lock at Start)

    private var exposureControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Exposure Mode", selection: $camera.exposureMode) {
                    ForEach(ExposureControlMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if camera.exposureMode != .manual {
                    Toggle(isOn: $camera.lockExposureAtStart) {
                        Label("Lock @ Rec", systemImage: camera.lockExposureAtStart ? "lock.fill" : "lock.open")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .toggleStyle(.button)
                    .tint(.orange)
                }
            }

            // Shutter Speed Ribbon (Enabled in Shutter Priority & Manual)
            if camera.exposureMode == .shutterPriority || camera.exposureMode == .manual {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SHUTTER SPEED")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        let is180Rule = camera.selectedShutterPreset.denominator == camera.frameRate.rawValue * 2
                        if is180Rule {
                            Text("180° SHUTTER ANGLE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ShutterSpeedPreset.presets) { preset in
                                let selected = (camera.selectedShutterPreset == preset)
                                let is180 = (preset.denominator == camera.frameRate.rawValue * 2)
                                Button {
                                    camera.selectedShutterPreset = preset
                                } label: {
                                    Text(preset.label)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(selected ? .black : (is180 ? .orange : .white))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selected ? Color.orange : Color.white.opacity(0.1))
                                        )
                                }
                            }
                        }
                    }
                }
            }

            // Manual ISO Slider (Enabled in Manual Mode)
            if camera.exposureMode == .manual {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("MANUAL ISO")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("ISO \(Int(camera.manualISO))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    Slider(
                        value: $camera.manualISO,
                        in: camera.minSupportedISO...camera.maxSupportedISO,
                        step: 10
                    )
                    .tint(.orange)
                }
            }

            // Software Exposure EV Trim (Always available in RAW pipeline)
            HStack {
                Text("RAW EV TRIM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Slider(value: $camera.exposureTrimEV, in: -2.0...2.0, step: 0.1)
                    .tint(.yellow)
                Text(String(format: "%+.1f EV", camera.exposureTrimEV))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    // MARK: - 2. Focus Panel (Manual Focus Only Before Recording per Log Cam Spec)

    private var focusControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $camera.isManualFocusEnabled) {
                    Text(camera.isManualFocusEnabled ? "MANUAL FOCUS" : "CONTINUOUS AUTO FOCUS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .toggleStyle(.button)
                .tint(.orange)
                .disabled(camera.videoRecorder.isRecording)

                Spacer()

                if camera.videoRecorder.isRecording {
                    Label("LOCKED FOR 30FPS RAW REC", systemImage: "lock.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                } else {
                    Text(String(format: "LENS POS: %.2f", camera.manualFocusLensPosition))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "camera.macro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $camera.manualFocusLensPosition, in: 0.0...1.0)
                    .tint(.orange)
                    .disabled(!camera.isManualFocusEnabled || camera.videoRecorder.isRecording)
                Text("∞")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 3. White Balance Panel (Auto with Lock-at-Start or Manual Kelvin/Tint)

    private var whiteBalanceControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("WB Mode", selection: $camera.whiteBalanceMode) {
                    ForEach(WhiteBalanceControlMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if camera.whiteBalanceMode == .auto {
                    Toggle(isOn: $camera.lockWhiteBalanceAtStart) {
                        Label("Lock @ Rec", systemImage: camera.lockWhiteBalanceAtStart ? "lock.fill" : "lock.open")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .toggleStyle(.button)
                    .tint(.orange)
                }
            }

            if camera.whiteBalanceMode == .manual {
                // Quick Cinema Kelvin Presets
                HStack(spacing: 8) {
                    ForEach([3200, 4300, 5600, 6500, 7500], id: \.self) { k in
                        Button {
                            camera.manualWhiteBalanceKelvin = Float(k)
                        } label: {
                            Text("\(k)K")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Int(camera.manualWhiteBalanceKelvin) == k ? .black : .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Int(camera.manualWhiteBalanceKelvin) == k ? Color.orange : Color.white.opacity(0.1))
                                )
                        }
                    }
                }

                HStack {
                    Text("TEMP")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    Slider(value: $camera.manualWhiteBalanceKelvin, in: 2500...10000, step: 50)
                        .tint(.orange)
                    Text("\(Int(camera.manualWhiteBalanceKelvin))K")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .frame(width: 54, alignment: .trailing)
                }

                HStack {
                    Text("TINT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    Slider(value: $camera.manualWhiteBalanceTint, in: -100...100, step: 1)
                        .tint(.green)
                    Text(String(format: "%+.0f", camera.manualWhiteBalanceTint))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - 4. Log Gamma Curve & 3D .cube LUT Panel (_LUTs Folder Integration)

    private var colorAndLUTControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Log Curve Horizontal Selector
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("LOG GAMMA PROFILE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(camera.logCurve.colorGamutName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LogGammaCurve.allCases) { curve in
                            let selected = (camera.logCurve == curve)
                            Button {
                                camera.logCurve = curve
                            } label: {
                                Text(curve.name)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(selected ? .black : .white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selected ? Color.orange : Color.white.opacity(0.1))
                                    )
                            }
                        }
                    }
                }
            }

            Divider().background(Color.white.opacity(0.15))

            // 3D LUT Mode (Off, Monitor Only, Bake Into Video)
            HStack {
                Picker("LUT Mode", selection: $camera.lutMode) {
                    ForEach(LUTApplicationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    camera.isImportingCubeFile = true
                } label: {
                    Label("Import .cube", systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                .foregroundStyle(.white)
            }

            if camera.lutMode != .off {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(camera.availableLUTs) { lut in
                            let isSelected = (camera.selectedLUT == lut)
                            Button {
                                camera.selectedLUT = lut
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "cube.transparent")
                                        .font(.system(size: 10))
                                    Text(lut.name)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(isSelected ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? Color.cyan : Color.white.opacity(0.1))
                                )
                            }
                        }
                    }
                }

                HStack {
                    Text("LUT STRENGTH")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Slider(value: $camera.lutIntensity, in: 0.0...1.0, step: 0.05)
                        .tint(.cyan)
                    Text("\(Int(camera.lutIntensity * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}
