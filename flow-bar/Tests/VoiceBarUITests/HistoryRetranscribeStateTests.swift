import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QA 2.2.25 lane B (C5–C8, QA recording part1 03:09–05:29): the History re-transcribe state in the notch panel and
/// Settings › History.
@MainActor
final class HistoryRetranscribeStateTests: XCTestCase {
    // MARK: - C5 the spinner is centred on its label

    /// C5 (decision D4): the "Re-transcribing…" label and its spinner must be vertically centred. Measured on the
    /// QA recording's 03:10 frame: the box is centred, but the spinner is an open arc, and with its gap facing down
    /// its ink sat 1.25 pt above the label. As it turns, the arc's ink centre wanders. At every angle, the spinner's
    /// visible ink must stay centred on the label's optical centre: halfway between the middle of a capital ("R") and
    /// the middle of a lowercase letter ("e").
    func testTheSpinnerStaysCentredOnItsLabelAtEveryAngle() throws {
        let scale: CGFloat = 4
        var worst: (angle: Double, offset: CGFloat) = (0, 0)
        for angle in stride(from: 0.0, to: 360.0, by: 30.0) {
            let badge = HistoryRetranscribingBadge(
                fontSize: 10, color: .black, spinner: HistoryRetranscribingSpinnerStyle.frame(angle: angle)
            )
            .padding(8)
            .background(Color.white)
            let image = try render(badge, scale: scale)
            let isInk: (RenderedImage.Pixel) -> Bool = { $0.r + $0.g + $0.b < 700 }
            let isText: (RenderedImage.Pixel) -> Bool = { $0.r < 120 && $0.g < 120 && $0.b < 120 }
            let runs = image.glyphColumnRuns(where: isInk)
            XCTAssertGreaterThanOrEqual(runs.count, 3, "spinner, R, e")
            let spinner = try XCTUnwrap(image.inkRows(in: runs[0], where: isInk), "spinner ink")
            let capital = try XCTUnwrap(image.inkRows(in: runs[1], where: isText))
            let lowercase = try XCTUnwrap(image.inkRows(in: runs[2], where: isText))

            let spinnerCentre = (spinner.lowerBound + spinner.upperBound) / 2
            let opticalCentre = ((capital.lowerBound + capital.upperBound) / 2
                + (lowercase.lowerBound + lowercase.upperBound) / 2) / 2
            let offset = (spinnerCentre - opticalCentre) / scale
            if abs(offset) > abs(worst.offset) { worst = (angle, offset) }
        }
        XCTAssertLessThanOrEqual(
            abs(worst.offset), 0.5,
            "at \(worst.angle)° the spinner's ink centre is \(worst.offset) pt from the label's optical centre"
        )
    }

    // MARK: - C6 blocked actions look blocked and say why

    /// C6 (04:52): during a re-transcription the daemon is also "transcribing", and that branch won, so a blocked
    /// button's tooltip gave the transcribing reason instead of naming the running re-transcription.
    func testWhileAReTranscriptionRunsTheReasonNamesIt() {
        let clip = part(path: "/tmp/lane-b/other/audio.wav")
        let running = SettingsHistoryActionEnablement(isRetranscribing: true, isRecording: false, isTranscribing: true)

        XCTAssertEqual(
            running.availability(.retranscribe, for: clip),
            .unavailable("Another re-transcription is running")
        )
        XCTAssertEqual(running.availability(.play, for: clip), .unavailable("Wait for the re-transcription to finish"))
        XCTAssertEqual(running.availability(.copy, for: clip), .unavailable("Wait for the re-transcription to finish"))
        XCTAssertEqual(running.availability(.finder, for: clip), .available)

        let recordingToo = SettingsHistoryActionEnablement(
            isRetranscribing: true,
            isRecording: true,
            isTranscribing: false
        )
        XCTAssertEqual(recordingToo.availability(.retranscribe, for: clip), .unavailable("Unavailable while recording"))
        let dictation = SettingsHistoryActionEnablement(
            isRetranscribing: false,
            isRecording: false,
            isTranscribing: true
        )
        XCTAssertEqual(dictation.availability(.retranscribe, for: clip), .unavailable("Unavailable while transcribing"))
    }

