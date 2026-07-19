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
}

private struct AuditResult {
    let appearance: String
    let name: String
    let ratio: Double
    let candidateCount: Int
    let passed: Bool
}

private let specs = [
    AuditSpec(
        name: "recording-mic",
        fileName: "03-recording.png",
        foreground: NormalizedRect(x: 0.321, y: 0.020, width: 0.022, height: 0.062),
        background: NormalizedRect(x: 0.318, y: 0.084, width: 0.038, height: 0.016),
        minimumRatio: VoiceBarContrast.minimumControlRatio
    ),
    AuditSpec(
        name: "recording-cancel",
        fileName: "03-recording.png",
        foreground: NormalizedRect(x: 0.746, y: 0.018, width: 0.034, height: 0.064),
        background: NormalizedRect(x: 0.742, y: 0.084, width: 0.046, height: 0.016),
        minimumRatio: VoiceBarContrast.minimumControlRatio
    ),
    AuditSpec(
        name: "transcribing-status",
        fileName: "04-transcribing.png",
        foreground: NormalizedRect(x: 0.670, y: 0.016, width: 0.120, height: 0.064),
        background: NormalizedRect(x: 0.680, y: 0.084, width: 0.110, height: 0.016),
        minimumRatio: VoiceBarContrast.minimumTextRatio
    ),
    AuditSpec(
        name: "teleprompter-text",
        fileName: "05-teleprompter.png",
        foreground: NormalizedRect(x: 0.225, y: 0.150, width: 0.500, height: 0.105),
        background: NormalizedRect(x: 0.225, y: 0.340, width: 0.500, height: 0.050),
        minimumRatio: VoiceBarContrast.minimumTextRatio
    ),
]

private func argument(named name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
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
    let sampleCount = max(1, min(ratios.count, max(8, Int(ceil(Double(ratios.count) * 0.12)))))
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

guard let darkDirectory = argument(named: "--dark"),
      let lightDirectory = argument(named: "--light")
else {
    fputs("usage: NotchCaptureContrastVerifier --dark <notch-only-dir> --light <notch-only-dir>\n", stderr)
    exit(2)
}

do {
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
    if results.contains(where: { !$0.passed }) {
        exit(1)
    }
} catch {
    fputs("contrast verification error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
