import AppKit
import Foundation
import VoiceBarUI

private struct NormalizedRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func pixels(in image: NSBitmapImageRep) -> [VoiceBarRGB] {
        let left = max(0, Int((x * Double(image.pixelsWide)).rounded(.down)))
        let top = max(0, Int((y * Double(image.pixelsHigh)).rounded(.down)))
        let right = min(
            image.pixelsWide,
            Int(((x + width) * Double(image.pixelsWide)).rounded(.up))
        )
        let bottom = min(
            image.pixelsHigh,
            Int(((y + height) * Double(image.pixelsHigh)).rounded(.up))
        )

        return (top ..< bottom).flatMap { y in
            (left ..< right).compactMap { x in
                guard let color = image.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB)
                else { return nil }
                return VoiceBarRGB(
                    red: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent
                )
            }
        }
    }
}

private struct AuditSpec {
    let name: String
    let fileName: String
    let foreground: NormalizedRect
    let background: NormalizedRect
    let minimumRatio: Double
    let coreStrokeFraction: Double
}

private struct AuditResult {
    let appearance: String
    let name: String
    let ratio: Double
    let candidateCount: Int
    let passed: Bool
}

private struct CursorProofPoint: Decodable {
    let x: Double
    let y: Double

    var point: CGPoint {
        CGPoint(x: x, y: y)
    }
}

private struct CursorProofRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct IdleHoldCursorProof: Decodable {
    let frameCount: Int
    let retentionRect: CursorProofRect
    let positions: [CursorProofPoint]
}

private struct RenderScaleReceipt: Decodable {
    let ready: Bool
    let screenScale: Double?
    let windowScale: Double
    let contentScale: Double?
    let layerScales: [Double]
}

private let specs = [
    AuditSpec(
        name: "recording-mic",
        fileName: "03-recording.png",
        foreground: NormalizedRect(x: 0.321, y: 0.020, width: 0.022, height: 0.062),
        background: NormalizedRect(x: 0.318, y: 0.084, width: 0.038, height: 0.016),
        minimumRatio: VoiceBarContrast.minimumControlRatio,
        coreStrokeFraction: 0.04
    ),
    AuditSpec(
        name: "recording-cancel",
        fileName: "03-recording.png",
        foreground: NormalizedRect(x: 0.746, y: 0.018, width: 0.034, height: 0.064),
        background: NormalizedRect(x: 0.742, y: 0.084, width: 0.046, height: 0.016),
        minimumRatio: VoiceBarContrast.minimumControlRatio,
        coreStrokeFraction: 0.04
    ),
    AuditSpec(
        name: "transcribing-status",
        fileName: "04-transcribing.png",
        foreground: NormalizedRect(x: 0.670, y: 0.016, width: 0.120, height: 0.064),
        background: NormalizedRect(x: 0.680, y: 0.084, width: 0.110, height: 0.016),
        minimumRatio: VoiceBarContrast.minimumTextRatio,
        coreStrokeFraction: 0.08
    ),
    AuditSpec(
        name: "teleprompter-text",
        fileName: "05-teleprompter.png",
        foreground: NormalizedRect(x: 0.225, y: 0.150, width: 0.500, height: 0.105),
        background: NormalizedRect(x: 0.225, y: 0.340, width: 0.500, height: 0.050),
        minimumRatio: VoiceBarContrast.minimumTextRatio,
        coreStrokeFraction: 0.08
    ),
]

private func argument(named name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
}

private func normalizedRect(argument rawValue: String, name: String) throws -> CGRect {
    let components = rawValue.split(separator: ",", omittingEmptySubsequences: false)
    guard components.count == 4,
          let x = Double(components[0]),
          let y = Double(components[1]),
          let width = Double(components[2]),
          let height = Double(components[3]),
          [x, y, width, height].allSatisfy(\.isFinite),
          x >= 0,
          y >= 0,
          width > 0,
          height > 0,
          x + width <= 1,
          y + height <= 1
    else {
        throw NSError(
            domain: "NotchCaptureContrastVerifier",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(name) must be normalized x,y,width,height inside 0...1",
            ]
        )
    }
    return CGRect(x: x, y: y, width: width, height: height)
}

private func sharpnessAudit(
    framePath: String,
    wingRegionValue: String,
    referenceRegionValue: String
) throws -> VoiceBarNotchEdgeSharpnessAuditResult {
    let frame = try lumaImage(at: URL(fileURLWithPath: framePath))
    return try VoiceBarNotchCaptureAudit.edgeSharpness(
        in: frame,
        wingContentRect: normalizedRect(
            argument: wingRegionValue,
            name: "--sharpness-wing-region"
        ),
        referenceGlyphRect: normalizedRect(
            argument: referenceRegionValue,
            name: "--sharpness-reference-region"
        )
    )
}

