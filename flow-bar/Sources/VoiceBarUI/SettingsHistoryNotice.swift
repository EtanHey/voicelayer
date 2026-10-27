import SwiftUI

enum SettingsHistoryCopy {
    static let playBusy = "Can't play while VoiceBar is recording, transcribing or speaking."
}

struct SettingsHistoryNotice: View {
    enum Kind: Equatable {
        case busy
        case failure(String)

        init?(isVoiceBusy: Bool, failureMessage: String?) {
            if isVoiceBusy {
                self = .busy
            } else if let failure = SettingsCopyPayload.nonempty(failureMessage) {
                self = .failure(failure)
            } else {
                return nil
            }
        }

        var symbol: String {
            switch self {
            case .busy: "play.slash"
            case .failure: "exclamationmark.triangle.fill"
            }
        }

        var announcement: String? {
            guard case let .failure(failure) = self else { return nil }
            return failure
        }

        var message: String {
            switch self {
            case .busy: SettingsHistoryCopy.playBusy
            case let .failure(failure): failure
            }
        }
    }

    let kind: Kind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(symbolStyle)
                Text(kind.message)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if case .failure = kind {
                SettingsCopyButton(text: kind.message, label: "History playback error")
            } else {
                SettingsCopyButton(text: kind.message, label: "History playback error").hidden()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .onAppear(perform: announceFailure)
        .onChange(of: kind) { _, _ in announceFailure() }
    }

    private var symbolStyle: Color {
        switch kind {
        case .busy: .secondary
        case .failure: .orange
        }
    }

    private func announceFailure() {
        guard let announcement = kind.announcement else { return }
        AccessibilityNotification.Announcement(announcement).post()
    }
}

struct SettingsHistoryNoticeSlot: View {
    let kind: SettingsHistoryNotice.Kind?

    var body: some View {
        ZStack(alignment: .topLeading) {
            SettingsHistoryNotice(kind: .busy).hidden()
            if let kind {
                SettingsHistoryNotice(kind: kind).transition(.opacity)
            }
        }
    }
}
