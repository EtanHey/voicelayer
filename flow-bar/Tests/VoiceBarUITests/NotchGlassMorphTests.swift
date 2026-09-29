import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Drive the production mask shape and material modifier at fixed progress values. Rendered frames may be skipped
/// on a busy CI runner, but the path at a given progress is deterministic.
final class NotchGlassMorphTests: XCTestCase {
    private struct MaskSample {
        let progress: CGFloat
        let bounds: CGRect
        let outerCornerRadius: CGFloat?
    }

    private static let progressValues: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]

    private static func presentation(
        recording: Bool = false, history: Bool = false, teleprompter: Bool = false, compactStatus: Bool = false
    ) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: teleprompter, isRecording: recording, hasCompactStatus: compactStatus,
            hasHistoryPanel: history, isHovered: !compactStatus, isKeyboardFocused: false
        )
    }

    func testMicTapGrowsTheGlassWithTheShape() throws {
        try assertGlassMorphs(from: Self.presentation(), to: Self.presentation(recording: true), "mic → recording")
    }

    func testCancelTapShrinksTheGlassWithTheShape() throws {
        try assertGlassMorphs(from: Self.presentation(recording: true), to: Self.presentation(), "X → launcher")
    }

    func testHistoryPanelGrowsTheGlassWithTheShape() throws {
        try assertGlassMorphs(from: Self.presentation(), to: Self.presentation(history: true), "History open")
    }

    func testTeleprompterGrowsTheGlassWithTheShape() throws {
        try assertGlassMorphs(
            from: Self.presentation(compactStatus: true), to: Self.presentation(teleprompter: true), "teleprompter"
        )
    }

    /// The History body and compact wings must carry the same rounded outer corner through the whole morph.
    /// A fixed 18 pt body radius, or a radius absent from animatableData, fails at interior progress values.
    func testTheOuterCornersStayRoundedWhileHistoryOpensAndCloses() throws {
        try assertCornersStayRounded(from: Self.presentation(), to: Self.presentation(history: true), "History open")
        try assertCornersStayRounded(from: Self.presentation(history: true), to: Self.presentation(), "History close")
    }

    private func maskSamples(
        from start: VoiceBarNotchPresentation,
        to destination: VoiceBarNotchPresentation
    ) -> [MaskSample] {
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: Self.presentation(history: true)).canvasGeometry
        let rect = CGRect(x: 0, y: 0, width: canvas.totalWidth, height: canvas.totalHeight)
        let startShape = VoiceBarNotchContinuousShape(
            geometry: start.geometry,
            compactOuterCornerRadius: VoiceBarNotchContract.material.compactOuterCornerRadius(for: start.visualState),
            coreAnchorX: canvas.coreOriginX
        )
        let destinationShape = VoiceBarNotchContinuousShape(
            geometry: destination.geometry,
            compactOuterCornerRadius: VoiceBarNotchContract.material
                .compactOuterCornerRadius(for: destination.visualState),
            coreAnchorX: canvas.coreOriginX
        )
        // VoiceBarNotchView uses this modifier; its animatableData forwards to the mask shape.
        var material = VoiceBarGlassMaterial(shape: startShape)
        let initial = material.animatableData
        let difference = destinationShape.animatableData - initial
        let samples = Self.progressValues.map { progress in
            var advance = difference
            advance.scale(by: Double(progress))
            material.animatableData = initial + advance
            let path = material.shape.path(in: rect).cgPath
            return MaskSample(
                progress: progress,
                bounds: path.boundingBoxOfPath,
                outerCornerRadius: Self.outerCornerRadius(in: path)
            )
        }
        // The modifier must reach the destination shape, not silently retain the launch mask.
        let actual = samples[4].bounds
        let expected = destinationShape.path(in: rect).cgPath.boundingBoxOfPath
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 0.01)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
        return samples
    }

    private func assertGlassMorphs(
        from start: VoiceBarNotchPresentation,
        to destination: VoiceBarNotchPresentation,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let samples = maskSamples(from: start, to: destination)
        let first = samples[0].bounds
        let last = samples[4].bounds
        // A travelling edge must move on the first quarter-step without arriving at the destination. The
        // teleprompter's shoulders can briefly extend past their endpoint as its lower body appears, so bounding
        // every intermediate edge between the endpoints would reject the real shape.
        let edges: [(String, (CGRect) -> CGFloat)] = [
            ("leading", { $0.minX }),
            ("trailing", { $0.maxX }),
            ("bottom", { $0.height }),
        ]
        XCTAssertTrue(edges.contains { abs($0.1(last) - $0.1(first)) >= 4 },
                      "\(label): the glass mask never reached a different size", file: file, line: line)
        for (edge, value) in edges {
            let from = value(first)
            let to = value(last)
            guard abs(to - from) >= 4 else { continue }
            let firstQuarter = (value(samples[1].bounds) - from) / (to - from)
            XCTAssertGreaterThan(abs(firstQuarter), 0.05, "\(label): \(edge) did not start moving",
                                 file: file, line: line)
            XCTAssertGreaterThan(abs(1 - firstQuarter), 0.05, "\(label): \(edge) snapped to its end",
                                 file: file, line: line)
        }
    }

    private func assertCornersStayRounded(
        from start: VoiceBarNotchPresentation,
        to destination: VoiceBarNotchPresentation,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let samples = maskSamples(from: start, to: destination)
        let from = VoiceBarNotchContract.material.compactOuterCornerRadius(for: start.visualState)
        let to = VoiceBarNotchContract.material.compactOuterCornerRadius(for: destination.visualState)
        for sample in samples {
            let radius = try XCTUnwrap(sample.outerCornerRadius,
                                       "\(label): no rounded outer corner at progress \(sample.progress)",
                                       file: file, line: line)
            let expected = from + (to - from) * sample.progress
            XCTAssertEqual(radius, expected, accuracy: 0.05,
                           "\(label): outer corner snapped at progress \(sample.progress)", file: file, line: line)
            XCTAssertGreaterThan(radius, 0, "\(label): corner lost rounding", file: file, line: line)
        }
    }

    /// The smallest outer quad-curve radius, independent of path orientation and the hardware-core cut-out.
    private static func outerCornerRadius(in path: CGPath) -> CGFloat? {
        let box = path.boundingBoxOfPath
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
        ]
        var radii: [CGFloat] = []
        path.applyWithBlock { element in
            guard element.pointee.type == .addQuadCurveToPoint else { return }
            let control = element.pointee.points[0]
            let end = element.pointee.points[1]
            guard corners.contains(where: { abs($0.x - control.x) < 0.01 && abs($0.y - control.y) < 0.01 })
            else { return }
            radii.append(max(abs(end.x - control.x), abs(end.y - control.y)))
        }
        return radii.min()
    }
}