private func printSharpness(_ result: VoiceBarNotchEdgeSharpnessAuditResult) {
    let verdict = result.passed ? "PASS" : "FAIL"
    let wing = String(format: "%.1f", result.wingContentMaxGradient)
    let reference = String(format: "%.1f", result.referenceGlyphMaxGradient)
    let ratio = String(format: "%.2f", result.referenceToWingRatio)
    let limit = String(format: "%.2f", result.maximumAllowedRatio)
    print(
        "\(verdict) EDGE-SHARPNESS wing=\(wing) reference=\(reference) " +
            "ratio=\(ratio) limit=\(limit)"
    )
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func medianColor(_ pixels: [VoiceBarRGB]) -> VoiceBarRGB {
    VoiceBarRGB(
        red: median(pixels.map(\.red)),
        green: median(pixels.map(\.green)),
        blue: median(pixels.map(\.blue))
    )
}

private func audit(
    appearance: VoiceBarNotchAppearance,
    appearanceName: String,
    directory: String,
    spec: AuditSpec
) throws -> AuditResult {
    let url = URL(fileURLWithPath: directory).appendingPathComponent(spec.fileName)
    guard let image = NSImage(contentsOf: url),
          let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data)
    else {
        throw NSError(
            domain: "NotchCaptureContrastVerifier",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not decode \(url.path)"]
        )
    }

    let background = medianColor(spec.background.pixels(in: bitmap))
    let candidates = spec.foreground.pixels(in: bitmap).filter {
        VoiceBarContrast.isForegroundCandidate(
            $0,
            against: background,
            appearance: appearance
        )
    }
    let ratios = candidates.map {
        VoiceBarContrast.ratio(foreground: $0, background: background)
    }.sorted(by: >)
    // Anti-aliased edge pixels are already composited with the backdrop and do
    // not represent the shipped foreground color. Grade the opaque core of the
    // glyph stroke while still requiring at least eight independent pixels.
    let sampleCount = max(
        1,
        min(
            ratios.count,
            max(8, Int(ceil(Double(ratios.count) * spec.coreStrokeFraction)))
        )
    )
    let measuredRatio = ratios.isEmpty ? 1 : median(Array(ratios.prefix(sampleCount)))
    let passed = candidates.count >= 8 && measuredRatio >= spec.minimumRatio
    return AuditResult(
        appearance: appearanceName,
        name: spec.name,
        ratio: measuredRatio,
        candidateCount: candidates.count,
        passed: passed
    )
}

private func lumaImage(at url: URL) throws -> VoiceBarLumaImage {
    guard let image = NSImage(contentsOf: url),
          let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data)
    else {
        throw NSError(
            domain: "NotchCaptureContrastVerifier",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not decode \(url.path)"]
        )
    }
    let brightness = (0 ..< bitmap.pixelsHigh).flatMap { y in
        (0 ..< bitmap.pixelsWide).map { x -> Double in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                return 0
            }
            return Double(
                (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
            )
        }
    }
    return VoiceBarLumaImage(
        width: bitmap.pixelsWide,
        height: bitmap.pixelsHigh,
        brightness: brightness
    )
}

private func rgbImage(at url: URL) throws -> VoiceBarRGBImage {
    guard let image = NSImage(contentsOf: url),
          let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data)
    else {
        throw NSError(
            domain: "NotchCaptureContrastVerifier",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not decode \(url.path)"]
        )
    }
    let pixels = (0 ..< bitmap.pixelsHigh).flatMap { y in
        (0 ..< bitmap.pixelsWide).map { x -> VoiceBarRGB in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                return VoiceBarRGB(red: 0, green: 0, blue: 0)
            }
            return VoiceBarRGB(
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent
            )
        }
    }
    return VoiceBarRGBImage(
        width: bitmap.pixelsWide,
        height: bitmap.pixelsHigh,
        pixels: pixels
    )
}

private func pixels(in image: VoiceBarRGBImage, rect: CGRect) -> [VoiceBarRGB] {
    let minX = max(0, min(image.width, Int((rect.minX * CGFloat(image.width)).rounded(.down))))
    let maxX = max(minX, min(image.width, Int((rect.maxX * CGFloat(image.width)).rounded(.up))))
    let minY = max(0, min(image.height, Int((rect.minY * CGFloat(image.height)).rounded(.down))))
    let maxY = max(minY, min(image.height, Int((rect.maxY * CGFloat(image.height)).rounded(.up))))
    return (minY ..< maxY).flatMap { y in
        (minX ..< maxX).map { x in image.pixels[y * image.width + x] }
    }
}

