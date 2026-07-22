import SwiftUI
@testable import VoiceBarUI
import XCTest

final class VoiceBarHoverHysteresisTests: XCTestCase {
    private var windows: [NSWindow] = []

    @MainActor
    func testMouseMovedKeepsUnflippedWindowYForVisibleSurfaceAdmission() throws {
        let presentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false,
            isHovered: false,
            isKeyboardFocused: false
        )
        let interactionConfiguration = VoiceBarNotchInteractionConfiguration(
            leadingControlCount: 3
        )
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: interactionConfiguration
        )
        let host = PillHostingView(rootView: EmptyView())
        host.frame = NSRect(origin: .zero, size: layout.panelSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        windows.append(window)

        var admitted: [Bool] = []
        var providerPoints: [NSPoint] = []
        var hoverExpansionPoints: [NSPoint] = []
        var hoverRetentionPoints: [NSPoint] = []
        host.onPointerMoved = { point in
            providerPoints.append(point)
            admitted.append(layout.containsVisibleSurface(point))
        }
        host.hoverExpansionHitTestProvider = { point in
            hoverExpansionPoints.append(point)
            return false
        }
        host.hoverRetentionHitTestProvider = { point in
            hoverRetentionPoints.append(point)
            return false
        }

        let holdRect = try XCTUnwrap(
            VoiceBarNotchHitRegion(
                geometry: presentation.geometry,
                configuration: interactionConfiguration
            ).rects.first
        ).offsetBy(
            dx: layout.visibleContentRect.minX,
            dy: layout.visibleContentRect.minY
        )
        let visibleControlTop = NSPoint(x: holdRect.midX, y: holdRect.maxY - 1)
        let bottomShadow = NSPoint(
            x: visibleControlTop.x,
            y: layout.visibleContentRect.minY - 1
        )
        for point in [visibleControlTop, bottomShadow] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 0,
                    pressure: 0
                )
            )
            host.mouseMoved(with: event)
        }

        XCTAssertTrue(host.isFlipped)
        XCTAssertTrue(layout.containsInteractiveContent(visibleControlTop))
        XCTAssertEqual(providerPoints, [visibleControlTop, bottomShadow])
        XCTAssertEqual(hoverExpansionPoints, [visibleControlTop, bottomShadow])
        XCTAssertEqual(hoverRetentionPoints, [visibleControlTop, bottomShadow])
        XCTAssertEqual(
            admitted,
            [true, false],
            "the visible top must capture and the bottom-only shadow lane must pass through"
        )
    }

    @MainActor
    func testSharedPointerPathCarriesHoverFromActiveThroughRetentionToOutside() async {
        let host = PillHostingView(rootView: EmptyView())
        let expansion = CGRect(x: 20, y: 20, width: 100, height: 32)
        let retention = expansion.insetBy(dx: -12, dy: -12)
        let exitExpectation = expectation(description: "hover exit completed")
        var pointerUpdates: [CGPoint] = []
        var hoverUpdates: [Bool] = []
        host.hoverExpansionHitTestProvider = { expansion.contains($0) }
        host.hoverRetentionHitTestProvider = { retention.contains($0) }
        host.onPointerMoved = { pointerUpdates.append($0) }
        host.onHoverChanged = { hovering in
            hoverUpdates.append(hovering)
            if !hovering {
                exitExpectation.fulfill()
            }
        }

        let activePoint = CGPoint(x: 40, y: 36)
        let retentionPoint = CGPoint(x: 12, y: 36)
        let outsidePoint = CGPoint(x: 2, y: 2)
        host.handlePointerMovement(at: activePoint)
        host.handlePointerMovement(at: retentionPoint)
        host.handlePointerMovement(at: outsidePoint)
        await fulfillment(
            of: [exitExpectation],
            timeout: VoiceBarHoverHysteresis.exitDelay + 1
        )

        XCTAssertEqual(pointerUpdates, [activePoint, retentionPoint, outsidePoint])
        XCTAssertEqual(hoverUpdates, [true, false])
    }

    func testEntryIsImmediateButExitUsesEtansTwoToThreeSecondGrace() {
        var hysteresis = VoiceBarHoverHysteresis()

        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            [.hoverChanged(true)]
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: false),
            [.scheduleExit(after: 2.5)]
        )
        XCTAssertGreaterThanOrEqual(VoiceBarHoverHysteresis.exitDelay, 2.0)
        XCTAssertLessThanOrEqual(VoiceBarHoverHysteresis.exitDelay, 3.0)
        XCTAssertEqual(hysteresis.exitDelayElapsed(), [.hoverChanged(false)])
    }

    func testCoreToWingIconAndBackNeverCollapses() {
        var hysteresis = VoiceBarHoverHysteresis()

        _ = hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true)
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            []
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            [],
            "a small overshoot past a wing icon stays inside the larger collapse-out zone"
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            []
        )
        XCTAssertTrue(hysteresis.isHovering)
    }

    func testReentryDuringExitGraceCancelsThePendingCollapse() {
        var hysteresis = VoiceBarHoverHysteresis()

        _ = hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true)
        _ = hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: false)
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            [.cancelExit]
        )
        XCTAssertEqual(hysteresis.exitDelayElapsed(), [])
        XCTAssertTrue(hysteresis.isHovering)
    }

    func testRetentionZoneAloneCannotSummonACollapsedSurface() {
        var hysteresis = VoiceBarHoverHysteresis()

        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            []
        )
        XCTAssertFalse(hysteresis.isHovering)
    }

    func testActiveToRetentionToOutsideSchedulesOneExit() {
        var hysteresis = VoiceBarHoverHysteresis()

        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            [.hoverChanged(true)]
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            []
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: false),
            [.scheduleExit(after: 2.5)]
        )
    }
}
