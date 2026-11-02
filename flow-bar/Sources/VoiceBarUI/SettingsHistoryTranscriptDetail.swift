import SwiftUI

/// Transcript state/scroll identity is retained by the existing parent composition.
struct SettingsHistoryTranscriptDetail: View {
    let entry: SettingsHistoryEntry
    init(entry: SettingsHistoryEntry, initiallyExpanded: Bool = false) { self.entry = entry }
    var body: some View {
        Text(entry.displayTranscript).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
