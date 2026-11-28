import CoreGraphics

/// The axis lock for VoiceBar's sideways tab swipes (History categories and the notch Settings tabs). Pure state, so
/// the gesture rules are unit-tested. Where the pill and pages sit, and where a release settles, is `GlassTabPager`'s
/// (docs/tab-swipe.md).
///
/// A gesture picks its axis once, from its first few points: sideways only when it is clearly more horizontal than
/// vertical. A vertical gesture stays the list's own scroll for its whole length and never switches tab. Once it is
/// sideways, the step that decided it hands over the whole travel so far, so the pages never lag the fingers by the slop
/// (BrainBar's `NDPagePager`, which took these rules from here).
struct NotchHistoryCategoryPager: Equatable {
    enum Axis: Equatable { case undecided, horizontal, vertical }

    /// How far a gesture travels before its axis is chosen.
    static let slop: CGFloat = 6
    /// Sideways travel must beat vertical travel by this much to count as a tab swipe.
    static let horizontalBias: CGFloat = 1.5

    private(set) var axis: Axis = .undecided
    private var travel: CGSize = .zero
    private var pointerActive = false
    private var pointerInvalidated = false

    var isSwiping: Bool { axis == .horizontal }

    mutating func begin() {
        axis = .undecided
        travel = .zero
        pointerActive = false
        pointerInvalidated = false
    }

    /// One more step of the gesture: the sideways points to move the pages by now, or nil while it is not a tab swipe
    /// (the caller then lets the event through to the list). On the step that decides the axis, that is the whole
    /// sideways travel so far.
    mutating func move(dx: CGFloat, dy: CGFloat) -> CGFloat? {
        guard axis != .vertical else { return nil } // decided: the rest of the gesture is the list's
        travel.width += dx
        travel.height += dy
        switch axis {
        case .horizontal: return dx
        case .vertical: return nil
        case .undecided:
            guard max(abs(travel.width), abs(travel.height)) >= Self.slop else { return nil }
            axis = abs(travel.width) > abs(travel.height) * Self.horizontalBias ? .horizontal : .vertical
            return axis == .horizontal ? travel.width : nil
        }
    }

    /// A pointer drag reports its whole translation each time.
    mutating func move(to translation: CGSize) -> CGFloat? {
        guard !pointerInvalidated else { return nil }
        if !pointerActive { begin(); pointerActive = true }
        return move(dx: translation.width - travel.width, dy: translation.height - travel.height)
    }

    /// The gesture ended: whether a tab swipe was in progress (and so must be released).
    mutating func end() -> Bool {
        defer { begin() }
        return axis == .horizontal
    }

    /// A click or a key chose a tab mid-gesture: the rest of that gesture moves nothing. A pointer drag in progress
    /// stays dead until its button comes up (its next translation is still the old full one).
    mutating func interrupt() {
        let invalidatesPointer = pointerActive
        begin()
        pointerActive = invalidatesPointer
        pointerInvalidated = invalidatesPointer
    }
}
