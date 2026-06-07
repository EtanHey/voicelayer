import AppKit
import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class V3MockRenderArtifactTests: XCTestCase {
    func testRenderV3MockBundleArtifacts() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent(".verified")
            .appendingPathComponent("voicebar-v3-mocks")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        try render(
            V3MockGallery(),
            proposedSize: CGSize(width: 560, height: 900),
            to: outputDirectory.appendingPathComponent("v3-r3-mocks-contact-sheet.png")
        )

        let screen = try XCTUnwrap(builtInScreen(), "No built-in NSScreen available for v3 mock render")
        let geometry = V3CaptureGeometry(screen: screen)

        try render(
            V3FullScreenMockComposite(
                screenSize: geometry.screenSize,
                mock: AnyView(V3MockIdleIsland(width: geometry.closedNotchWidth, height: geometry.stripHeight)),
                mockSize: CGSize(width: geometry.closedNotchWidth, height: geometry.stripHeight),
                notchOutline: geometry.notchRect
            ),
            proposedSize: geometry.screenSize,
            to: outputDirectory.appendingPathComponent("v3-r3-mocks-builtin-idle-fullscreen-notchoutline.png")
        )

        let recordingWidth = geometry.closedNotchWidth * V3Theme.recordingWidthRatio
        try render(
            V3FullScreenMockComposite(
                screenSize: geometry.screenSize,
                mock: AnyView(V3MockRecordingIsland(
                    notchWidth: geometry.closedNotchWidth,
                    height: geometry.stripHeight
                )),
                mockSize: CGSize(width: recordingWidth, height: geometry.stripHeight),
                notchOutline: geometry.notchRect
            ),
            proposedSize: geometry.screenSize,
            to: outputDirectory.appendingPathComponent("v3-r3-mocks-builtin-recording-fullscreen-notchoutline.png")
        )

        try render(
            V3FullScreenMockComposite(
                screenSize: geometry.screenSize,
                mock: AnyView(V3MockTranscriptMenu(notchWidth: geometry.closedNotchWidth)),
                mockSize: CGSize(width: V3Theme.menuWidth, height: geometry.stripHeight + 252),
                notchOutline: geometry.notchRect
            ),
            proposedSize: geometry.screenSize,
            to: outputDirectory.appendingPathComponent("v3-r3-mocks-builtin-menu-fullscreen-notchoutline.png")
        )

        let attestation = """
        displayID=\(geometry.displayID)
        isBuiltIn=true
        screenFrame=\(NSStringFromRect(geometry.screenFrame))
        visibleFrame=\(NSStringFromRect(geometry.visibleFrame))
        safeAreaInsets.top=\(geometry.safeTop)
        auxiliaryTopLeftArea.width=\(geometry.auxLeftWidth)
        auxiliaryTopRightArea.width=\(geometry.auxRightWidth)
        closedNotchWidth=screen.width-auxLeft-auxRight+4=\(geometry.closedNotchWidth)
        stripHeight=safeAreaInsets.top=\(geometry.stripHeight)
        notchRect=\(NSStringFromRect(geometry.notchRect))
        idleIslandFrame=\(NSStringFromRect(geometry.frame(
            width: geometry.closedNotchWidth,
            height: geometry.stripHeight
        )))
        recordingIslandFrame=\(NSStringFromRect(geometry.frame(width: recordingWidth, height: geometry.stripHeight)))
        menuFrame=\(NSStringFromRect(geometry.frame(width: V3Theme.menuWidth, height: geometry.stripHeight + 252)))
        """
        try attestation.write(
            to: outputDirectory.appendingPathComponent("v3-r3-mocks-geometry-attestation.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func render(_ view: some View, proposedSize: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(proposedSize)
        renderer.scale = 2

        let cgImage = try XCTUnwrap(renderer.cgImage, "ImageRenderer did not produce \(url.lastPathComponent)")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:]),
            "Could not encode \(url.lastPathComponent)"
        )
        try data.write(to: url, options: .atomic)
        XCTAssertGreaterThan(data.count, 4096)
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let displayID = screen
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0 && screen.safeAreaInsets.top > 0
        }
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct V3CaptureGeometry {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let safeTop: CGFloat
    let auxLeftWidth: CGFloat
    let auxRightWidth: CGFloat
    let screenSize: CGSize
    let closedNotchWidth: CGFloat
    let stripHeight: CGFloat
    let notchRect: CGRect

    init(screen: NSScreen) {
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        safeTop = screen.safeAreaInsets.top
        auxLeftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        auxRightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        screenSize = screen.frame.size
        closedNotchWidth = V3Theme.closedNotchWidth(for: screen)
        stripHeight = V3Theme.stripHeight(for: screen)
        notchRect = CGRect(
            x: (screen.frame.width - V3Theme.closedNotchWidth(for: screen)) / 2,
            y: 0,
            width: V3Theme.closedNotchWidth(for: screen),
            height: V3Theme.stripHeight(for: screen)
        )
    }

    func frame(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: (screenSize.width - width) / 2, y: 0, width: width, height: height)
    }
}

private struct V3FullScreenMockComposite: View {
    let screenSize: CGSize
    let mock: AnyView
    let mockSize: CGSize
    let notchOutline: CGRect

    var body: some View {
        ZStack(alignment: .top) {
            V3DesktopBackdrop()
                .frame(width: screenSize.width, height: screenSize.height)

            mock
                .frame(width: mockSize.width, height: mockSize.height)
                .position(x: screenSize.width / 2, y: mockSize.height / 2)

            Path { path in
                path.addRect(notchOutline)
            }
            .stroke(Color.green, lineWidth: 1)
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }
}

private struct V3DesktopBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.91, blue: 0.95),
                    Color(red: 0.35, green: 0.30, blue: 0.58),
                    Color(red: 0.13, green: 0.12, blue: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 38)
                .overlay(alignment: .leading) {
                    HStack(spacing: 18) {
                        Image(systemName: "apple.logo")
                        Text("Finder")
                            .fontWeight(.semibold)
                        Text("File")
                        Text("Edit")
                        Text("View")
                        Text("Go")
                        Text("Window")
                        Text("Help")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.86))
                    .padding(.leading, 18)
                }
        }
    }
}