    /// C6 (04:55): blocked actions must look disabled. A blocked History action's icon keeps at most half the
    /// contrast it has when available.
    func testBlockedActionsAreVisiblyDimmed() throws {
        let idle = try renderHistory(retranscribingPath: nil)
        let blocked = try renderHistory(retranscribingPath: Self.otherPath)
        let row = try XCTUnwrap(actionsRegion(in: idle), "actions row")
        let buttons = idle.inkColumnRuns(in: row)
        XCTAssertEqual(buttons.count, 5, "Play, Copy, Paste, Re-transcribe, Finder")
        // Finder stays available; measure the four that are blocked.
        let finder = try XCTUnwrap(buttons.last)
        let region = RenderedImage.Region(x: row.x.lowerBound ..< finder.lowerBound, y: row.y)

        let idleContrast = idle.meanContrast(in: region)
        let blockedContrast = blocked.meanContrast(in: region)
        XCTAssertGreaterThan(idleContrast, 0)
        XCTAssertLessThanOrEqual(
            blockedContrast / idleContrast, 0.5,
            "blocked actions keep \(Int(blockedContrast / idleContrast * 100))% of their contrast"
        )
    }

    // MARK: - C7 / C8 the re-transcribing entry

    /// C7 (03:52): action buttons must not move when a re-transcription starts. The spinner has its own slot.
    func testStartingAReTranscriptionDoesNotMoveTheActions() throws {
        let idle = try renderHistory(retranscribingPath: nil)
        let running = try renderHistory(retranscribingPath: Self.selectedPath)
        let region = try XCTUnwrap(actionsRegion(in: idle), "actions row")

        /// Button centres, not edges: a dimmed icon loses a faint anti-aliased edge pixel without moving, and the
        /// spinning icon's two arrows separate into two ink runs at some angles, so runs closer than 10 pt (20 px)
        /// are one button. Buttons sit 36 pt apart; the tolerance is 1 pt (a turning glyph's ink box wobbles).
        func centres(_ runs: [Range<Int>]) -> [Double] {
            var slots: [Range<Int>] = []
            for run in runs {
                if let last = slots.last, run.lowerBound - last.upperBound < 20 {
                    slots[slots.count - 1] = last.lowerBound ..< run.upperBound
                } else {
                    slots.append(run)
                }
            }
            return slots.map { Double($0.lowerBound + $0.upperBound) / 2 }
        }
        let before = centres(idle.inkColumnRuns(in: region))
        let after = centres(running.inkColumnRuns(in: region))
        XCTAssertEqual(before.count, 5)
        XCTAssertEqual(after.count, before.count, "no button appears or disappears")
        for (moved, original) in zip(after, before) {
            XCTAssertEqual(moved, original, accuracy: 2, "every action button keeps its place")
        }
        let rowsBefore = try XCTUnwrap(idle.inkRowSpan(in: region))
        let rowsAfter = try XCTUnwrap(running.inkRowSpan(in: region))
        XCTAssertEqual(
            Double(rowsAfter.lowerBound + rowsAfter.upperBound) / 2,
            Double(rowsBefore.lowerBound + rowsBefore.upperBound) / 2,
            accuracy: 1, "and its line"
        )
    }

    /// C8 (04:35): the spinner must keep turning after switching entries. It followed a state change, so an entry
    /// that was already re-transcribing when it came into view never spun. It must spin whenever it is shown, from
    /// the first frame.
    func testAnEntryAlreadyReTranscribingSpinsFromItsFirstFrame() throws {
        let host = try hostHistory(retranscribingPath: Self.selectedPath)
        defer { host.window?.contentView = nil }
        let first = try capture(host)
        settle(milliseconds: 180)
        let second = try capture(host)

        XCTAssertGreaterThan(first.differingPixelCount(from: second), 0, "the spinner moved between two frames")
    }

