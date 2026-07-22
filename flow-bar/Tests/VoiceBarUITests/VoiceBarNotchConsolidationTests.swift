import Foundation
import XCTest

final class VoiceBarNotchConsolidationTests: XCTestCase {
    func testShippedNotchHasOneRenderingPathAndNoPrototypeSelectors() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = packageRoot.deletingLastPathComponent()
        let sourcePaths = [
            "Sources/VoiceBar/VoiceBarApp.swift",
            "Sources/VoiceBarUI/BarView.swift",
            "Sources/VoiceBarUI/PillContextMenuController.swift",
            "Sources/VoiceBarUI/VoiceBarNotchMaterial.swift",
            "Sources/VoiceBarUI/VoiceBarNotchView.swift",
        ]
        let source = try sourcePaths
            .map { path in
                try String(
                    contentsOf: packageRoot.appendingPathComponent(path),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")

        for removedSelector in [
            "VoiceBarNotchMorphVariant",
            "VoiceBarNotchMorphSelection",
            "VOICEBAR_NOTCH_MORPH_VARIANT",
            "Morph Prototype",
            "morphPrototypeProvider",
            "onSelectMorphPrototype",
            "morphSelection",
            "morphVariant",
        ] {
            XCTAssertFalse(source.contains(removedSelector), "Found stale selector: \(removedSelector)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: packageRoot
                    .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchMorphPrototype.swift")
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot
                    .appendingPathComponent("scripts/capture-notch-morph-prototypes.sh")
                    .path
            )
        )
    }

    func testSinglePathRetainsMatchedShellMotionAndDirectGlassHost() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notchView = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchView.swift"),
            encoding: .utf8
        )
        let material = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchMaterial.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(notchView.contains(".interpolatingSpring("))
        XCTAssertTrue(notchView.contains("mass: VoiceBarNotchContract.motion.mass"))
        XCTAssertTrue(notchView.contains("stiffness: VoiceBarNotchContract.motion.stiffness"))
        XCTAssertTrue(notchView.contains("damping: VoiceBarNotchContract.motion.damping"))
        XCTAssertFalse(notchView.contains("VoiceBarNotchMorphDelightEdge"))
        XCTAssertFalse(material.contains("GlassEffectContainer"))
        XCTAssertFalse(material.contains("NSGlassEffectContainerView"))
        XCTAssertTrue(material.contains("return glassView"))
    }
}
