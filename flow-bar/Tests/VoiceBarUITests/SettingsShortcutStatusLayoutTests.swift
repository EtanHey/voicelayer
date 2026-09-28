import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C14 (QA recording 2026-09-25): the Shortcut section's green "Active" sat beside its "Status" label on the left,
/// while every other value in General (F5, Granted, Visible) sits in the trailing column, and "Check shortcut" took
/// that column instead. The status now reads in the same trailing column as the shortcut above it.
@MainActor
final class SettingsShortcutStatusLayoutTests: XCTestCase {
    func testActiveStatusSitsInTheTrailingValueColumn() throws {
        let image = try renderGeneral()
        let dots = greenDots(in: image)
        XCTAssertGreaterThanOrEqual(dots.count, 4, "Status plus the three Permissions dots: \(dots)")
        guard dots.count >= 4 else { return }

        // Top-down: the Shortcut section's Status dot, then Microphone / Accessibility / Input Monitoring.
        let status = dots[0]
        let permissions = dots[1 ... 3]
        let permissionX = permissions.map(\.midX).reduce(0, +) / CGFloat(permissions.count)
        // "Active" is a few points shorter than "Granted", so the dot lands a little right of theirs; before the
        // fix it sat ~420 pt to the left, beside the row label.
        XCTAssertEqual(status.midX, permissionX, accuracy: 20 * scale,
                       "the Active dot shares the trailing value column with the Permissions dots")
    }

    func testCheckShortcutIsItsOwnRowBelowTheStatus() throws {
        let image = try renderGeneral()
        let dots = greenDots(in: image)
        guard let status = dots.first else { return XCTFail("no status dot") }

        // On the Status row, nothing but the dot and its word may sit right of the dot: no button beside it.
        let background = image.pixel(x: Int(status.minX) - 12, y: Int(status.midY))
        // Stop short of the card's trailing edge; the window background beyond it is a different grey.
        let inked = (Int(status.maxX) + 2 ..< Int((size.width - 24) * scale)).filter { x in
            (Int(status.minY) ..< Int(status.maxY)).contains { y in
                let p = image.pixel(x: x, y: y)
                return abs(p.r - background.r) + abs(p.g - background.g) + abs(p.b - background.b) > 60
            }
        }
        let span = try CGFloat(XCTUnwrap(inked.last, "the status word") - XCTUnwrap(inked.first))
        XCTAssertLessThan(span, 70 * scale, "only the status word follows the dot on its row")
    }

    /// Bugbot on #192: the listener-off state is the one most likely to crowd the trailing column. Its red
    /// "Missing: …" status must still read as one phrase ending on the same trailing edge as "Granted" below.
    func testWithTheListenerOffTheMissingStatusStillEndsOnTheTrailingEdge() throws {
        let image = try renderGeneral(hotkeyEnabled: false, missing: [.accessibility, .inputMonitoring])
        let status = try XCTUnwrap(dots(in: image, where: { $0.r > 200 && $0.g < 90 && $0.b < 90 }).first,
                                   "the red status dot")
        let granted = try XCTUnwrap(greenDots(in: image).first, "Microphone's green Granted dot")

        let statusInk = inkedColumns(in: image, rightOf: status)
        let statusEnd = try XCTUnwrap(statusInk.last, "the Missing status text")
        let grantedEnd = try XCTUnwrap(inkedColumns(in: image, rightOf: granted).last, "Granted")
        XCTAssertEqual(CGFloat(statusEnd), CGFloat(grantedEnd), accuracy: 3 * scale,
                       "Missing: … ends on the same trailing edge as Granted")
        let widestGap = zip(statusInk, statusInk.dropFirst()).map { $1 - $0 }.max() ?? 0
        XCTAssertLessThan(CGFloat(widestGap), 20 * scale, "one phrase after the dot, no button beside it")
    }

    // MARK: - Helpers

    private let scale: CGFloat = 2
    private let size = CGSize(width: 780, height: 620)

    /// The General tab in an offscreen titled window, light appearance, at 2×, like the P03 shots harness.
    private func renderGeneral(hotkeyEnabled: Bool = true, missing: [HotkeyPermission] = []) throws -> RenderedImage {
        let view = SettingsView(
            hotkeyEnabled: hotkeyEnabled,
            missingPermissions: missing,
            availableDevices: { [MicrophoneDevice(id: "fixture-mic", name: "Fixture Microphone")] },
            selectedDeviceID: { "fixture-mic" },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: []) },
            vocabularyRevision: { 0 },
            initialTab: .general
        )
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try RenderedImage(XCTUnwrap(bitmap.cgImage))
    }

    /// Columns right of `dot`, on its row and short of the card's trailing edge, holding ink.
    private func inkedColumns(in image: RenderedImage, rightOf dot: CGRect) -> [Int] {
        let background = image.pixel(x: Int(dot.minX) - 12, y: Int(dot.midY))
        return (Int(dot.maxX) + 2 ..< Int((size.width - 24) * scale)).filter { x in
            (Int(dot.minY) ..< Int(dot.maxY)).contains { y in
                let p = image.pixel(x: x, y: y)
                return abs(p.r - background.r) + abs(p.g - background.g) + abs(p.b - background.b) > 60
            }
        }
    }

    /// Green status dots in the content pane (right of the sidebar), top-down, in pixel coordinates.
    private func greenDots(in image: RenderedImage) -> [CGRect] {
        dots(in: image, where: { $0.g > 150 && $0.r < 110 && $0.b < 130 })
    }

    private func dots(in image: RenderedImage, where matches: (RenderedImage.Pixel) -> Bool) -> [CGRect] {
        let sidebarEdge = Int(200 * scale)
        var boxes: [CGRect] = []
        for y in 0 ..< image.height {
            for x in sidebarEdge ..< image.width {
                guard matches(image.pixel(x: x, y: y)) else { continue }
                let point = CGRect(x: x, y: y, width: 1, height: 1)
                if let index = boxes.firstIndex(where: { $0.insetBy(dx: -3, dy: -3).intersects(point) }) {
                    boxes[index] = boxes[index].union(point)
                } else {
                    boxes.append(point)
                }
            }
        }
        // A dot is ~8 pt round; drop stray antialiasing specks.
        return boxes.filter { $0.width >= 8 && $0.height >= 8 }.sorted { $0.minY < $1.minY }
    }
}
