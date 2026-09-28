import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane C1: while recording, the notch's Stop disc and the Cancel (X) control must read as two
/// separate buttons — a visible gap between them, and neither plate wider than its layout slot.
/// Measured on production views rendered offscreen at 2×, in both appearances.
@MainActor
final class NotchControlSpacingTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private static let scale: CGFloat = 2
    private var slot: CGFloat {
        VoiceBarNotchContract.material.compactControlSize
    }

    private var spacing: CGFloat {
        VoiceBarNotchContract.material.compactControlSpacing
    }

    func testRecordingStopDiscFitsItsSlotAndLeavesAGapBeforeCancel() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let state = VoiceState()
            state.isConnected = true
            state.isCollapsed = false
            state.mode = .recording
            state.recordingMode = "vad"
            let bitmap = try render(
                BarView(state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
                        includesPanelOutsets: true),
                size: CGSize(width: 600, height: 80),
                appearance: appearance
            )
            let disc = try XCTUnwrap(redBounds(in: bitmap), "\(appearance.rawValue): no Stop disc rendered")
            let discWidth = CGFloat(disc.maxX - disc.minX + 1) / Self.scale
            XCTAssertLessThanOrEqual(
                discWidth, slot + 0.5,
                "\(appearance.rawValue): the Stop disc (\(discWidth) pt) is wider than its \(slot) pt slot"
            )

            // The first non-background ink to the right of the disc, inside the disc's rows, is the X.
            let background = pixel(bitmap, x: disc.minX - 3 * Int(Self.scale), y: (disc.minY + disc.maxY) / 2)
            var gapColumns = 0
            var x = disc.maxX + 1
            // Skip the disc's own antialiased rim (at most one point).
            while x <= disc.maxX + Int(Self.scale), columnHasInk(bitmap, x: x, rows: disc.minY ... disc.maxY,
                                                                 background: background) {
                x += 1
            }
            while x < bitmap.pixelsWide, !columnHasInk(bitmap, x: x, rows: disc.minY ... disc.maxY,
                                                       background: background) {
                gapColumns += 1
                x += 1
            }
            let gap = CGFloat(gapColumns) / Self.scale
            XCTAssertGreaterThanOrEqual(
                gap, spacing,
                "\(appearance.rawValue): only \(gap) pt between the Stop disc and the X; they read as touching"
            )
        }
    }

    func testHoveredNeighbourPlatesNeverTouch() throws {
        // Two hovered pill controls laid out exactly as the recording wing lays them out.
        for (appearance, foreground) in [(NSAppearance.Name.darkAqua, Color.white), (.aqua, Color.black)] {
            let pair = HStack(spacing: spacing) {
                VoiceBarPillControlButton(
                    icon: "stop.fill", optics: .resolve(for: "stop.fill"), foreground: foreground, halo: .clear,
                    isSelected: false, isDestructive: true, accessibilityLabel: "Stop", accessibilityHint: "",
                    action: {}
                )
                VoiceBarPillControlButton(
                    icon: "xmark", optics: .resolve(for: "xmark"), foreground: foreground, halo: .clear,
                    isSelected: false, isDestructive: false, accessibilityLabel: "Cancel", accessibilityHint: "",
                    previewHovered: true, action: {}
                )
            }
            .padding(20)
            .background(appearance == .aqua ? Color.white : Color.black)
            let bitmap = try render(pair, size: CGSize(width: 120, height: 70), appearance: appearance)
            let disc = try XCTUnwrap(redBounds(in: bitmap))
            let row = (disc.minY + disc.maxY) / 2
            let background = pixel(bitmap, x: disc.minX - 4 * Int(Self.scale), y: row)
            // Walk right from the disc along its middle row: past at most one point of antialiased
            // rim, then count background columns until the hovered X plate starts.
            var x = disc.maxX + 1
            while x <= disc.maxX + Int(Self.scale), isInk(pixel(bitmap, x: x, y: row), background: background) {
                x += 1
            }
            let gapStart = x
            while x < bitmap.pixelsWide, !isInk(pixel(bitmap, x: x, y: row), background: background) {
                x += 1
            }
            let gap = CGFloat(x - gapStart) / Self.scale
            XCTAssertGreaterThanOrEqual(
                gap, spacing - 1,
                "\(appearance.rawValue): the hovered X plate sits \(gap) pt from the Stop disc"
            )
        }
    }

    // MARK: - Rendering + pixels

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .aqua ? .white : .black
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        // A cold CI runner can take well over one short run-loop turn to draw the first frame, so capture
        // until the Stop red is on screen (every view rendered here has it), for at most five seconds.
        let deadline = Date().addingTimeInterval(5)
        var bitmap: NSBitmapImageRep
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * Self.scale),
                pixelsHigh: Int(size.height * Self.scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
        } while redBounds(in: bitmap) == nil && Date() < deadline
        return bitmap
    }

    private struct RGB { let r: Int, g: Int, b: Int }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> RGB {
        var values = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&values, atX: x, y: y)
        return RGB(r: values[0], g: values[1], b: values[2])
    }

    private func isRed(_ p: RGB) -> Bool {
        p.r > 170 && p.r - p.g > 90 && p.r - p.b > 90
    }

    private func isInk(_ p: RGB, background: RGB) -> Bool {
        abs(p.r - background.r) + abs(p.g - background.g) + abs(p.b - background.b) > 24
    }

    private func columnHasInk(_ bitmap: NSBitmapImageRep, x: Int, rows: ClosedRange<Int>, background: RGB) -> Bool {
        rows.contains { isInk(pixel(bitmap, x: x, y: $0), background: background) }
    }

    /// The bounding box of the saturated Stop red, in pixels. Only the Stop disc uses it here.
    private func redBounds(in bitmap: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var box: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide where isRed(pixel(bitmap, x: x, y: y)) {
                if let current = box {
                    box = (min(current.minX, x), max(current.maxX, x), min(current.minY, y), max(current.maxY, y))
                } else {
                    box = (x, x, y, y)
                }
            }
        }
        return box
    }
}
