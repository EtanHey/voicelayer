import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QA 2026-11-08 (Etan, live on 870b1617): the narration said "Codex", the teleprompter showed "cod…". Teleprompter A
/// wraps whole words to its column, but each line's HStack could still tail-truncate a last word that fit
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

    func testEveryWordRendersWholeWhenItEndsALine() throws {
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

        let text = "I asked Codex to review it, then Claude Code and Codex again. Did codex agree with Codex? Ask Codex."
        // 160 pt puts "Codex." at the end of a line that fits (the QA shape); the others are the widths where base
        // truncated a line-ending word, plus the live column.
        for column: CGFloat in [150, 152, 160, 172, 404] {
            let words = renderedWords(text, column: column)
            XCTAssertEqual(words.count, 19, "column \(column): every word is drawn")
            for (word, frame) in words {
                XCTAssertGreaterThanOrEqual(frame.width + 0.5, TeleprompterAModel.width(word, heading: false),
                                            "column \(column): \"\(word)\" is truncated (\(frame.width) pt drawn)")
            }
            // Whole words never push a line past the column: the wrap still decides where lines break.
            let left = try XCTUnwrap(words.map(\.frame.minX).min())
            for (word, frame) in words {
                XCTAssertLessThanOrEqual(frame.maxX - left, column + 0.5, "column \(column): \"\(word)\" overflows")
            }
        }
    }

    /// A decorated word is drawn as separate Texts, each rounded on its own; the wrap measures it the same way.
    func testADecoratedWordIsMeasuredAsItIsDrawn() {
        let pieces = ["• ", "Codex"]
        let drawn = pieces.reduce(CGFloat(0)) { $0 + TeleprompterAModel.width($1, heading: false) }
        XCTAssertGreaterThanOrEqual(drawn, TeleprompterAModel.width(pieces.joined(), heading: false))
    }
}
