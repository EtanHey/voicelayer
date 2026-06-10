import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Renders the v9 silhouette + material preview (NotchShape / FunnelPanelShape) to real
/// Swift-rendered PNGs for the qa-video gate. ImageRenderer renders the geometry and the
/// black→glass gradient faithfully; the `.ultraThinMaterial` blur is approximated by the
/// offline renderer (true Liquid Glass needs an on-screen window) — captured separately by
/// the dev-instance window screenshot. This artifact proves the TESTED geometry renders.
@MainActor
final class NotchV9ArtifactTests: XCTestCase {
    func testWritesV9PreviewSurfaceArtifact() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("v9-build-qa")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let surface = NotchV9PreviewSurface()
        let renderer = ImageRenderer(content: surface)
        renderer.proposedSize = ProposedViewSize(width: 460, height: 470)
        renderer.scale = 2

        let cgImage = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no CGImage")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "PNG encode failed")

        let outputURL = outputDirectory.appendingPathComponent("v9-swift-render-states.png")
        try data.write(to: outputURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000, "artifact should be a non-trivial PNG")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
