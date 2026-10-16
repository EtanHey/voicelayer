import Foundation
import AppKit

enum UIE2EInterruptionDisposition: Equatable {
    case permissionPrompt
    case qaOwnedInterruption
    case knownBenignForeign(owner: String)
    case unknown(owner: String?)
}

enum UIE2EInterruptionProcessState: Equatable {
    case running
    case notRunning
    case unknown
}

enum UIE2EClickRevealPolicy: Equatable {
    /// Use the Settings identity match to reveal an otherwise unreachable control.
    case automatic
    /// The resolver already identifies its owner (for example a Dictionary sheet).
    /// A same-label Settings control must not route this target through Settings scrolling.
    case explicitlyScoped
}

enum UIE2ERevealRouting {
    static func shouldReveal(isHittable: Bool, isMenuItem: Bool, settingsContainsMatchingControl: Bool,
                             policy: UIE2EClickRevealPolicy) -> Bool {
        guard policy == .automatic else { return false }
        return !isHittable && !isMenuItem && settingsContainsMatchingControl
    }
}

/// Pure classification shared by the native UI monitor and its regression tests.
/// Only the two explicitly approved foreign owners can be re-activated around.
enum UIE2EInterruptionPolicy {
    static let qaBundleIdentifier = "com.voicelayer.voicebar.uie2e"
    static let benignForeignOwners: Set<String> = ["com.t3tools.t3code", "com.apple.screencaptureui"]

    static func classify(alertDescription: String) -> UIE2EInterruptionDisposition {
        let text = alertDescription.lowercased()
        if ["password", "enable ui automation", "would like", "permission"].contains(where: text.contains) {
            return .permissionPrompt
        }

        guard let owner = applicationBundleIdentifier(in: alertDescription) else { return .unknown(owner: nil) }
        if owner == qaBundleIdentifier { return .qaOwnedInterruption }
        if benignForeignOwners.contains(owner) { return .knownBenignForeign(owner: owner) }
        return .unknown(owner: owner)
    }

    static func applicationBundleIdentifier(in description: String) -> String? {
        let pattern = #"Application '([^']+)'"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let searchRange = NSRange(description.startIndex..<description.endIndex, in: description)
        guard let match = expression.firstMatch(in: description, range: searchRange),
              let capture = Range(match.range(at: 1), in: description) else { return nil }
        return String(description[capture])
    }

    /// The closure owns the AX query so tests can prove it is never invoked for
    /// a terminated or unclassifiable process. Callers map XCUIApplication.state
    /// immediately before passing it here.
    static func queryHierarchyIfRunning<Value>(
        state: UIE2EInterruptionProcessState,
        _ query: () -> Value
    ) -> Value? {
        guard state == .running else { return nil }
        return query()
    }
}

