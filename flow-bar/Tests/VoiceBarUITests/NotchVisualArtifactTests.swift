import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchVisualArtifactTests: XCTestCase {
    final class SnapshotCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
    }

    func testWritesCommittedNotchShapeArtifactsForLightAndDarkMenuBars() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs")
            .appendingPathComponent("visual-qa")
            .appendingPathComponent("voicebar-notch-gen15")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let scenarios: [(name: String, isCollapsed: Bool, menuBarColor: Color, scheme: ColorScheme)] = [
            ("idle-light", true, Color(red: 0.92, green: 0.92, blue: 0.90), .light),
            ("hover-light", false, Color(red: 0.92, green: 0.92, blue: 0.90), .light),
            ("idle-dark", true, Color(red: 0.07, green: 0.07, blue: 0.075), .dark),
            ("hover-dark", false, Color(red: 0.07, green: 0.07, blue: 0.075), .dark),
        ]

        for scenario in scenarios {
            let state = VoiceState()
            state.mode = .idle
            state.isConnected = true
            state.hotkeyEnabled = true
            state.isCollapsed = scenario.isCollapsed
            state.setHovering(!scenario.isCollapsed)

            let view = NotchMenuBarArtifactView(
                state: state,
                menuBarColor: scenario.menuBarColor
            )
            .environment(\.colorScheme, scenario.scheme)
            .frame(width: 700, height: 150)

            try writePNG(
                view,
                size: CGSize(width: 700, height: 150),
                named: "\(scenario.name).png",
                in: outputDirectory
            )
        }
    }

    private func writePNG(
        _ view: some View,
        size: CGSize,
        named name: String,
        in directory: URL
    ) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not create bitmap for \(name)")
            return
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)

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

private struct NotchMenuBarArtifactView: View {
    let state: VoiceState
    let menuBarColor: Color

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                menuBarColor
                    .frame(height: 48)
                Color(red: 0.58, green: 0.62, blue: 0.68)
            }

            cameraIsland

            BarView(
                state: state,
                commandRouter: NotchVisualArtifactTests.SnapshotCommandRouter()
            )
            .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        }
    }

    private var layout: VoiceBarPanelLayout {
        VoiceBarPanelLayout.make(
            mode: state.mode,
            isCollapsed: state.isCollapsed,
            previewText: nil,
            statusText: VoiceBarPresentation.readyHotkeyHint,
            padding: Theme.panelPadding
        )
    }

    private var cameraIsland: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black)
            .frame(
                width: max(44, layout.panelSize.width - (Theme.notchSideRadius * 2)),
                height: 30
            )
            .offset(y: -8)
            .accessibilityHidden(true)
    }
}
