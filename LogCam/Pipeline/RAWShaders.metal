#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms Shared Between Swift and Metal

struct PipelineUniforms {
    uint cfaPattern;              // 0 = RGGB, 1 = BGGR, 2 = GRBG, 3 = GBRG
    uint logCurveIndex;           // 0 = AppleLog, 1 = LogC3, 2 = LogC4, 3 = SLog3, 4 = Log3G10, 5 = DWG, 6 = CLog3, 7 = VLog, 8 = Rec709
    uint applyLUTToRecord;        // 1 = bake 3D LUT into recorded frame
    uint applyLUTToMonitor;       // 1 = apply 3D LUT on monitor output
    uint rec709AssistEnabled;     // 1 = apply Rec709 viewing gamma assist on monitor
    uint zebrasEnabled;           // 1 = show IRE zebra stripes on monitor
    uint falseColorEnabled;       // 1 = show IRE false color map on monitor
    uint rotate180;               // 1 = 180-degree rotation for DoF lens adapters

    float4 blackLevels;           // Per-CFA-channel black levels
    float4 sensorParams;          // x = whiteLevel, y = exposureEV, z = vignetteStrength, w = denoiseStrength
    float4 wbAndAnamorphic;       // xyz = wbGains, w = anamorphicStretch
    float4 colorMatrixRow0AndZebra; // xyz = colorMatrixRow0, w = zebraThreshold
    float4 colorMatrixRow1AndPhase; // xyz = colorMatrixRow1, w = framePhase
    float4 colorMatrixRow2AndLUT;   // xyz = colorMatrixRow2, w = lutIntensity
    uint4 cropRect;               // xy = cropOrigin, zw = cropSize
};

// MARK: - Helper: Identify Color Channel at (x, y) in 2x2 Bayer Tile
// Returns: 0 = Red, 1 = Green (on Red row), 2 = Green (on Blue row), 3 = Blue

inline uint bayerColorAt(uint x, uint y, uint cfaPattern) {
    uint px = x & 1u;
    uint py = y & 1u;
    uint idx = (py << 1u) | px; // 0:(0,0), 1:(1,0), 2:(0,1), 3:(1,1)

    // RGGB: (0,0)=R, (1,0)=G1, (0,1)=G2, (1,1)=B
    if (cfaPattern == 0u) {
        return idx;
    }
    // BGGR: (0,0)=B, (1,0)=G2, (0,1)=G1, (1,1)=R
    if (cfaPattern == 1u) {
        const uint mapBGGR[4] = { 3u, 2u, 1u, 0u };
        return mapBGGR[idx];
    }
    // GRBG: (0,0)=G1, (1,0)=R, (0,1)=B, (1,1)=G2
    if (cfaPattern == 2u) {
        const uint mapGRBG[4] = { 1u, 0u, 3u, 2u };
        return mapGRBG[idx];
    }
    // GBRG: (0,0)=G2, (1,0)=B, (0,1)=R, (1,1)=G1
    const uint mapGBRG[4] = { 2u, 3u, 0u, 1u };
    return mapGBRG[idx];
}

// MARK: - Helper: Read Normalized Linear Sample from 14-bit/16-bit Bayer Texture

inline float sampleBayerNormalized(
    texture2d<ushort, access::read> rawTex,
    int x,
    int y,
    int width,
    int height,
    constant PipelineUniforms &u
) {
    // Reflect at boundaries to preserve 2x2 CFA parity
    int cx = clamp(x, 0, width - 1);
    int cy = clamp(y, 0, height - 1);
    uint c = bayerColorAt(uint(cx), uint(cy), u.cfaPattern);
    float rawVal = float(rawTex.read(uint2(cx, cy)).r);
    float black = u.blackLevels[c];
    float denom = max(u.sensorParams.x - black, 1.0f);
    return max((rawVal - black) / denom, 0.0f);
}

// MARK: - Malvar-He-Cutler 5x5 High-Quality Demosaicing

