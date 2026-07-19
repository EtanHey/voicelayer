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
      let idleHoldCursorProofPath = argument(named: "--idle-hold-cursor-proof")
else {
    fputs(
        "usage: NotchCaptureContrastVerifier --dark <notch-only-dir> " +
            "--light <notch-only-dir> --expanded-strip <800x100-png> " +
            "--idle-hold-frames <three-second-60fps-png-dir> " +
            "--idle-hold-cursor-proof <cursor-proof-json> " +
            "--sharpness-frame <same-frame-png> " +
            "--sharpness-wing-region <normalized-x,y,w,h> " +
            "--sharpness-reference-region <normalized-x,y,w,h>\n",
        stderr
    )
    exit(2)
}

do {
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

    if !sharpnessResult.passed ||
        results.contains(where: { !$0.passed }) ||
        birthmarkResults.contains(where: { !$0.passed }) ||
        !idleHoldResult.passed ||
        !cursorAbsencePassed {
        exit(1)
    }
} catch {
    fputs("contrast verification error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
