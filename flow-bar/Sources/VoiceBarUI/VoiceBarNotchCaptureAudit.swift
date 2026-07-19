import Foundation

public struct VoiceBarLumaImage: Equatable {
    public let width: Int
    public let height: Int
    public let brightness: [Double]

    public init(width: Int, height: Int, brightness: [Double]) {
        precondition(width > 0 && height > 0)
        precondition(brightness.count == width * height)
        self.width = width
        self.height = height
        self.brightness = brightness
    }

    public func meanBrightness(in rect: CGRect) -> Double? {
        let xRange = pixelRange(origin: rect.minX, extent: rect.width, limit: width)
        let yRange = pixelRange(origin: rect.minY, extent: rect.height, limit: height)
        guard !xRange.isEmpty, !yRange.isEmpty else { return nil }
        var sum = 0.0
        var count = 0
        for y in yRange {
            for x in xRange {
                sum += brightness[y * width + x]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    fileprivate func values(in rect: CGRect) -> [(x: Int, y: Int, brightness: Double)] {
        let xRange = pixelRange(origin: rect.minX, extent: rect.width, limit: width)
        let yRange = pixelRange(origin: rect.minY, extent: rect.height, limit: height)
        return yRange.flatMap { y in
            xRange.map { x in
                (x: x, y: y, brightness: brightness[y * width + x])
            }
        }
    }

    private func pixelRange(origin: CGFloat, extent: CGFloat, limit: Int) -> Range<Int> {
        let lower = max(0, min(limit, Int((origin * CGFloat(limit)).rounded(.down))))
        let upper = max(lower, min(limit, Int(((origin + extent) * CGFloat(limit)).rounded(.up))))
        return lower ..< upper
    }
}

public struct VoiceBarNotchBirthmarkAuditResult: Equatable {
    public let side: VoiceBarNotchSide
    public let fillBaseline: Double
    public let largestBlobPixels: Int
    public let blobPixelLimit: Int
    public let settledContrast: Double
    public let passed: Bool
}

public struct VoiceBarNotchIdleHoldAuditResult: Equatable {
    public let frameCount: Int
    public let visibilityTransitions: Int
    public let expandedFrameCount: Int
    public let passed: Bool
}

public struct VoiceBarNotchCursorAbsenceAuditResult: Equatable {
    public let frameCount: Int
    public let sampleCount: Int
    public let insideFrameCount: Int
    public let passed: Bool
}

public enum VoiceBarNotchCaptureAudit {
    public static let referenceSize = CGSize(width: 800, height: 100)
    public static let birthmarkBrightnessOffset = 18.0
    public static let maximumSettledBirthmarkContrast = 10.0
    public static let maximumBirthmarkBrightness = 130.0
    public static let maximumBirthmarkBlobPixels = 150
    public static let idleVisibilityThreshold = 90.0
    public static let minimumIdleHoldFrames = 180

    public static func birthmark(
        in image: VoiceBarLumaImage,
        side: VoiceBarNotchSide
    ) -> VoiceBarNotchBirthmarkAuditResult {
        let regions = birthmarkRegions(for: side)
        let baselinePixels = image.values(in: regions.baseline).map(\.brightness)
        let fillBaseline = mean(baselinePixels)
        let auditPixels = image.values(in: regions.audit)
        let mask = Set(auditPixels.compactMap { pixel -> PixelCoordinate? in
            guard pixel.brightness > fillBaseline + birthmarkBrightnessOffset,
                  pixel.brightness < maximumBirthmarkBrightness
            else { return nil }
            return PixelCoordinate(x: pixel.x, y: pixel.y)
        })
        let largestBlobPixels = largestConnectedComponent(in: mask)
        let dimWingPixels = auditPixels
            .map(\.brightness)
            .filter { $0 < maximumBirthmarkBrightness }
        let settledContrast = max(0, percentile(dimWingPixels, percentile: 0.95) - fillBaseline)
        let scale = (Double(image.width) / referenceSize.width) *
            (Double(image.height) / referenceSize.height)
        let blobPixelLimit = max(1, Int((Double(maximumBirthmarkBlobPixels) * scale).rounded(.up)))
        let passed = !baselinePixels.isEmpty &&
            largestBlobPixels <= blobPixelLimit &&
            settledContrast < maximumSettledBirthmarkContrast

        return VoiceBarNotchBirthmarkAuditResult(
            side: side,
            fillBaseline: fillBaseline,
            largestBlobPixels: largestBlobPixels,
            blobPixelLimit: blobPixelLimit,
            settledContrast: settledContrast,
            passed: passed
        )
    }

    public static func idleHold(
        frameBrightnesses: [Double]
    ) -> VoiceBarNotchIdleHoldAuditResult {
        let expanded = frameBrightnesses.map { $0 < idleVisibilityThreshold }
        let transitions = zip(expanded, expanded.dropFirst()).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        let expandedFrameCount = expanded.filter { $0 }.count
        return VoiceBarNotchIdleHoldAuditResult(
            frameCount: frameBrightnesses.count,
            visibilityTransitions: transitions,
            expandedFrameCount: expandedFrameCount,
            passed: frameBrightnesses.count >= minimumIdleHoldFrames &&
                transitions == 0 &&
                expandedFrameCount == frameBrightnesses.count
        )
    }

    public static func idleHoldSampleBrightness(in image: VoiceBarLumaImage) -> Double? {
        image.meanBrightness(in: normalizedRect(x: 40, y: 20, width: 80, height: 25))
    }

    public static func cursorAbsent(
        frameCount: Int,
        cursorPositions: [CGPoint],
        retentionRect: CGRect
    ) -> VoiceBarNotchCursorAbsenceAuditResult {
        let insideFrameCount = cursorPositions.filter(retentionRect.contains).count
        return VoiceBarNotchCursorAbsenceAuditResult(
            frameCount: frameCount,
            sampleCount: cursorPositions.count,
            insideFrameCount: insideFrameCount,
            passed: frameCount >= minimumIdleHoldFrames &&
                cursorPositions.count == frameCount &&
                insideFrameCount == 0
        )
    }

    private static func birthmarkRegions(
        for side: VoiceBarNotchSide
    ) -> (audit: CGRect, baseline: CGRect) {
        switch side {
        case .leading:
            (
                audit: normalizedRect(x: 35, y: 48, width: 85, height: 34),
                baseline: normalizedRect(x: 95, y: 35, width: 30, height: 15)
            )
        case .trailing:
            (
                audit: normalizedRect(x: 560, y: 48, width: 80, height: 30),
                baseline: normalizedRect(x: 515, y: 35, width: 40, height: 15)
            )
        }
    }

    private static func normalizedRect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        CGRect(
            x: x / referenceSize.width,
            y: y / referenceSize.height,
            width: width / referenceSize.width,
            height: height / referenceSize.height
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * percentile).rounded(.down)))
        )
        return sorted[index]
    }

    private static func largestConnectedComponent(
        in mask: Set<PixelCoordinate>
    ) -> Int {
        var remaining = mask
        var largest = 0
        while let seed = remaining.first {
            var stack = [seed]
            remaining.remove(seed)
            var size = 0
            while let pixel = stack.popLast() {
                size += 1
                for neighbor in pixel.neighbors where remaining.remove(neighbor) != nil {
                    stack.append(neighbor)
                }
            }
            largest = max(largest, size)
        }
        return largest
    }
}

private struct PixelCoordinate: Hashable {
    let x: Int
    let y: Int

    var neighbors: [PixelCoordinate] {
        [
            PixelCoordinate(x: x - 1, y: y),
            PixelCoordinate(x: x + 1, y: y),
            PixelCoordinate(x: x, y: y - 1),
            PixelCoordinate(x: x, y: y + 1),
        ]
    }
}
