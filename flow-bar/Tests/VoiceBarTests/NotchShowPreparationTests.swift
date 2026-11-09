import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class NotchShowPreparationTests: XCTestCase {
    func testShowCommitsFreshShellBeforeOrderingWhileHoverKeepsItsIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"))
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchView.swift"))
        let show = try XCTUnwrap(app.components(separatedBy: "func unsnoozeNow() {").last?
            .components(separatedBy: "private func orderPanelFront").first)
        let reset = try XCTUnwrap(show.range(of: "notchPresentationModel.prepareForPresentation()"))
        let layout = try XCTUnwrap(show.range(of: "layoutSubtreeIfNeeded()"))
        let paint = try XCTUnwrap(show.range(of: "displayIfNeeded()"))
        let front = try XCTUnwrap(show.range(of: "orderPanelFront(reason: \"unsnooze\")"))
        XCTAssertLessThan(reset.lowerBound, layout.lowerBound)
        XCTAssertLessThan(layout.lowerBound, paint.lowerBound)
        XCTAssertLessThan(paint.lowerBound, front.lowerBound)
        XCTAssertTrue(bar.contains(".id(presentationModel?.presentationGeneration ?? 0)"))
        XCTAssertTrue(shell.contains("_renderedGeometry = State(initialValue: presentation.geometry)"))
        // The existing hover morph still uses the same geometry transaction and spring.
        XCTAssertTrue(shell.contains("withAnimation(shellAnimation.delay(transition.delay))"))
        XCTAssertTrue(app.contains("notchPresentationModel.setHovered(hovering)"))
    }
    @MainActor func testShowPublishesResolvedTargetsAtFirstPresentation() throws {
        _ = NSApplication.shared
        for speaking in [false, true] {
            let app = AppDelegate()
            app.voiceState.sendCommand = { _ in }
            app.voiceState.setConnectionStatus(true)
            let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100)))
            app.configurePanelVisibilityForTesting(panel)
            defer { panel.orderOut(nil) }
            app.hideNotchForOneHour(nil)
            if speaking {
                app.voiceState.handleEvent(["type": "state", "state": "speaking", "text": "synthetic"])
            }
            var presentations = 0
            app.onPanelPresentationForTesting = { presentation, generation in
                presentations += 1
                XCTAssertEqual(generation, 1, "no mode callback may publish the retained shell")
                let expected = VoiceBarNotchPresentationModel()
                AppDelegate.refreshNotchPresentationModel(expected, for: app.voiceState,
                    coreWidth: presentation.geometry.coreWidth,
                    visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset,
                    virtualNotchIdleCoreHeight: presentation.virtualNotchIdleCoreHeight)
                XCTAssertEqual(presentation.geometry.leadingWingWidth, expected.presentation.geometry.leadingWingWidth)
                XCTAssertEqual(presentation.geometry.trailingWingWidth, expected.presentation.geometry.trailingWingWidth)
                XCTAssertEqual(presentation.geometry, expected.presentation.geometry)
            }
            app.unsnoozeNow()
            XCTAssertEqual(presentations, 1)
            app.onPanelPresentationForTesting = nil
        }
    }

    func testHoverRetainsShellGenerationAndExistingMotionCoordinator() {
        let model = VoiceBarNotchPresentationModel()
        model.prepareForPresentation()
        let generation = model.presentationGeneration
        model.setHovered(true)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)
        XCTAssertNotNil(model.activeTransition)
        XCTAssertEqual(model.presentationGeneration, generation)
        model.setHovered(false)
        XCTAssertEqual(model.presentation.visualState, .idle)
        XCTAssertNotNil(model.activeTransition)
        XCTAssertEqual(model.presentationGeneration, generation)
    }

}
