import Foundation

/// Scope is required even when the visible label is shared. Row/profile identify
/// sibling actions in the same page; JSON encoding prevents separator collisions.
struct UIE2EControlContext {
    var page: String
    var scope: String? = nil
    var row: String? = nil
    var profile: String? = nil
}

struct UIE2ECoverageLedger {
    var observed = Set<String>()
    var exercised = Set<String>()
    var missing: Set<String> { observed.subtracting(exercised) }

    func key(role: String, identity: String, context: UIE2EControlContext) -> String {
        let fields = [context.page, context.scope ?? "", context.row ?? "", context.profile ?? "", role, identity]
        return String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
    }
}
