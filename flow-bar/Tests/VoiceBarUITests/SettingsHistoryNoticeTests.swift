import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsHistoryNoticeTests: XCTestCase {
    func testTheBusySentenceIsOneConstantInTheBannerTheTooltipAndThePlaybackModel() {
        XCTAssertEqual(SettingsHistoryCopy.playBusy, "Can't play while VoiceBar is recording, transcribing or speaking.")

        let clip = SettingsHistoryMediaPart(
            role: .recording, displayText: "Synthetic transcript", isPlaceholder: false,
            actionableText: "Synthetic transcript", audioPath: URL(fileURLWithPath: "/tmp/notice/audio.wav"),
            durationLabel: nil, transcribedDurationLabel: nil
        )
        let busy = SettingsHistoryActionEnablement(isRetranscribing: false, isRecording: false,
                                                   isTranscribing: false, isVoiceBusy: true)
        XCTAssertEqual(busy.availability(.play, for: clip), .unavailable(SettingsHistoryCopy.playBusy))

        let playback = SettingsAudioPlayback(start: { _ in true }, stop: {}, canPlay: { false })
        playback.toggle(URL(fileURLWithPath: "/tmp/notice/audio.wav"))
        XCTAssertEqual(playback.failureMessage, SettingsHistoryCopy.playBusy)
        XCTAssertEqual(SettingsHistoryNotice.Kind(isVoiceBusy: true, failureMessage: "Audio could not start."), .busy)
    }

    func testAFailureShowsOnlyWhenVoiceIsIdle() {
        XCTAssertNil(SettingsHistoryNotice.Kind(isVoiceBusy: false, failureMessage: nil))
        XCTAssertNil(SettingsHistoryNotice.Kind(isVoiceBusy: false, failureMessage: "  \n"))
        XCTAssertEqual(SettingsHistoryNotice.Kind(isVoiceBusy: false, failureMessage: "Audio could not start."),
                       .failure("Audio could not start."))
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
        let dictations = try render(scope: .recording, playback: Self.idlePlayback())
        let ask = try render(scope: .ask, playback: Self.idlePlayback())
        let rows = max(0, Int(noticeTop) - Int(40 * scale)) ..< Int(noticeTop)
        return try CGFloat(XCTUnwrap(changedColumns(from: dictations, to: ask, rows: rows).first,
                                     "the selected Dictations segment"))
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

    private func render(scope: SettingsHistoryScope, playback: SettingsAudioPlayback) throws -> RenderedImage {
        try RenderedImage(XCTUnwrap(renderBitmap(scope: scope, playback: playback, appearance: .aqua).cgImage))
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
