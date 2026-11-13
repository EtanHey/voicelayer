import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsRS5Round2Tests: XCTestCase {
    private let installed = VoiceBarInstalledVersion(version: "2.4.0", commit: "123456789abc")
    private let statuses: [(String, VoiceBarVersionStatus)] = [
        ("latest", .latest), ("available", .available("2.4.1")),
        ("checking", .checking), ("failed", .couldNotCheck), ("ahead", .ahead(latest: "2.3.9"))]

    func testReleaseAndNonReleaseKeepEachUpdateStatusOnAllThreeSurfaces() {
        for describe in [VoiceBarGitDescribe.parse("v2.4.0"), VoiceBarGitDescribe.parse("v2.4.0-0-g1234567")] {
            for (name, status) in statuses {
                let release = describe?.isTaggedRelease == true
                let identity = release ? "2.4.0" : "2.4.0 · 1234567"
                XCTAssertEqual(SettingsVersionFooter.statusText(status, describe: describe), status.sidebarMessage, name)
                XCTAssertEqual(VoiceBarBuildLine.menuStatus(installed: installed, describe: describe, status: status),
                    release ? VoiceBarBuildLine.status(status, describe: nil) : "1234567 · \(VoiceBarBuildLine.status(status, describe: describe)!)", name)
                XCTAssertEqual(VoiceBarBuildLine.displayText(installed: installed, describe: describe, status: status),
                    release ? identity : "\(identity) · \(VoiceBarBuildLine.status(status, describe: describe)!)", name)
                let phase: NotchUpdatePhase = switch status {
                case .latest: .upToDate
                case .available(let version): .available(version: version)
                case .checking: .checking
                case .couldNotCheck: .couldNotCheck
                case .ahead(let latest): .ahead(latest: latest)
                }
                let expectedDrawer = switch status {
                case .latest: "No newer release is available."
                case .available: "VoiceBar 2.4.1 is available."
                case .checking: "Checking for updates…"
                case .couldNotCheck: "Could not check for updates. Try again in a moment."
                case .ahead: "No newer release. This build is past 2.3.9."
                }
                XCTAssertEqual(NotchSettingsDrawerPresentation.updateStatus(phase), expectedDrawer, name)
            }
        }
    }

    func testRenderReleaseAndCandidateStatusMatrix() async throws {
        for (build, describe) in [("release", "v2.4.0"), ("candidate", "v2.4.0-0-g1234567")] {
            for (name, status) in statuses {
                let pending = PendingFetch()
                let controller = NotchUpdateController(installed: installed, describe: .parse(describe),
                    check: VoiceBarVersionCheck(fetch: {
                        if name == "checking" { await pending.wait() }
                        if name == "failed" { throw URLError(.notConnectedToInternet) }
                        return "cask \"voicebar\" do\n version \"\(name == "available" ? "2.4.1" : name == "ahead" ? "2.3.9" : "2.4.0")\"\nend\n"
                    }), launcher: NoLauncher(), isDictating: { false })
                let check = Task { await controller.checkForUpdates() }
                if name == "checking" {
                    for _ in 0..<20 where controller.phase != .checking { await Task.yield() }
                    XCTAssertEqual(controller.phase, .checking)
                } else { await check.value }
                defer { check.cancel(); Task { await pending.release() } }
                let menu = PillContextMenuController.versionItem(PillContextMenuController.versionLine(
                    version: "2.4.0", updateStatus: VoiceBarBuildLine.menuStatus(
                        installed: installed, describe: .parse(describe), status: status)))
                let menuView = try XCTUnwrap(menu.view)
                let bitmap = try SettingsPolishS5Tests.render(VStack(alignment: .leading, spacing: 12) {
                    Text("Settings footer").font(.caption)
                    SettingsVersionFooter(installed: installed, status: status, describe: .parse(describe))
                        .frame(width: 172, alignment: .leading)
                    Text("Pill menu").font(.caption)
                    NativeRow(view: menuView).frame(height: 32)
                    Text("Drawer footer").font(.caption)
                    NotchSettingsVersionRow(updates: controller, appearance: .dark).frame(width: 420)
                }.padding(12), width: 620, height: 330, name: "r2-version-\(build)-\(name)")
                let lines = try SettingsPolishS5Tests.ocr(bitmap)
                // The hosted runner's text recognition reads "i" as "l" in this face ("update avallable", PR #904),
                // so both sides are compared with l and i folded together. Wording is still checked letter for letter otherwise.
                func fold(_ text: String) -> String { text.replacingOccurrences(of: "l", with: "i") }
                func count(_ needles: String...) -> Int {
                    lines.filter { line in needles.contains { fold(line).contains(fold($0)) } }.count
                }
                let matched: Int
                switch status {
                case .latest: matched = count("up to date")
                case .available: matched = count("update available")
                case .checking: matched = count("checking")
                case .couldNotCheck: matched = count("check failed", "could not check")
                case .ahead: matched = count("ahead of release")
                    XCTAssertTrue(fold(lines.joined(separator: " ")).contains(fold("this build is past 2.3.9.")), "The candidate helper stays verbatim on releases too")
                }
                let expected = switch name {
                case "checking": 3
                case "failed": build == "release" ? 3 : 4
                default: build == "release" ? 2 : 3
                }
                XCTAssertEqual(matched, expected, "\(build) \(name): \(lines)")
                XCTAssertEqual(lines.joined(separator: " ").contains("1234567"), build == "candidate")
                await pending.release()
                check.cancel()
                await check.value
            }
        }
    }

    private actor PendingFetch {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct NoLauncher: VoiceBarUpdateLaunching {
        let isAvailable = false
        func launch() { XCTFail("Rendering must not launch an update") }
    }
    private struct NativeRow: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    func testTooltipFactsAreAlsoAccessibilityHints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI")
        let reasons = try String(contentsOf: root.appendingPathComponent("SettingsLockedReason.swift"), encoding: .utf8)
        XCTAssertTrue(reasons.contains(".modifier(OptionalAccessibilityHint(text: reason))"))
        let dictionary = try String(contentsOf: root.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(dictionary.contains(".accessibilityHint(entry.variants.isEmpty ? \"\" : variantSummary(entry.variants))"))
        let speech = try String(contentsOf: root.appendingPathComponent("SpeechSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(speech.contains(".accessibilityHint(SpeechThresholdDraft.revertHelp)"))
    }

    func testOtherCandidate7HelpersStayVerbatim() {
        XCTAssertEqual(SettingsGeneralCopy.dictationKeyDescription,
            "Hold to talk. Double-tap to keep recording hands-free; it stops after 10 minutes of silence.")
        XCTAssertEqual(SettingsGeneralCopy.diagnosticDescription, "Copies the build and recognizer facts for a bug report.")
        XCTAssertEqual(SettingsGeneralCopy.microphoneNote,
            "Drag to reorder. VoiceBar uses the first connected microphone. Disconnected ones keep their place.")
        XCTAssertEqual(VoiceBarHotkeyContract.singleTapDescription, "Stop recording or speech; cancel transcription")
        XCTAssertEqual(VoiceBarHotkeyContract.readClipboardDescription,
            "Reads what you copied. New text queues; the same text again stops.")
    }
}
