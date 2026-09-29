import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// UXP-4 parity: the popover's content as the status item now hosts it (`MenuBarPopoverHost`), light + dark.
/// The export is skipped unless VOICEBAR_UXP4_SHOTS_DIR is set. Its state is synthetic: a fresh VoiceState would
/// read the recent dictations saved in UserDefaults, and the default microphone is the real device (#224 r1).
@MainActor
final class MenuBarPopoverShotsTests: XCTestCase {
    static let syntheticTranscript = "A synthetic transcript for the popover shot."
    static let syntheticMicrophone = "Synthetic Test Microphone"

    /// The production host and content, fed synthetic state that never reads or writes UserDefaults.
    static func syntheticHost(_ app: AppDelegate) -> MenuBarPopoverHost {
        let state = VoiceState(
            recentTranscriptionsLoader: { [syntheticTranscript] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            keepsExpandedInDevState: false
        )
        return MenuBarPopoverHost(appDelegate: app, voiceState: state, defaultMicrophoneName: { syntheticMicrophone })
    }

    /// The parity render cannot pick up a saved dictation or the real microphone: the popover it draws carries only
    /// the synthetic values.
    func testTheShotPopoverCarriesOnlySyntheticState() {
        let popover = Self.syntheticHost(AppDelegate()).popover
        XCTAssertEqual(popover.transcript, Self.syntheticTranscript)
        XCTAssertEqual(popover.defaultMicrophoneName, Self.syntheticMicrophone)
        XCTAssertNil(popover.degradationHint)
    }

    func testRenderMenuBarPopover() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_UXP4_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_UXP4_SHOTS_DIR to render the menu-bar popover")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppDelegate()
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: Self.syntheticHost(app)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme == "light" ? .light : .dark))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("popover-\(scheme).png"), options: .atomic)
            window.orderOut(nil)
        }
    }
}
