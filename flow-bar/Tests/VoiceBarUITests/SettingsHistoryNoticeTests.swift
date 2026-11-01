import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsHistoryNoticeTests: XCTestCase {
    private var renderedPickerMinX: CGFloat?
    func testTheBusySentenceIsOneConstantInTheBannerAndTheTooltip() {
        XCTAssertEqual(SettingsHistoryCopy.playBusy, "Can't play while VoiceBar is recording, transcribing or speaking.")

        let clip = SettingsHistoryMediaPart(
            role: .recording, displayText: "Synthetic transcript", isPlaceholder: false,
            actionableText: "Synthetic transcript", audioPath: URL(fileURLWithPath: "/tmp/notice/audio.wav"),
            durationLabel: nil, transcribedDurationLabel: nil
        )
        let busy = SettingsHistoryActionEnablement(isRetranscribing: false, isRecording: false,
                                                   isTranscribing: false, isVoiceBusy: true)
        XCTAssertEqual(busy.availability(.play, for: clip), .unavailable(SettingsHistoryCopy.playBusy))

        XCTAssertEqual(SettingsHistoryNotice.Kind(isVoiceBusy: true, failureMessage: "Audio couldn't start."), .busy)
    }

    func testAFailureShowsOnlyWhenVoiceIsIdle() {
        XCTAssertNil(SettingsHistoryNotice.Kind(isVoiceBusy: false, failureMessage: nil))
        XCTAssertNil(SettingsHistoryNotice.Kind(isVoiceBusy: false, failureMessage: "  \n"))
        XCTAssertEqual(SettingsHistoryNotice.Kind(isVoiceBusy: false, failureMessage: "Audio couldn't start."),
                       .failure("Audio couldn't start."))
    }

    func testABusyRefusalLeavesNothingBehindOnceVoiceIsIdle() {
        var voiceIsBusy = false
        let playback = SettingsAudioPlayback(start: { _ in false }, stop: {}, canPlay: { !voiceIsBusy })
        let clip = URL(fileURLWithPath: "/tmp/notice/audio.wav")
        func notice() -> SettingsHistoryNotice.Kind? {
            SettingsHistoryNotice.Kind(isVoiceBusy: playback.isVoiceBusy, failureMessage: playback.failureMessage)
        }

        playback.toggle(clip)
        XCTAssertEqual(notice(), .failure("Audio couldn't start. Try Play again or reveal the file in Finder."))

        voiceIsBusy = true
        playback.toggle(clip)
        XCTAssertEqual(notice(), .busy)
        XCTAssertNil(playback.failureMessage, "busy is state, never a stored failure")

        voiceIsBusy = false
        XCTAssertNil(notice(), "nothing is left to show or announce once voice goes idle")
    }

    func testOnlyAFailureIsAnnounced() {
        XCTAssertNil(SettingsHistoryNotice.Kind.busy.announcement)
        XCTAssertEqual(SettingsHistoryNotice.Kind.failure("Audio couldn't start.").announcement, "Audio couldn't start.")
    }

    func testTheNoticeSymbolsExist() {
        XCTAssertEqual(SettingsHistoryNotice.Kind.busy.symbol, "play.slash")
        XCTAssertEqual(SettingsHistoryNotice.Kind.failure("x").symbol, "exclamationmark.triangle.fill")
        for kind in [SettingsHistoryNotice.Kind.busy, .failure("x")] {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil), kind.symbol)
        }
    }

    func testBusyAndFailureFillOneReservedSlotSoTheListNeverMoves() throws {
        let idle = try render(scope: .recording, playback: Self.idlePlayback())
        var heights: [Int] = []
        for playback in [Self.busyPlayback(), Self.failedPlayback()] {
            let shown = try render(scope: .recording, playback: playback)
            let notice = try XCTUnwrap(noticeRows(from: idle, to: shown))
            heights.append(notice.count)
            let below = notice.upperBound ..< min(idle.height, notice.upperBound + Int(120 * scale))
            XCTAssertEqual(changedColumns(from: idle, to: shown, rows: below).count, 0,
                           "the toolbar and the first rows stay where they were")
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 1, "busy and failure are the same height")
    }

    func testNoticeTextReadsAtAAContrastInLightAndDark() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let idle = try render(scope: .recording, playback: Self.idlePlayback(), appearance: appearance)
            for (name, playback) in [("busy", Self.busyPlayback()), ("failure", Self.failedPlayback())] {
                let shown = try render(scope: .recording, playback: playback, appearance: appearance)
                let rows = try XCTUnwrap(noticeRows(from: idle, to: shown), name)
                let columns = changedColumns(from: idle, to: shown, rows: rows)
                let left = try XCTUnwrap(columns.first, name)
                let right = try XCTUnwrap(columns.last, name)
                let fill = shown.pixel(x: left + Int(4 * scale), y: (rows.lowerBound + rows.upperBound) / 2)
                let textColumns = (left + Int(34 * scale)) ... right
                let strongest = rows.flatMap { y in textColumns.map { x in contrast(shown.pixel(x: x, y: y), fill) } }.max() ?? 0
                XCTAssertGreaterThanOrEqual(strongest, 4.5, "\(name) text in \(appearance.rawValue)")
            }
        }
    }

    func testTheBusyNoticeSitsInsideTheSamePaddingAsTheScopePicker() throws {
        let idle = try render(scope: .recording, playback: Self.idlePlayback())
        let busy = try render(scope: .recording, playback: Self.busyPlayback())
        let notice = try XCTUnwrap(firstChangedBand(from: idle, to: busy, height: 12), "the busy notice")
        let pickerMinX = try scopePickerMinX(above: notice.minY)

        XCTAssertEqual(notice.minX, pickerMinX, accuracy: 3 * scale, "left edge lines up with the picker")
        XCTAssertEqual(size.width * scale - notice.maxX, 18 * scale, accuracy: 2 * scale,
                       "right edge keeps the toolbar's 18 pt trailing inset")
    }

    func testTheFailureNoticeSitsInsideTheSamePaddingAsTheScopePicker() throws {
        let idle = try render(scope: .recording, playback: Self.idlePlayback())
        let failed = try render(scope: .recording, playback: Self.failedPlayback())
        let notice = try XCTUnwrap(firstChangedBand(from: idle, to: failed, height: 12), "the failure notice")
        let pickerMinX = try scopePickerMinX(above: notice.minY)

        XCTAssertEqual(notice.minX, pickerMinX, accuracy: 3 * scale, "left edge lines up with the picker")
        XCTAssertEqual(size.width * scale - notice.maxX, 18 * scale, accuracy: 2 * scale,
                       "right edge keeps the toolbar's 18 pt trailing inset")
    }

    func testWritesNoticeArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/ui-pr-a")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (state, playback) in [("idle", Self.idlePlayback), ("busy", Self.busyPlayback), ("failure", Self.failedPlayback)] {
            for (appearance, appearanceName) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let bitmap = try renderBitmap(scope: .recording, playback: playback(), appearance: appearance)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: outputDirectory.appendingPathComponent("history-notice-\(state)-\(appearanceName).png"))
            }
        }
    }

    private func noticeRows(from idle: RenderedImage, to shown: RenderedImage) -> Range<Int>? {
        func differs(_ y: Int) -> Bool {
            (0 ..< idle.width).contains { x in !same(idle.pixel(x: x, y: y), shown.pixel(x: x, y: y)) }
        }
        guard let top = (0 ..< idle.height).first(where: differs) else { return nil }
        let bottom = (top ..< idle.height).first { !differs($0) } ?? idle.height
        return top ..< bottom
    }

    private func contrast(_ lhs: RenderedImage.Pixel, _ rhs: RenderedImage.Pixel) -> Double {
        func luminance(_ pixel: RenderedImage.Pixel) -> Double {
            func linear(_ channel: Int) -> Double {
                let value = Double(channel) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(pixel.r) + 0.7152 * linear(pixel.g) + 0.0722 * linear(pixel.b)
        }
        let (light, dark) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
        return (light + 0.05) / (dark + 0.05)
    }

    private let scale: CGFloat = 2
    private let size = CGSize(width: 900, height: 640)

    private static func idlePlayback() -> SettingsAudioPlayback {
        SettingsAudioPlayback(start: { _ in true }, stop: {})
    }

    private static func busyPlayback() -> SettingsAudioPlayback {
        SettingsAudioPlayback(start: { _ in true }, stop: {}, canPlay: { false })
    }

    private static func failedPlayback() -> SettingsAudioPlayback {
        let playback = SettingsAudioPlayback(start: { _ in false }, stop: {})
        playback.toggle(URL(fileURLWithPath: "/tmp/notice-0/audio.wav"))
        return playback
    }

    private func scopePickerMinX(above noticeTop: CGFloat) throws -> CGFloat {
        _ = try render(scope: .recording, playback: Self.idlePlayback())
        // Stock macOS26 selection ink is inset from the control's frame. Align
        // notice padding to the actual control, not to a changed-pixel capsule.
        return try XCTUnwrap(renderedPickerMinX, "native History scope control frame")
    }

    private func firstChangedBand(from before: RenderedImage, to after: RenderedImage, height: CGFloat) -> CGRect? {
        guard let top = (0 ..< before.height).first(where: { y in
            (0 ..< before.width).contains { x in !same(before.pixel(x: x, y: y), after.pixel(x: x, y: y)) }
        }) else { return nil }
        let columns = changedColumns(from: before, to: after, rows: top ..< min(before.height, top + Int(height * scale)))
        guard let first = columns.first, let last = columns.last else { return nil }
        return CGRect(x: CGFloat(first), y: CGFloat(top), width: CGFloat(last - first + 1), height: height * scale)
    }

    private func changedColumns(from before: RenderedImage, to after: RenderedImage, rows: Range<Int>) -> [Int] {
        (0 ..< before.width).filter { x in
            rows.contains { y in !same(before.pixel(x: x, y: y), after.pixel(x: x, y: y)) }
        }
    }

    private func same(_ lhs: RenderedImage.Pixel, _ rhs: RenderedImage.Pixel) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b && lhs.a == rhs.a
    }

    private func render(
        scope: SettingsHistoryScope,
        playback: SettingsAudioPlayback,
        appearance: NSAppearance.Name = .aqua
    ) throws -> RenderedImage {
        try RenderedImage(XCTUnwrap(renderBitmap(scope: scope, playback: playback, appearance: appearance).cgImage))
    }

    private func renderBitmap(
        scope: SettingsHistoryScope,
        playback: SettingsAudioPlayback,
        appearance: NSAppearance.Name
    ) throws -> NSBitmapImageRep {
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { _ in Self.dictations },
            initialHistoryPage: Self.dictations,
            askHistoryPage: { _ in Self.asks },
            initialAskHistoryPage: Self.asks,
            initialTab: .history,
            initialHistoryScope: scope,
            historyPlayback: playback
        )
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        VLOrderTestWindow(window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        func scopeControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 3 { return control }
            return view.subviews.compactMap { scopeControl($0) }.first
        }
        let control = try XCTUnwrap(scopeControl(host))
        renderedPickerMinX = control.convert(control.bounds, to: host).minX * scale

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private static let dictations = SettingsHistoryPage(groups: [
        SettingsHistoryDayGroup(dayKey: "2026-10-27", date: date(hour: 0), entries: (0 ..< 6).map { index in
            SettingsHistoryEntry(
                id: "/tmp/notice-\(index)/audio.wav",
                dayKey: "2026-10-27",
                recordingID: "notice-\(index)",
                createdAt: date(hour: 9 - index, minute: 12),
                transcript: [
                    "Move the busy notice inside the padding so it lines up with the picker.",
                    "Ship the History notice after the review round.",
                    "Deploy the notch build to the M1 after lunch.",
                ][index % 3],
                audioPath: URL(fileURLWithPath: "/tmp/notice-\(index)/audio.wav"),
                durationMs: 5000 + index * 7000
            )
        }),
    ], hasMore: false)

    private static let asks = SettingsAskHistoryPage(groups: [
        SettingsAskHistoryDayGroup(dayKey: "2026-10-27", date: date(hour: 0), entries: [
            SettingsAskHistoryEntry(
                id: "/tmp/notice-ask-1", dayKey: "2026-10-27", askID: "a1",
                createdAt: date(hour: 8, minute: 30),
                questionText: "Should the notice line up with the picker?",
                questionAudioPath: URL(fileURLWithPath: "/tmp/notice-ask-1/agent-audio.mp3"),
                responseTranscript: "Yes, inside the same padding.",
                responseAudioPath: URL(fileURLWithPath: "/tmp/notice-ask-1/audio.wav")
            ),
        ]),
    ], hasMore: false)

    private static func date(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 10
        components.day = 27
        components.hour = hour
        components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}
