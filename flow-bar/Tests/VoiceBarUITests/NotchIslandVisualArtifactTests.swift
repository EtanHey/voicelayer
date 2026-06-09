import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchIslandVisualArtifactTests: XCTestCase {
    final class ArtifactCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
    }

    func testWritesNotchIslandReviewArtifacts() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("artifacts")
            .appendingPathComponent("notch-island")
            .appendingPathComponent("rendered")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        try writeArtifact(colorScheme: .light, name: "notch-island-render-light.png", in: outputDirectory)
        try writeArtifact(colorScheme: .dark, name: "notch-island-render-dark.png", in: outputDirectory)
    }

    private func writeArtifact(
        colorScheme: ColorScheme,
        name: String,
        in directory: URL
    ) throws {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false

        let view = NotchIslandReviewArtifactView(
            state: state,
            commandRouter: ArtifactCommandRouter(),
            colorScheme: colorScheme
        )
        .frame(width: 900, height: 220)
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(CGSize(width: 900, height: 220))
        renderer.scale = 2

        guard let cgImage = renderer.cgImage else {
            XCTFail("ImageRenderer did not produce a CGImage for \(name)")
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode PNG for \(name)")
            return
        }

        let outputURL = directory.appendingPathComponent(name)
        try data.write(to: outputURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0, 0)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct NotchIslandReviewArtifactView: View {
    var state: VoiceState
    var commandRouter: BarCommandRouting
    var colorScheme: ColorScheme

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(hex: 0x14171C), Color(hex: 0x2B3038)]
                    : [Color(hex: 0xEDF1F6), Color(hex: 0xCDD5DF)],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(colorScheme == .dark ? Color.black.opacity(0.78) : Color.white.opacity(0.62))
                .frame(height: 54)

            RoundedRectangle(cornerRadius: 0)
                .fill(Color.black)
                .frame(width: NotchIslandGeometry.notchWidth, height: NotchIslandGeometry.notchDepth)
                .clipShape(.rect(cornerRadius: 16))
                .offset(y: -1)

            VoiceBarRootView(
                state: state,
                commandRouter: commandRouter,
                usesNotchIsland: true
            )
            .offset(y: 0)
        }
    }
}