    // MARK: - Hosted Settings › History

    private static let selectedPath = "/tmp/lane-b/selected/audio.wav"
    private static let otherPath = "/tmp/lane-b/other/audio.wav"

    private func hostHistory(retranscribingPath: String?) throws -> NSHostingView<AnyView> {
        let page = SettingsHistoryPage(groups: [
            SettingsHistoryDayGroup(dayKey: "2026-09-25", date: Date(timeIntervalSince1970: 1_790_294_400), entries: [
                historyEntry(path: Self.selectedPath, transcript: "Testing the history re-transcribe row.", minute: 8),
                historyEntry(path: Self.otherPath, transcript: "A much longer one, so it takes a while.", minute: 3),
            ]),
        ], hasMore: false)
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { _ in page },
            initialHistoryPage: page,
            isHistoryRetranscribing: { $0 == retranscribingPath },
            isAnyHistoryRetranscribing: { retranscribingPath != nil },
            isTranscribingActive: { retranscribingPath != nil },
            initialTab: .history,
            initialHistoryScope: .recording
        )
        let size = CGSize(width: 900, height: 700)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        settle(milliseconds: 600)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func renderHistory(retranscribingPath: String?) throws -> RenderedImage {
        let host = try hostHistory(retranscribingPath: retranscribingPath)
        defer { host.window?.contentView = nil }
        return try capture(host)
    }

    private func capture(_ host: NSView) throws -> RenderedImage {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try RenderedImage(XCTUnwrap(bitmap.cgImage))
    }

    private func settle(milliseconds: Int) {
        let settled = expectation(description: "settled")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)
    }

    /// The detail pane's action row: the band of left-side ink just above "Saved on this Mac"'s divider. Found as
    /// the last run of inked rows in the detail's left 260 pt before the attribution line.
    private func actionsRegion(in image: RenderedImage) -> RenderedImage.Region? {
        image.actionRowRegion()
    }

    private func historyEntry(path: String, transcript: String, minute: Int) -> SettingsHistoryEntry {
        SettingsHistoryEntry(
            id: path,
            dayKey: "2026-09-25",
            recordingID: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 1_790_341_200 + TimeInterval(minute * 60)),
            transcript: transcript,
            audioPath: URL(fileURLWithPath: path),
            durationMs: 10000,
            performanceEffort: .accurate
        )
    }

    private func part(path: String) -> SettingsHistoryMediaPart {
        SettingsHistoryMediaPart(
            role: .recording,
            displayText: "hello",
            isPlaceholder: false,
            actionableText: "hello",
            audioPath: URL(fileURLWithPath: path),
            durationLabel: nil,
            transcribedDurationLabel: nil
        )
    }

    // MARK: - Helpers

    private func render(_ view: some View, scale: CGFloat) throws -> RenderedImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = scale
        let cgImage = try XCTUnwrap(renderer.cgImage)
        return try RenderedImage(cgImage)
    }
}

/// An RGBA8 copy of a rendered view, for measuring where ink landed.
struct RenderedImage {
    struct Pixel {
        let r: Int
        let g: Int
        let b: Int
        let a: Int
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let w = image.width
        let h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        width = w
        height = h
        guard drawn else { throw XCTSkip("could not draw the rendered image") }
        bytes = buffer
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]),
                     a: Int(bytes[offset + 3]))
    }

    /// First and last row (top-down, in pixels) holding a matching pixel within `columns`.
    func inkRows(in columns: Range<Int>? = nil, where matches: (Pixel) -> Bool) -> ClosedRange<CGFloat>? {
        let columns = columns ?? 0 ..< width
        let rows = (0 ..< height).filter { y in columns.contains { x in matches(pixel(x: x, y: y)) } }
        guard let first = rows.first, let last = rows.last else { return nil }
        return CGFloat(first) ... CGFloat(last + 1)
    }

    func inkRows(where matches: (Pixel) -> Bool) -> ClosedRange<CGFloat>? {
        inkRows(in: nil, where: matches)
    }

    /// Runs of adjacent columns holding a matching pixel, left to right: one run per glyph at text sizes.
    func glyphColumnRuns(where matches: (Pixel) -> Bool) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0 ... width {
            let inked = x < width && (0 ..< height).contains { y in matches(pixel(x: x, y: y)) }
            if inked, start == nil { start = x }
            if !inked, let begin = start {
                runs.append(begin ..< x)
                start = nil
            }
        }
        return runs
    }
}

