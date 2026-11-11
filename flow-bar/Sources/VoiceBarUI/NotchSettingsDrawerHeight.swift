import CoreGraphics
import Foundation

/// C6 L2c (N16, Etan 12:40 X1-45: "this should be expandable and it currently is not expandable downwards"): the
/// Settings drawer's height. It opens at expanded History's eight rows and its grip drags it taller, one whole row
/// at a time, up to eleven. The height it is let go at is remembered.
///
/// History's window grows to hold the tallest drawer (`NotchHistoryMorph.historyCanvasLowerSurfaceHeight`, 528 →
/// 560 pt below the band; the panel 577 → 609 pt, inside the 640 pt narrow-display guard), so dragging the grip
/// never resizes the window under the pointer and the History/Settings swap never resizes it either. Under the last
/// row the window keeps room for whichever is taller, so neither ever covers that row: the grip's rubber band past
/// eleven, or a one-line note band (a note on a full drawer is otherwise clamped to the window, on the last row).
public extension NotchSettingsDrawerPresentation {
    /// The height a drawer that has never been resized opens at: History's expanded detent.
    static let minimumRows = NotchHistoryMorph.maximumRows

    /// The tallest drawer: three rows more than History's expanded detent (532 pt of drawer), the most that fits a
    /// 640 pt window with its clearance.
    static let maximumRows = 11

    /// Room the window keeps under the tallest drawer's last row (see above).
    static var bottomClearance: CGFloat {
        max(NotchHistoryMorph.rubberBandRows * NotchHistoryMorph.rowHeight,
            VoiceBarNotchContract.transientNoteBandHeight)
    }

    /// The drawer family's window below the band needs this much for the tallest Settings drawer.
    static var tallestCanvasLowerSurfaceHeight: CGFloat {
        (lowerSurfaceHeight(rows: CGFloat(maximumRows)) + bottomClearance).rounded(.up)
    }

    static func clampedRows(_ rows: Int) -> Int {
        min(maximumRows, max(minimumRows, rows))
    }

    /// Where a released grip settles: the nearest whole row inside the range (no detents, no empty half row).
    static func settledRows(_ rows: CGFloat) -> Int {
        guard rows.isFinite else { return minimumRows }
        return clampedRows(Int(rows.rounded()))
    }

    static func lowerSurfaceHeight(rows: CGFloat) -> CGFloat {
        NotchHistoryMorph.lowerSurfaceHeight(rows: rows)
    }

    /// The History tab's list at a drawer height (live while the grip is dragged).
    static func historyListHeight(rows: CGFloat) -> CGFloat {
        lowerSurfaceHeight(rows: rows) - topInset - tabBarHeight - NotchHistoryMorph.listTopInset
            - NotchHistoryMorph.handleBandHeight
    }

    static func gripAccessibilityValue(rows: Int) -> String {
        "\(rows) of \(maximumRows) rows"
    }
}

/// Where the Settings drawer's height is remembered. The app keeps it in its defaults, so the drawer reopens at the
/// height it was left at, also after a relaunch. Everything else (tests, previews) keeps it for the session only, so
/// no test writes a preference.
public struct NotchSettingsRowsStore {
    public var load: () -> Int?
    public var save: (Int) -> Void

    public init(load: @escaping () -> Int?, save: @escaping (Int) -> Void) {
        self.load = load
        self.save = save
    }

    public static let defaultsKey = "voicebar.notchSettingsDrawerRows"

    public static var session: NotchSettingsRowsStore {
        NotchSettingsRowsStore(load: { nil }, save: { _ in })
    }

    public static func userDefaults(_ defaults: UserDefaults) -> NotchSettingsRowsStore {
        NotchSettingsRowsStore(
            load: { defaults.object(forKey: defaultsKey) == nil ? nil : defaults.integer(forKey: defaultsKey) },
            save: { defaults.set($0, forKey: defaultsKey) }
        )
    }
}
