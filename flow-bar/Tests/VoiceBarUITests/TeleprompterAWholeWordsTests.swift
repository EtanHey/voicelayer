import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Reported 2026-11-08 on 870b1617: the final word could truncate despite fitting the column.
/// Teleprompter A wraps whole words, but each line HStack could tail-truncate a word
/// (154 pt measured in a 160 pt column, "Codex." drawn at 46.5 of its 55 pt). Every word renders whole; lines wrap.
@MainActor
final class TeleprompterAWholeWordsTests: XCTestCase {
    private struct AX {
        let object: NSObject
        var label: String? { object.value(forKey: "accessibilityLabel") as? String }
        var frame: CGRect { (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var children: [Any] { object.value(forKey: "accessibilityChildren") as? [Any] ?? [] }
    }

    private func elements(_ root: Any, depth: Int = 0) -> [AX] {
        guard depth < 30, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return [] }
        let node = AX(object: object)
        return [node] + node.children.flatMap { elements($0, depth: depth + 1) }
    }

    /// Renders the real view at `column` and returns each word's drawn frame, read from its "Jump to:" button.
    private func renderedWords(_ text: String, column: CGFloat) -> [(word: String, frame: CGRect)] {
        let view = TeleprompterAView(text: text, visibleLines: 8, columnWidth: column, playbackElapsedMilliseconds: { 0 })
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: CGSize(width: column + 40, height: 400))
        let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        VLOrderCompositorTestWindow(window)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        return elements(host).compactMap { element in
            guard let label = element.label, label.hasPrefix("Jump to: ") else { return nil }
            return (String(label.dropFirst("Jump to: ".count)), element.frame)
        }
    }

    private func withAccessibility(_ body: () throws -> Void) throws {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let app = NSApplication.shared
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        XCTAssertTrue(app.responds(to: setter), "Offscreen SwiftUI AX must be available")
        guard app.responds(to: setter) else { return }
        // Enables AX in this test process only; no AX client, system setting or live app is touched.
        let wasEnhanced = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setEnhanced = unsafeBitCast(app.method(for: setter), to: Setter.self)
        setEnhanced(app, setter, true)
        defer { setEnhanced(app, setter, wasEnhanced) }
        try body()
    }

    /// Every piece that fits the column is drawn whole, and no piece is drawn past the column, where it would clip.
    private func assertWholeWordsWithinTheColumn(_ text: String, columns: [CGFloat], expectedWords: Int? = nil,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        for column in columns {
            let words = renderedWords(text, column: column)
            if let expectedWords {
                XCTAssertEqual(words.count, expectedWords, "column \(column): every word is drawn", file: file, line: line)
            }
            XCTAssertFalse(words.isEmpty, file: file, line: line)
            let left = try XCTUnwrap(words.map(\.frame.minX).min(), file: file, line: line)
            for (word, frame) in words {
                let measured = TeleprompterAModel.width(word, heading: false)
                if measured <= column {
                    XCTAssertGreaterThanOrEqual(frame.width + 0.5, measured,
                                                "column \(column): \"\(word)\" fits but is truncated (\(frame.width) pt drawn)",
                                                file: file, line: line)
                }
                XCTAssertLessThanOrEqual(frame.maxX - left, column + 0.5,
                                         "column \(column): \"\(word)\" (\(measured) pt) is drawn past the column",
                                         file: file, line: line)
            }
        }
    }

    func testEveryWordRendersWholeWhenItEndsALine() throws {
        try withAccessibility {
            // 160 pt puts "Codex." at the end of a line that fits (the QA shape); the others are the widths where base
            // truncated a line-ending word, plus the live column.
            try assertWholeWordsWithinTheColumn(
                "l asked Codex to review it, then Claude Code and Codex again. Did codex agree with Codex? Ask Codex.",
                columns: [150, 152, 160, 172, 404], expectedWords: 19)
        }
    }

    /// Review round 2 (Codex, P2): a piece wider than the column (the splitter caps pieces at 24 characters, not at a
    /// width) must never be pinned past the column's clip. 24 family emoji are one 552 pt piece; long URLs and paths
    /// split into pieces wider than a narrow column. Each stays inside the column, and every piece that fits is whole.
    func testAPieceWiderThanTheColumnStaysInsideItAndFittingPiecesStayWhole() throws {
        try withAccessibility {
            let family = String(repeating: "👨‍👩‍👧‍👦", count: 24)
            XCTAssertGreaterThan(TeleprompterAModel.width(family, heading: false), 404)
            try assertWholeWordsWithinTheColumn("Ask \(family) Codex.", columns: [150, 160, 404], expectedWords: 3)
            try assertWholeWordsWithinTheColumn(
                "See https://github.com/EtanHey/voicelayer/blob/main/flow-bar/Sources/VoiceBarUI/TeleprompterAView.swift for Codex.",
                columns: [150, 160, 404])
            try assertWholeWordsWithinTheColumn(
                "Open /Users/happycampr/.t3/worktrees/voicelayer/flow-bar/Sources/VoiceBarUI/BarView.swift with Codex.",
                columns: [150, 160, 404])
        }
    }

    /// A decorated word is drawn as separate Texts, each rounded on its own; the wrap measures it the same way.
    func testADecoratedWordIsMeasuredAsItIsDrawn() {
        let pieces = ["• ", "Codex"]
        let drawn = pieces.reduce(CGFloat(0)) { $0 + TeleprompterAModel.width($1, heading: false) }
        XCTAssertGreaterThanOrEqual(drawn, TeleprompterAModel.width(pieces.joined(), heading: false))
    }
}
