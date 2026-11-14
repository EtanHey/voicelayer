import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.4 geometry verification uses the actual notch dimensions,
/// recorded once on the M4 (Mac16,5) by `swift scripts/record-notch-geometry.swift` into
/// flow-bar/Tests/Fixtures/notch-geometry-m4-mac16-5.json. No assumed notch width anywhere in this file.
/// Each state checks that nothing it draws beside the notch comes within 8 pt of the physical camera housing,
/// and renders a snapshot (written as PNGs when VOICEBAR_LANE_A_SHOTS_DIR is set).
@MainActor
final class NotchRealGeometryTests: XCTestCase {
    struct Fixture: Decodable {
        struct Rect: Decodable {
            let x, y, width, height: CGFloat
            var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }
        struct Insets: Decodable { let top, left, bottom, right: CGFloat }
        struct Screen: Decodable {
            let name: String
            let builtIn: Bool
            let backingScaleFactor: CGFloat
            let frame, visibleFrame: Rect
            let safeAreaInsets: Insets
            let auxiliaryTopLeftArea, auxiliaryTopRightArea: Rect?
        }
        let hardwareModel: String
        let screens: [Screen]
    }

    static func loadM4() throws -> Fixture.Screen {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/notch-geometry-m4-mac16-5.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.hardwareModel, "Mac16,5")
        return try XCTUnwrap(fixture.screens.first { $0.builtIn })
    }

    static func metrics(_ screen: Fixture.Screen) -> VoiceBarNotchScreenMetrics {
        VoiceBarNotchScreenMetrics(
            frame: screen.frame.cgRect, visibleFrame: screen.visibleFrame.cgRect,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea?.cgRect,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea?.cgRect
        )
    }

    /// The gap AppKit reports between the two auxiliary menu-bar areas. It includes a clear rounded shoulder on
    /// each side of the camera glass.
    static func auxiliaryGap(_ screen: Fixture.Screen) throws -> CGRect {
        let left = try XCTUnwrap(screen.auxiliaryTopLeftArea).cgRect
        let right = try XCTUnwrap(screen.auxiliaryTopRightArea).cgRect
        return CGRect(x: left.maxX, y: screen.frame.height - screen.safeAreaInsets.top,
                      width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    /// The physical camera housing: the auxiliary gap without its shoulders. #359 verified this calibration on the
    /// hardware (operator and phone evidence); it is what the shell's core is drawn on.
    static func physicalNotch(_ screen: Fixture.Screen) throws -> CGRect {
        try auxiliaryGap(screen).insetBy(dx: VoiceBarNotchContract.hardwareHorizontalCalibrationInset, dy: 0)
    }

    enum Surface: String, CaseIterable {
        case hoverLauncher, recording, compactStatus, teleprompter, historyCollapsed, historyExpanded, settings
        case settingsTranscription
    }

    static func presentation(_ surface: Surface, screen: VoiceBarNotchScreenGeometry) -> VoiceBarNotchPresentation {
        let rows: Int = switch surface {
        case .historyCollapsed: NotchHistoryMorph.visibleRows
        case .historyExpanded: NotchHistoryMorph.maximumRows
        case .settings, .settingsTranscription: NotchSettingsDrawerPresentation.rows
        default: NotchHistoryMorph.visibleRows
        }
        let isDrawer = [.historyCollapsed, .historyExpanded, .settings, .settingsTranscription].contains(surface)
        return VoiceBarNotchPresentation.resolve(
            hasTeleprompter: surface == .teleprompter,
            isRecording: surface == .recording,
            hasCompactStatus: surface == .compactStatus,
            hasHistoryPanel: isDrawer,
            historyRows: rows,
            isHovered: true,
            isKeyboardFocused: false,
            coreWidth: screen.housingFrame.width,
            visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset
        )
    }

    func testTheFixtureIsARealHardwareNotch() throws {
        let screen = try Self.loadM4()
        let geometry = VoiceBarNotchScreenGeometry.resolve(metrics: Self.metrics(screen))
        XCTAssertEqual(geometry.kind, .hardwareNotch)
        XCTAssertEqual(try Self.auxiliaryGap(screen).width, 185, "Mac16,5 measures 185 pt between the auxiliary areas")
        XCTAssertEqual(screen.safeAreaInsets.top, 32)
        XCTAssertEqual(geometry.housingFrame.width, 168, "the glass, without AppKit's shoulders")
        XCTAssertEqual(geometry.housingFrame.minX, try Self.physicalNotch(screen).minX)
    }

    /// Verify at least 8 pt of physical-notch clearance for all wing content and controls in screen coordinates.
    func testEverySurfaceKeepsEightPointsFromThePhysicalNotch() throws {
        let screenFixture = try Self.loadM4()
        let screen = VoiceBarNotchScreenGeometry.resolve(metrics: Self.metrics(screenFixture))
        let notch = try Self.physicalNotch(screenFixture)
        let clearance = VoiceBarNotchContract.physicalNotchClearance
        XCTAssertEqual(clearance, 8)
        for surface in Surface.allCases {
            let presentation = Self.presentation(surface, screen: screen)
            let geometry = presentation.geometry
            let panel = screen.panelFrame(for: geometry)
            let coreMinX = panel.minX + geometry.coreOriginX
            let coreMaxX = coreMinX + geometry.coreWidth
            XCTAssertEqual(coreMinX, screen.housingFrame.minX, accuracy: 0.01, "\(surface): centred on the housing")

            for side in [VoiceBarNotchSide.leading, .trailing] {
                let wing = side == .leading ? geometry.leadingWingWidth : geometry.trailingWingWidth
                guard wing > 0 else { continue }
                let slot = VoiceBarNotchContract.material.wingContentLayout(
                    for: side, state: presentation.visualState,
                    visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
                )
                if side == .leading {
                    let contentMaxX = coreMinX - slot.coreInset
                    XCTAssertLessThanOrEqual(contentMaxX, notch.minX - clearance + 0.001,
                                             "\(surface) leading content is \(notch.minX - contentMaxX) pt from the notch")
                    XCTAssertGreaterThan(wing - slot.coreInset - slot.outerInset, 0, "\(surface) leading lane is not empty")
                } else {
                    let contentMinX = coreMaxX + slot.coreInset
                    XCTAssertGreaterThanOrEqual(contentMinX, notch.maxX + clearance - 0.001,
                                                "\(surface) trailing content is \(contentMinX - notch.maxX) pt from the notch")
                    XCTAssertGreaterThan(wing - slot.coreInset - slot.outerInset, 0, "\(surface) trailing lane is not empty")
                }
            }

            let layout = VoiceBarPanelLayout.make(
                presentation: presentation, canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
            )
            let region = VoiceBarNotchHitRegion(geometry: geometry, configuration: .fallback(for: presentation))
            for rect in region.rects where rect.minY >= geometry.lowerSurfaceHeight && rect.height < geometry.topHeight {
                let onScreen = rect.offsetBy(dx: panel.minX, dy: 0)
                let gap = onScreen.maxX <= notch.midX ? notch.minX - onScreen.maxX : onScreen.minX - notch.maxX
                XCTAssertGreaterThanOrEqual(gap, clearance - 0.001, "\(surface): a control \(gap) pt from the notch")
            }
            XCTAssertLessThanOrEqual(layout.panelSize.width, screenFixture.frame.width, "\(surface) fits the screen")
            XCTAssertLessThanOrEqual(geometry.totalHeight + 17, screenFixture.visibleFrame.height,
                                     "\(surface) fits under the menu bar")
        }
    }

    /// The clearance rule itself: every core-side inset the wings use is at least 8 pt.
    func testEveryCoreSideInsetIsAtLeastTheClearance() {
        let states: [VoiceBarNotchVisualState] = [.hoverLauncher, .recording, .compactStatus, .teleprompter, .history]
        for state in states {
            for side in [VoiceBarNotchSide.leading, .trailing] {
                let slot = VoiceBarNotchContract.material.wingContentLayout(for: side, state: state)
                XCTAssertGreaterThanOrEqual(slot.coreInset, VoiceBarNotchContract.physicalNotchClearance, "\(state) \(side)")
            }
        }
        XCTAssertGreaterThanOrEqual(VoiceBarNotchContract.compactCoreContentInset, VoiceBarNotchContract.physicalNotchClearance)
    }

    // MARK: Snapshots at the real geometry

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private func state(for surface: Surface) -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< 20).map { index in
            RecentTranscriptionEntry(
                text: "Synthetic dictation number \(index + 1), long enough to show how a row ends when it is cut.",
                recordingPath: "/synthetic/\(index).wav",
                dictationReceipt: DictationReceipt(audioDurationMilliseconds: 4000 + index * 1000,
                                                   processingDurationMilliseconds: 400),
                createdAt: Date().addingTimeInterval(Double(-90 * index))
            )
        }
        return state
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        window.close()
        return bitmap
    }

    func testEverySurfaceRendersAtTheRealM4Geometry() throws {
        let screenFixture = try Self.loadM4()
        let screen = VoiceBarNotchScreenGeometry.resolve(metrics: Self.metrics(screenFixture))
        let directory = ProcessInfo.processInfo.environment["VOICEBAR_LANE_A_SHOTS_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let check = VoiceBarVersionCheck(fetch: { "cask \"voicebar\" do\n  version \"2.4.0\"\nend\n" })
        let updates = NotchUpdateController(
            installed: VoiceBarInstalledVersion(version: "2.4.0", commit: "abc1234def"),
            describe: VoiceBarGitDescribe(releaseVersion: "2.3.0", commitsAhead: 14),
            check: check, launcher: VoiceBarUpdateLauncher(fileExists: { _ in false }), isDictating: { false }
        )
        let context = NotchSettingsDrawerContext(updates: updates)
        for surface in Surface.allCases {
            let state = state(for: surface)
            let model = VoiceBarNotchPresentationModel()
            model.updateOperationalEnvelope(
                hasTeleprompter: surface == .teleprompter, isRecording: surface == .recording,
                hasCompactStatus: surface == .compactStatus,
                coreWidth: screen.housingFrame.width, visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset
            )
            model.setHovered(true)
            if surface == .teleprompter {
                state.handleEvent(["type": "state", "state": "speaking", "text": "A synthetic read aloud for the shot.",
                                   "duration_ms": 6000])
            }
            if surface == .recording { state.mode = .recording }
            let drawer: NotchDrawer? = switch surface {
            case .historyCollapsed: .history(.collapsed)
            case .historyExpanded: .history(.expanded)
            case .settings: .settings(.general)
            case .settingsTranscription: .settings(.transcription)
            default: nil
            }
            if drawer != nil { model.setHistoryPanelOpen(true) }
            if let drawer { model.setHistoryRows(BarView.rows(for: drawer, entries: 20)) }
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var bar = BarView(
                    state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true, settingsDrawer: context
                )
                if let drawer { bar = bar.presenting(drawer) }
                let bitmap = try render(bar, size: size, appearance: appearance)
                var opaque = 0
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                        opaque += 1
                    }
                }
                XCTAssertGreaterThan(opaque, 0, "\(surface) \(scheme) rendered something")
                if let directory, let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("m4-\(surface.rawValue)-\(scheme).png"))
                }
            }
        }
    }
}
