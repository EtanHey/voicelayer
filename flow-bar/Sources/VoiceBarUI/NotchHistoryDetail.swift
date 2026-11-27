import AppKit
import SwiftUI

/// L99 (QA N18/H3): a History row opened INSIDE the notch. A click on a row shows its whole text, when it happened
/// and what it can do (Play, Copy, Paste, Re-transcribe, Show in Finder) in the list's own place, under the same
/// category selector, at the drawer's height; Back returns to the list where it was. It never leaves the notch:
/// before, a row click closed the drawer and opened the History window.
struct NotchHistoryDetail: Equatable {
    let scope: SettingsHistoryScope
    /// The whole text: the dictation, the Ask answer, or what was read aloud.
    let text: String
    /// Ask only: what was asked.
    let question: String?
    /// "2 min ago · 0:13", or nil for an entry saved before times were recorded.
    let meta: String?
    /// The audio Play plays, in order (an Ask answer, a dictation, a read's chunks). Empty: no Play.
    let audio: [URL]
    /// The file Show in Finder selects. Nil: no Finder action.
    let revealURL: URL?
    /// A dictation's recording, for Re-transcribe.
    let recordingPath: String?
    let hasActionableText: Bool
    /// The row entry the shared Copy / Paste closures take.
    let entry: RecentTranscriptionEntry

    enum Action: Equatable, CaseIterable {
        case play, copy, paste, retranscribe, reveal

        /// The button's own word; five of them fit the 404 pt bar at 11.5 pt without truncating.
        var label: String {
            switch self {
            case .play: "Play"
            case .copy: "Copy"
            case .paste: "Paste"
            case .retranscribe: "Re-transcribe"
            case .reveal: "Finder"
            }
        }

        /// Tooltip and VoiceOver: the whole action.
        var help: String {
            switch self {
            case .paste: "Paste into the app you were using"
            case .reveal: "Show in Finder"
            default: label
            }
        }

        var symbol: String {
            switch self {
            case .play: "play.fill"
            case .copy: VoiceBarActionSymbol.copy
            case .paste: VoiceBarActionSymbol.paste
            case .retranscribe: "arrow.clockwise"
            case .reveal: "folder"
            }
        }
    }

    /// What this entry can do, in the bar's order. Speech keeps the rows' rule: no Paste, no Re-transcribe.
    var actions: [Action] {
        Action.allCases.filter { action in
            switch action {
            case .play: !audio.isEmpty
            case .copy: hasActionableText
            case .paste: hasActionableText && scope != .speech
            case .retranscribe: recordingPath != nil && scope == .recording
            case .reveal: revealURL != nil
            }
        }
    }

    static func dictation(_ entry: RecentTranscriptionEntry) -> Self {
        let audio = entry.recordingPath.map { URL(fileURLWithPath: $0) }
        return Self(
            scope: .recording, text: entry.text, question: nil,
            meta: NotchHistoryPresentation.rowHeader(for: entry), audio: audio.map { [$0] } ?? [],
            revealURL: audio, recordingPath: entry.recordingPath,
            hasActionableText: !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry: entry
        )
    }

    static func archive(_ row: NotchHistoryArchiveStore.Row, scope: SettingsHistoryScope) -> Self {
        Self(
            scope: scope, text: row.entry.text, question: row.question,
            meta: [VoiceBarRelativeTime.label(row.entry.createdAt), row.detailMeta].compactMap { $0 }
                .joined(separator: " · ").nilIfEmpty,
            audio: row.audio, revealURL: row.audio.first, recordingPath: nil,
            hasActionableText: row.hasActionableText, entry: row.entry
        )
    }
}

/// The calls an opened row makes; the notch passes the same closures its rows use.
struct NotchHistoryDetailActions {
    var copy: (RecentTranscriptionEntry) -> Bool
    var paste: (RecentTranscriptionEntry) -> Void
    var retranscribe: (String) -> Void
    var reveal: (URL) -> Void
    var playback: SettingsAudioPlayback?
    var retranscriptionAvailability: () -> HistoryRetranscriptionAvailability

    /// Shots: every button shows, none does anything.
    static let inert = Self(copy: { _ in false }, paste: { _ in }, retranscribe: { _ in }, reveal: { _ in },
                            playback: nil, retranscriptionAvailability: { .available })
}

struct NotchHistoryDetailView: View {
    static let identifier = "history-detail"
    static let textIdentifier = "history-detail-text"
    static let backIdentifier = "history-detail-back"
    static func actionIdentifier(_ action: NotchHistoryDetail.Action) -> String {
        "history-detail-\(action)"
    }

    let detail: NotchHistoryDetail
    let palette: VoiceBarNotchContrastPalette
    let actions: NotchHistoryDetailActions
    let onBack: () -> Void

    @State private var copyFeedback = CopyFeedback()
    @State private var playbackOwner = UUID()