extension RenderedImage {
    struct Region: Equatable {
        let x: Range<Int>
        let y: Range<Int>
    }

    private var background: Pixel {
        pixel(x: width - 2, y: height - 2)
    }

    private func isInk(_ pixel: Pixel) -> Bool {
        let bg = background
        return abs(pixel.r - bg.r) + abs(pixel.g - bg.g) + abs(pixel.b - bg.b) > 24
    }

    /// Mean distance from the background over the region's pixels: how strongly its ink reads.
    func meanContrast(in region: Region) -> Double {
        let bg = background
        var total = 0
        for y in region.y {
            for x in region.x {
                let p = pixel(x: x, y: y)
                total += abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b)
            }
        }
        return Double(total) / Double(max(1, region.x.count * region.y.count))
    }

    func inkColumnRuns(in region: Region) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for x in region.x.lowerBound ... region.x.upperBound {
            let inked = x < region.x.upperBound && region.y.contains { isInk(pixel(x: x, y: $0)) }
            if inked, start == nil { start = x }
            if !inked, let begin = start {
                runs.append(begin ..< x)
                start = nil
            }
        }
        return runs
    }

    func inkRowSpan(in region: Region) -> Range<Int>? {
        let rows = region.y.filter { y in region.x.contains { isInk(pixel(x: $0, y: y)) } }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first ..< last + 1
    }

    func differingPixelCount(from other: RenderedImage) -> Int {
        guard other.width == width, other.height == height else { return Int.max }
        var count = 0
        for y in 0 ..< height {
            for x in 0 ..< width where pixel(x: x, y: y) != other.pixel(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    /// Rows that are a full-width divider across the content column.
    private func dividerRows() -> [Range<Int>] {
        let span = Int(Double(width) * 0.25) ..< Int(Double(width) * 0.95)
        var rows: [Range<Int>] = []
        for y in 0 ..< height {
            let inked = span.filter { isInk(pixel(x: $0, y: y)) }.count
            guard Double(inked) > Double(span.count) * 0.9 else { continue }
            if let last = rows.last, last.upperBound == y {
                rows[rows.count - 1] = last.lowerBound ..< y + 1
            } else {
                rows.append(y ..< y + 1)
            }
        }
        return rows
    }

    /// Settings › History's detail pane sits between the list's divider and the "Saved on this Mac" divider; its
    /// last band of ink (transcript, stats, then actions) is the action row. Only the left side, where the buttons
    /// are.
    func actionRowRegion() -> Region? {
        let dividers = dividerRows()
        guard dividers.count >= 3 else { return nil }
        let top = dividers[dividers.count - 3].upperBound
        let bottom = dividers[dividers.count - 2].lowerBound
        let columns = Int(Double(width) * 0.2) ..< Int(Double(width) * 0.55)
        var bands: [Range<Int>] = []
        for y in top ..< bottom where columns.contains(where: { isInk(pixel(x: $0, y: y)) }) {
            if let last = bands.last, y - last.upperBound <= 2 {
                bands[bands.count - 1] = last.lowerBound ..< y + 1
            } else {
                bands.append(y ..< y + 1)
            }
        }
        guard let actions = bands.last else { return nil }
        return Region(x: columns, y: max(top, actions.lowerBound - 6) ..< min(bottom, actions.upperBound + 6))
    }
}

extension RenderedImage.Pixel: Equatable {}
