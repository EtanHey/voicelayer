import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// V27 (Etan, 2026-11-04): History rows were clipped, "only the last in the list in a given date… right before the
/// title of the next date". Cause: each day header's opaque cover reached 18 pt above it (sized for the Ask list's
/// 18 pt section spacing) while the Dictations list spaces rows 2 pt apart, so the next day's header painted over the
/// bottom 16 pt of the previous day's last row: its time line vanished.
///
/// The guard renders the real Settings › History list with a day holding exactly one dictation (the newest, so it is
/// the selected row and draws the selection tint over its whole frame) directly above the next day's header, then
/// measures the tint's height in pixels. Clipped, the tint is ~16 pt shorter than the row.
@MainActor
final class HistoryDayBoundaryClipTests: XCTestCase {
    /// A two-line row is ~51 pt (9 pt padding, a 13 pt line, 3 pt, a caption line, 9 pt); clipped it was ~35 pt.
    private static let minimumUnclippedRowHeight: CGFloat = 44

    func testTheLastRowOfADayIsNotCoveredByTheNextDaysHeader() throws {
        for (appearance, name) in [(NSAppearance(named: .aqua), "light"), (NSAppearance(named: .darkAqua), "dark")] {
            let height = try selectedRowTintHeight(appearance: appearance, name: name)
            XCTAssertGreaterThanOrEqual(
                height, Self.minimumUnclippedRowHeight,
                "\(name): the selected last row of a day shows \(height) pt of its frame; the next day's header covers the rest"
            )
        }
    }

    // MARK: - Rendering

    private func selectedRowTintHeight(appearance: NSAppearance?, name: String) throws -> CGFloat {
        let page = Self.page
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { _ in page }, initialHistoryPage: page,
            askHistoryPage: { _ in SettingsAskHistoryPage(groups: [], hasMore: false) },
            initialTab: .history, initialHistoryScope: .recording
        )
        let size = CGSize(width: 900, height: 700)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // UI-assessment crop (opt-in): the whole 900 × 700 window, 1:1 at the backing scale.
        if let directory = ProcessInfo.processInfo.environment["VOICEBAR_U4_SHOTS_DIR"], !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("v27-day-boundary-\(name).png"))
        }
        let scale = CGFloat(bitmap.pixelsHigh) / size.height
        return CGFloat(longestTintRun(in: bitmap)) / scale
    }

    /// The tallest vertical run of selection-tinted pixels (the accent at 13 % over the window background: clearly
    /// bluer than red, which no grey surface, text or divider is) in the left two-thirds of the window.
    private func longestTintRun(in bitmap: NSBitmapImageRep) -> Int {
        var longest = 0
        for x in stride(from: 0, to: bitmap.pixelsWide * 2 / 3, by: 2) {
            var run = 0
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { run = 0; continue }
                if (color.blueComponent - color.redComponent) * 255 > 12 {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
        }
        return longest
    }

    // MARK: - Fixture

    /// Day 1: one dictation (newest, selected). Day 2: two more. No audio is touched.
    private static let page = SettingsHistoryPage(groups: [
        SettingsHistoryDayGroup(dayKey: "2026-11-04", date: date(day: 4, hour: 0), entries: [
            entry(index: 0, day: 4, hour: 21, text: "Move the History handle under the last row."),
        ]),
        SettingsHistoryDayGroup(dayKey: "2026-11-03", date: date(day: 3, hour: 0), entries: [
            entry(index: 1, day: 3, hour: 18, text: "Ship the notch build after the review round."),
            entry(index: 2, day: 3, hour: 9, text: "Check the contrast of the time line in dark mode."),
        ]),
    ], hasMore: false)

    private static func entry(index: Int, day: Int, hour: Int, text: String) -> SettingsHistoryEntry {
        SettingsHistoryEntry(
            id: "/tmp/v27-\(index)/audio.wav",
            dayKey: String(format: "2026-11-%02d", day),
            recordingID: "v27-\(index)",
            createdAt: date(day: day, hour: hour),
            transcript: text,
            audioPath: URL(fileURLWithPath: "/tmp/v27-\(index)/audio.wav"),
            durationMs: 6000 + index * 4000,
            performanceEffort: .accurate
        )
    }

    private static func date(day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 11
        components.day = day
        components.hour = hour
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}