enum UIE2EFeedbackFrame {
    static func requiredSize(text: String, width: CGFloat) -> CGSize {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            .boundingRect(with: CGSize(width: width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    }
    static func isReadable(text: String, frame: CGRect) -> Bool {
        guard !text.isEmpty, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return false }
        let required = requiredSize(text: text, width: frame.width)
        return ceil(required.width) <= frame.width + 1 && ceil(required.height) <= frame.height + 1
    }
}

/// The terminal pill is intentionally a preview; the adjacent production card must expose the full payload.
enum UIE2ETerminalPreview {
    static func isProven(fullText: String, previewFrame: CGRect, fullFrame: CGRect, panel: CGRect) -> Bool {
        func valid(_ frame: CGRect) -> Bool {
            !frame.isEmpty && !frame.isInfinite && !frame.isNull && panel.insetBy(dx: -1, dy: -1).contains(frame)
        }
        guard !fullText.isEmpty, valid(previewFrame), valid(fullFrame) else { return false }
        let required = NSAttributedString(string: fullText,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            .boundingRect(with: CGSize(width: fullFrame.width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return ceil(required.width) <= fullFrame.width + 1 && ceil(required.height) <= fullFrame.height + 1
    }
}

/// Scope is required even when the visible label is shared. Row/profile identify
/// sibling actions in the same page; JSON encoding prevents separator collisions.
struct UIE2EControlContext {
    var page: String
    var scope: String? = nil
    var row: String? = nil
    var profile: String? = nil
}

/// Lead-assigned product packets, not generic waivers for missing controls.
enum UIE2EKnownIssue: String {
    case listNewlines = "P14b", seekIdle = "SEEK2", supersedePreparing = "SEL1", pasteFeedback = "P1e", selectionFeedback = "P1f"
    var marker: String { "[" + rawValue + "]" }
    func matches(_ description: String) -> Bool { description.contains(marker) }
}

struct UIE2ECoverageLedger {
    static let requiredSurfaces: Set<String> = ["General", "Transcription", "Dictionary", "Speech", "History",
        "Pill", "Popover", "Context menu", "Setup wizard", "notch:supersede-preparing", "notch:replay-playing",
        "notch:seek-playing", "notch:seek-idle", "notch:list-newlines"]
    var requiredScope: Set<String> = Self.requiredSurfaces
    var verifiedSurfaces = Set<String>()
    private(set) var expectedSurfaces: [String: String] = [:]
    var missingSurfaces: Set<String> { requiredScope.subtracting(verifiedSurfaces).subtracting(expectedSurfaces.keys) }
    var observed = Set<String>()
    var exercised = Set<String>()
    var missing: Set<String> { observed.subtracting(exercised) }

    @discardableResult
    mutating func recordExpected(surface: String, issue: UIE2EKnownIssue, descriptions: [String]) -> Bool {
        guard requiredScope.contains(surface), !descriptions.isEmpty,
              descriptions.allSatisfy(issue.matches) else { return false }
        expectedSurfaces[surface] = issue.rawValue
        return true
    }

    func key(role: String, identity: String, context: UIE2EControlContext) -> String {
        let fields = [context.page, context.scope ?? "", context.row ?? "", context.profile ?? "", role, identity]
        return String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
    }
}

/// Native screen-space evidence; terminal is Stop or X. Row is the tight AX
/// controls envelope, so it does not depend on SwiftUI exposing an HStack group.
struct UIE2EControlGeometry: Codable {
    var replay: CGRect
    var eye: CGRect
    var terminal: CGRect
    var row: CGRect

    func differences(from baseline: Self, tolerance: CGFloat = 1) -> [String] {
        var result: [String] = []
        for (name, current, previous) in [("Replay", replay, baseline.replay), ("Eye", eye, baseline.eye),
                                          ("terminal", terminal, baseline.terminal), ("row", row, baseline.row)] {
            let fields = name == "row" ? [("x", current.minX, previous.minX), ("y", current.minY, previous.minY),
                ("width", current.width, previous.width), ("height", current.height, previous.height)] : [("x", current.minX, previous.minX)]
            for (field, a, b) in fields where abs(a - b) > tolerance { result.append(name + "." + field) }
        }
        return result
    }
}

enum UIE2EScrollEdge {
    static func reached(_ value: Double, direction: CGFloat) -> Bool {
        value.isFinite && abs(value - (direction < 0 ? 1 : 0)) <= 0.01
    }
}

enum UIE2EAXSelection {
    static func isSelected(flag: Bool, value: Any?) -> Bool {
        if flag { return true }
        if let number = value as? NSNumber { return number.boolValue }
        return value as? String == "1"
    }
}

enum UIE2EAXText {
    static func predicate(_ text: String, staticTextRole: UInt, additionalTextRoles: [UInt] = []) -> NSPredicate {
        let valueRoles = Set([staticTextRole] + additionalTextRoles).sorted()
        return NSCompoundPredicate(orPredicateWithSubpredicates:
            [NSPredicate(format: "label CONTAINS %@", text)] + valueRoles.map { role in
                NSPredicate(format: "elementType == %d AND value CONTAINS %@", role, text)
            })
    }
}

/// QA hit geometry, expressed in native screen-space points.
enum UIE2EHistoryGeometry {
    static func selectionOffset(in frame: CGRect) -> CGVector {
        CGVector(dx: min(45, frame.width / 2), dy: frame.height * 0.2)
    }
    static func actionIndex(after payload: CGRect, before nextPayloadY: CGFloat?, candidates: [CGRect]) -> Int? {
        guard !payload.isEmpty, !payload.isInfinite, !payload.isNull else { return nil }
        let matches = candidates.indices.filter { index in
            let frame = candidates[index]
            return !frame.isEmpty && !frame.isInfinite && !frame.isNull &&
                frame.minY >= payload.minY && frame.maxY <= (nextPayloadY ?? .greatestFiniteMagnitude) &&
                frame.maxX > payload.minX && frame.minX < payload.maxX
        }
        return matches.count == 1 ? matches.first : nil
    }
}

/// Pure gallery oracle: AX strings alone never prove readable, unobscured placement.
enum UIE2EGalleryFrames {
    /// Credit is per variant; one clipped sibling still fails the page but cannot erase measured good variants.
    static func verifiedIDs(panels: [String: CGRect], texts: [String: CGRect], expected: [String: String],
                            bounds: CGRect) -> Set<String> {
        Set(expected.keys.filter { id in
            guard let panel = panels[id], let text = texts[id],
                  problems(panels: [id: panel], texts: [id: text], expected: [id: expected[id]!], bounds: bounds).isEmpty
            else { return false }
            return panels.allSatisfy { other, otherPanel in
                guard other != id else { return true }
                let overlap = panel.intersection(otherPanel)
                return overlap.isNull || overlap.width <= 1 || overlap.height <= 1
            }
        })
    }
    static func problems(panels: [String: CGRect], texts: [String: CGRect], expected: [String: String],
                         bounds: CGRect, fonts: [String: NSFont] = [:]) -> [String] {
        var issues: [String] = []
        let ids = Set(expected.keys)
        if ids.isEmpty || Set(panels.keys) != ids || Set(texts.keys) != ids {
            issues.append("Missing/extra gallery instance or text frame")
        }
        func valid(_ frame: CGRect) -> Bool {
            !frame.isNull && !frame.isInfinite && !frame.isEmpty &&
                [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        }
        guard valid(bounds) else { return issues + ["Invalid gallery screen bounds"] }
        for id in ids.sorted() {
            guard let panel = panels[id], let text = texts[id], valid(panel), valid(text) else {
                issues.append(id + ": missing/invalid visible frame"); continue
            }
            if !bounds.insetBy(dx: -1, dy: -1).contains(panel) { issues.append(id + ": panel outside screen") }
            if !panel.insetBy(dx: -1, dy: -1).contains(text) { issues.append(id + ": text clipped by panel") }
            let font = fonts[id] ?? NSFont.systemFont(ofSize: 12, weight: .medium)
            let required = NSAttributedString(string: expected[id]!, attributes: [.font: font])
                .boundingRect(with: CGSize(width: text.width, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            if ceil(required.width) > text.width + 1 || ceil(required.height) > text.height + 1 {
                issues.append(id + ": full text does not fit visible text frame")
            }
        }
        let ordered = panels.keys.sorted()
        for (offset, id) in ordered.enumerated() {
            for other in ordered.dropFirst(offset + 1) {
                let overlap = panels[id]!.intersection(panels[other]!)
                if !overlap.isNull && overlap.width > 1 && overlap.height > 1 {
                    issues.append(id + ": overlaps " + other)
                }
            }
        }
        return issues
    }
}