    private var isVoiceBusy: Bool { actions.playback?.isVoiceBusy == true }
    private var failureMessage: String? {
        guard actions.playback?.requestOwner == playbackOwner else { return nil }
        return actions.playback?.failureMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if let question = detail.question {
                        Text("Asked “\(question)”")
                            .font(.system(size: NotchHistoryPresentation.rowMetaFontSize))
                            .foregroundStyle(palette.secondary.color)
                    }
                    let shown = detail.text.isEmpty ? "No text was kept for this entry." : detail.text
                    Text(shown)
                        .font(.system(size: NotchHistoryPresentation.rowTextFontSize))
                        .foregroundStyle(detail.text.isEmpty ? palette.tertiary.color : palette.primary.color)
                        .lineSpacing(2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(shown)
                        .accessibilityIdentifier(Self.textIdentifier)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NotchHistoryPresentation.rowLeadingPadding)
            }
            .scrollIndicators(.automatic)
            if let failureMessage {
                Text(failureMessage)
                    .font(.system(size: NotchHistoryPresentation.rowMetaFontSize))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NotchHistoryPresentation.rowLeadingPadding)
                    .accessibilityLabel(failureMessage)
            }
            actionBar
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
        .accessibilityAction(.escape) { onBack() }
        .onChange(of: isVoiceBusy) { _, busy in
            if busy { actions.playback?.stop(ownedBy: playbackOwner) }
        }
        .onDisappear { actions.playback?.stop(ownedBy: playbackOwner) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(detail.scope.title).font(.system(size: NotchHistoryPresentation.rowMetaFontSize, weight: .medium))
                }
                .foregroundStyle(palette.primary.color)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PillControlTooltip(text: "Back to \(detail.scope.title)"))
            .accessibilityLabel("Back to \(detail.scope.title)")
            .accessibilityIdentifier(Self.backIdentifier)
            Spacer(minLength: 0)
            if let meta = detail.meta {
                Text(meta)
                    .font(.system(size: NotchHistoryPresentation.rowMetaFontSize))
                    .monospacedDigit()
                    .foregroundStyle(palette.tertiary.color)
                    .lineLimit(1)
                    .padding(.trailing, NotchHistoryPresentation.rowTrailingPadding)
            }
        }
        .padding(.leading, NotchHistoryPresentation.rowLeadingPadding - 6)
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            ForEach(detail.actions, id: \.self) { action in
                actionButton(action)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchHistoryPresentation.rowLeadingPadding - 4)
    }

    private func actionButton(_ action: NotchHistoryDetail.Action) -> some View {
        let isCopied = action == .copy && copyFeedback.isCopied(at: Date())
        let isPlaying = action == .play && actions.playback?.requestOwner == playbackOwner
            && actions.playback?.playingURL != nil
        let label = isCopied ? "Copied" : isPlaying ? "Stop" : action.label
        let help = isCopied ? "Copied" : isPlaying ? "Stop" : action.help
        let symbol = isCopied ? VoiceBarActionSymbol.copied : isPlaying ? "stop.fill" : action.symbol
        let reason = unavailableReason(action)
        return Button { perform(action) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(label).font(.system(size: NotchHistoryPresentation.rowMetaFontSize, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(palette.primary.color)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Capsule().fill(palette.primary.color.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .opacity(reason == nil ? 1 : 0.45)
        .background(PillControlTooltip(text: reason ?? help))
        .accessibilityLabel(help)
        .accessibilityHint(reason ?? "")
        .accessibilityIdentifier(Self.actionIdentifier(action))
    }

    /// Why an action can't run right now, or nil when it can.
    private func unavailableReason(_ action: NotchHistoryDetail.Action) -> String? {
        switch action {
        case .play:
            if isVoiceBusy { return SettingsHistoryCopy.playBusy }
            guard let first = detail.audio.first, FileManager.default.fileExists(atPath: first.path) else {
                return "The audio file is missing"
            }
            return nil
        case .retranscribe:
            return actions.retranscriptionAvailability().reason
        case .reveal:
            guard let url = detail.revealURL, FileManager.default.fileExists(atPath: url.path) else {
                return "The audio file is missing"
            }
            return nil
        case .copy, .paste:
            return nil
        }
    }

    private func perform(_ action: NotchHistoryDetail.Action) {
        switch action {
        case .play:
            actions.playback?.toggle(detail.audio, owner: playbackOwner)
        case .copy:
            let succeeded = actions.copy(detail.entry)
            copyFeedback.copied(succeeded: succeeded, byPointer: CopyFeedback.isPointerEvent(NSApp.currentEvent), at: Date())
            guard succeeded else { return }
            AccessibilityNotification.Announcement("Copied").post()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(CopyFeedback.duration))
                copyFeedback.expire(at: Date())
            }
        case .paste:
            actions.paste(detail.entry)
        case .retranscribe:
            if let path = detail.recordingPath { actions.retranscribe(path) }
        case .reveal:
            if let url = detail.revealURL { actions.reveal(url) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
