@testable import VoiceBarUI

/// Lane head: the dismissal is NotchDrawerDismissal (every reason closes the drawer).
@MainActor
enum LaneAProbeShim {
    static func dismissal(reason: NotchDismissReason? = nil, onClose: @escaping () -> Void) -> AnyObject {
        NotchDrawerDismissal { received in
            if reason == nil || received == reason { onClose() }
        }
    }
    static func start(_ object: AnyObject) { (object as! NotchDrawerDismissal).start() }
    static func stop(_ object: AnyObject) { (object as! NotchDrawerDismissal).stop() }
    static func recentEntryLimit() -> Int {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { (0 ..< 30).map { RecentTranscriptionEntry(text: "row \($0)") } },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        return state.recentTranscriptionEntries.count
    }
}
