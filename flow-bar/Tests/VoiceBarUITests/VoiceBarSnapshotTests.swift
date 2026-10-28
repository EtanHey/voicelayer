import AppKit
import QuartzCore
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class SnapshotDiffTests: XCTestCase {
    func testToleranceAcceptsAntialiasingButRejectsLayoutChanges() {
        let expected = [UInt8](repeating: 100, count: 400)
        var actual = expected
        actual[0] = 110
        XCTAssertEqual(SnapshotDiff.changedPixels(expected, actual), 0)
        actual[0] = 140
        XCTAssertEqual(SnapshotDiff.changedPixels(expected, actual), 1)
        for pixel in 0..<10 { actual[pixel * 4] = 140 }
        XCTAssertGreaterThan(SnapshotDiff.changedPixels(expected, actual), 1)
    }
}

private enum SnapshotDiff {
    static func changedPixels(_ expected: [UInt8], _ actual: [UInt8]) -> Int {
        guard expected.count == actual.count, !expected.isEmpty else { return Int.max }
        let changed = stride(from: 0, to: expected.count, by: 4).filter { offset in
            (0..<4).contains { abs(Int(expected[offset + $0]) - Int(actual[offset + $0])) > 16 }
        }.count
        return changed
    }
}

/// Synthetic pixel coverage only; native click/focus/audio acceptance remains separate.
@MainActor
final class VoiceBarSnapshotTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }
    private let names = ["idle", "recording-ptt", "recording-vad", "transcribing",
                         "speaking", "paused", "teleprompter-expanded", "teleprompter-collapsed",
                         "queue-1", "queue-10", "last-item", "paused-controls", "hidden", "snoozed",
                         "busy-note", "typed"]
    private let aliases = ["last-item": "speaking", "teleprompter-collapsed": "speaking", "snoozed": "hidden"]
    private var referenceEnvironment: [String: String]?
    private var recordedEnvironment: [String: String]?
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCatalog() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VOICEBAR_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Local MBP pixel catalog: use scripts/voicebar-snapshots.sh")
        }
        let record = env["VOICEBAR_SNAPSHOTS_RECORD"] == "1"
        let output = root.appendingPathComponent(".build.noindex/snapshots")
        let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Snapshots")
        let metadata = references.appendingPathComponent("environment.json")
        if !record {
            guard let data = try? Data(contentsOf: metadata),
                  let value = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw XCTSkip("SKIP: missing renderer metadata; review environment and use repo script --record")
            }
            referenceEnvironment = value
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [String] = []
        for light in [false, true] {
            var images: [String: [UInt8]] = [:]
            var distinctImages: [String: [UInt8]] = [:]
            for name in names.filter({ aliases[$0] == nil }) {
                let id = name + (light ? "-light" : "-dark")
                let actual = try render(name, light: light)
                let actualPNG = try XCTUnwrap(actual.representation(using: .png, properties: [:]))
                try actualPNG.write(to: temporary.appendingPathComponent(id + ".png"))
                try actualPNG.write(to: output.appendingPathComponent(id + "-actual.png"))
                let reference = references.appendingPathComponent(id + ".png")
                try? FileManager.default.removeItem(at: output.appendingPathComponent(id + "-diff.png"))
                if record { try actualPNG.write(to: reference) }
                guard FileManager.default.fileExists(atPath: reference.path) else {
                    XCTFail("Missing reference \(id); --record is required")
                    continue
                }
                let expectedPNG = try Data(contentsOf: reference)
                try expectedPNG.write(to: output.appendingPathComponent(id + "-expected.png"))
                let expected = try XCTUnwrap(NSBitmapImageRep(data: expectedPNG))
                let a = try rgba(actual), e = try rgba(expected)
                // A common canvas prevents fixture-selected height alone from
                // disguising a fallback to the default visual state.
                let distinct = try rgba(render(name, light: light, canvasHeight: 270))
                for (other, pixels) in distinctImages {
                    XCTAssertFalse(distinct == pixels, "Distinct fixtures silently render identically: \(name), \(other)")
                }
                images[name] = a
                distinctImages[name] = distinct
                if name != "hidden" && name != "snoozed" {
                    XCTAssertGreaterThan(Set(a).count, 20, "Blank/dim fixture: \(id)")
                }
                let sameSize = actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh
                let changed = sameSize ? SnapshotDiff.changedPixels(e, a) : Int.max
                let matches = sameSize && changed <= 25
                if !matches {
                    let diff = try difference(actual, expected)
                    try XCTUnwrap(diff.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent(id + "-diff.png"))
                }
                XCTAssertTrue(matches, "\(id): changed \(changed) pixels (channel >16, maximum 25); \(output.path)")
                rows.append("<section><h2>\(id) — \(matches ? "PASS" : "FAIL") (\(changed) pixels)</h2>" +
                    "<figure><img src='\(id)-expected.png'><figcaption>Reference</figcaption></figure>" +
                    "<figure><img src='\(id)-actual.png'><figcaption>Actual</figcaption></figure>" +
                    (matches ? "" : "<figure><img src='\(id)-diff.png'><figcaption>Changed pixels</figcaption></figure>") + "</section>")
            }
            // Aliases share references, but still construct and assert their own behavioral states.
            for (alias, canonical) in aliases {
                XCTAssertTrue(try rgba(render(alias, light: light)) == images[canonical],
                               "Documented visual alias drifted: \(alias) -> \(canonical)")
            }
        }
        if record {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(try XCTUnwrap(recordedEnvironment)).write(to: metadata)
        }
        let html = "<!doctype html><meta charset='utf-8'><title>VoiceBar snapshots</title><style>body{font:14px system-ui;background:#ddd}figure{display:inline-block;margin:8px}img{max-width:100%;border:1px solid #888}section{border-bottom:1px solid #888}</style><h1>VoiceBar synthetic state catalog</h1><p>Channel threshold: 16/255; maximum changed pixels: 25. References require explicit --record and review. Native click, focus and audio gates remain separate.</p>" + rows.joined(separator: "\n")
        try html.write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private func state(_ name: String, expiry: @escaping () async -> Void) -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            playbackAmplitudeClock: { 100 }, selectionBusyNoteExpiry: expiry, keepsExpandedInDevState: false)
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        switch name {
        case "recording-ptt", "recording-vad", "busy-note":
            state.mode = .recording
            state.recordingMode = name == "recording-ptt" ? "ptt" : "vad"
            if name == "busy-note" { state.speakSelection() }
        case "transcribing": state.mode = .transcribing
        case "hidden", "snoozed": state.snooze(until: name == "snoozed" ? Date(timeIntervalSince1970: 2_000_000_000) : nil)
        case "typed": state.confirmationText = "Typed"
        case "idle": break
        case "speaking", "paused", "teleprompter-expanded", "teleprompter-collapsed",
             "queue-1", "queue-10", "last-item", "paused-controls":
            state.handleEvent(["type": "state", "state": "speaking", "text": "A synthetic sentence for the VoiceBar visual catalog. Every word stays visible.",
                               "request_id": "snapshot-read", "playback_id": "snapshot-player", "generation": 1])
            if name == "queue-1" || name == "queue-10" || name == "last-item" {
                state.handleEvent(["type": "read_queue", "count": name == "queue-1" ? 1 : (name == "queue-10" ? 10 : 0),
                                   "current_request_id": "snapshot-read"])
            }
            if name == "paused" || name == "paused-controls" {
                state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "snapshot-player",
                                   "generation": 2, "offset_ms": 0, "chunk_offset_ms": 0])
                XCTAssertTrue(state.isPlaybackPaused)
            }
            if name != "teleprompter-expanded" && name != "paused" { state.dismissTeleprompter() }
            if name == "paused" || name == "paused-controls" {
                XCTAssertEqual(state.isTeleprompterDismissed, name == "paused-controls")
            }
        default: XCTFail("Unknown snapshot fixture: \(name)")
        }
        if name == "queue-1" || name == "queue-10" {
            XCTAssertNotNil(VoiceBarPresentation.readQueueControl(for: state))
        }
        if name == "last-item" { XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state)) }
        return state
    }

    private func render(_ name: String, light: Bool, canvasHeight: CGFloat? = nil) throws -> NSBitmapImageRep {
        let expiry = AsyncStream<Void>.makeStream()
        defer { expiry.continuation.finish() }
        let state = state(name, expiry: { for await _ in expiry.stream {} })
        let app = NSApplication.shared
        let old = app.appearance
        app.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        defer { app.appearance = old }
        // F13: a paused read keeps its teleprompter open; only the hidden pause fixture is compact.
        let expanded = name == "teleprompter-expanded" || name == "paused"
        let height: CGFloat = canvasHeight ?? (expanded ? 270 : (name == "busy-note" ? 90 : 64))
        let size = CGSize(width: 540, height: height)
        // The real app orders its panel out while snoozed. Model that visibility boundary;
        // BarView alone intentionally does not implement window lifecycle.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let host = NSHostingView(rootView: ZStack(alignment: .top) {
            (light ? Color(red: 0.88, green: 0.89, blue: 0.91) : Color(red: 0.16, green: 0.17, blue: 0.19))
            if !state.isHidden {
                BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {}, includesPanelOutsets: true)
            }
        }.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, light ? .light : .dark)
            .environment(\.visualRenderTime, 0)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.calendar, calendar)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .font(.system(size: 13, weight: .regular, design: .default))
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = app.appearance
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.appearance = app.appearance
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        VLOrderTestWindow(panel)
        defer { panel.contentView = nil; panel.close() }
        let font = NSFont.systemFont(ofSize: 13)
        let environment = [
            "hostModel": hostModel(),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceBackingScale": String(Double(panel.backingScaleFactor)),
            "fontSmoothing": String(describing: UserDefaults.standard.object(forKey: "AppleFontSmoothing")),
            "antialiasingThreshold": String(describing: UserDefaults.standard.object(forKey: "AppleAntiAliasingThreshold")),
            "fontIdentity": "\(font.fontName)|\(font.familyName ?? "unknown")|\(font.pointSize)",
            "textContract": "system-default-13-regular; product absolute system sizes; DynamicType=large; en_US_POSIX; LTR; gregorian; UTC",
            "output": "540pt-wide; 1x RGBA; aqua/darkAqua; visualRenderTime=0"
        ]
        if let expectedEnvironment = referenceEnvironment ?? recordedEnvironment, expectedEnvironment != environment {
            let differences = Set(expectedEnvironment.keys).union(environment.keys).sorted().compactMap { key -> String? in
                guard expectedEnvironment[key] != environment[key] else { return nil }
                return "\(key): expected \(expectedEnvironment[key] ?? "<missing>"), actual \(environment[key] ?? "<missing>")"
            }
            throw XCTSkip("SNAPSHOTS NOT COMPARED — renderer mismatch: " + differences.joined(separator: "; "))
        }
        recordedEnvironment = environment
        // Explicit layout/display flush with animations disabled, then require three
        // consecutive identical source bitmaps. Deadline failure is never a pass.
        let deadline = Date().addingTimeInterval(5)
        var previous: [UInt8]?
        var stable = 0
        var captured: NSBitmapImageRep?
        repeat {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            CATransaction.flush()
            let frame = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            guard frame.pixelsWide == Int(size.width * panel.backingScaleFactor),
                  frame.pixelsHigh == Int(size.height * panel.backingScaleFactor) else {
                throw XCTSkip("SNAPSHOTS NOT COMPARED — bitmap dimensions: expected \(Int(size.width * panel.backingScaleFactor))x\(Int(size.height * panel.backingScaleFactor)), actual \(frame.pixelsWide)x\(frame.pixelsHigh)")
            }
            host.cacheDisplay(in: host.bounds, to: frame)
            let pixels = try rgba(frame)
            stable = previous == pixels ? stable + 1 : 0
            previous = pixels
            captured = frame
            if stable >= 2 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        guard stable >= 2 else {
            XCTFail("Rendered bitmap never stabilized within 5s: \(name)")
            throw NSError(domain: "SnapshotStability", code: 1)
        }
        if name == "busy-note" { XCTAssertNotNil(state.selectionFeedbackNote, "Busy-note expired before capture completed") }
        let image = try XCTUnwrap(captured)
        // Normalize to 1x RGBA so backing-scale metadata cannot change comparison dimensions.
        let normalized = try bitmap(width: Int(size.width), height: Int(size.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: normalized)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return normalized
    }

    private func hostModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes)
    }

    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
    }
    private func rgba(_ image: NSBitmapImageRep) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.pixelsWide, height: image.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: image.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
                                        count: image.pixelsWide * image.pixelsHigh * 4))
    }
    private func difference(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let diff = try bitmap(width: actual.pixelsWide, height: actual.pixelsHigh)
        let a = try rgba(actual), e = try rgba(expected)
        let bytes = try XCTUnwrap(diff.bitmapData)
        for pixel in 0..<(actual.pixelsWide * actual.pixelsHigh) {
            let offset = pixel * 4
            let changed = e.count != a.count || (0..<4).contains { abs(Int(a[offset + $0]) - Int(e[offset + $0])) > 16 }
            bytes[offset] = changed ? 255 : 30
            bytes[offset + 1] = changed ? 0 : 30
            bytes[offset + 2] = changed ? 100 : 30
            bytes[offset + 3] = 255
        }
        return diff
    }
}