private func glyphContrastParity(
    framePath: String,
    appearance: VoiceBarNotchAppearance,
    wingForegroundRegionValue: String,
    wingBackgroundRegionValue: String,
    referenceForegroundRegionValue: String,
    referenceBackgroundRegionValue: String
) throws -> VoiceBarNotchGlyphContrastParityAuditResult {
    let image = try rgbImage(at: URL(fileURLWithPath: framePath))
    let wingBackgroundPixels = try pixels(
        in: image,
        rect: normalizedRect(
            argument: wingBackgroundRegionValue,
            name: "--glyph-wing-background-region"
        )
    )
    let referenceBackgroundPixels = try pixels(
        in: image,
        rect: normalizedRect(
            argument: referenceBackgroundRegionValue,
            name: "--glyph-reference-background-region"
        )
    )
    let wingBackground = medianColor(wingBackgroundPixels)
    let referenceBackground = medianColor(referenceBackgroundPixels)
    let wingForegroundPixels = try pixels(
        in: image,
        rect: normalizedRect(
            argument: wingForegroundRegionValue,
            name: "--glyph-wing-foreground-region"
        )
    ).filter {
        VoiceBarContrast.isForegroundCandidate(
            $0,
            against: wingBackground,
            appearance: appearance
        )
    }
    let referenceForegroundPixels = try pixels(
        in: image,
        rect: normalizedRect(
            argument: referenceForegroundRegionValue,
            name: "--glyph-reference-foreground-region"
        )
    ).filter {
        VoiceBarContrast.isForegroundCandidate(
            $0,
            against: referenceBackground,
            appearance: appearance
        )
    }
    return VoiceBarNotchCaptureAudit.glyphContrastParity(
        wingForegroundPixels: wingForegroundPixels,
        wingBackgroundPixels: wingBackgroundPixels,
        referenceForegroundPixels: referenceForegroundPixels,
        referenceBackgroundPixels: referenceBackgroundPixels
    )
}

private func idleHoldFrameURLs(in directory: String) throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func captureFrameURLs(in directory: String, count: Int) -> [URL] {
    VoiceBarNotchCaptureAudit.captureFrameNames(count: count).map {
        URL(fileURLWithPath: directory).appendingPathComponent($0)
    }
}

private func lumaPixels(in image: VoiceBarLumaImage, rect: CGRect) -> [Double] {
    let minX = max(0, min(image.width, Int((rect.minX * CGFloat(image.width)).rounded(.down))))
    let maxX = max(minX, min(image.width, Int((rect.maxX * CGFloat(image.width)).rounded(.up))))
    let minY = max(0, min(image.height, Int((rect.minY * CGFloat(image.height)).rounded(.down))))
    let maxY = max(minY, min(image.height, Int((rect.maxY * CGFloat(image.height)).rounded(.up))))
    return (minY ..< maxY).flatMap { y in
        (minX ..< maxX).map { x in image.brightness[y * image.width + x] }
    }
}

private func meanAbsoluteDifference(
    _ lhs: VoiceBarLumaImage,
    _ rhs: VoiceBarLumaImage,
    rect: CGRect
) throws -> Double {
    guard lhs.width == rhs.width, lhs.height == rhs.height else {
        throw NSError(
            domain: "NotchCaptureContrastVerifier",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "dismissal frames must have identical dimensions"]
        )
    }
    let lhsPixels = lumaPixels(in: lhs, rect: rect)
    let rhsPixels = lumaPixels(in: rhs, rect: rect)
    guard !lhsPixels.isEmpty, lhsPixels.count == rhsPixels.count else { return 0 }
    return zip(lhsPixels, rhsPixels).reduce(0) { result, values in
        result + abs(values.0 - values.1)
    } / Double(lhsPixels.count)
}

private func teleprompterDismissalAudit(
    framesDirectory: String,
    textRegionValue: String,
    interiorRegionValue: String
) throws -> VoiceBarNotchTeleprompterDismissalAuditResult {
    let textRect = try normalizedRect(
        argument: textRegionValue,
        name: "--teleprompter-dismissal-text-region"
    )
    let interiorRect = try normalizedRect(
        argument: interiorRegionValue,
        name: "--teleprompter-dismissal-interior-region"
    )
    let frames = try captureFrameURLs(in: framesDirectory, count: 18).map(lumaImage)
    guard let dismissedReference = frames.last else {
        throw NSError(
            domain: "NotchCaptureContrastVerifier",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "dismissal capture has no PNG frames"]
        )
    }
    let textDeltas = try frames.map {
        try meanAbsoluteDifference($0, dismissedReference, rect: textRect)
    }
    let materialDeltas = try frames.map {
        try meanAbsoluteDifference($0, dismissedReference, rect: interiorRect)
    }
    let textReference = textDeltas.max() ?? 0
    let materialReference = materialDeltas.max() ?? 0
    let frameSamples = zip(zip(frames, textDeltas), materialDeltas).map { values, materialDelta in
        let (frame, textDelta) = values
        return VoiceBarNotchTeleprompterDismissalFrameSample(
            textOpacity: textReference > 0 ? textDelta / textReference : 0,
            materialOpacity: materialReference > 0 ? materialDelta / materialReference : 0,
            interiorBrightness: lumaPixels(in: frame, rect: interiorRect)
        )
    }
    return VoiceBarNotchCaptureAudit.teleprompterDismissal(frameSamples: frameSamples)
}

