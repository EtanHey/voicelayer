import SwiftUI
@testable import VoiceBarUI
import XCTest

/// The v9 live-BarView swap: every voice state must render the notch-conforming silhouette
/// (NotchShape / FunnelPanelShape from NotchGeometry.swift), NOT the v8 Capsule. This test
/// pins the mode→silhouette mapping (the steal-list §3 state table) so a regression that
/// re-introduces the floating pill is caught.
final class BarSilhouetteTests: XCTestCase {
    func testCompactStatesUseTheBareNotchBand() {
        // idle / recording / transcribing / error are the compact "band hugs the island"
        // states — one black NotchShape silhouette flush to the menu bar.
        for mode in [VoiceMode.idle, .recording, .transcribing, .error, .disconnected] {
            XCTAssertEqual(
                BarSilhouette.kind(for: mode),
                .notchBand,
                "\(mode) must render the notch band, not the funnel panel or a pill"
            )
        }
    }

    func testSpeakingGrowsTheFunnelPanelOutOfTheNotch() {
        // speaking = the headline v9 transition: the funnel panel grows OUT of the notch.
        XCTAssertEqual(BarSilhouette.kind(for: .speaking), .funnelPanel)
    }

    func testNotchBandRadiiMatchTheClosedIslandSilhouette() {
        // Compact band uses the closed-island radii (steal-list S3: top 6, bottom 14).
        let band = BarSilhouette.notchBandShape()
        XCTAssertEqual(band.topRadius, NotchV9Style.closedTopRadius, accuracy: 0.001)
        XCTAssertEqual(band.bottomRadius, NotchV9Style.closedBottomRadius, accuracy: 0.001)
    }

    func testFunnelNeckMatchesTheClosedNotchWidth() {
        // The funnel's flat neck must equal the notch width so it reads as growing from the
        // island, not a wider box clipped at the top.
        let funnel = BarSilhouette.funnelPanelShape(neckWidth: 128)
        XCTAssertEqual(funnel.neckWidth, 128, accuracy: 0.001)
    }

    func testBarShapePathIsNonEmptyForBothKinds() {
        // Both silhouettes produce a real path at the pill's typical frame — guards against
        // a degenerate clip that would render an invisible / mis-clipped bar.
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        XCTAssertFalse(BarShape(.notchBand).path(in: rect).isEmpty)
        XCTAssertFalse(BarShape(.funnelPanel).path(in: rect).isEmpty)
    }
}