inline float3 demosaicMalvarHeCutler(
    texture2d<ushort, access::read> rawTex,
    int x,
    int y,
    int width,
    int height,
    constant PipelineUniforms &u
) {
    uint c = bayerColorAt(uint(x), uint(y), u.cfaPattern);

    float c00 = sampleBayerNormalized(rawTex, x, y, width, height, u);

    // 1-px cross neighbors
    float n1 = sampleBayerNormalized(rawTex, x, y - 1, width, height, u);
    float s1 = sampleBayerNormalized(rawTex, x, y + 1, width, height, u);
    float w1 = sampleBayerNormalized(rawTex, x - 1, y, width, height, u);
    float e1 = sampleBayerNormalized(rawTex, x + 1, y, width, height, u);

    // Diagonal neighbors
    float nw = sampleBayerNormalized(rawTex, x - 1, y - 1, width, height, u);
    float ne = sampleBayerNormalized(rawTex, x + 1, y - 1, width, height, u);
    float sw = sampleBayerNormalized(rawTex, x - 1, y + 1, width, height, u);
    float se = sampleBayerNormalized(rawTex, x + 1, y + 1, width, height, u);

    // 2-px cardinal neighbors for gradient correction
    float n2 = sampleBayerNormalized(rawTex, x, y - 2, width, height, u);
    float s2 = sampleBayerNormalized(rawTex, x, y + 2, width, height, u);
    float w2 = sampleBayerNormalized(rawTex, x - 2, y, width, height, u);
    float e2 = sampleBayerNormalized(rawTex, x + 2, y, width, height, u);

    float R = 0.0f, G = 0.0f, B = 0.0f;

    if (c == 0u) {
        // Center is Red
        R = c00;
        G = 0.25f * (n1 + s1 + w1 + e1) + 0.125f * (4.0f * c00 - n2 - s2 - w2 - e2);
        B = 0.25f * (nw + ne + sw + se) + 0.1875f * (4.0f * c00 - n2 - s2 - w2 - e2);
    } else if (c == 3u) {
        // Center is Blue
        B = c00;
        G = 0.25f * (n1 + s1 + w1 + e1) + 0.125f * (4.0f * c00 - n2 - s2 - w2 - e2);
        R = 0.25f * (nw + ne + sw + se) + 0.1875f * (4.0f * c00 - n2 - s2 - w2 - e2);
    } else if (c == 1u) {
        // Center is Green on a Red row (Horizontal = R, Vertical = B)
        G = c00;
        R = 0.5f * (w1 + e1) + 0.0625f * (5.0f * c00 - w2 - e2 - nw - ne - sw - se + 0.5f * (n2 + s2));
        B = 0.5f * (n1 + s1) + 0.0625f * (5.0f * c00 - n2 - s2 - nw - ne - sw - se + 0.5f * (w2 + e2));
    } else {
        // Center is Green on a Blue row (Horizontal = B, Vertical = R)
        G = c00;
        B = 0.5f * (w1 + e1) + 0.0625f * (5.0f * c00 - w2 - e2 - nw - ne - sw - se + 0.5f * (n2 + s2));
        R = 0.5f * (n1 + s1) + 0.0625f * (5.0f * c00 - n2 - s2 - nw - ne - sw - se + 0.5f * (w2 + e2));
    }

    return max(float3(R, G, B), float3(0.0f));
}

// MARK: - Industry Log Gamma Transfer Functions (Linear -> Log)

inline float encodeAppleLogChannel(float x) {
    const float R0 = -0.05641088f;
    const float Rt = 0.01f;
    const float c  = 47.28711236f;
    const float b  = 0.00964052f;
    const float g  = 0.08550479f;
    const float d  = 0.69336945f;

    if (x < R0) {
        return 0.0f;
    } else if (x < Rt) {
        float diff = x - R0;
        return c * diff * diff;
    } else {
        return g * log2(x + b) + d;
    }
}

inline float encodeARRILogC3Channel(float x) {
    // ARRI LogC3 EI 800
    const float cut = 0.010591f;
    const float a = 5.555556f;
    const float b = 0.052272f;
    const float c = 0.247190f;
    const float d = 0.385537f;
    const float e = 5.367655f;
    const float f = 0.092809f;

    return (x > cut) ? (c * log10(a * x + b) + d) : (e * x + f);
}