private func contrastingPixels(
    in image: VoiceBarRGBImage,
    foregroundRect: CGRect,
    backgroundRect: CGRect
) -> (foreground: [VoiceBarRGB], background: [VoiceBarRGB]) {
    let background = pixels(in: image, rect: backgroundRect)
    let backgroundColor = medianColor(background)
    let backgroundLuminance = VoiceBarContrast.relativeLuminance(backgroundColor)
    let foreground = pixels(in: image, rect: foregroundRect).filter {
        abs(VoiceBarContrast.relativeLuminance($0) - backgroundLuminance) >=
            VoiceBarContrast.minimumForegroundLuminanceDelta
    }
    return (foreground, background)
}

private func glassReadabilityAudit(
    teleprompterFramesDirectory: String,
    blackFramesDirectory: String,
    brightFramesDirectory: String,
    teleprompterInteriorRegionValue: String,
    teleprompterTextRegionValue: String,
    teleprompterBackgroundRegionValue: String,
    wingForegroundRegionValue: String,
    wingBackgroundRegionValue: String,
    referenceForegroundRegionValue: String,
    referenceBackgroundRegionValue: String
) throws -> VoiceBarNotchGlassReadabilityAuditResult {
    let teleprompterInteriorRect = try normalizedRect(
        argument: teleprompterInteriorRegionValue,
        name: "--glass-teleprompter-interior-region"
    )
    let teleprompterTextRect = try normalizedRect(
        argument: teleprompterTextRegionValue,
        name: "--glass-teleprompter-text-region"
    )
    let teleprompterBackgroundRect = try normalizedRect(
        argument: teleprompterBackgroundRegionValue,
        name: "--glass-teleprompter-background-region"
    )
    let wingForegroundRect = try normalizedRect(
        argument: wingForegroundRegionValue,
        name: "--glass-wing-foreground-region"
    )
    let wingBackgroundRect = try normalizedRect(
        argument: wingBackgroundRegionValue,
        name: "--glass-wing-background-region"
    )
    let referenceForegroundRect = try normalizedRect(
        argument: referenceForegroundRegionValue,
        name: "--glass-reference-foreground-region"
    )
    let referenceBackgroundRect = try normalizedRect(
        argument: referenceBackgroundRegionValue,
        name: "--glass-reference-background-region"
    )

    let teleprompterSamples = try captureFrameURLs(
        in: teleprompterFramesDirectory,
        count: 3
    ).map { url in
        let luma = try lumaImage(at: url)
        let rgb = try rgbImage(at: url)
        let text = contrastingPixels(
            in: rgb,
            foregroundRect: teleprompterTextRect,
            backgroundRect: teleprompterBackgroundRect
        )
        return VoiceBarNotchTeleprompterReadabilitySample(
            interiorBrightness: lumaPixels(in: luma, rect: teleprompterInteriorRect),
            textForegroundPixels: text.foreground,
            textBackgroundPixels: text.background
        )
    }

    func wingSamples(in directory: String) throws -> [VoiceBarNotchWingReadabilitySample] {
        try captureFrameURLs(in: directory, count: 3).map { url in
            let image = try rgbImage(at: url)
            let wing = contrastingPixels(
                in: image,
                foregroundRect: wingForegroundRect,
                backgroundRect: wingBackgroundRect
            )
            let reference = contrastingPixels(
                in: image,
                foregroundRect: referenceForegroundRect,
                backgroundRect: referenceBackgroundRect
            )
            return VoiceBarNotchWingReadabilitySample(
                wingForegroundPixels: wing.foreground,
                wingBackgroundPixels: wing.background,
                referenceForegroundPixels: reference.foreground,
                referenceBackgroundPixels: reference.background
            )
        }
    }

    return try VoiceBarNotchCaptureAudit.glassReadability(
        teleprompterFrames: teleprompterSamples,
        blackWingFrames: wingSamples(in: blackFramesDirectory),
        brightWingFrames: wingSamples(in: brightFramesDirectory)
    )
}

