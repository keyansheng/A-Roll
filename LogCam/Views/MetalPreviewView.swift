import SwiftUI
import MetalKit

struct MetalPreviewView: UIViewRepresentable {
    let texture: MTLTexture?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let device = RAWImagePipeline.sharedDevice ?? MTLCreateSystemDefaultDevice()
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.framebufferOnly = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.autoResizeDrawable = true
        mtkView.contentMode = .scaleAspectFit
        mtkView.backgroundColor = .black
        mtkView.delegate = context.coordinator
        if let device {
            context.coordinator.setupPipeline(device: device, pixelFormat: mtkView.colorPixelFormat)
        }
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.currentTexture = texture
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var commandQueue: MTLCommandQueue?
        var renderPipeline: MTLRenderPipelineState?
        var currentTexture: MTLTexture?

        func setupPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) {
            commandQueue = device.makeCommandQueue()
            guard let library = RAWImagePipeline.loadMetalLibrary(device: device),
                  let vertexFn = library.makeFunction(name: "preview_vertex"),
                  let fragmentFn = library.makeFunction(name: "preview_fragment") else {
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = pixelFormat
            renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else {
                return
            }

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                if let srcTex = currentTexture, let pso = renderPipeline {
                    encoder.setRenderPipelineState(pso)
                    encoder.setFragmentTexture(srcTex, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                encoder.endEncoding()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - Viewfinder Overlays (3x3 Grid, Horizon Level, False Color IRE Scale)

struct ViewfinderOverlaysView: View {
    let showGrid: Bool
    let showHorizon: Bool
    let showFalseColorScale: Bool
    let rollDegrees: Double
    let pitchDegrees: Double
    let gateMode: CaptureGateMode
    let anamorphic: AnamorphicDesqueeze

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Active Gate Frame Border
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)

                // 3x3 Rule-of-Thirds Grid
                if showGrid {
                    Path { path in
                        let w = geo.size.width
                        let h = geo.size.height
                        for i in 1...2 {
                            let x = w * CGFloat(i) / 3.0
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))

                            let y = h * CGFloat(i) / 3.0
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                }

                // Dual-Axis Horizon Indicator
                if showHorizon {
                    HorizonIndicatorOverlay(rollDegrees: rollDegrees, pitchDegrees: pitchDegrees)
                }

                // False Color IRE Scale Legend
                if showFalseColorScale {
                    VStack {
                        Spacer()
                        FalseColorLegendBar()
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct HorizonIndicatorOverlay: View {
    let rollDegrees: Double
    let pitchDegrees: Double

    private var isLevel: Bool {
        abs(rollDegrees) < 1.0 && abs(pitchDegrees) < 1.5
    }

    var body: some View {
        ZStack {
            // Fixed center reference ticks
            HStack(spacing: 90) {
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 16, height: 1.5)
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 16, height: 1.5)
            }

            // Dynamic Horizon Line + Pitch Offset
            HStack(spacing: 12) {
                Rectangle()
                    .fill(isLevel ? Color.green : Color.yellow)
                    .frame(width: 34, height: 2)
                Circle()
                    .strokeBorder(isLevel ? Color.green : Color.yellow, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                Rectangle()
                    .fill(isLevel ? Color.green : Color.yellow)
                    .frame(width: 34, height: 2)
            }
            .offset(y: CGFloat(min(max(pitchDegrees * 2.0, -30.0), 30.0)))
            .rotationEffect(.degrees(-rollDegrees))

            // Degree readout pill
            Text(String(format: "%+.1f°", rollDegrees))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isLevel ? Color.green : Color.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: Capsule())
                .offset(y: 26)
        }
    }
}

struct FalseColorLegendBar: View {
    private let stops: [(label: String, color: Color)] = [
        ("CLIP", Color(red: 0.96, green: 0.12, blue: 0.12)),
        ("90", Color(red: 0.98, green: 0.50, blue: 0.10)),
        ("80", Color(red: 0.95, green: 0.85, blue: 0.15)),
        ("55 SKIN", Color(red: 0.92, green: 0.48, blue: 0.68)),
        ("42 GREY", Color(red: 0.15, green: 0.82, blue: 0.28)),
        ("15", Color(red: 0.18, green: 0.75, blue: 0.88)),
        ("7", Color(red: 0.15, green: 0.35, blue: 0.92)),
        ("0 IRE", Color(red: 0.52, green: 0.12, blue: 0.78))
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(stops, id: \.label) { item in
                Text(item.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(item.color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
        )
    }
}