inline float encodeARRILogC4Channel(float x) {
    // ARRI LogC4 standard formula
    const float a = 2231.826309067688f;
    const float b = 0.9071358748778104f;
    const float c = 0.0928641251221896f;
    const float s = 0.1135972086105891f;
    const float t = -0.0180569961199113f;

    if (x >= t) {
        return (log2(a * x + 64.0f) - 6.0f) / 14.0f * b + c;
    } else {
        return (x - t) / s;
    }
}

inline float encodeSonySLog3Channel(float x) {
    const float cut = 0.01125000f;
    if (x >= cut) {
        return (420.0f + log10((x + 0.01f) / (0.18f + 0.01f)) * 261.5f) / 1023.0f;
    } else {
        return (x * (171.2102946929f - 95.0f) / 0.01125000f + 95.0f) / 1023.0f;
    }
}

inline float encodeREDLog3G10Channel(float x) {
    const float a = 0.224282f;
    const float b = 155.975327f;
    const float c = 0.01f;
    const float g = 15.1927f;
    float xc = x + c;
    if (xc < 0.0f) {
        return xc * g;
    }
    return a * log10((xc * b) + 1.0f);
}

inline float encodeDaVinciIntermediateChannel(float x) {
    const float A = 0.0075f;
    const float B = 7.0f;
    const float C = 0.07329248f;
    const float M = 10.44426855f;
    const float LIN_CUT = 0.00262409f;

    if (x <= LIN_CUT) {
        return x * M;
    }
    return (log2(x + A) + B) * C;
}

inline float encodeCanonLog3Channel(float x) {
    if (x < -0.014f) {
        return -0.36726845f * log10(1.0f - 14.98325f * x) + 0.12783901f;
    } else if (x <= 0.014f) {
        return 1.9754798f * x + 0.12512219f;
    } else {
        return 0.36726845f * log10(14.98325f * x + 1.0f) + 0.12240537f;
    }
}

inline float encodePanasonicVLogChannel(float x) {
    const float cut1 = 0.01f;
    const float b = 0.00873f;
    const float c = 0.241514f;
    const float d = 0.598206f;
    if (x < cut1) {
        return 5.6f * x + 0.125f;
    }
    return c * log10(x + b) + d;
}

inline float encodeRec709Channel(float x) {
    float v = max(x, 0.0f);
    return (v < 0.018f) ? (4.5f * v) : (1.099f * pow(v, 0.45f) - 0.099f);
}

inline float3 applyLogCurve(float3 linearRGB, uint curveIndex) {
    float3 c = max(linearRGB, float3(-0.05f));
    switch (curveIndex) {
        case 0u:
            return clamp(float3(encodeAppleLogChannel(c.r), encodeAppleLogChannel(c.g), encodeAppleLogChannel(c.b)), 0.0f, 1.0f);
        case 1u:
            return clamp(float3(encodeARRILogC3Channel(c.r), encodeARRILogC3Channel(c.g), encodeARRILogC3Channel(c.b)), 0.0f, 1.0f);
        case 2u:
            return clamp(float3(encodeARRILogC4Channel(c.r), encodeARRILogC4Channel(c.g), encodeARRILogC4Channel(c.b)), 0.0f, 1.0f);
        case 3u:
            return clamp(float3(encodeSonySLog3Channel(c.r), encodeSonySLog3Channel(c.g), encodeSonySLog3Channel(c.b)), 0.0f, 1.0f);
        case 4u:
            return clamp(float3(encodeREDLog3G10Channel(c.r), encodeREDLog3G10Channel(c.g), encodeREDLog3G10Channel(c.b)), 0.0f, 1.0f);
        case 5u:
            return clamp(float3(encodeDaVinciIntermediateChannel(c.r), encodeDaVinciIntermediateChannel(c.g), encodeDaVinciIntermediateChannel(c.b)), 0.0f, 1.0f);
        case 6u:
            return clamp(float3(encodeCanonLog3Channel(c.r), encodeCanonLog3Channel(c.g), encodeCanonLog3Channel(c.b)), 0.0f, 1.0f);
        case 7u:
            return clamp(float3(encodePanasonicVLogChannel(c.r), encodePanasonicVLogChannel(c.g), encodePanasonicVLogChannel(c.b)), 0.0f, 1.0f);
        default:
            return clamp(float3(encodeRec709Channel(c.r), encodeRec709Channel(c.g), encodeRec709Channel(c.b)), 0.0f, 1.0f);
    }
}

