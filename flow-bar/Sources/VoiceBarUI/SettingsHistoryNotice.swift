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
    }

    let kind: Kind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(symbolStyle)
                Text(message)
                    .foregroundStyle(messageStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if case let .failure(failure) = kind {
                SettingsCopyButton(text: failure, label: "History playback error")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .onAppear(perform: announceFailure)
        .onChange(of: kind) { _, _ in announceFailure() }
    }

    private var message: String {
        switch kind {
        case .busy: SettingsHistoryCopy.playBusy
        case let .failure(failure): failure
        }
    }

    private var symbol: String {
        switch kind {
        case .busy: "speaker.slash"
        case .failure: "exclamationmark.triangle"
        }
    }

    private var symbolStyle: Color {
        switch kind {
        case .busy: .secondary
        case .failure: .orange
        }
    }

    private var messageStyle: Color {
        switch kind {
        case .busy: .secondary
        case .failure: .primary
        }
    }

    private func announceFailure() {
        guard case let .failure(failure) = kind else { return }
        AccessibilityNotification.Announcement(failure).post()
    }
}