private func printGlassReadability(_ result: VoiceBarNotchGlassReadabilityAuditResult) {
    for (index, metric) in result.teleprompterMetrics.enumerated() {
        print(
            "\(metric.passed ? "PASS" : "FAIL") GLASS-TELEPROMPTER/\(index + 1) " +
                "pixels=\(metric.interiorPixelCount) " +
                "textPixels=\(metric.textPixelCount) " +
                "interiorSD=\(String(format: "%.2f", metric.interiorStandardDeviation)) " +
                "textContrast=\(String(format: "%.2f", metric.textContrastRatio)) " +
                "readableFraction=\(String(format: "%.2f", metric.readableForegroundFraction))"
        )
    }
    for (backdrop, metrics) in [
        ("black", result.blackWingMetrics),
        ("bright", result.brightWingMetrics),
    ] {
        for (index, metric) in metrics.enumerated() {
            print(
                "\(metric.passed ? "PASS" : "FAIL") GLASS-WING/\(backdrop)/\(index + 1) " +
                    "wingPixels=\(metric.wingPixelCount) " +
                    "referencePixels=\(metric.nativeReferencePixelCount) " +
                    "wing=\(String(format: "%.2f", metric.wingContrastRatio)) " +
                    "reference=\(String(format: "%.2f", metric.nativeReferenceContrastRatio)) " +
                    "readableFraction=\(String(format: "%.2f", metric.readableForegroundFraction))"
            )
        }
    }
    print(
        "\(result.passed ? "PASS" : "FAIL") GLASS-READABILITY " +
            "frames=\(result.teleprompterFrameCount)/" +
            "\(result.blackWingFrameCount)/\(result.brightWingFrameCount) " +
            "maxInteriorSD=\(String(format: "%.2f", result.maximumInteriorStandardDeviation)) " +
            "minText=\(String(format: "%.2f", result.minimumTextContrastRatio)) " +
            "minWing=\(String(format: "%.2f", result.minimumWingContrastRatio)) " +
            "minReference=\(String(format: "%.2f", result.minimumNativeReferenceContrastRatio))"
    )
}

