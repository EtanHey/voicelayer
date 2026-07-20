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

    fileprivate func maximumEdgeGradient(in rect: CGRect) -> Double? {
        let xRange = pixelRange(origin: rect.minX, extent: rect.width, limit: width)
        let yRange = pixelRange(origin: rect.minY, extent: rect.height, limit: height)
        guard xRange.count >= 2, yRange.count >= 2 else { return nil }
        var maximum = 0.0
        for y in yRange {
            for x in xRange {
                let value = brightness[y * width + x]
                if x + 1 < xRange.upperBound {
                    maximum = max(maximum, abs(value - brightness[y * width + x + 1]))
                }
                if y + 1 < yRange.upperBound {
                    maximum = max(maximum, abs(value - brightness[(y + 1) * width + x]))
                }
            }
        }
        return maximum
    }

    private func pixelRange(origin: CGFloat, extent: CGFloat, limit: Int) -> Range<Int> {
        let lower = max(0, min(limit, Int((origin * CGFloat(limit)).rounded(.down))))
        let upper = max(lower, min(limit, Int(((origin + extent) * CGFloat(limit)).rounded(.up))))
        return lower ..< upper
    }
}

public struct VoiceBarRGBImage: Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [VoiceBarRGB]

    public init(width: Int, height: Int, pixels: [VoiceBarRGB]) {
        precondition(width > 0 && height > 0)
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
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

public struct VoiceBarNotchEdgeSharpnessAuditResult: Equatable {
    public let wingContentMaxGradient: Double
    public let referenceGlyphMaxGradient: Double
    public let referenceToWingRatio: Double
    public let maximumAllowedRatio: Double
    public let passed: Bool
}

public struct VoiceBarNotchGlyphContrastParityAuditResult: Equatable {
    public let wingContrastRatio: Double
    public let referenceContrastRatio: Double
    public let passed: Bool
}

public struct VoiceBarNotchCompactPaddingAuditResult: Equatable {
    public let spinnerLeadingPadding: Double
    public let waveformLeadingPadding: Double
    public let paddingDelta: Double
    public let passed: Bool
}

public struct VoiceBarNotchWaveformCensusAuditResult: Equatable {
    public let recordingFrameCount: Int
    public let transcribingFrameCount: Int
    public let speakingFrameCount: Int
    public let minimumRecordingBarCount: Int
    public let minimumTranscribingBarCount: Int
    public let minimumSpeakingBarCount: Int
    public let transcribingCompleteFraction: Double
    public let recordingToSpeakingPeakRatio: Double
    public let recordingMaximumCenterDeviation: Double
    public let transcribingMaximumCenterDeviation: Double
    public let transcribingMaximumBottomSpread: Double
    public let maximumSlotOffsetDelta: Double
    public let passed: Bool
}

public struct VoiceBarNotchTeleprompterDismissalFrameSample: Equatable {
    public let textOpacity: Double
    public let materialOpacity: Double?
    public let interiorBrightness: [Double]

    public init(
        textOpacity: Double,
        materialOpacity: Double? = nil,
        interiorBrightness: [Double]
    ) {
        self.textOpacity = textOpacity
        self.materialOpacity = materialOpacity
        self.interiorBrightness = interiorBrightness
    }
}

public struct VoiceBarNotchTeleprompterDismissalAuditResult: Equatable {
    public let frameCount: Int
    public let violatingFrameIndices: [Int]
    public let maximumOpaqueTextInteriorStandardDeviation: Double
    public let passed: Bool
}

public struct VoiceBarNotchTeleprompterReadabilitySample: Equatable {
    public let interiorBrightness: [Double]
    public let textForegroundPixels: [VoiceBarRGB]
    public let textBackgroundPixels: [VoiceBarRGB]

    public init(
        interiorBrightness: [Double],
        textForegroundPixels: [VoiceBarRGB],
        textBackgroundPixels: [VoiceBarRGB]
    ) {
        self.interiorBrightness = interiorBrightness
        self.textForegroundPixels = textForegroundPixels
        self.textBackgroundPixels = textBackgroundPixels
    }
}

public struct VoiceBarNotchWingReadabilitySample: Equatable {
    public let wingForegroundPixels: [VoiceBarRGB]
    public let wingBackgroundPixels: [VoiceBarRGB]
    public let referenceForegroundPixels: [VoiceBarRGB]
    public let referenceBackgroundPixels: [VoiceBarRGB]

    public init(
        wingForegroundPixels: [VoiceBarRGB],
        wingBackgroundPixels: [VoiceBarRGB],
        referenceForegroundPixels: [VoiceBarRGB],
        referenceBackgroundPixels: [VoiceBarRGB]
    ) {
        self.wingForegroundPixels = wingForegroundPixels
        self.wingBackgroundPixels = wingBackgroundPixels
        self.referenceForegroundPixels = referenceForegroundPixels
        self.referenceBackgroundPixels = referenceBackgroundPixels
    }
}

public struct VoiceBarNotchTeleprompterReadabilityMetric: Equatable {
    public let interiorPixelCount: Int
    public let textPixelCount: Int
    public let interiorStandardDeviation: Double
    public let textContrastRatio: Double
    public let passed: Bool
}

public struct VoiceBarNotchWingReadabilityMetric: Equatable {
    public let wingPixelCount: Int
    public let nativeReferencePixelCount: Int
    public let wingContrastRatio: Double
    public let nativeReferenceContrastRatio: Double
    public let passed: Bool
}

public struct VoiceBarNotchGlassReadabilityAuditResult: Equatable {
    public let teleprompterMetrics: [VoiceBarNotchTeleprompterReadabilityMetric]
    public let blackWingMetrics: [VoiceBarNotchWingReadabilityMetric]
    public let brightWingMetrics: [VoiceBarNotchWingReadabilityMetric]
    public let maximumInteriorStandardDeviation: Double
    public let minimumTextContrastRatio: Double
    public let minimumWingContrastRatio: Double
    public let minimumNativeReferenceContrastRatio: Double
    public let passed: Bool

    public var teleprompterFrameCount: Int {
        teleprompterMetrics.count
    }

    public var blackWingFrameCount: Int {
        blackWingMetrics.count
    }

    public var brightWingFrameCount: Int {
        brightWingMetrics.count
    }
}

public enum VoiceBarNotchCaptureAudit {
    public static let referenceSize = CGSize(width: 800, height: 100)
    public static let birthmarkBrightnessOffset = 18.0
    public static let maximumSettledBirthmarkContrast = 10.0
    public static let maximumBirthmarkBrightness = 130.0
    public static let maximumBirthmarkBlobPixels = 150
    public static let idleVisibilityThreshold = 90.0
    public static let minimumIdleHoldFrames = 180
    public static let maximumReferenceToWingSharpnessRatio = 2.0
    public static let minimumReferenceGlyphGradient = 80.0
    public static let waveformBarCount = 7
    public static let minimumTranscribingCompleteFraction = 0.95
    public static let minimumRecordingToSpeakingPeakRatio = 0.8
    public static let maximumWaveformCenterDeviation = 2.0
    public static let maximumWaveformSlotOffsetDelta = 2.0
    public static let maximumCompactPaddingDelta = 2.0
    public static let maximumTeleprompterInteriorStandardDeviation = 10.0
    public static let minimumOpaqueTeleprompterTextOpacity = 0.9
    public static let minimumVisibleTeleprompterTextOpacity = 0.5
    public static let maximumDismissedTeleprompterMaterialOpacity = 0.25
    public static let maximumGlassInteriorStandardDeviation = 10.0
    public static let minimumGlassSettledFrameCount = 3
    public static let minimumGlassInteriorPixelCount = 1000
    public static let minimumGlassForegroundPixelCount = 8

    public static func birthmark(
        in image: VoiceBarLumaImage,
        side: VoiceBarNotchSide
    ) -> VoiceBarNotchBirthmarkAuditResult {
        let regions = birthmarkRegions(for: side)
        let baselinePixels = image.values(in: regions.baseline).map(\.brightness)
        let fillBaseline = mean(baselinePixels)
        let auditPixels = image.values(in: regions.audit)
        let dimArtifactMask = Set(auditPixels.compactMap { pixel -> PixelCoordinate? in
            guard pixel.brightness > fillBaseline + birthmarkBrightnessOffset,
                  pixel.brightness < maximumBirthmarkBrightness
            else { return nil }
            return PixelCoordinate(x: pixel.x, y: pixel.y)
        })
        // The broad audit band intentionally excludes the bright symbol/menu-bar
        // range. Re-check its fully in-wing interior without that ceiling so an
        // abnormally bright compositing patch cannot disappear from the gate.
        let brightInteriorPixels = image.values(in: regions.brightInterior)
        let brightArtifactMask = Set(brightInteriorPixels.compactMap { pixel -> PixelCoordinate? in
            guard pixel.brightness > fillBaseline + birthmarkBrightnessOffset
            else { return nil }
            return PixelCoordinate(x: pixel.x, y: pixel.y)
        })
        let dimWingPixels = auditPixels
            .map(\.brightness)
            .filter { $0 < maximumBirthmarkBrightness }
        let scale = (Double(image.width) / referenceSize.width) *
            (Double(image.height) / referenceSize.height)
        let blobPixelLimit = max(1, Int((Double(maximumBirthmarkBlobPixels) * scale).rounded(.up)))
        let brightBlobPixels = largestConnectedComponent(in: brightArtifactMask)
        let largestBlobPixels = max(
            largestConnectedComponent(in: dimArtifactMask),
            brightBlobPixels
        )
        let dimSettledContrast = max(
            0,
            percentile(dimWingPixels, percentile: 0.95) - fillBaseline
        )
        let brightSettledContrast = brightBlobPixels > blobPixelLimit
            ? max(0, percentile(brightInteriorPixels.map(\.brightness), percentile: 0.95) - fillBaseline)
            : 0
        let settledContrast = max(dimSettledContrast, brightSettledContrast)
        let passed = passesBirthmarkGate(
            baselinePixelCount: baselinePixels.count,
            auditPixelCount: auditPixels.count,
            brightInteriorPixelCount: brightInteriorPixels.count,
            largestBlobPixels: largestBlobPixels,
            blobPixelLimit: blobPixelLimit,
            settledContrast: settledContrast
        )

        return VoiceBarNotchBirthmarkAuditResult(
            side: side,
            fillBaseline: fillBaseline,
            largestBlobPixels: largestBlobPixels,
            blobPixelLimit: blobPixelLimit,
            settledContrast: settledContrast,
            passed: passed
        )
    }

    static func passesBirthmarkGate(
        baselinePixelCount: Int,
        auditPixelCount: Int,
        brightInteriorPixelCount: Int,
        largestBlobPixels: Int,
        blobPixelLimit: Int,
        settledContrast: Double
    ) -> Bool {
        baselinePixelCount > 0 &&
            auditPixelCount > 0 &&
            brightInteriorPixelCount > 0 &&
            largestBlobPixels <= blobPixelLimit &&
            settledContrast < maximumSettledBirthmarkContrast
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

    public static func teleprompterDismissal(
        frameSamples: [VoiceBarNotchTeleprompterDismissalFrameSample]
    ) -> VoiceBarNotchTeleprompterDismissalAuditResult {
        let visibleTextObservations = frameSamples.enumerated().compactMap {
            index, sample -> (index: Int, interiorStandardDeviation: Double)? in
            let minimumTextOpacity = sample.materialOpacity == nil
                ? minimumOpaqueTeleprompterTextOpacity
                : minimumVisibleTeleprompterTextOpacity
            guard sample.textOpacity >= minimumTextOpacity else {
                return nil
            }
            return (
                index: index,
                interiorStandardDeviation: sample.interiorBrightness.isEmpty
                    ? .infinity
                    : standardDeviation(sample.interiorBrightness)
            )
        }
        let violatingFrameIndices = visibleTextObservations.compactMap { observation in
            let sample = frameSamples[observation.index]
            let materialIsGone = sample.materialOpacity.map {
                $0 <= maximumDismissedTeleprompterMaterialOpacity
            }
            let appShowsThrough = materialIsGone == true ||
                observation.interiorStandardDeviation > maximumTeleprompterInteriorStandardDeviation
            return appShowsThrough ? observation.index : nil
        }
        return VoiceBarNotchTeleprompterDismissalAuditResult(
            frameCount: frameSamples.count,
            violatingFrameIndices: violatingFrameIndices,
            maximumOpaqueTextInteriorStandardDeviation: visibleTextObservations
                .map(\.interiorStandardDeviation)
                .max() ?? 0,
            passed: !frameSamples.isEmpty && violatingFrameIndices.isEmpty
        )
    }

    public static func glassTeleprompterFrame(
        _ sample: VoiceBarNotchTeleprompterReadabilitySample
    ) -> VoiceBarNotchTeleprompterReadabilityMetric {
        let interiorStandardDeviation = sample.interiorBrightness.isEmpty
            ? .infinity
            : standardDeviation(sample.interiorBrightness)
        let textContrastRatio = strongestCoreContrast(
            foregroundPixels: sample.textForegroundPixels,
            backgroundPixels: sample.textBackgroundPixels
        )
        return VoiceBarNotchTeleprompterReadabilityMetric(
            interiorPixelCount: sample.interiorBrightness.count,
            textPixelCount: sample.textForegroundPixels.count,
            interiorStandardDeviation: interiorStandardDeviation,
            textContrastRatio: textContrastRatio,
            passed: sample.interiorBrightness.count >= minimumGlassInteriorPixelCount &&
                sample.textForegroundPixels.count >= minimumGlassForegroundPixelCount &&
                !sample.textBackgroundPixels.isEmpty &&
                interiorStandardDeviation <= maximumGlassInteriorStandardDeviation &&
                textContrastRatio >= VoiceBarContrast.minimumTextRatio
        )
    }

    public static func glassWingFrame(
        _ sample: VoiceBarNotchWingReadabilitySample
    ) -> VoiceBarNotchWingReadabilityMetric {
        let wingContrastRatio = strongestCoreContrast(
            foregroundPixels: sample.wingForegroundPixels,
            backgroundPixels: sample.wingBackgroundPixels
        )
        let nativeReferenceContrastRatio = strongestCoreContrast(
            foregroundPixels: sample.referenceForegroundPixels,
            backgroundPixels: sample.referenceBackgroundPixels
        )
        return VoiceBarNotchWingReadabilityMetric(
            wingPixelCount: sample.wingForegroundPixels.count,
            nativeReferencePixelCount: sample.referenceForegroundPixels.count,
            wingContrastRatio: wingContrastRatio,
            nativeReferenceContrastRatio: nativeReferenceContrastRatio,
            passed: sample.wingForegroundPixels.count >= minimumGlassForegroundPixelCount &&
                !sample.wingBackgroundPixels.isEmpty &&
                sample.referenceForegroundPixels.count >= minimumGlassForegroundPixelCount &&
                !sample.referenceBackgroundPixels.isEmpty &&
                wingContrastRatio >= VoiceBarContrast.minimumControlRatio &&
                wingContrastRatio >= nativeReferenceContrastRatio
        )
    }

    public static func glassReadability(
        teleprompterFrames: [VoiceBarNotchTeleprompterReadabilitySample],
        blackWingFrames: [VoiceBarNotchWingReadabilitySample],
        brightWingFrames: [VoiceBarNotchWingReadabilitySample]
    ) -> VoiceBarNotchGlassReadabilityAuditResult {
        let teleprompterMetrics = teleprompterFrames.map(glassTeleprompterFrame)
        let blackWingMetrics = blackWingFrames.map(glassWingFrame)
        let brightWingMetrics = brightWingFrames.map(glassWingFrame)
        let wingMetrics = blackWingMetrics + brightWingMetrics
        let enoughFrames = teleprompterMetrics.count >= minimumGlassSettledFrameCount &&
            blackWingMetrics.count >= minimumGlassSettledFrameCount &&
            brightWingMetrics.count >= minimumGlassSettledFrameCount
        return VoiceBarNotchGlassReadabilityAuditResult(
            teleprompterMetrics: teleprompterMetrics,
            blackWingMetrics: blackWingMetrics,
            brightWingMetrics: brightWingMetrics,
            maximumInteriorStandardDeviation: teleprompterMetrics
                .map(\.interiorStandardDeviation)
                .max() ?? .infinity,
            minimumTextContrastRatio: teleprompterMetrics
                .map(\.textContrastRatio)
                .min() ?? 0,
            minimumWingContrastRatio: wingMetrics
                .map(\.wingContrastRatio)
                .min() ?? 0,
            minimumNativeReferenceContrastRatio: wingMetrics
                .map(\.nativeReferenceContrastRatio)
                .min() ?? 0,
            passed: enoughFrames &&
                teleprompterMetrics.allSatisfy(\.passed) &&
                blackWingMetrics.allSatisfy(\.passed) &&
                brightWingMetrics.allSatisfy(\.passed)
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

    public static func edgeSharpness(
        in image: VoiceBarLumaImage,
        wingContentRect: CGRect,
        referenceGlyphRect: CGRect
    ) -> VoiceBarNotchEdgeSharpnessAuditResult {
        let wingGradient = image.maximumEdgeGradient(in: wingContentRect) ?? 0
        let referenceGradient = image.maximumEdgeGradient(in: referenceGlyphRect) ?? 0
        let ratio = wingGradient > 0 ? referenceGradient / wingGradient : .infinity
        return VoiceBarNotchEdgeSharpnessAuditResult(
            wingContentMaxGradient: wingGradient,
            referenceGlyphMaxGradient: referenceGradient,
            referenceToWingRatio: ratio,
            maximumAllowedRatio: maximumReferenceToWingSharpnessRatio,
            passed: wingGradient > 0 &&
                referenceGradient >= minimumReferenceGlyphGradient &&
                ratio <= maximumReferenceToWingSharpnessRatio
        )
    }

    public static func glyphContrastParity(
        wingForegroundPixels: [VoiceBarRGB],
        wingBackgroundPixels: [VoiceBarRGB],
        referenceForegroundPixels: [VoiceBarRGB],
        referenceBackgroundPixels: [VoiceBarRGB]
    ) -> VoiceBarNotchGlyphContrastParityAuditResult {
        let wingBackground = medianColor(wingBackgroundPixels)
        let referenceBackground = medianColor(referenceBackgroundPixels)
        let wingRatio = median(
            wingForegroundPixels.map {
                VoiceBarContrast.ratio(foreground: $0, background: wingBackground)
            }
        )
        let referenceRatio = median(
            referenceForegroundPixels.map {
                VoiceBarContrast.ratio(foreground: $0, background: referenceBackground)
            }
        )
        return VoiceBarNotchGlyphContrastParityAuditResult(
            wingContrastRatio: wingRatio,
            referenceContrastRatio: referenceRatio,
            passed: !wingForegroundPixels.isEmpty &&
                !wingBackgroundPixels.isEmpty &&
                !referenceForegroundPixels.isEmpty &&
                !referenceBackgroundPixels.isEmpty &&
                wingRatio >= referenceRatio
        )
    }

    public static func compactPadding(
        in image: VoiceBarRGBImage,
        leadingWingRect: CGRect,
        trailingWingRect: CGRect,
        backingScale: Double
    ) -> VoiceBarNotchCompactPaddingAuditResult {
        let leadingBounds = blueForegroundBounds(in: image, rect: leadingWingRect)
        let trailingBounds = blueForegroundBounds(in: image, rect: trailingWingRect)
        let leadingPixelRect = pixelRect(
            normalized: leadingWingRect,
            width: image.width,
            height: image.height
        )
        let trailingPixelRect = pixelRect(
            normalized: trailingWingRect,
            width: image.width,
            height: image.height
        )
        let scale = backingScale > 0 ? backingScale : 1
        let spinnerPadding = leadingBounds.map {
            Double($0.minX - leadingPixelRect.minX) / scale
        } ?? .infinity
        let waveformPadding = trailingBounds.map {
            Double($0.minX - trailingPixelRect.minX) / scale
        } ?? .infinity
        let delta = abs(spinnerPadding - waveformPadding)
        return VoiceBarNotchCompactPaddingAuditResult(
            spinnerLeadingPadding: spinnerPadding,
            waveformLeadingPadding: waveformPadding,
            paddingDelta: delta,
            passed: spinnerPadding.isFinite &&
                waveformPadding.isFinite &&
                delta <= maximumCompactPaddingDelta
        )
    }

    public static func waveformCensus(
        recordingFrames: [VoiceBarRGBImage],
        transcribingFrames: [VoiceBarRGBImage],
        speakingFrames: [VoiceBarRGBImage]
    ) -> VoiceBarNotchWaveformCensusAuditResult {
        let recording = recordingFrames.map { waveformBars(in: $0, color: .red) }
        let transcribing = transcribingFrames.map { waveformBars(in: $0, color: .blue) }
        let speaking = speakingFrames.map { waveformBars(in: $0, color: .blue) }
        let recordingMinimum = recording.map(\.count).min() ?? 0
        let transcribingMinimum = transcribing.map(\.count).min() ?? 0
        let speakingMinimum = speaking.map(\.count).min() ?? 0
        let transcribingCompleteFraction = transcribing.isEmpty
            ? 0
            : Double(transcribing.filter { $0.count == waveformBarCount }.count) /
            Double(transcribing.count)
        let recordingPeak = recording.flatMap { $0 }.map(\.height).max() ?? 0
        let speakingPeak = speaking.flatMap { $0 }.map(\.height).max() ?? 0
        let peakRatio = speakingPeak > 0 ? recordingPeak / speakingPeak : 0
        let recordingCenterDeviation = zip(recordingFrames, recording)
            .flatMap { image, bars in
                let center = Double(image.height - 1) / 2
                return bars.map { abs($0.centerY - center) }
            }
            .max() ?? .infinity
        let transcribingCenterDeviation = zip(transcribingFrames, transcribing)
            .flatMap { image, bars in
                let center = Double(image.height - 1) / 2
                return bars.map { abs($0.centerY - center) }
            }
            .max() ?? .infinity
        let transcribingBottomSpread = transcribing
            .filter { $0.count == waveformBarCount }
            .map { bars in
                (bars.map(\.maxY).max() ?? 0) - (bars.map(\.maxY).min() ?? 0)
            }
            .max() ?? 0
        let slotOffsetDelta = maximumSlotOffsetDelta(
            observations: recording + transcribing + speaking
        )
        let passed = !recordingFrames.isEmpty &&
            !transcribingFrames.isEmpty &&
            !speakingFrames.isEmpty &&
            recordingMinimum == waveformBarCount &&
            transcribingCompleteFraction >= minimumTranscribingCompleteFraction &&
            speakingMinimum == waveformBarCount &&
            peakRatio >= minimumRecordingToSpeakingPeakRatio &&
            recordingCenterDeviation <= maximumWaveformCenterDeviation &&
            transcribingCenterDeviation <= maximumWaveformCenterDeviation &&
            transcribingBottomSpread >= maximumWaveformCenterDeviation &&
            slotOffsetDelta <= maximumWaveformSlotOffsetDelta

        return VoiceBarNotchWaveformCensusAuditResult(
            recordingFrameCount: recordingFrames.count,
            transcribingFrameCount: transcribingFrames.count,
            speakingFrameCount: speakingFrames.count,
            minimumRecordingBarCount: recordingMinimum,
            minimumTranscribingBarCount: transcribingMinimum,
            minimumSpeakingBarCount: speakingMinimum,
            transcribingCompleteFraction: transcribingCompleteFraction,
            recordingToSpeakingPeakRatio: peakRatio,
            recordingMaximumCenterDeviation: recordingCenterDeviation,
            transcribingMaximumCenterDeviation: transcribingCenterDeviation,
            transcribingMaximumBottomSpread: transcribingBottomSpread,
            maximumSlotOffsetDelta: slotOffsetDelta,
            passed: passed
        )
    }

    private static func birthmarkRegions(
        for side: VoiceBarNotchSide
    ) -> (audit: CGRect, baseline: CGRect, brightInterior: CGRect) {
        switch side {
        case .leading:
            (
                audit: normalizedRect(x: 35, y: 48, width: 85, height: 34),
                baseline: normalizedRect(x: 95, y: 35, width: 30, height: 15),
                brightInterior: normalizedRect(x: 50, y: 48, width: 60, height: 14)
            )
        case .trailing:
            (
                audit: normalizedRect(x: 560, y: 48, width: 80, height: 30),
                baseline: normalizedRect(x: 515, y: 35, width: 40, height: 15),
                brightInterior: normalizedRect(x: 570, y: 48, width: 50, height: 14)
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

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { total, value in
            let distance = value - average
            return total + distance * distance
        } / Double(values.count)
        return variance.squareRoot()
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func medianColor(_ values: [VoiceBarRGB]) -> VoiceBarRGB {
        VoiceBarRGB(
            red: median(values.map(\.red)),
            green: median(values.map(\.green)),
            blue: median(values.map(\.blue))
        )
    }

    private static func strongestCoreContrast(
        foregroundPixels: [VoiceBarRGB],
        backgroundPixels: [VoiceBarRGB]
    ) -> Double {
        guard foregroundPixels.count >= minimumGlassForegroundPixelCount,
              !backgroundPixels.isEmpty
        else { return 0 }
        let background = medianColor(backgroundPixels)
        let ratios = foregroundPixels.map {
            VoiceBarContrast.ratio(foreground: $0, background: background)
        }.sorted(by: >)
        let sampleCount = min(
            ratios.count,
            max(
                minimumGlassForegroundPixelCount,
                Int(ceil(Double(ratios.count) * 0.08))
            )
        )
        return median(Array(ratios.prefix(sampleCount)))
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

    private enum WaveformPixelColor {
        case red
        case blue
    }

    private struct WaveformBarObservation {
        let centerX: Double
        let centerY: Double
        let height: Double
        let maxY: Double
    }

    private static func waveformBars(
        in image: VoiceBarRGBImage,
        color: WaveformPixelColor
    ) -> [WaveformBarObservation] {
        let mask = (0 ..< image.width).map { x in
            (0 ..< image.height).contains { y in
                waveformPixelMatches(image.pixels[y * image.width + x], color: color)
            }
        }
        var groups: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0 ... image.width {
            let occupied = x < image.width ? mask[x] : false
            if occupied, start == nil {
                start = x
            } else if !occupied, let groupStart = start {
                groups.append(groupStart ... max(groupStart, x - 1))
                start = nil
            }
        }

        return groups.compactMap { group in
            var matchingRows: [Int] = []
            for y in 0 ..< image.height where group.contains(where: { x in
                waveformPixelMatches(image.pixels[y * image.width + x], color: color)
            }) {
                matchingRows.append(y)
            }
            guard let minY = matchingRows.min(), let maxY = matchingRows.max() else { return nil }
            return WaveformBarObservation(
                centerX: Double(group.lowerBound + group.upperBound) / 2,
                centerY: Double(minY + maxY) / 2,
                height: Double(maxY - minY + 1),
                maxY: Double(maxY)
            )
        }
    }

    private static func waveformPixelMatches(
        _ pixel: VoiceBarRGB,
        color: WaveformPixelColor
    ) -> Bool {
        switch color {
        case .red:
            pixel.red > 0.50 && pixel.red - max(pixel.green, pixel.blue) >= 0.18
        case .blue:
            pixel.blue > 0.50 && pixel.blue - pixel.red >= 0.18 &&
                pixel.blue - pixel.green >= 0.08
        }
    }

    private static func blueForegroundBounds(
        in image: VoiceBarRGBImage,
        rect: CGRect
    ) -> CGRect? {
        let bounds = pixelRect(
            normalized: rect,
            width: image.width,
            height: image.height
        )
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        for y in Int(bounds.minY) ..< Int(bounds.maxY) {
            for x in Int(bounds.minX) ..< Int(bounds.maxX)
                where waveformPixelMatches(
                    image.pixels[y * image.width + x],
                    color: .blue
                ) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private static func pixelRect(
        normalized rect: CGRect,
        width: Int,
        height: Int
    ) -> CGRect {
        let minX = max(0, min(width, Int((rect.minX * CGFloat(width)).rounded(.down))))
        let maxX = max(minX, min(width, Int((rect.maxX * CGFloat(width)).rounded(.up))))
        let minY = max(0, min(height, Int((rect.minY * CGFloat(height)).rounded(.down))))
        let maxY = max(minY, min(height, Int((rect.maxY * CGFloat(height)).rounded(.up))))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func maximumSlotOffsetDelta(
        observations: [[WaveformBarObservation]]
    ) -> Double {
        let complete = observations.filter { $0.count == waveformBarCount }
        guard let reference = complete.first else { return .infinity }
        let referenceCenter = reference.map(\.centerX).reduce(0, +) / Double(reference.count)
        let referenceOffsets = reference.map { $0.centerX - referenceCenter }
        return complete.dropFirst().reduce(0) { maximum, bars in
            let center = bars.map(\.centerX).reduce(0, +) / Double(bars.count)
            let offsets = bars.map { $0.centerX - center }
            return max(
                maximum,
                zip(referenceOffsets, offsets).map { abs($0 - $1) }.max() ?? .infinity
            )
        }
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