// MARK: - 3D LUT Trilinear Sampler

inline float3 sample3DLUT(
    float3 rgb,
    texture3d<float, access::sample> lutTex,
    float intensity
) {
    constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 uvw = clamp(rgb, 0.0f, 1.0f);
    float3 graded = lutTex.sample(lutSampler, uvw).rgb;
    return mix(rgb, graded, clamp(intensity, 0.0f, 1.0f));
}

// MARK: - False Color IRE Mapping (ARRI / Atomos 10-Band Scale)

inline float3 mapIREToFalseColor(float luma) {
    float ire = clamp(luma * 100.0f, 0.0f, 100.0f);
    if (ire < 3.0f) {
        return float3(0.52f, 0.12f, 0.78f); // Purple: Crushed Black (<3% IRE)
    } else if (ire < 10.0f) {
        return float3(0.15f, 0.35f, 0.92f); // Blue: Deep Shadow (3-10% IRE)
    } else if (ire < 20.0f) {
        return float3(0.18f, 0.75f, 0.88f); // Cyan: Shadow (10-20% IRE)
    } else if (ire < 38.0f) {
        return float3(0.f + ire * 0.008f, float2(ire * 0.008f));
    } else if (ire < 45.0f) {
        return float3(0.15f, 0.82f, 0.28f); // Green: 18% Middle Grey (38-45% IRE)
    } else if (ire < 52.0f) {
        return float3(0.48f, 0.48f, 0.48f); // Neutral Mid-Tone
    } else if (ire < 58.0f) {
        return float3(0.92f, 0.48f, 0.68f); // Pink: Caucasian / Key Skin Tone (52-58% IRE)
    } else if (ire < 78.0f) {
        return float3(0.68f, 0.68f, 0.68f); // Upper Mid-Tone
    } else if (ire < 90.0f) {
        return float3(0.95f, 0.85f, 0.15f); // Yellow: High Key / Shoulder (78-90% IRE)
    } else if (ire < 97.0f) {
        return float3(0.98f, 0.50f, 0.10f); // Orange: Near Clip (90-97% IRE)
    } else {
        return float3(0.96f, 0.12f, 0.12f); // Red: Clipped Highlight (>97% IRE)
    }
}

// MARK: - Rec.709 Gamma Assist Curve for Viewing Flat Log Footage

inline float3 applyRec709GammaAssist(float3 logRGB) {
    // Filmic S-curve normalization for monitoring flat Log profiles in Rec.709 contrast
    float3 x = clamp((logRGB - 0.14f) / 0.74f, 0.0f, 1.0f);
    float3 sCurve = x * x * (3.0f - 2.0f * x);
    // Boost chroma saturation slightly since Log curves look desaturated in raw code values
    float luma = dot(sCurve, float3(0.2126f, 0.7152f, 0.0722f));
    return clamp(mix(float3(luma), sCurve, 1.28f), 0.0f, 1.0f);
}

// MARK: - Kernel 1: True 14-Bit Bayer RAW Debayering + Log Color Pipeline

