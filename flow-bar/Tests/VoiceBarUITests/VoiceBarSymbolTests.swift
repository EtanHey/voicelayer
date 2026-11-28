import AppKit
import Observation
import OffscreenTestSupport
import SwiftUI
import XCTest
@testable import VoiceBarUI

/// T19 (L67/L68/L69): VoiceBar's custom History symbol and its symbol swaps.
@MainActor
final class VoiceBarSymbolTests: XCTestCase {
    override func tearDown() {
        VoiceBarSymbol.bundle = .main
        super.tearDown()
    }

    // MARK: - L68 custom History symbol

    /// The committed template compiles with the same actool call `build-app.sh` makes, and the compiled catalog serves
    /// a real template symbol, so the History button draws the take loop, not the clock.
    func testHistoryTakeLoopCompilesIntoATemplateSymbolAndReplacesTheClock() throws {
        let bundle = try Self.compiledSymbolBundle()
        VoiceBarSymbol.bundle = bundle

        XCTAssertNil(VoiceBarSymbol.systemName(for: VoiceBarSymbol.history), "the custom symbol must be found")
        let image = try XCTUnwrap(VoiceBarSymbol.nsImage(VoiceBarSymbol.history, accessibilityDescription: "History"))
        XCTAssertTrue(image.isTemplate, "a symbol takes the control's foreground colour")
        let sized = try XCTUnwrap(image.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)))
        // Within a point of the system clock it replaces, so the wing's spacing is unchanged.
        let clock = try XCTUnwrap(NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)))
        XCTAssertEqual(sized.size.width, clock.size.width, accuracy: 1.5)
        XCTAssertEqual(sized.size.height, clock.size.height, accuracy: 1.5)

        let custom = try Self.ink(of: VoiceBarSymbol.image(VoiceBarSymbol.history))
        let system = try Self.ink(of: Image(systemName: "clock.arrow.circlepath"))
        XCTAssertGreaterThan(custom.count, 60, "the take loop draws ink at notch size")
        let differing = custom.symmetricDifference(system).count
        XCTAssertGreaterThan(differing, 40, "the History button must draw the take loop, not the clock")
    }

    /// Without the compiled catalog (swift test, a dev binary) the History control still draws, as the clock.
    func testMissingCatalogFallsBackToTheSystemClock() throws {
        VoiceBarSymbol.bundle = Bundle(for: Self.self)
        XCTAssertEqual(VoiceBarSymbol.systemName(for: VoiceBarSymbol.history), "clock.arrow.circlepath")
        XCTAssertEqual(VoiceBarSymbol.systemName(for: "gearshape"), "gearshape")
        XCTAssertNotNil(VoiceBarSymbol.nsImage(VoiceBarSymbol.history, accessibilityDescription: nil))
        let fallback = try Self.ink(of: VoiceBarSymbol.image(VoiceBarSymbol.history))
        let clock = try Self.ink(of: Image(systemName: "clock.arrow.circlepath"))
        XCTAssertEqual(fallback, clock)
    }

    // MARK: - L67/L69 swaps

    func testSwapsFadeOnlyUnderReduceMotion() {
        XCTAssertEqual(VoiceBarSymbolMotion.swap(reduceMotion: true), .opacity)
        XCTAssertEqual(VoiceBarSymbolMotion.copyConfirmation(reduceMotion: true), .opacity)
        XCTAssertEqual(VoiceBarSymbolMotion.swap(reduceMotion: false), .symbolEffect(.replace))
        XCTAssertNotEqual(VoiceBarSymbolMotion.copyConfirmation(reduceMotion: false), .opacity)
    }

    /// A setup step bounces once when it becomes done; never on the way out, never twice, never with Reduce Motion.
    func testSetupMarkBouncesOnlyOnArrivalAtDone() {
        typealias Kind = SettingsSetupMark.Kind
        XCTAssertTrue(SettingsSetupMark.bouncesOnChange(from: .attention, to: .done, reduceMotion: false))
        XCTAssertTrue(SettingsSetupMark.bouncesOnChange(from: .pending, to: .done, reduceMotion: false))
        XCTAssertFalse(SettingsSetupMark.bouncesOnChange(from: .done, to: .done, reduceMotion: false))
        XCTAssertFalse(SettingsSetupMark.bouncesOnChange(from: .done, to: .attention, reduceMotion: false))
        XCTAssertFalse(SettingsSetupMark.bouncesOnChange(from: .attention, to: .pending, reduceMotion: false))
        XCTAssertFalse(SettingsSetupMark.bouncesOnChange(from: .attention, to: .done, reduceMotion: true))
    }

    /// L69: the Copy glyph turns into the tick over several frames (the replace effect). On main it teleported: the
    /// first frame after the copy already showed the finished tick, with no frame in between.
    func testCopyTickReplacesTheGlyphOverSeveralFrames() throws {
        let restore = ReduceMotionOverride.pin(false)
        defer { restore() }
        let box = CopyFeedbackBox()
        let host = NSHostingView(rootView: CopyFeedbackHarness(box: box))
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = try Self.pixels(host)

        box.feedback.copied(succeeded: true, byPointer: true, at: Date())
        var frames: [[UInt8]] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 0.6 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            frames.append(try Self.pixels(host))
        }
        let after = try XCTUnwrap(frames.last)
        XCTAssertNotEqual(before, after, "the tick must be showing at the end")
        let between = Set(frames.filter { $0 != before && $0 != after }.map { $0.hashValue })
        XCTAssertGreaterThanOrEqual(between.count, 3,
                                    "the tick must arrive through intermediate frames, not in one swap")
    }

    /// Every symbol swap goes through `VoiceBarSymbolMotion`, so none moves under Reduce Motion (the three notch
    /// swaps used a bare `.symbolEffect(.replace)` that scaled and offset the glyph with Reduce Motion on), and the
    /// History glyph is drawn through `VoiceBarSymbol` wherever the notch draws it.
    func testSymbolSwapsAndHistoryGlyphsGoThroughTheSharedHelpers() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI")
        var bareSwaps: [String] = []
        var bareHistory: [String] = []
        let notchFiles: Set = ["BarView.swift", "VoiceBarNotchFeedback.swift"]
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                if line.contains(".contentTransition(.symbolEffect"), file != "VoiceBarSymbol.swift" {
                    bareSwaps.append("\(file):\(index + 1)")
                }
                if notchFiles.contains(file), line.contains("\"clock.arrow.circlepath\"") {
                    bareHistory.append("\(file):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(bareSwaps, [], "use VoiceBarSymbolMotion.swap/copyConfirmation(reduceMotion:)")
        XCTAssertEqual(bareHistory, [], "draw History through VoiceBarSymbol.history")
    }

    /// The production launcher, read back from the window server: its History button draws the take loop from the
    /// compiled catalog (the app's path), and the clock when the catalog is absent. The two band pictures differ only
    /// in the History glyph. VOICEBAR_W2_SHOTS=<directory> writes both as PNGs (the PR's before/after).
    func testTheLauncherHistoryButtonDrawsTheTakeLoop() throws {
        let restore = ReduceMotionOverride.pin(true)
        defer { restore() }
        VoiceBarSymbol.bundle = Bundle(for: Self.self)
        let clock = try Self.launcherShot()
        VoiceBarSymbol.bundle = try Self.compiledSymbolBundle()
        let takeLoop = try Self.launcherShot()
        if let directory = ProcessInfo.processInfo.environment["VOICEBAR_W2_SHOTS"] {
            for (name, image) in [("history-glyph-before-clock", clock), ("history-glyph-after-take-loop", takeLoop)] {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
        let a = NSBitmapImageRep(cgImage: clock), b = NSBitmapImageRep(cgImage: takeLoop)
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        var differing: [Int] = []
        for y in 0 ..< min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0 ..< a.pixelsWide {
                let p = a.colorAt(x: x, y: y)!, q = b.colorAt(x: x, y: y)!
                if abs(p.brightnessComponent - q.brightnessComponent) > 0.25 { differing.append(x) }
            }
        }
        XCTAssertGreaterThan(differing.count, 30, "the History glyph must change")
        // Only the History slot changes: right of the core, inside the right wing.
        let centre = a.pixelsWide / 2
        XCTAssertTrue(differing.allSatisfy { $0 > centre }, "nothing but the right wing's History glyph changes")
    }

    private static func launcherShot() throws -> CGImage {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               keepsExpandedInDevState: false)
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        let model = VoiceBarNotchPresentationModel()
        let bar = BarView(state: state, commandRouter: ShotRouter(), onOpenSettings: {}, onOpenHistory: {},
                          presentationModel: model, includesPanelOutsets: true)
        let size = CGSize(width: 540, height: 60)
        let host = NSHostingView(rootView: AnyView(ZStack(alignment: .top) { Color(white: 0.42); bar }
            .frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, .dark)))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.backgroundColor = NSColor(white: 0.42, alpha: 1)
        window.hasShadow = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        VLOrderCompositorTestWindow(window)
        defer { window.orderOut(nil); window.contentView = nil }
        state.isHovering = true
        model.setHovered(true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let lookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(lookup, "CGWindowListCreateImage") else { throw XCTSkip("no window capture") }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        return try XCTUnwrap(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                     UInt32(window.windowNumber), options.rawValue)?.takeRetainedValue())
    }

    // MARK: - Helpers

    /// Compiles the committed catalog exactly as `build-app.sh` does into a throwaway bundle.
    static func compiledSymbolBundle() throws -> Bundle {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Symbols/VoiceBarSymbols.xcassets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalog.path), "missing \(catalog.path)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebar-symbols-\(UUID().uuidString)/Symbols.bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.voicelayer.symbols-test", "CFBundlePackageType": "BNDL"]
        try (plist as NSDictionary).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let actool = Process()
        actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        actool.arguments = ["actool", catalog.path, "--compile", resources.path, "--platform", "macosx",
                            "--minimum-deployment-target", "14.0", "--output-partial-info-plist",
                            root.deletingLastPathComponent().appendingPathComponent("partial.plist").path,
                            "--errors", "--warnings", "--output-format", "human-readable-text"]
        let log = Pipe()
        actool.standardOutput = log
        actool.standardError = log
        try actool.run()
        actool.waitUntilExit()
        let output = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(actool.terminationStatus, 0, output)
        XCTAssertFalse(output.contains("error:"), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("Assets.car").path), output)
        return try XCTUnwrap(Bundle(url: root))
    }

    /// The set of inked pixel positions of `image` drawn at the notch's 12 pt medium.
    static func ink(of image: Image) throws -> Set<Int> {
        let renderer = ImageRenderer(content: image.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.black).frame(width: 20, height: 20))
        renderer.scale = 2
        let cg = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: cg)
        var inked = Set<Int>()
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inked.insert(y * rep.pixelsWide + x)
            }
        }
        return inked
    }

    static func pixels(_ host: NSView) throws -> [UInt8] {
        let rep = try EtanQA0510Tests.fixedScaleBitmap(host, scale: 2)
        let data = try XCTUnwrap(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }
}

private final class ShotRouter: BarCommandRouting {
    func handlePrimaryTap() {}
    func handleCancel() {}
    func handleStop() {}
    func handleReplay() {}
    func handleRetranscribeHistoryEntry(recordingPath: String) {}
}

@Observable
private final class CopyFeedbackBox {
    var feedback = CopyFeedback()
}

private struct CopyFeedbackHarness: View {
    let box: CopyFeedbackBox

    var body: some View {
        CopyFeedbackButton("Copy", feedback: Binding(get: { box.feedback }, set: { box.feedback = $0 }),
                           foreground: .black, copy: { true })
            .frame(width: 40, height: 40)
            .background(Color.white)
    }
}
