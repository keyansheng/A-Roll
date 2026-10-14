import SwiftUI

struct CameraMainView: View {
    @StateObject private var camera = RAWCaptureSessionManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top Cinema Telemetry Bar
                topTelemetryHeader
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .background(Color.black.opacity(0.85))

                // MARK: - Main Viewfinder Container
                ZStack {
                    Color(white: 0.05)

                    viewfinderContent

                    // Top-Left Pipeline Status & Audio Meters
                    VStack {
                        HStack(alignment: .top) {
                            pipelineModeBadge
                            Spacer()
                            audioLevelMeterBadge
                        }
                        .padding(10)

                        Spacer()

                        // Lens Switcher Pills
                        if camera.activeDrawer == nil {
                            lensSwitcherBar
                                .padding(.bottom, 10)
                        }
                    }

                    // Active Bottom Drawer Overlay
                    if let drawer = camera.activeDrawer {
                        VStack {
                            Spacer()
                            ExposureWBControlsView(camera: camera, activeDrawer: drawer)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                // MARK: - Video Assists & Parameter Strip
                assistAndDrawerStrip
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.07))

                // MARK: - Main Transport & Shutter Bar
                bottomTransportBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            camera.startPipeline()
        }
        .onDisappear {
            camera.stopPipeline()
        }
        .sheet(isPresented: $camera.showingSettingsSheet) {
            PipelineSettingsSheet(
                camera: camera,
                recorder: camera.videoRecorder,
                audioMonitor: camera.audioMonitor
            )
        }
        .sheet(isPresented: $camera.showingRecordingsSheet) {
            RecordingsBrowserView(recorder: camera.videoRecorder)
        }
    }

    // MARK: - Viewfinder

    private var viewfinderContent: some View {
        GeometryReader { geo in
            let baseAspect = camera.gateMode.portraitViewfinderAspectRatio
            let desqueeze = CGFloat(camera.anamorphicDesqueeze.rawValue)
            let effectiveAspect = baseAspect * desqueeze

            ZStack {
                MetalPreviewView(texture: camera.latestMonitorTexture)

                ViewfinderOverlaysView(
                    showGrid: camera.showGridOverlay,
                    showHorizon: camera.showHorizonOverlay,
                    showFalseColorScale: camera.falseColorEnabled,
                    rollDegrees: camera.gyroflowLogger.rollDegrees,
                    pitchDegrees: camera.gyroflowLogger.pitchDegrees,
                    gateMode: camera.gateMode,
                    anamorphic: camera.anamorphicDesqueeze
                )

                // Recording Red Border Tally
                if camera.videoRecorder.isRecording {
                    Rectangle()
                        .stroke(Color.red.opacity(0.85), lineWidth: 3)
                }
            }
            .aspectRatio(effectiveAspect, contentMode: .fit)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Top Telemetry Header

    private var topTelemetryHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Gate & Resolution Pill
                Button {
                    camera.showingSettingsSheet = true
                } label: {
                    let dims = camera.gateMode.dimensions(for: camera.activeCaptureOrientation)
                    HStack(spacing: 4) {
                        Text(camera.gateMode.shortLabel)
                            .fontWeight(.black)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 4))

                        Text("\(dims.width)×\(dims.height)")
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                }

                // FPS Pill
                Text(camera.frameRate.label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

                // Codec & Bitrate Pill
                Text(codecSummaryBadge)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

                Spacer()

                // Timecode / Recording Status
                HStack(spacing: 5) {
                    Circle()
                        .fill(camera.videoRecorder.isRecording ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)

                    Text(formattedTimecode(camera.videoRecorder.recordingElapsedSeconds))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(camera.videoRecorder.isRecording ? .red : .white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }

            // Secondary Live Sensor Telemetry Row
            HStack(spacing: 12) {
                telemetryItem(label: "SHUTTER", value: "1/\(max(1, camera.liveShutterDenominator))")
                telemetryItem(label: "ISO", value: "\(Int(camera.liveSensorISO.rounded()))")
                telemetryItem(label: "WB", value: "\(Int(camera.manualWhiteBalanceKelvin.rounded()))K")
                telemetryItem(label: "LOG", value: camera.logCurve.shortLabel)
                if camera.anamorphicDesqueeze != .none {
                    telemetryItem(label: "ANA", value: camera.anamorphicDesqueeze.shortBadge)
                }
                Spacer()
                Text(String(format: "%.1f FPS", camera.measuredRAWFPS))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(camera.videoRecorder.isRecording ? .green : .secondary)
            }
        }
    }

    private func telemetryItem(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private var codecSummaryBadge: String {
        if !camera.codec.isHEVC {
            return camera.codec.shortLabel
        } else {
            return "\(camera.codec.shortLabel) \(camera.hevcBitrate.rawValue)M"
        }
    }

    // MARK: - Viewfinder Badges

    private var pipelineModeBadge: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(camera.videoRecorder.isRecording ? Color.orange : Color.cyan)
                    .frame(width: 7, height: 7)

                Text(camera.statusBannerMessage ?? camera.activeSensorFormatDescription)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.68), in: Capsule())

            if camera.lutMode != .off,
               let lut = camera.selectedLUT {
                HStack(spacing: 4) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 9))
                    Text("\(lut.name) (\(camera.lutMode.rawValue))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.68), in: Capsule())
            }
        }
    }

    private var audioLevelMeterBadge: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Text("L")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                audioBar(dbfs: camera.audioMonitor.leftChannelDBFS)
            }
            HStack(spacing: 4) {
                Text("R")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                audioBar(dbfs: camera.audioMonitor.rightChannelDBFS)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }

    private func audioBar(dbfs: Float) -> some View {
        let normalized = min(max((dbfs + 60.0) / 60.0, 0.0), 1.0)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * CGFloat(normalized)))
            }
        }
        .frame(width: 56, height: 4)
    }

    private var lensSwitcherBar: some View {
        HStack(spacing: 10) {
            ForEach(CameraLensType.allCases) { lens in
                let isSelected = camera.selectedLens == lens
                Button {
                    camera.selectedLens = lens
                } label: {
                    Text(lens.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(width: 40, height: 40)
                        .background(
                            isSelected ? Color.orange : Color.black.opacity(0.65),
                            in: Circle()
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                }
                .disabled(camera.videoRecorder.isRecording)
            }
        }
    }

    // MARK: - Video Assists & Parameter Drawer Strip

    private var assistAndDrawerStrip: some View {
        VStack(spacing: 8) {
            // Quick Video Assists Row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    assistTogglePill(
                        title: "709 ASSIST",
                        icon: "eye",
                        isOn: $camera.rec709GammaAssist
                    )
                    assistTogglePill(
                        title: "FALSE COLOR",
                        icon: "paintpalette",
                        isOn: $camera.falseColorEnabled
                    )
                    assistTogglePill(
                        title: "ZEBRAS \(Int(camera.zebraThreshold * 100))%",
                        icon: "line.diagonal",
                        isOn: $camera.zebrasEnabled
                    )
                    assistTogglePill(
                        title: "GRID",
                        icon: "squareshape.split.3x3",
                        isOn: $camera.showGridOverlay
                    )
                    assistTogglePill(
                        title: "HORIZON",
                        icon: "level",
                        isOn: $camera.showHorizonOverlay
                    )
                    assistTogglePill(
                        title: "VIGNETTE",
                        icon: "circle.dashed",
                        isOn: $camera.vignetteCorrectionEnabled
                    )
                }
            }

            // Parameter Drawer Tabs
            HStack(spacing: 8) {
                ForEach(ActiveControlDrawer.allCases) { tab in
                    let isSelected = camera.activeDrawer == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            camera.activeDrawer = (camera.activeDrawer == tab) ? nil : tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.orange : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                }
            }
        }
    }

    private func assistTogglePill(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(isOn.wrappedValue ? .black : .white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isOn.wrappedValue ? Color.yellow : Color.white.opacity(0.1),
                in: Capsule()
            )
        }
    }

    // MARK: - Bottom Transport Bar

    private var bottomTransportBar: some View {
        HStack {
            // Clips Library Button
            Button {
                camera.showingRecordingsSheet = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 20, weight: .semibold))
                    Text("CLIPS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .frame(width: 64, height: 50)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(camera.videoRecorder.isRecording)

            Spacer()

            // Main 30fps RAW Record Trigger Button
            Button {
                camera.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 74, height: 74)

                    RoundedRectangle(cornerRadius: camera.videoRecorder.isRecording ? 8 : 32)
                        .fill(Color.red)
                        .frame(
                            width: camera.videoRecorder.isRecording ? 30 : 58,
                            height: camera.videoRecorder.isRecording ? 30 : 58
                        )
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: camera.videoRecorder.isRecording)
                }
            }
            .accessibilityIdentifier("recordBurstButton")

            Spacer()

            // Pipeline Settings Button
            Button {
                camera.showingSettingsSheet = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                    Text("SETUP")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .frame(width: 64, height: 50)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(camera.videoRecorder.isRecording)
        }
    }

    private func formattedTimecode(_ seconds: TimeInterval) -> String {
        let fps = max(1, camera.frameRate.rawValue)
        let totalFrames = Int(seconds * Double(fps))
        let ff = totalFrames % fps
        let totalSeconds = Int(seconds)
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }
}