kernel void debayer_raw_bayer_kernel(
    texture2d<ushort, access::read> rawBayerTex [[texture(0)]],
    texture3d<float, access::sample> lutTex     [[texture(1)]],
    texture2d<float, access::write> outCleanTex [[texture(2)]],
    constant PipelineUniforms &u                [[buffer(0)]],
    uint2 gid                                   [[thread_position_in_grid]]
) {
    uint outW = outCleanTex.get_width();
    uint outH = outCleanTex.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    // Bit 0 = 180-degree flip for Depth-of-Field (DoF) lens adapters
    uint2 targetCoord = ((u.rotate180 & 1u) != 0u)
        ? uint2(outW - 1u - gid.x, outH - 1u - gid.y)
        : gid;

    // Map output pixel coordinate to active sensor crop region
    float2 normUV = (float2(targetCoord) + 0.5f) / float2(outW, outH);

    float exposureEV = u.sensorParams.y;
    float vignetteStrength = u.sensorParams.z;
    float denoiseStrength = u.sensorParams.w;
    float3 wbGains = u.wbAndAnamorphic.xyz;
    float anamorphicStretch = u.wbAndAnamorphic.w;
    float3 colorMatrixRow0 = u.colorMatrixRow0AndZebra.xyz;
    float3 colorMatrixRow1 = u.colorMatrixRow1AndPhase.xyz;
    float3 colorMatrixRow2 = u.colorMatrixRow2AndLUT.xyz;
    float lutIntensity = u.colorMatrixRow2AndLUT.w;

    // Anamorphic desqueeze horizontal sampling around center
    if (anamorphicStretch > 1.001f) {
        normUV.x = (normUV.x - 0.5f) / anamorphicStretch + 0.5f;
        if (normUV.x < 0.0f || normUV.x > 1.0f) {
            outCleanTex.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            return;
        }
    }

    int rawW = int(rawBayerTex.get_width());
    int rawH = int(rawBayerTex.get_height());

    // Bits 1..2 encode SensorCaptureOrientation:
    // 0 = landscapeLeft (horizontal), 1 = landscapeRight (horizontal),
    // 2 = portrait (vertical), 3 = portraitUpsideDown (vertical)
    uint orientation = (u.rotate180 >> 1u) & 3u;
    float2 cropUV;
    if (orientation == 0u) {
        cropUV = normUV;
    } else if (orientation == 1u) {
        cropUV = float2(1.0f - normUV.x, 1.0f - normUV.y);
    } else if (orientation == 2u) {
        cropUV = float2(normUV.y, 1.0f - normUV.x);
    } else {
        cropUV = float2(1.0f - normUV.y, normUV.x);
    }

    int sx = int(float(u.cropRect.x) + cropUV.x * float(u.cropRect.z));
    int sy = int(float(u.cropRect.y) + cropUV.y * float(u.cropRect.w));
    sx = clamp(sx, 0, rawW - 1);
    sy = clamp(sy, 0, rawH - 1);

    // 1. Malvar-He-Cutler 5x5 Demosaic
    float3 rgb = demosaicMalvarHeCutler(rawBayerTex, sx, sy, rawW, rawH, u);

    // 2. Spatial Bilateral Chroma/Luma Denoise in Linear Space
    if (denoiseStrength > 0.01f) {
        float3 nUp    = demosaicMalvarHeCutler(rawBayerTex, sx, max(sy - 2, 0), rawW, rawH, u);
        float3 nDown  = demosaicMalvarHeCutler(rawBayerTex, sx, min(sy + 2, rawH - 1), rawW, rawH, u);
        float3 nLeft  = demosaicMalvarHeCutler(rawBayerTex, max(sx - 2, 0), sy, rawW, rawH, u);
        float3 nRight = demosaicMalvarHeCutler(rawBayerTex, min(sx + 2, rawW - 1), sy, rawW, rawH, u);

        float sigmaRange = 0.04f + 0.08f * denoiseStrength;
        float wU = exp(-length_squared(nUp - rgb) / sigmaRange);
        float wD = exp(-length_squared(nDown - rgb) / sigmaRange);
        float wL = exp(-length_squared(nLeft - rgb) / sigmaRange);
        float wR = exp(-length_squared(nRight - rgb) / sigmaRange);

        float3 blurred = (rgb + wU * nUp + wD * nDown + wL * nLeft + wR * nRight) / (1.0f + wU + wD + wL + wR);
        rgb = mix(rgb, blurred, denoiseStrength);
    }

    // 3. Radial Vignette / Lens Shading Compensation
    if (vignetteStrength > 0.001f) {
        float2 centered = (float2(sx, sy) / float2(rawW, rawH)) - 0.5f;
        float r2 = dot(centered, centered) * 4.0f; // 0 at center, ~2 at corners
        float gain = 1.0f + vignetteStrength * (0.42f * r2 + 0.18f * r2 * r2);
        rgb *= gain;
    }

    // 4. White Balance & Exposure Trim
    rgb *= wbGains;
    rgb *= exp2(exposureEV);

    // 5. 3x3 Color Correction Matrix (Sensor -> Target Cinema Gamut)
    float3 gamutRGB = float3(
        dot(colorMatrixRow0, rgb),
        dot(colorMatrixRow1, rgb),
        dot(colorMatrixRow2, rgb)
    );

    // 6. Log Gamma Encoding
    float3 logRGB = applyLogCurve(gamutRGB, u.logCurveIndex);

    // 7. Optional Baked-In 3D LUT
    if (u.applyLUTToRecord != 0u) {
        logRGB = sample3DLUT(logRGB, lutTex, lutIntensity);
    }

    outCleanTex.write(float4(logRGB, 1.0f), gid);
}

