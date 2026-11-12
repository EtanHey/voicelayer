import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// c11-Q (Etan, 2026-11-12 23:40 IST, after candidate 10): the transcribing spinner "actually more blue" and plainly
/// more present, where candidate 9 had it; and the clock already at `0:00` while the mic opens, so the lane between
/// the meter and the notch is never empty. Measured on the real `BarView` rendered offscreen at 2x (not the glass
/// material: neither this host nor the M1 renders it). This file uses only API that candidate 9 already had, so the
/// same tests run against candidate 9's sources as the fail-first receipt. Set `VOICEBAR_C11Q_SHOTS_DIR` to also
/// write the frames as PNGs.
@MainActor
final class TranscribingSpinnerRenderTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private struct Pixel { let r, g, b: Double }
    private struct Image {
        let width: Int
        let height: Int
        let pixels: [Pixel]
        func at(_ x: Int, _ y: Int) -> Pixel { pixels[y * width + x] }
    }
    private struct Box {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
        mutating func add(_ x: Int, _ y: Int) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
        }
        var width: Int { count == 0 ? 0 : maxX - minX + 1 }
        var height: Int { count == 0 ? 0 : maxY - minY + 1 }
        var midX: Double { count == 0 ? 0 : (Double(minX) + Double(maxX)) / 2 }
        var midY: Double { count == 0 ? 0 : (Double(minY) + Double(maxY)) / 2 }
    }

    /// The capture is at the display's backing scale (2x on every Mac this runs on).
    private static let scale = 2.0
    /// The M4's grey glass behind the wings as recorded on 2026-11-12 (c9-P report; the brief's 1.27:1 figure).
    private static let m4Glass = Pixel(r: 106.3 / 255, g: 114.8 / 255, b: 125.0 / 255)

    // MARK: - Spinner

    /// The arc's core is a saturated blue (HSV saturation ≥ 0.72, hue 205-217°) in both appearances and reads ≥ 3:1
    /// against the pill right behind it. Candidate 9's #4A90D9 is 0.66 saturated and 1.7:1 on the light wing.
    func testTranscribingSpinnerIsASaturatedBlueThatHoldsThreeToOneOnItsPill() throws {
        for scheme in ["dark", "light"] {
            let mounted = try transcribing(scheme)
            defer { unmount(mounted) }
            let image = try capture(mounted, shot: "spinner-\(scheme)")
            let core = try XCTUnwrap(arcCore(image), "\(scheme): no blue arc found")
            let (hue, saturation) = Self.hueSaturation(core)
            let pill = try pillBehindSpinner(image)
            let onPill = Self.contrast(core, pill)
            let onM4 = Self.contrast(core, Self.m4Glass)
            print(String(format: "C11Q spinner %@ core (%.0f,%.0f,%.0f) hue %.1f sat %.2f pill (%.0f,%.0f,%.0f) %.2f:1 "
                + "M4-grey %.2f:1", scheme, core.r * 255, core.g * 255, core.b * 255, hue, saturation,
                pill.r * 255, pill.g * 255, pill.b * 255, onPill, onM4))
            XCTAssertGreaterThanOrEqual(saturation, 0.72, "\(scheme): the arc must read as BLUE, not pale or grey-blue")
            XCTAssertTrue((205.0 ... 217.0).contains(hue), "\(scheme): the processing hue, got \(hue)")
            XCTAssertGreaterThanOrEqual(onPill, 3, "\(scheme): arc on its own pill \(onPill):1")
        }
    }

    /// More present: a full faint ring under the arc, and the ink fills more of the 20 pt slot (≥ 17 pt; candidate
    /// 9's arc was 16.2 pt at most) without leaving it.
    func testTranscribingSpinnerInkIsLargerAndAFullRingWithinItsSlot() throws {
        for scheme in ["dark", "light"] {
            let mounted = try transcribing(scheme)
            defer { unmount(mounted) }
            let image = try capture(mounted)
            let ink = blueBox(image, minimumBlueOverRed: 0.12)
            let slot = VoiceBarNotchContract.material.compactControlSize * Self.scale
            print("C11Q spinner \(scheme) ink \(ink.width)x\(ink.height) px (slot \(slot) px)")
            XCTAssertGreaterThanOrEqual(Double(ink.width), 17 * Self.scale, "\(scheme): ink width")
            XCTAssertGreaterThanOrEqual(Double(ink.height), 17 * Self.scale, "\(scheme): ink height")
            XCTAssertLessThanOrEqual(Double(ink.width), slot, "\(scheme): stays inside its slot")
            XCTAssertEqual(Double(ink.width), Double(ink.height), accuracy: 2, "\(scheme): a full ring, not a partial arc")
        }
    }

    /// Where candidate 9 had it: one control pitch left of the microphone chevron, on the same centre line.
    func testTranscribingSpinnerSitsOneControlPitchLeftOfTheChevron() throws {
        let mounted = try transcribing("dark")
        defer { unmount(mounted) }
        let image = try capture(mounted)
        let ink = blueBox(image, minimumBlueOverRed: 0.12)
        var chevron = Box()
        for y in 0 ..< image.height {
            for x in 0 ..< image.width / 2 {
                let p = image.at(x, y)
                if min(p.r, p.g, p.b) > 0.75 { chevron.add(x, y) }
            }
        }
        XCTAssertGreaterThan(chevron.count, 0, "chevron glyph")
        let pitch = (VoiceBarNotchContract.material.compactControlSize
            + VoiceBarNotchContract.material.compactControlSpacing) * Self.scale
        print("C11Q spinner centre (\(ink.midX), \(ink.midY)) chevron centre (\(chevron.midX), \(chevron.midY)) pitch \(pitch)")
        XCTAssertEqual(chevron.midX - ink.midX, Double(pitch), accuracy: 2.5)
        XCTAssertEqual(chevron.midY, ink.midY, accuracy: 2.5)
    }

    // MARK: - Arming clock

    /// While the mic opens the right wing shows the clock at 0:00 (quieter than the live clock) left of the grey
    /// dots; when capture opens the live 0:00 takes exactly the same pixels' box, brighter. Candidate 9 drew nothing
    /// there.
    func testArmingShowsAQuietZeroClockThatTurnsLiveInPlace() throws {
        let mounted = try arming("dark")
        defer { unmount(mounted) }
        XCTAssertEqual(mounted.state.mode, .recording)
        XCTAssertFalse(mounted.state.isRecordingCaptureOpen)
        let arming = try capture(mounted, shot: "arming-dark")
        let armingClock = try XCTUnwrap(clockCluster(arming), "arming: the lane between the notch and the meter is empty")

        send(mounted, ["type": "audio_level", "rms": 0.3])
        XCTAssertTrue(mounted.state.isRecordingCaptureOpen)
        XCTAssertEqual(mounted.state.recordingElapsedMilliseconds(), 0)
        let live = try capture(mounted, shot: "live-dark")
        let liveClock = try XCTUnwrap(clockCluster(live), "live clock")
        print("C11Q clock arming x \(armingClock.box.minX)-\(armingClock.box.maxX) y \(armingClock.box.minY)-\(armingClock.box.maxY) "
            + "peak \(armingClock.peak) | live x \(liveClock.box.minX)-\(liveClock.box.maxX) "
            + "y \(liveClock.box.minY)-\(liveClock.box.maxY) peak \(liveClock.peak)")
        XCTAssertEqual(armingClock.box.minX, liveClock.box.minX, accuracy: 1, "no shift at the switch")
        XCTAssertEqual(armingClock.box.maxX, liveClock.box.maxX, accuracy: 1, "no shift at the switch")
        XCTAssertEqual(armingClock.box.minY, liveClock.box.minY, accuracy: 1, "no shift at the switch")
        XCTAssertLessThan(armingClock.peak, liveClock.peak - 0.08, "arming is quieter than the live clock")
    }

    /// The arming 0:00 is a constant: the region never asks for elapsed time before capture opens.
    func testTheTimeRegionNeverReadsTheClockBeforeCaptureOpens() throws {
        var reads = 0
        let region = VoiceBarRecordingTimeRegion(elapsedMilliseconds: { reads += 1; return 0 }, isCaptureOpen: false,
                                                 microphoneName: nil, color: .white)
        try render(region.frame(width: 60, height: 20).background(Color.black), size: CGSize(width: 60, height: 20),
                   scheme: "dark")
        XCTAssertEqual(reads, 0, "arming must not read the recording clock")
    }

    // MARK: - Shots (opt-in)

    func testWriteShotsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["VOICEBAR_C11Q_SHOTS_DIR"]?.isEmpty == false else {
            throw XCTSkip("Set VOICEBAR_C11Q_SHOTS_DIR to write the c11-Q frames")
        }
        for scheme in ["light", "dark"] {
            let spinner = try transcribing(scheme)
            _ = try capture(spinner, shot: "spinner-\(scheme)")
            unmount(spinner)
            let mounted = try arming(scheme)
            _ = try capture(mounted, shot: "arming-\(scheme)")
            send(mounted, ["type": "audio_level", "rms": 0.3])
            _ = try capture(mounted, shot: "live-\(scheme)")
            unmount(mounted)
        }
    }

    // MARK: - Measurements

    /// The most saturated blue pixel: the arc's full-opacity core.
    private func arcCore(_ image: Image) -> Pixel? {
        var best: Pixel?
        var bestScore = 0.25
        for p in image.pixels where p.b - p.r > bestScore && p.b >= p.g {
            bestScore = p.b - p.r
            best = p
        }
        return best
    }

    private func blueBox(_ image: Image, minimumBlueOverRed: Double) -> Box {
        var box = Box()
        for y in 0 ..< image.height {
            for x in 0 ..< image.width / 2 {
                let p = image.at(x, y)
                if p.b - p.r > minimumBlueOverRed, p.b >= p.g { box.add(x, y) }
            }
        }
        return box
    }

    /// The pill at the spinner's centre (inside the ring, where nothing is drawn).
    private func pillBehindSpinner(_ image: Image) throws -> Pixel {
        let box = blueBox(image, minimumBlueOverRed: 0.25)
        try XCTSkipIf(box.count == 0, "no arc")
        return image.at(Int(box.midX.rounded()), Int(box.midY.rounded()))
    }

    /// The leftmost run of light (grey or white, not red) columns right of the notch: the clock lane's ink. nil when
    /// nothing as wide as a clock is there (candidate 9's arming lane is empty; its grey dots are 3 pt each).
    private func clockCluster(_ image: Image) -> (box: Box, peak: Double)? {
        var columns: [Int: (Box, Double)] = [:]
        for y in 0 ..< image.height {
            for x in image.width / 2 ..< image.width {
                let p = image.at(x, y)
                let lightness = min(p.r, p.g, p.b)
                if lightness > 0.35, max(p.r, p.g, p.b) - lightness < 0.12 {
                    var entry = columns[x] ?? (Box(), 0)
                    entry.0.add(x, y)
                    entry.1 = max(entry.1, lightness)
                    columns[x] = entry
                }
            }
        }
        let xs = columns.keys.sorted()
        var clusters: [[Int]] = []
        for x in xs {
            if let last = clusters.last?.last, x - last <= 8 { clusters[clusters.count - 1].append(x) } else { clusters.append([x]) }
        }
        // Glyph gaps are under 8 px at 2x; the time-to-meter gap is 8 pt. The clock is the leftmost cluster at least
        // as wide as a "0:00" at 11 pt (about 25 pt); a meter dot is 3 pt.
        // Digits are about 8 pt tall at 11 pt; the meter's dots are 3 pt, so the box must be at least 12 px tall too.
        guard let first = clusters.first, let last = first.last, last - first[0] >= 36 else { return nil }
        var box = Box()
        var peak = 0.0
        for x in first {
            let (b, p) = columns[x]!
            box.add(b.minX, b.minY); box.add(b.maxX, b.maxY)
            peak = max(peak, p)
        }
        return box.height >= 12 ? (box, peak) : nil
    }

    // MARK: - Colour maths (WCAG 2.x)

    private static func luminance(_ p: Pixel) -> Double {
        func lin(_ s: Double) -> Double { s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(p.r) + 0.7152 * lin(p.g) + 0.0722 * lin(p.b)
    }

    private static func contrast(_ a: Pixel, _ b: Pixel) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hueSaturation(_ p: Pixel) -> (Double, Double) {
        let mx = max(p.r, p.g, p.b), mn = min(p.r, p.g, p.b), d = mx - mn
        guard d > 0, mx > 0 else { return (0, 0) }
        let h: Double = mx == p.r ? (p.g - p.b) / d : mx == p.g ? 2 + (p.b - p.r) / d : 4 + (p.r - p.g) / d
        return ((h * 60 + 360).truncatingRemainder(dividingBy: 360), d / mx)
    }

    // MARK: - Harness (c9-P's: the production BarView, captured from the window server, since cacheDisplay draws the
    // wings empty)

    private final class RenderClock: ObservableObject {
        @Published var time: Double = 1.25
    }

    private struct Harness: View {
        @ObservedObject var clock: RenderClock
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
        let scheme: ColorScheme

        var body: some View {
            BarView(state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, scheme)
                .environment(\.visualRenderTime, clock.time)
        }
    }

    private struct Mounted {
        let host: NSHostingView<Harness>
        let window: NSWindow
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
        let scheme: String
    }

    private func makeState() -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            keepsExpandedInDevState: false
        )
        state.sendCommand = { _ in }
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        return state
    }

    private func mount(_ state: VoiceState, scheme: String) throws -> Mounted {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let appearance = NSAppearance(named: scheme == "light" ? .aqua : .darkAqua)
        let model = VoiceBarNotchPresentationModel()
        let host = NSHostingView(rootView: Harness(clock: RenderClock(), state: state, model: model,
                                                   scheme: scheme == "light" ? .light : .dark))
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        VLOrderCompositorTestWindow(window)
        let mounted = Mounted(host: host, window: window, state: state, model: model, scheme: scheme)
        sync(mounted)
        return mounted
    }

    /// The app's one feed from VoiceState into the presentation model (`refreshNotchPresentationModel`).
    private func sync(_ mounted: Mounted) {
        let state = mounted.state
        let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
            showsRecordingPause: state.mode == .recording && state.recordingMode == "ptt",
            isCollapsed: false,
            showsEarlierTakeProcessing: VoiceBarPresentation.showsEarlierTakeProcessing(for: state)
        ))
        let isStatus = resolved.visualState == .compactStatus
        let isRecording = resolved.visualState == .recording
        mounted.model.updateOperationalEnvelope(
            hasTeleprompter: false, isRecording: isRecording, hasCompactStatus: isStatus,
            compactStatusLeadingWingWidth: isStatus ? resolved.geometry.leadingWingWidth : nil,
            compactStatusTrailingWingWidth: isStatus ? resolved.geometry.trailingWingWidth : nil,
            recordingLeadingWingWidth: isRecording ? resolved.geometry.leadingWingWidth : nil,
            recordingTrailingWingWidth: isRecording ? resolved.geometry.trailingWingWidth : nil
        )
        mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        mounted.host.layoutSubtreeIfNeeded()
    }

    private func send(_ mounted: Mounted, _ event: [String: Any]) {
        mounted.state.handleEvent(event)
        sync(mounted)
    }

    private func unmount(_ mounted: Mounted) {
        mounted.window.orderOut(nil)
        mounted.window.contentView = nil
        mounted.window.close()
    }

    private func transcribing(_ scheme: String) throws -> Mounted {
        let mounted = try mount(makeState(), scheme: scheme)
        send(mounted, ["type": "state", "state": "transcribing"])
        return mounted
    }

    private func arming(_ scheme: String) throws -> Mounted {
        let state = makeState()
        state.recordingTimingClock = { 10.0 }
        let mounted = try mount(state, scheme: scheme)
        send(mounted, ["type": "state", "state": "recording", "mode": "ptt"])
        return mounted
    }

    /// Captures the window from the window server and redraws it into an sRGB RGBA8 buffer.
    private func capture(_ mounted: Mounted, shot: String? = nil) throws -> Image {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let lookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(lookup, "CGWindowListCreateImage") else {
            throw XCTSkip("CGWindowListCreateImage is unavailable")
        }
        let grab = unsafeBitCast(symbol, to: Capture.self)
        let cg = try XCTUnwrap(grab(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                    UInt32(mounted.window.windowNumber),
                                    CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution).rawValue)?
            .takeRetainedValue(), "the compositor returned no image of the test window")
        if let shot, let dir = ProcessInfo.processInfo.environment["VOICEBAR_C11Q_SHOTS_DIR"], !dir.isEmpty {
            let directory = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(shot).png"), options: .atomic)
        }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var pixels: [Pixel] = []
        pixels.reserveCapacity(width * height)
        for i in 0 ..< width * height {
            pixels.append(Pixel(r: Double(bytes[i * 4]) / 255, g: Double(bytes[i * 4 + 1]) / 255,
                                b: Double(bytes[i * 4 + 2]) / 255))
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    private func render(_ view: some View, size: CGSize, scheme: String) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == "light" ? .aqua : .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        window.contentView = nil
        window.close()
    }
}
