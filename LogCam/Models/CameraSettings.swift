import Foundation
import AVFoundation
import CoreMedia

// MARK: - Physical Sensor Orientation

enum SensorCaptureOrientation: UInt32, Codable, Equatable {
    case landscapeLeft = 0      // Phone horizontal, top (Dynamic Island) on left -> native 0° sensor
    case landscapeRight = 1     // Phone horizontal, top (Dynamic Island) on right -> 180° sensor
    case portrait = 2           // Phone vertical upright -> 90° CW sensor
    case portraitUpsideDown = 3 // Phone vertical upside down -> 90° CCW sensor

    var isPortrait: Bool {
        self == .portrait || self == .portraitUpsideDown
    }
}

// MARK: - Resolution & Aspect Gate

enum CaptureGateMode: String, CaseIterable, Identifiable, Codable {
    case openGate = "Open Gate (4:3)"
    case uhd4K = "4K UHD (16:9)"
    case dci4K = "4K DCI (17:9)"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .openGate: return "OPEN GATE"
        case .uhd4K: return "4K UHD"
        case .dci4K: return "4K DCI"
        }
    }

    /// Native landscape dimensions (long axis × short axis)
    var dimensions: CMVideoDimensions {
        switch self {
        case .openGate:
            return CMVideoDimensions(width: 4032, height: 3024)
        case .uhd4K:
            return CMVideoDimensions(width: 3840, height: 2160)
        case .dci4K:
            return CMVideoDimensions(width: 4032, height: 2128)
        }
    }

    /// Output video dimensions matching the physical sensor orientation (vertical when portrait, horizontal when landscape)
    func dimensions(for orientation: SensorCaptureOrientation) -> CMVideoDimensions {
        let base = dimensions
        if orientation.isPortrait {
            return CMVideoDimensions(width: base.height, height: base.width)
        } else {
            return base
        }
    }

    var aspectRatio: CGFloat {
        let dims = dimensions
        return CGFloat(dims.width) / CGFloat(dims.height)
    }

    /// Aspect ratio of the sensor gate in Portrait UI window coordinates (short axis / long axis)
    var portraitViewfinderAspectRatio: CGFloat {
        let dims = dimensions
        return CGFloat(dims.height) / CGFloat(dims.width)
    }
}

// MARK: - Frame Rate (Up to 30fps per Bayer RAW Photo Output Hardware Limit)

enum CaptureFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps24 = 24
    case fps25 = 25
    case fps30 = 30

    var id: Int { rawValue }

    var label: String { "\(rawValue) FPS" }

    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }

    var intervalSeconds: Double {
        1.0 / Double(rawValue)
    }

    /// Standard 180-degree shutter duration for this frame rate
    var standard180ShutterDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue * 2))
    }
}

// MARK: - Video Codec & Bitrate

enum VideoCodecOption: String, CaseIterable, Identifiable, Codable {
    case hevc10Bit420 = "10-bit HEVC 4:2:0"
    case hevc10Bit444 = "10-bit HEVC 4:4:4"
    case proRes422LT = "ProRes 422 LT"
    case proRes422 = "ProRes 422"
    case proRes422HQ = "ProRes 422 HQ"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .hevc10Bit420: return "HEVC 4:2:0 10B"
        case .hevc10Bit444: return "HEVC 4:4:4 10B"
        case .proRes422LT: return "PRORES LT"
        case .proRes422: return "PRORES 422"
        case .proRes422HQ: return "PRORES HQ"
        }
    }

    var isHEVC: Bool {
        switch self {
        case .hevc10Bit420, .hevc10Bit444: return true
        default: return false
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .hevc10Bit420, .hevc10Bit444:
            return .hevc
        case .proRes422LT:
            return .proRes422LT
        case .proRes422:
            return .proRes422
        case .proRes422HQ:
            return .proRes422HQ
        }
    }

    var pixelFormatType: OSType {
        switch self {
        case .hevc10Bit420:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .hevc10Bit444:
            return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case .proRes422LT, .proRes422, .proRes422HQ:
            return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        }
    }
}

enum HEVCBitrateOption: Int, CaseIterable, Identifiable, Codable {
    case mbps60 = 60
    case mbps100 = 100
    case mbps150 = 150
    case mbps220 = 220
    case mbps300 = 300

    var id: Int { rawValue }
    var label: String { "\(rawValue) Mbps" }
    var bitsPerSecond: Int { rawValue * 1_000_000 }
}

// MARK: - Industry Log Gamma Curves & Color Spaces