// MARK: - Kernel 2: Process Live Camera Preview Frame (Linearized -> Log Pipeline)

kernel void process_live_video_frame_kernel(
    texture2d<float, access::sample> inVideoTex [[texture(0)]],
    texture3d<float, access::sample> lutTex     [[texture(1)]],
    texture2d<float, access::write> outCleanTex [[texture(2)]],
    constant PipelineUniforms &u                [[buffer(0)]],
    uint2 gid                                   [[thread_position_in_grid]]
) {
    uint outW = outCleanTex.get_width();
    uint outH = outCleanTex.get_height();
    if (gid.x >= outW || gid.y >= outH) {
        return;
    }

    float exposureEV = u.sensorParams.y;
    float vignetteStrength = u.sensorParams.z;
    float denoiseStrength = u.sensorParams.w;
    float3 wbGains = u.wbAndAnamorphic.xyz;
    float anamorphicStretch = u.wbAndAnamorphic.w;
    float3 colorMatrixRow0 = u.colorMatrixRow0AndZebra.xyz;
    float3 colorMatrixRow1 = u.colorMatrixRow1AndPhase.xyz;
    float3 colorMatrixRow2 = u.colorMatrixRow2AndLUT.xyz;
    float lutIntensity = u.colorMatrixRow2AndLUT.w;

    uint2 targetCoord = ((u.rotate180 & 1u) != 0u)
        ? uint2(outW - 1u - gid.x, outH - 1u - gid.y)
        : gid;

    float2 normUV = (float2(targetCoord) + 0.5f) / float2(outW, outH);
    if (anamorphicStretch > 1.001f) {
        normUV.x = (normUV.x - 0.5f) / anamorphicStretch + 0.5f;
        if (normUV.x < 0.0f || normUV.x > 1.0f) {
            outCleanTex.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            return;
        }
    }

    // Map upright output UV into native landscape-left sensor coordinates
    uint orientation = (u.rotate180 >> 1u) & 3u;
    float2 cropUV;
    if (orientation == 0u) {
        cropUV = normUV;
    } else if (orientation == 1u) {
        cropUV = float2(1.0f - normUV.x, 1.0f - normUV.y);
    } else if (orientation == 2u) {
        cropUV = float2(normUV.y, 1.0f - normUV.x);
    } else {
        cropUV = float2(1.0f - normUV.y, normUV.x);
    }

    // Aspect-preserving center crop from native landscape input video texture to active Gate aspect
    float inAspect = float(inVideoTex.get_width()) / float(max(inVideoTex.get_height(), 1u));
    float sensorOutAspect = float(max(outW, outH)) / float(max(min(outW, outH), 1u));
    float2 aspectScale = float2(1.0f, 1.0f);
    if (sensorOutAspect > inAspect) {
        aspectScale.y = inAspect / sensorOutAspect;
    } else {
        aspectScale.x = sensorOutAspect / inAspect;
    }
    float2 uv = clamp((cropUV - 0.5f) * aspectScale + 0.5f, 0.0f, 1.0f);

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 srgb = inVideoTex.sample(s, uv).rgb;

    // Linearize display-referred frame to scene-referred linear light
    float3 linearRGB = pow(max(srgb, float3(0.0f)), float3(2.2f)) * 0.45f;

    // Spatial denoise if requested
    if (denoiseStrength > 0.01f) {
        float2 texel = 1.5f / float2(inVideoTex.get_width(), inVideoTex.get_height());
        float3 c1 = pow(max(inVideoTex.sample(s, uv + float2(texel.x, 0)).rgb, 0.0f), 2.2f) * 0.45f;
        float3 c2 = pow(max(inVideoTex.sample(s, uv - float2(texel.x, 0)).rgb, 0.0f), 0.0f);
        c2 = pow(c2, 2.2f) * 0.45f;
        float3 c3 = pow(max(inVideoTex.sample(s, uv + float2(0, texel.y)).rgb, 0.0f), 2.2f) * 0.45f;
        float3 c4 = pow(max(inVideoTex.sample(s, uv - float2(0, texel.y)).rgb, 0.0f), 2.2f) * 0.45f;
        linearRGB = mix(linearRGB, 0.2f * (linearRGB + c1 + c2 + c3 + c4), denoiseStrength * 0.65f);
    }

    // Vignette compensation
    if (vignetteStrength > 0.001f) {
        float2 centered = uv - 0.5f;
        float r2 = dot(centered, centered) * 4.0f;
        linearRGB *= (1.0f + vignetteStrength * 0.35f * r2);
    }

    // Apply White Balance trim & Exposure EV
    linearRGB *= (wbGains / float3(2.05f, 1.0f, 1.65f));
    linearRGB *= exp2(exposureEV);

    // Apply Color Matrix
    float3 gamutRGB = float3(
        dot(colorMatrixRow0, linearRGB),
        dot(colorMatrixRow1, linearRGB),
        dot(colorMatrixRow2, linearRGB)
    );

    // Apply Log Gamma Curve
    float3 logRGB = applyLogCurve(gamutRGB, u.logCurveIndex);

    if (u.applyLUTToRecord != 0u) {
        logRGB = sample3DLUT(logRGB, lutTex, lutIntensity);
    }

    outCleanTex.write(float4(logRGB, 1.0f), gid);
}

