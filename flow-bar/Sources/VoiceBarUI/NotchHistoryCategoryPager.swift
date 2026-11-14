import CoreGraphics

/// Candidate-6 QA: track the selected History category and horizontal gesture displacement.
/// Pure state allows the gesture rules to be unit-tested.
///
/// A gesture picks its axis once, from its first few points: sideways only when it is clearly more horizontal than
/// vertical. A vertical gesture stays the list's own scroll for its whole length and never switches category.
struct NotchHistoryCategoryPager: Equatable {
    enum Axis: Equatable { case undecided, horizontal, vertical }

    /// How far a gesture travels before its axis is chosen.
    static let slop: CGFloat = 6
    /// Sideways travel must beat vertical travel by this much to count as a category swipe.
    static let horizontalBias: CGFloat = 1.5
    /// A release past this share of the list's width moves to the next category.
    static let commitFraction: CGFloat = 0.22
    /// A scroll event this large at release is a flick: it moves on however short the swipe was.
    static let flickDelta: CGFloat = 14
    /// Past the first or last category the lists follow the finger at this rate, so the end never feels like a wall.
    static let edgeResistance: CGFloat = 0.3

    let count: Int
    private(set) var index = 0
    private(set) var axis: Axis = .undecided
    private var travel: CGSize = .zero
    private var lastDeltaX: CGFloat = 0
    private var pointerActive = false
    private var pointerInvalidated = false

    init(count: Int, index: Int = 0) {
        self.count = max(1, count)
        self.index = min(max(0, index), self.count - 1)
    }

    var isSwiping: Bool { axis == .horizontal }

    /// How far the lists sit from rest, in points (positive: moved right, toward the previous category).
    func offset(width: CGFloat) -> CGFloat {
        guard axis == .horizontal, width > 0 else { return 0 }
        let x = min(width, max(-width, travel.width))
        let towardMissing = (x > 0 && index == 0) || (x < 0 && index == count - 1)
        return towardMissing ? x * Self.edgeResistance : x
    }

    /// The selector thumb's position in segments, following the finger.
    func position(width: CGFloat) -> CGFloat {
        guard width > 0 else { return CGFloat(index) }
        return min(CGFloat(count - 1), max(0, CGFloat(index) - offset(width: width) / width))
    }

    mutating func begin() {
        axis = .undecided
        travel = .zero
        lastDeltaX = 0
        pointerActive = false
        pointerInvalidated = false
    }

    /// One more step of the gesture. Returns whether it is a category swipe (the caller then keeps the event from
    /// the list's vertical scroll).
    @discardableResult
    mutating func move(dx: CGFloat, dy: CGFloat) -> Bool {
        guard axis != .vertical else { return false } // decided: the rest of the gesture is the list's
        travel.width += dx
        travel.height += dy
        lastDeltaX = dx
        if axis == .undecided, max(abs(travel.width), abs(travel.height)) >= Self.slop {
            axis = abs(travel.width) > abs(travel.height) * Self.horizontalBias ? .horizontal : .vertical
        }
        return axis == .horizontal
    }

    /// A pointer drag reports its whole translation each time.
    @discardableResult
    mutating func move(to translation: CGSize) -> Bool {
        guard !pointerInvalidated else { return false }
        if !pointerActive { begin(); pointerActive = true }
        return move(dx: translation.width - travel.width, dy: translation.height - travel.height)
    }

    /// The gesture ended: settle on a category. `flick` overrides the scroll-delta test (a drag passes its own).
    mutating func end(width: CGFloat, flick: Bool? = nil) {
        defer { begin() }
        guard axis == .horizontal, width > 0 else { return }
        let x = travel.width
        let flicked = flick ?? (abs(lastDeltaX) >= Self.flickDelta && (lastDeltaX > 0) == (x > 0))
        guard abs(x) > width * Self.commitFraction || flicked else { return }
        index = min(count - 1, max(0, index + (x < 0 ? 1 : -1)))
    }

    mutating func select(_ target: Int) {
        let invalidatesPointer = pointerActive
        begin()
        pointerActive = invalidatesPointer
        pointerInvalidated = invalidatesPointer
        index = min(count - 1, max(0, target))
    }
}