enum LogGammaCurve: Int, CaseIterable, Identifiable, Codable {
    case appleLog = 0
    case arriLogC3 = 1
    case arriLogC4 = 2
    case sonySLog3 = 3
    case redLog3G10 = 4
    case davinciIntermediate = 5
    case canonLog3 = 6
    case panasonicVLog = 7
    case rec709Linear = 8

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .appleLog: return "Apple Log"
        case .arriLogC3: return "ARRI LogC3"
        case .arriLogC4: return "ARRI LogC4"
        case .sonySLog3: return "Sony S-Log3"
        case .redLog3G10: return "RED Log3G10"
        case .davinciIntermediate: return "DaVinci Intermediate"
        case .canonLog3: return "Canon Log 3"
        case .panasonicVLog: return "Panasonic V-Log"
        case .rec709Linear: return "Rec.709 Standard"
        }
    }

    var shortLabel: String {
        switch self {
        case .appleLog: return "APPLE LOG"
        case .arriLogC3: return "LOG-C3"
        case .arriLogC4: return "LOG-C4"
        case .sonySLog3: return "S-LOG3"
        case .redLog3G10: return "LOG3G10"
        case .davinciIntermediate: return "DWG/DI"
        case .canonLog3: return "C-LOG3"
        case .panasonicVLog: return "V-LOG"
        case .rec709Linear: return "REC.709"
        }
    }

    var colorGamutName: String {
        switch self {
        case .appleLog: return "Rec.2020"
        case .arriLogC3: return "ARRI Wide Gamut 3"
        case .arriLogC4: return "ARRI Wide Gamut 4"
        case .sonySLog3: return "S-Gamut3.Cine"
        case .redLog3G10: return "REDWideGamutRGB"
        case .davinciIntermediate: return "DaVinci Wide Gamut"
        case .canonLog3: return "Cinema Gamut"
        case .panasonicVLog: return "V-Gamut"
        case .rec709Linear: return "Rec.709"
        }
    }
}

// MARK: - LUT Application Mode

enum LUTApplicationMode: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case monitoringOnly = "Monitor Only"
    case bakedIn = "Bake Into Video"

    var id: String { rawValue }
}

// MARK: - Anamorphic Desqueeze Ratio

enum AnamorphicDesqueeze: Float, CaseIterable, Identifiable, Codable {
    case none = 1.0
    case x1_33 = 1.33
    case x1_50 = 1.50
    case x1_60 = 1.60
    case x1_80 = 1.80
    case x2_00 = 2.00

    var id: Float { rawValue }

    var label: String {
        switch self {
        case .none: return "1.0x (Spherical)"
        case .x1_33: return "1.33x Anamorphic"
        case .x1_50: return "1.50x Anamorphic"
        case .x1_60: return "1.60x Anamorphic"
        case .x1_80: return "1.80x Anamorphic"
        case .x2_00: return "2.00x Anamorphic"
        }
    }

    var shortBadge: String {
        self == .none ? "1.0x" : String(format: "%.2fx", rawValue)
    }
}

// MARK: - Exposure & White Balance Control Modes

enum ExposureControlMode: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case shutterPriority = "Shutter Priority"
    case manual = "Manual"

    var id: String { rawValue }
}

enum WhiteBalanceControlMode: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto WB"
    case manual = "Manual Kelvin"

    var id: String { rawValue }
}

enum NoiseReductionLevel: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off (Pure RAW)"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var shaderStrength: Float {
        switch self {
        case .off: return 0.0
        case .low: return 0.28
        case .medium: return 0.55
        case .high: return 0.85
        }
    }
}

// MARK: - Standard Shutter Speeds

struct ShutterSpeedPreset: Identifiable, Equatable {
    let denominator: Int
    var id: Int { denominator }

    var label: String { "1/\(denominator)" }

    var duration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(denominator))
    }

    static let presets: [ShutterSpeedPreset] = [
        ShutterSpeedPreset(denominator: 24),
        ShutterSpeedPreset(denominator: 25),
        ShutterSpeedPreset(denominator: 30),
        ShutterSpeedPreset(denominator: 48),
        ShutterSpeedPreset(denominator: 50),
        ShutterSpeedPreset(denominator: 60),
        ShutterSpeedPreset(denominator: 100),
        ShutterSpeedPreset(denominator: 120),
        ShutterSpeedPreset(denominator: 250),
        ShutterSpeedPreset(denominator: 500),
        ShutterSpeedPreset(denominator: 1000),
        ShutterSpeedPreset(denominator: 2000)
    ]
}

// MARK: - Camera Lens Selection

enum CameraLensType: String, CaseIterable, Identifiable, Codable {
    case ultraWide = "0.5x"
    case wide = "1x"
    case telephoto = "3x"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    var focalLengthEquivalent: String {
        switch self {
        case .ultraWide: return "13mm"
        case .wide: return "24mm"
        case .telephoto: return "77mm"
        }
    }
}

// MARK: - RAW Frame Metadata Passed to Metal Shader

struct RAWFrameMetadata {
    /// CFA pattern: 0 = RGGB, 1 = BGGR, 2 = GRBG, 3 = GBRG
    var cfaPattern: UInt32 = 0
    /// Per-channel sensor black levels [R, G1, G2, B] in 14-bit or 16-bit ADU
    var blackLevels: SIMD4<Float> = SIMD4<Float>(528, 528, 528, 528)
    /// Sensor white clip level (typically 16383 for 14-bit Bayer RAW)
    var whiteLevel: Float = 16383.0
    /// Camera AsShotNeutral or manual RGB white balance multipliers
    var whiteBalanceGains: SIMD3<Float> = SIMD3<Float>(2.05, 1.0, 1.65)
    /// 3x3 Color Correction Matrix from Sensor RGB to CIE XYZ / Target Gamut
    var colorMatrixRow0: SIMD3<Float> = SIMD3<Float>(1.32, -0.24, -0.08)
    var colorMatrixRow1: SIMD3<Float> = SIMD3<Float>(-0.18, 1.28, -0.10)
    var colorMatrixRow2: SIMD3<Float> = SIMD3<Float>(-0.04, -0.31, 1.35)
    /// Baseline exposure offset in stops (EV)
    var baselineExposureEV: Float = 0.0
    /// Captured ISO & Shutter
    var iso: Float = 100.0
    var exposureDurationSeconds: Double = 1.0 / 48.0
}