// MARK: - Kernel 3: Monitoring Assists (LUT Preview, Rec.709 Assist, Zebras, False Color)

kernel void monitoring_assist_kernel(
    texture2d<float, access::read> inCleanLogTex   [[texture(0)]],
    texture3d<float, access::sample> lutTex        [[texture(1)]],
    texture2d<float, access::write> outMonitorTex  [[texture(2)]],
    constant PipelineUniforms &u                   [[buffer(0)]],
    uint2 gid                                      [[thread_position_in_grid]]
) {
    uint w = outMonitorTex.get_width();
    uint h = outMonitorTex.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    float zebraThreshold = u.colorMatrixRow0AndZebra.w;
    float framePhase = u.colorMatrixRow1AndPhase.w;
    float lutIntensity = u.colorMatrixRow2AndLUT.w;

    // Map portrait-locked monitor screen coordinates to cleanLogTex coordinates
    // so the physical screen viewfinder always stays locked to the real world.
    uint orientation = (u.rotate180 >> 1u) & 3u;
    float2 mUV = (float2(gid) + 0.5f) / float2(max(w, 1u), max(h, 1u));
    float2 cUV;
    if (orientation == 0u) {
        cUV = float2(mUV.y, 1.0f - mUV.x);
    } else if (orientation == 1u) {
        cUV = float2(1.0f - mUV.y, mUV.x);
    } else if (orientation == 2u) {
        cUV = mUV;
    } else {
        cUV = float2(1.0f - mUV.x, 1.0f - mUV.y);
    }

    uint cleanW = inCleanLogTex.get_width();
    uint cleanH = inCleanLogTex.get_height();
    uint srcX = min(uint(clamp(cUV.x, 0.0f, 0.999999f) * float(cleanW)), cleanW - 1u);
    uint srcY = min(uint(clamp(cUV.y, 0.0f, 0.999999f) * float(cleanH)), cleanH - 1u);

    float3 rgb = inCleanLogTex.read(uint2(srcX, srcY)).rgb;
    float rawLuma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));

    // 1. Monitoring-Only 3D LUT (when not already baked into record texture)
    if (u.applyLUTToMonitor != 0u && u.applyLUTToRecord == 0u) {
        rgb = sample3DLUT(rgb, lutTex, lutIntensity);
    } else if (u.rec709AssistEnabled != 0u && u.applyLUTToRecord == 0u) {
        // 2. Rec.709 Gamma Assist for Log gammas
        rgb = applyRec709GammaAssist(rgb);
    }

    float displayLuma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));

    // 3. False Color Assist
    if (u.falseColorEnabled != 0u) {
        rgb = mapIREToFalseColor(rawLuma);
    }

    // 4. Zebras Assist (marching diagonal stripes over threshold IRE)
    if (u.zebrasEnabled != 0u && max(rawLuma, displayLuma) >= zebraThreshold) {
        int stripe = int(float(gid.x + gid.y) * 0.25f + framePhase * 12.0f) & 3;
        if (stripe < 2) {
            rgb = float3(1.0f, 0.18f, 0.12f);
        } else {
            rgb = float3(0.08f, 0.08f, 0.08f);
        }
    }

    outMonitorTex.write(float4(rgb, 1.0f), gid);
}