if CommandLine.arguments.contains("--glass-readability-only") {
    guard let teleprompterFramesDirectory = argument(named: "--glass-teleprompter-frames"),
          let blackFramesDirectory = argument(named: "--glass-black-frames"),
          let brightFramesDirectory = argument(named: "--glass-bright-frames"),
          let teleprompterInteriorRegionValue = argument(named: "--glass-teleprompter-interior-region"),
          let teleprompterTextRegionValue = argument(named: "--glass-teleprompter-text-region"),
          let teleprompterBackgroundRegionValue = argument(named: "--glass-teleprompter-background-region"),
          let wingForegroundRegionValue = argument(named: "--glass-wing-foreground-region"),
          let wingBackgroundRegionValue = argument(named: "--glass-wing-background-region"),
          let referenceForegroundRegionValue = argument(named: "--glass-reference-foreground-region"),
          let referenceBackgroundRegionValue = argument(named: "--glass-reference-background-region")
    else {
        fputs(
            "usage: NotchCaptureContrastVerifier --glass-readability-only " +
                "--glass-teleprompter-frames <png-dir> --glass-black-frames <png-dir> " +
                "--glass-bright-frames <png-dir> plus all normalized glass regions\n",
            stderr
        )
        exit(2)
    }
    do {
        let result = try glassReadabilityAudit(
            teleprompterFramesDirectory: teleprompterFramesDirectory,
            blackFramesDirectory: blackFramesDirectory,
            brightFramesDirectory: brightFramesDirectory,
            teleprompterInteriorRegionValue: teleprompterInteriorRegionValue,
            teleprompterTextRegionValue: teleprompterTextRegionValue,
            teleprompterBackgroundRegionValue: teleprompterBackgroundRegionValue,
            wingForegroundRegionValue: wingForegroundRegionValue,
            wingBackgroundRegionValue: wingBackgroundRegionValue,
            referenceForegroundRegionValue: referenceForegroundRegionValue,
            referenceBackgroundRegionValue: referenceBackgroundRegionValue
        )
        printGlassReadability(result)
        exit(result.passed ? 0 : 1)
    } catch {
        fputs("glass readability verification error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

if CommandLine.arguments.contains("--teleprompter-dismissal-only") {
    guard let framesDirectory = argument(named: "--teleprompter-dismissal-frames"),
          let textRegionValue = argument(named: "--teleprompter-dismissal-text-region"),
          let interiorRegionValue = argument(named: "--teleprompter-dismissal-interior-region")
    else {
        fputs(
            "usage: NotchCaptureContrastVerifier --teleprompter-dismissal-only " +
                "--teleprompter-dismissal-frames <real-capture-png-dir> " +
                "--teleprompter-dismissal-text-region <normalized-x,y,w,h> " +
                "--teleprompter-dismissal-interior-region <normalized-x,y,w,h>\n",
            stderr
        )
        exit(2)
    }
    do {
        let result = try teleprompterDismissalAudit(
            framesDirectory: framesDirectory,
            textRegionValue: textRegionValue,
            interiorRegionValue: interiorRegionValue
        )
        let verdict = result.passed ? "PASS" : "FAIL"
        print(
            "\(verdict) TELEPROMPTER-DISMISSAL " +
                "frames=\(result.frameCount) violations=\(result.violatingFrameIndices) " +
                "maxOpaqueInteriorSD=" +
                String(format: "%.2f", result.maximumOpaqueTextInteriorStandardDeviation)
        )
        exit(result.passed ? 0 : 1)
    } catch {
        fputs("teleprompter dismissal verification error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

guard let sharpnessFramePath = argument(named: "--sharpness-frame"),
      let sharpnessWingRegionValue = argument(named: "--sharpness-wing-region"),
      let sharpnessReferenceRegionValue = argument(named: "--sharpness-reference-region")
else {
    fputs(
        "usage: NotchCaptureContrastVerifier --sharpness-frame <same-frame-png> " +
            "--sharpness-wing-region <normalized-x,y,w,h> " +
            "--sharpness-reference-region <normalized-x,y,w,h> [--sharpness-only]\n",
        stderr
    )
    exit(2)
}

if CommandLine.arguments.contains("--sharpness-only") {
    do {
        let sharpness = try sharpnessAudit(
            framePath: sharpnessFramePath,
            wingRegionValue: sharpnessWingRegionValue,
            referenceRegionValue: sharpnessReferenceRegionValue
        )
        printSharpness(sharpness)
        exit(sharpness.passed ? 0 : 1)
    } catch {
        fputs("sharpness verification error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

guard let darkDirectory = argument(named: "--dark"),
      let lightDirectory = argument(named: "--light"),
      let expandedStripPath = argument(named: "--expanded-strip"),
      let idleHoldFramesDirectory = argument(named: "--idle-hold-frames"),
      let idleHoldCursorProofPath = argument(named: "--idle-hold-cursor-proof"),
      let waveformRecordingFramesDirectory = argument(named: "--waveform-recording-frames"),
      let waveformTranscribingFramesDirectory = argument(named: "--waveform-transcribing-frames"),
      let waveformSpeakingFramesDirectory = argument(named: "--waveform-speaking-frames"),
      let darkLiveFramePath = argument(named: "--dark-live-frame"),
      let lightLiveFramePath = argument(named: "--light-live-frame"),
      let glyphWingForegroundRegionValue = argument(named: "--glyph-wing-foreground-region"),
      let glyphWingBackgroundRegionValue = argument(named: "--glyph-wing-background-region"),
      let glyphReferenceForegroundRegionValue = argument(named: "--glyph-reference-foreground-region"),
      let glyphReferenceBackgroundRegionValue = argument(named: "--glyph-reference-background-region"),
      let paddingFramePath = argument(named: "--padding-frame"),
      let paddingLeadingWingRegionValue = argument(named: "--padding-leading-wing-region"),
      let paddingTrailingWingRegionValue = argument(named: "--padding-trailing-wing-region"),
      let captureBackingScaleValue = argument(named: "--capture-backing-scale"),
      let captureBackingScale = Double(captureBackingScaleValue),
      let renderScaleReceiptPath = argument(named: "--render-scale-receipt")
else {
    fputs(
        "usage: NotchCaptureContrastVerifier --dark <notch-only-dir> " +
            "--light <notch-only-dir> --expanded-strip <800x100-png> " +
            "--idle-hold-frames <three-second-60fps-png-dir> " +
            "--idle-hold-cursor-proof <cursor-proof-json> " +
            "--waveform-recording-frames <cropped-png-dir> " +
            "--waveform-transcribing-frames <cropped-png-dir> " +
            "--waveform-speaking-frames <cropped-png-dir> " +
            "--dark-live-frame <same-frame-dark-png> " +
            "--light-live-frame <same-frame-light-png> " +
            "--glyph-wing-foreground-region <normalized-x,y,w,h> " +
            "--glyph-wing-background-region <normalized-x,y,w,h> " +
            "--glyph-reference-foreground-region <normalized-x,y,w,h> " +
            "--glyph-reference-background-region <normalized-x,y,w,h> " +
            "--padding-frame <transcribing-png> " +
            "--padding-leading-wing-region <normalized-x,y,w,h> " +
            "--padding-trailing-wing-region <normalized-x,y,w,h> " +
            "--capture-backing-scale <scale> " +
            "--render-scale-receipt <json> " +
            "--sharpness-frame <same-frame-png> " +
            "--sharpness-wing-region <normalized-x,y,w,h> " +
            "--sharpness-reference-region <normalized-x,y,w,h>\n",
        stderr
    )
    exit(2)
}

do {
    let renderScaleReceipt = try JSONDecoder().decode(
        RenderScaleReceipt.self,
        from: Data(contentsOf: URL(fileURLWithPath: renderScaleReceiptPath))
    )
    let renderScalePassed = renderScaleReceipt.ready &&
        renderScaleReceipt.screenScale != nil &&
        abs((renderScaleReceipt.screenScale ?? 0) - renderScaleReceipt.windowScale) <= 0.01 &&
        abs((renderScaleReceipt.screenScale ?? 0) - (renderScaleReceipt.contentScale ?? 0)) <= 0.01 &&
        !renderScaleReceipt.layerScales.isEmpty &&
        renderScaleReceipt.layerScales.allSatisfy {
            abs((renderScaleReceipt.screenScale ?? 0) - $0) <= 0.01
        }
    print(
        "\(renderScalePassed ? "PASS" : "FAIL") RENDER-SCALE " +
            "screen=\(renderScaleReceipt.screenScale.map { String(format: "%.2f", $0) } ?? "nil") " +
            "window=\(String(format: "%.2f", renderScaleReceipt.windowScale)) " +
            "content=\(renderScaleReceipt.contentScale.map { String(format: "%.2f", $0) } ?? "nil") " +
            "layers=\(renderScaleReceipt.layerScales.map { String(format: "%.2f", $0) }.joined(separator: ","))"
    )

    let sharpnessResult = try sharpnessAudit(
        framePath: sharpnessFramePath,
        wingRegionValue: sharpnessWingRegionValue,
        referenceRegionValue: sharpnessReferenceRegionValue
    )
    printSharpness(sharpnessResult)

    let results = try [
        (VoiceBarNotchAppearance.dark, "dark", darkDirectory),
        (VoiceBarNotchAppearance.light, "light", lightDirectory),
    ].flatMap { appearance, appearanceName, directory in
        try specs.map {
            try audit(
                appearance: appearance,
                appearanceName: appearanceName,
                directory: directory,
                spec: $0
            )
        }
    }

    for result in results {
        print(
            "\(result.passed ? "PASS" : "FAIL") " +
                "\(result.appearance)/\(result.name) " +
                "contrast=\(String(format: "%.2f", result.ratio)) " +
                "candidates=\(result.candidateCount)"
        )
    }

    let glyphParityResults = try [
        (
            "dark",
            glyphContrastParity(
                framePath: darkLiveFramePath,
                appearance: .dark,
                wingForegroundRegionValue: glyphWingForegroundRegionValue,
                wingBackgroundRegionValue: glyphWingBackgroundRegionValue,
                referenceForegroundRegionValue: glyphReferenceForegroundRegionValue,
                referenceBackgroundRegionValue: glyphReferenceBackgroundRegionValue
            )
        ),
        (
            "light",
            glyphContrastParity(
                framePath: lightLiveFramePath,
                appearance: .light,
                wingForegroundRegionValue: glyphWingForegroundRegionValue,
                wingBackgroundRegionValue: glyphWingBackgroundRegionValue,
                referenceForegroundRegionValue: glyphReferenceForegroundRegionValue,
                referenceBackgroundRegionValue: glyphReferenceBackgroundRegionValue
            )
        ),
    ]
    for (appearance, result) in glyphParityResults {
        print(
            "\(result.passed ? "PASS" : "FAIL") GLYPH-CONTRAST-PARITY/\(appearance) " +
                "wing=\(String(format: "%.2f", result.wingContrastRatio)) " +
                "reference=\(String(format: "%.2f", result.referenceContrastRatio))"
        )
    }

    let expandedStrip = try lumaImage(at: URL(fileURLWithPath: expandedStripPath))
    let birthmarkResults = [VoiceBarNotchSide.leading, .trailing].map {
        VoiceBarNotchCaptureAudit.birthmark(in: expandedStrip, side: $0)
    }
    for result in birthmarkResults {
        let side = result.side == .leading ? "leading" : "trailing"
        print(
            "\(result.passed ? "PASS" : "FAIL") BIRTHMARK/\(side) " +
                "baseline=\(String(format: "%.1f", result.fillBaseline)) " +
                "contrast=\(String(format: "%.1f", result.settledContrast)) " +
                "largestBlob=\(result.largestBlobPixels) " +
                "limit=\(result.blobPixelLimit)"
        )
    }

    let idleHoldFrames = try idleHoldFrameURLs(in: idleHoldFramesDirectory)
    let idleHoldBrightness = try idleHoldFrames.map { url -> Double in
        let frame = try lumaImage(at: url)
        guard let sample = VoiceBarNotchCaptureAudit.idleHoldSampleBrightness(in: frame) else {
            throw NSError(
                domain: "NotchCaptureContrastVerifier",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Empty idle-hold sample in \(url.path)"]
            )
        }
        return sample
    }
    let idleHoldResult = VoiceBarNotchCaptureAudit.idleHold(
        frameBrightnesses: idleHoldBrightness
    )
    print(
        "\(idleHoldResult.passed ? "PASS" : "FAIL") IDLE-HOLD " +
            "frames=\(idleHoldResult.frameCount) " +
            "expanded=\(idleHoldResult.expandedFrameCount) " +
            "transitions=\(idleHoldResult.visibilityTransitions)"
    )

    let cursorProofData = try Data(
        contentsOf: URL(fileURLWithPath: idleHoldCursorProofPath)
    )
    let cursorProof = try JSONDecoder().decode(
        IdleHoldCursorProof.self,
        from: cursorProofData
    )
    let cursorAbsenceResult = VoiceBarNotchCaptureAudit.cursorAbsent(
        frameCount: idleHoldFrames.count,
        cursorPositions: cursorProof.positions.map(\.point),
        retentionRect: cursorProof.retentionRect.rect
    )
    let cursorFrameCountMatches = cursorProof.frameCount == idleHoldFrames.count
    let cursorAbsencePassed = cursorFrameCountMatches && cursorAbsenceResult.passed
    print(
        "\(cursorAbsencePassed ? "PASS" : "FAIL") CURSOR-ABSENT " +
            "frames=\(idleHoldFrames.count) " +
            "declared=\(cursorProof.frameCount) " +
            "samples=\(cursorAbsenceResult.sampleCount) " +
            "inside=\(cursorAbsenceResult.insideFrameCount)"
    )

    let recordingWaveformFrames = try idleHoldFrameURLs(
        in: waveformRecordingFramesDirectory
    ).map(rgbImage)
    let transcribingWaveformFrames = try idleHoldFrameURLs(
        in: waveformTranscribingFramesDirectory
    ).map(rgbImage)
    let speakingWaveformFrames = try idleHoldFrameURLs(
        in: waveformSpeakingFramesDirectory
    ).map(rgbImage)
    let waveformCensus = VoiceBarNotchCaptureAudit.waveformCensus(
        recordingFrames: recordingWaveformFrames,
        transcribingFrames: transcribingWaveformFrames,
        speakingFrames: speakingWaveformFrames
    )
    print(
        "\(waveformCensus.passed ? "PASS" : "FAIL") WAVEFORM-CENSUS " +
            "frames=\(waveformCensus.recordingFrameCount)/" +
            "\(waveformCensus.transcribingFrameCount)/" +
            "\(waveformCensus.speakingFrameCount) bars=" +
            "\(waveformCensus.minimumRecordingBarCount)/" +
            "\(waveformCensus.minimumTranscribingBarCount)/" +
            "\(waveformCensus.minimumSpeakingBarCount) peakRatio=" +
            String(format: "%.2f", waveformCensus.recordingToSpeakingPeakRatio) +
            " transcribingComplete=" +
            String(format: "%.3f", waveformCensus.transcribingCompleteFraction) +
            " centerDeviation=" +
            String(format: "%.2f", waveformCensus.recordingMaximumCenterDeviation) +
            " transcribingCenterDeviation=" +
            String(format: "%.2f", waveformCensus.transcribingMaximumCenterDeviation) +
            " transcribingBottomSpread=" +
            String(format: "%.2f", waveformCensus.transcribingMaximumBottomSpread) +
            " slotDelta=" +
            String(format: "%.2f", waveformCensus.maximumSlotOffsetDelta)
    )

    let paddingFrame = try rgbImage(at: URL(fileURLWithPath: paddingFramePath))
    let compactPadding = try VoiceBarNotchCaptureAudit.compactPadding(
        in: paddingFrame,
        leadingWingRect: normalizedRect(
            argument: paddingLeadingWingRegionValue,
            name: "--padding-leading-wing-region"
        ),
        trailingWingRect: normalizedRect(
            argument: paddingTrailingWingRegionValue,
            name: "--padding-trailing-wing-region"
        ),
        backingScale: captureBackingScale
    )
    print(
        "\(compactPadding.passed ? "PASS" : "FAIL") COMPACT-PADDING " +
            "spinner=\(String(format: "%.2f", compactPadding.spinnerLeadingPadding)) " +
            "waveform=\(String(format: "%.2f", compactPadding.waveformLeadingPadding)) " +
            "delta=\(String(format: "%.2f", compactPadding.paddingDelta))"
    )

    if !renderScalePassed ||
        !sharpnessResult.passed ||
        results.contains(where: { !$0.passed }) ||
        glyphParityResults.contains(where: { !$0.1.passed }) ||
        birthmarkResults.contains(where: { !$0.passed }) ||
        !idleHoldResult.passed ||
        !cursorAbsencePassed ||
        !waveformCensus.passed ||
        !compactPadding.passed {
        exit(1)
    }
} catch {
    fputs("contrast verification error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
