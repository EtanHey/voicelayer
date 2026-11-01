import SwiftUI

/// A parent may retain this view-only controller when coordinating selection across composed panes.
@Observable @MainActor
final class SettingsHistoryAttemptSelectionController {
    var detailsExpanded: Bool? // Optional view-only composition seam; no preference writes.
    var value: SettingsHistoryAttemptSelection
    init(entry: SettingsHistoryEntry) { value = SettingsHistoryAttemptSelection(entry: entry) }
}

private struct SettingsHistoryAttemptSelectionKey: EnvironmentKey {
    static let defaultValue: SettingsHistoryAttemptSelectionController? = nil
}

extension EnvironmentValues {
    var historyAttemptSelectionController: SettingsHistoryAttemptSelectionController? {
        get { self[SettingsHistoryAttemptSelectionKey.self] }
        set { self[SettingsHistoryAttemptSelectionKey.self] = newValue }
    }
}

/// Content and pinned actions consume the same immutable UI projection in the same render.
/// The caller retains all playback/capture/retranscription enablement and effects.
struct SettingsHistoryAttemptDetailPane<Header: View, Content: View, Actions: View>: View {
    let entry: SettingsHistoryEntry
    let load: @Sendable (URL) async -> SettingsHistoryDiagnostics
    let loadAttempts: SettingsHistoryAttemptLogReader
    let runs: [SettingsHistoryRunLog.Run]
    let omittedCount: Int
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: (SettingsHistoryEntry) -> Content
    @ViewBuilder var actions: (SettingsHistoryEntry) -> Actions
    @State private var ownedController: SettingsHistoryAttemptSelectionController
    @Environment(\.historyAttemptSelectionController) private var parentController
    private var controller: SettingsHistoryAttemptSelectionController {
        if let parentController, parentController.value.entryID == entry.id,
           parentController.value.recordingPath == entry.audioPath.standardizedFileURL.path { return parentController }
        return ownedController
    }
    @State private var snapshot: SettingsHistoryDiagnostics?
    @State private var refresh = 0

    init(entry: SettingsHistoryEntry, load: @escaping @Sendable (URL) async -> SettingsHistoryDiagnostics,
         loadAttempts: @escaping SettingsHistoryAttemptLogReader, runs: [SettingsHistoryRunLog.Run], omittedCount: Int,
         @ViewBuilder header: @escaping () -> Header, @ViewBuilder content: @escaping (SettingsHistoryEntry) -> Content,
         @ViewBuilder actions: @escaping (SettingsHistoryEntry) -> Actions) {
        self.entry = entry; self.load = load; self.loadAttempts = loadAttempts
        self.runs = runs; self.omittedCount = omittedCount
        self.header = header; self.content = content; self.actions = actions
        _ownedController = State(initialValue: SettingsHistoryAttemptSelectionController(entry: entry))
    }

    var body: some View {
        let displayed = controller.value.displayedEntry(entry)
        VStack(alignment: .leading, spacing: 0) {
            header().padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: 14) {
                if let message = controller.value.emptyMessage {
                    Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
                } else { content(displayed) }
                SettingsHistoryDiagnosticsPanel(snapshot: snapshot, runs: runs, omittedCount: omittedCount,
                    initiallyExpanded: controller.detailsExpanded, attemptHistory: controller.value.history, selectedAttemptID: controller.value.selectedAttemptID,
                    shownAttemptID: controller.value.shownAttemptID, onSelectAttempt: { controller.value.select($0) }, recordingID: entry.recordingID, recordingEntry: entry)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.frame(minHeight: 0, maxHeight: .infinity).clipped()
            Divider()
            actions(displayed).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor)).clipped()
        .task(id: refresh) {
            let token = controller.value.beginRead()
            let requestedEntry = entry
            async let diagnostics = load(requestedEntry.audioPath)
            async let history = loadAttempts(requestedEntry.audioPath)
            let (result, attempts) = await (diagnostics, history)
            guard !Task.isCancelled,
                  controller.value.receive(attempts, entry: requestedEntry, token: token) else { return }
            snapshot = result
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { _ in refresh &+= 1 }
    }
}
