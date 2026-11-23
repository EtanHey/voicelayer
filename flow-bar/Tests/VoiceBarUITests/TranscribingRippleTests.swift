import AppKit
import OffscreenTestSupport
import ObjectiveC
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Live recording colour and clock-allocation contracts retained after removing the transcribing ripple.
@MainActor
final class TranscribingRippleTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    /// The deterministic render clock used by the recording meter.
    private final class RenderClock: ObservableObject {
        @Published var time: Double = 100
    }

    private struct Harness: View {
        @ObservedObject var clock: RenderClock
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
        let reduceMotion: Bool?
        var scheme: ColorScheme = .dark

        var body: some View {
            // The app's shape (WingsU2ShotsTests): a presentation model and the panel outsets, so the wings render.
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, scheme)
                .environment(\.visualRenderTime, clock.time)
                .environment(\.voiceBarReduceMotionOverride, reduceMotion)
        }
    }

    private struct Mounted {
        let host: NSHostingView<Harness>
        let window: NSWindow
        let clock: RenderClock
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
    }

    func testANewTakeStartsRedWhileAnEarlierTakeStillProcesses() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        startRecording(mounted)
        send(mounted, ["type": "state", "state": "transcribing"])
        advance(mounted, by: 1)
        send(mounted, ["type": "state", "state": "recording", "mode": "ptt", "mic_take_id": "B",
            "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                               ["take_id": "B", "kind": "live", "phase": "capturing"]]])
        XCTAssertEqual(mounted.state.processingTakeCount, 1, "take A is still processing")
        send(mounted, ["type": "audio_level", "rms": 0.45])
        advance(mounted, by: 0.016)
        let meter = try frame("Input level", in: mounted.host)
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isRed).count, WaveformLayout.barCount,
                       "take B's meter is red at once")
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isBlueInk).count, 0,
                       "no blue rides into take B")
    }

    func testTranscribingMountsNoRecordingClock() throws {
        var calls = 0
        let mounted = try mount(recordingClock: { calls += 1; return 100 })
        defer { unmount(mounted) }
        startRecording(mounted)
        XCTAssertGreaterThan(calls, 0, "recording exercises the real clock")
        send(mounted, ["type": "state", "state": "transcribing"])
        advance(mounted, by: 1)
        calls = 0
        for _ in 0..<3 { advance(mounted, by: 0.3) }
        XCTAssertEqual(calls, 0, "transcribing must not sample the capture clock")
        XCTAssertFalse(elements(mounted.host).contains { $0.label == "Recording time" }, "no mounted clock in the transcribing band")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        let gate = try XCTUnwrap(source.components(separatedBy: "private var showsRecordingMeterRow: Bool").last)
            .components(separatedBy: "private var recordingMeterRow")[0]
        XCTAssertTrue(gate.contains("case .recording: true"))
        XCTAssertTrue(gate.contains("case .compactStatus: false"), "transcribing cannot mount the clock/TimelineView row")
    }

    private func mount(reduceMotion: Bool? = false, appearance: NSAppearance.Name = .darkAqua,
                       recordingClock: (() -> TimeInterval)? = nil) throws -> Mounted {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let app = NSApplication.shared
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        guard app.responds(to: setter) else { throw XCTSkip("Offscreen SwiftUI AX must be available") }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(app.method(for: setter), to: Setter.self)(app, setter, true)
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            keepsExpandedInDevState: false
        )
        state.sendCommand = { _ in }
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        if let recordingClock { state.recordingTimingClock = recordingClock }
        let clock = RenderClock()
        let model = VoiceBarNotchPresentationModel()
        let host = NSHostingView(rootView: Harness(clock: clock, state: state, model: model,
                                                   reduceMotion: reduceMotion,
                                                   scheme: appearance == .aqua ? .light : .dark))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        // The wings' glass only reaches the compositor (cacheDisplay draws them empty), so these windows are captured
        // from the window server like ReadQueueShotsTests' processing shots.
        VLOrderCompositorTestWindow(window)
        let mounted = Mounted(host: host, window: window, clock: clock, state: state, model: model)
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
            recordingTrailingWingWidth: isRecording ? resolved.geometry.trailingWingWidth : nil,
            holdsRecordingWings: false // transcribing now has its own navigation envelope
        )
        settle(mounted.host)
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

    private func startRecording(_ mounted: Mounted) {
        send(mounted, ["type": "state", "state": "recording", "mode": "ptt"])
        send(mounted, ["type": "audio_level", "rms": 0.45])
        advance(mounted, by: 0.5)
    }

    private func advance(_ mounted: Mounted, by seconds: Double) {
        mounted.clock.time += seconds
        settle(mounted.host)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
    }

    // SwiftUI AccessibilityNode implements the AX selectors without declaring NSAccessibilityProtocol.
    private struct AX {
        let object: NSObject
        var label: String? { object.value(forKey: "accessibilityLabel") as? String }
        var role: String? { object.value(forKey: "accessibilityRole") as? String }
        var value: Any? { object.value(forKey: "accessibilityValue") }
        var frame: CGRect { (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var children: [Any] { object.value(forKey: "accessibilityChildren") as? [Any] ?? [] }
    }

    private func elements(_ root: Any, depth: Int = 0) -> [AX] {
        guard depth < 30, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return [] }
        let node = AX(object: object)
        return [node] + node.children.flatMap { elements($0, depth: depth + 1) }
    }

    private func staticTexts(_ host: NSView) -> [String] {
        elements(host).filter { $0.role == NSAccessibility.Role.staticText.rawValue }
            .map { "\($0.label ?? "")|\($0.value.map { "\($0)" } ?? "")" }
    }

    private func hasStaticText(_ host: NSView) -> Bool { !staticTexts(host).isEmpty }

    private func localFrame(_ element: AX, in host: NSView) -> CGRect {
        host.convert(host.window!.convertFromScreen(element.frame), from: nil)
    }

    private func frame(_ label: String, in host: NSView) throws -> CGRect {
        let element = try XCTUnwrap(elements(host).first { $0.label == label },
                                    "Missing \(label); AX: \(elements(host).compactMap(\.label))")
        let rect = localFrame(element, in: host)
        XCTAssertGreaterThan(rect.width, 0)
        return rect
    }

    // MARK: - Pixels

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func isRed(_ c: RGB) -> Bool { c.r > 170 && c.r - c.g > 80 && c.r - c.b > 80 }
    private static func isRippleBlue(_ c: RGB) -> Bool { c.b > 215 && c.g > 170 && c.b - c.r > 50 }
    /// Any of the ripple's blue over the dark wing, dimmed included (Reduce Motion breathes down to 70 %).
    private static func isBlueInk(_ c: RGB) -> Bool { c.b > 110 && c.b - c.r > 30 }
    /// Half-way between #E54D4D and #A3D7FF is about (196, 146, 166): neither red nor blue.
    private static func isMidHandOver(_ c: RGB) -> Bool {
        abs(c.r - 196) < 30 && abs(c.g - 146) < 30 && abs(c.b - 166) < 30
    }

    private func bitmap(_ host: NSView) throws -> NSBitmapImageRep {
        let window = try XCTUnwrap(host.window)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let lookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(lookup, "CGWindowListCreateImage") else {
            throw XCTSkip("CGWindowListCreateImage is unavailable")
        }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let image = try XCTUnwrap(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                          UInt32(window.windowNumber),
                                          CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution).rawValue)?
            .takeRetainedValue(), "the compositor returned no image of the test window")
        return NSBitmapImageRep(cgImage: image)
    }

    /// The rect in bitmap pixels (top-left origin).
    private func pixelRect(_ rect: CGRect, host: NSView, rep: NSBitmapImageRep) -> (x: Range<Int>, y: Range<Int>) {
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((top * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh, Int(((top + rect.height) * scale).rounded(.up)))
        return (x0 ..< max(x0, x1), y0 ..< max(y0, y1))
    }

    private func colour(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> RGB {
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    /// Centres (in pixels) of each run of columns holding at least one matching pixel.
    private func barColumns(in rect: CGRect, of host: NSView, matching match: (RGB) -> Bool) throws -> [Double] {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        var runs: [Double] = []
        var start: Int?
        for x in area.x {
            let ink = area.y.contains { match(colour(rep, x, $0)) }
            if ink, start == nil { start = x }
            if !ink, let s = start { runs.append(Double(s + x - 1) / 2); start = nil }
        }
        if let s = start { runs.append(Double(s + area.x.upperBound - 1) / 2) }
        return runs
    }

    /// Each blue bar's height in pixels (the tallest matching run in its columns), left to right.
    private func barHeights(in rect: CGRect, of host: NSView) throws -> [Int] {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        var heights: [Int] = []
        var current = 0
        var inBar = false
        for x in area.x {
            let count = area.y.filter { Self.isBlueInk(colour(rep, x, $0)) }.count
            if count > 0 { current = max(current, count); inBar = true }
            if count == 0, inBar { heights.append(current); current = 0; inBar = false }
        }
        if inBar { heights.append(current) }
        return heights
    }

    /// The bars' ink (median of each column's brightest-blue pixel, bar centres only) and the wing just outside
    /// the meter, both from the render.
    private func barInk(in rect: CGRect, of host: NSView) throws -> (ink: RGB, background: RGB) {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let background = colour(rep, max(0, area.x.lowerBound - Int(10 * scale)), (area.y.lowerBound + area.y.upperBound) / 2)
        // Per column, the blue pixel that stands out most from the wing (a bar's core, not its glow or edge); then the
        // upper quartile across columns, so gaps and anti-aliased edges do not decide it.
        var cores: [(RGB, Double)] = []
        for x in area.x {
            let column = area.y.map { colour(rep, x, $0) }.filter { $0.b - $0.r > 30 }
            if let best = column.max(by: { Self.contrast($0, background) < Self.contrast($1, background) }) {
                cores.append((best, Self.contrast(best, background)))
            }
        }
        let sorted = cores.sorted { $0.1 < $1.1 }
        let ink = sorted.isEmpty ? (r: 0, g: 0, b: 0) : sorted[sorted.count * 3 / 4].0
        return (ink, background)
    }

    private func coreColour(in rect: CGRect, of host: NSView) throws -> String {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        var best: RGB = (0, 0, 0)
        for x in area.x { for y in area.y {
            let c = colour(rep, x, y)
            if c.b - c.r > best.b - best.r { best = c }
        } }
        return String(format: "(%.0f, %.0f, %.0f)", best.r, best.g, best.b)
    }

    private func backgroundColour(beside rect: CGRect, of host: NSView) throws -> String {
        let rep = try bitmap(host)
        let area = pixelRect(rect.offsetBy(dx: -rect.width / 2 - 4, dy: 0).insetBy(dx: rect.width / 4, dy: 4),
                             host: host, rep: rep)
        let x = (area.x.lowerBound + area.x.upperBound) / 2, y = (area.y.lowerBound + area.y.upperBound) / 2
        let c = colour(rep, x, y)
        return String(format: "(%.0f, %.0f, %.0f)", c.r, c.g, c.b)
    }

    private func shot(_ mounted: Mounted, _ name: String, into directory: URL) throws {
        let rep = try bitmap(mounted.host)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Colour maths (WCAG 2.x relative luminance)

    private func rgb(_ color: Color) throws -> RGB {
        let c = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    private static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hue(_ c: RGB) -> Double {
        let r = c.r / 255, g = c.g / 255, b = c.b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        let h: Double = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }
}