// MARK: - Kernel 4: RGB -> 10-Bit YCbCr 4:2:0 / 4:4:4 Bi-Planar Encoder Conversion

kernel void rgb_to_ycbcr10_biplanar_kernel(
    texture2d<float, access::read> inRGBTex       [[texture(0)]],
    texture2d<ushort, access::write> outLumaTex   [[texture(1)]],
    texture2d<ushort, access::write> outChromaTex [[texture(2)]],
    uint2 gid                                     [[thread_position_in_grid]]
) {
    uint w = outLumaTex.get_width();
    uint h = outLumaTex.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    float3 rgb = clamp(inRGBTex.read(gid).rgb, 0.0f, 1.0f);

    // Rec.2020 / Rec.709 Video Range 10-bit YCbCr (Y: 64..940, CbCr: 64..960, shifted into 16-bit MSBs as P010 format expects)
    float yNorm  = 0.2126f * rgb.r + 0.7152f * rgb.g + 0.0722f * rgb.b;
    float cbNorm = (rgb.b - yNorm) / 1.8556f + 0.5f;
    float crNorm = (rgb.r - yNorm) / 1.5748f + 0.5f;

    ushort y10  = ushort(clamp(64.0f + yNorm * 876.0f, 64.0f, 940.0f)) << 6u;
    ushort cb10 = ushort(clamp(64.0f + cbNorm * 896.0f, 64.0f, 960.0f)) << 6u;
    ushort cr10 = ushort(clamp(64.0f + crNorm * 896.0f, 64.0f, 960.0f)) << 6u;

    outLumaTex.write(ushort4(y10, 0u, 0u, 0u), gid);

    uint chromaW = outChromaTex.get_width();
    uint chromaH = outChromaTex.get_height();
    if (chromaW == w && chromaH == h) {
        // 4:4:4 Chroma
        outChromaTex.write(ushort4(cb10, cr10, 0u, 0u), gid);
    } else if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
        // 4:2:0 or 4:2:2 Subsampled Chroma
        uint2 chromaCoord = uint2(gid.x / (w / max(chromaW, 1u)), gid.y / (h / max(chromaH, 1u)));
        if (chromaCoord.x < chromaW && chromaCoord.y < chromaH) {
            outChromaTex.write(ushort4(cb10, cr10, 0u, 0u), chromaCoord);
        }
    }
}

// MARK: - Kernel 5: Bilinear Scale Monitor Texture to MTKView Drawable

kernel void scale_monitor_to_drawable_kernel(
    texture2d<float, access::sample> inMonitorTex  [[texture(0)]],
    texture2d<float, access::write> outDrawableTex [[texture(1)]],
    uint2 gid                                      [[thread_position_in_grid]]
) {
    uint dstW = outDrawableTex.get_width();
    uint dstH = outDrawableTex.get_height();
    if (gid.x >= dstW || gid.y >= dstH) {
        return;
    }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5f) / float2(dstW, dstH);
    float4 color = inMonitorTex.sample(s, uv);
    outDrawableTex.write(color, gid);
}

// MARK: - Render Pipeline Shaders for MTKView Hardware Viewfinder

struct PreviewVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PreviewVertexOut preview_vertex(uint vid [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    const float2 uvs[3] = {
        float2(0.0f, 1.0f),
        float2(2.0f, 1.0f),
        float2(0.0f, -1.0f)
    };
    PreviewVertexOut out;
    out.position = float4(positions[vid], 0.0f, 1.0f);
    out.uv = uvs[vid];
    return out;
}

fragment float4 preview_fragment(
    PreviewVertexOut in [[stage_in]],
    texture2d<float, access::sample> tex [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv);
}

