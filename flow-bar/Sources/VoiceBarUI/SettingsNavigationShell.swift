import SwiftUI

/// Native settings navigation shared by the production app and the isolated development host.
struct SettingsNavigationShell<Detail: View>: View {
    @Binding var selection: SettingsTab
    let footer: VoiceBarFooterPresentation
    @ViewBuilder let detail: Detail

    init(
        selection: Binding<SettingsTab>,
        footer: VoiceBarFooterPresentation,
        @ViewBuilder detail: () -> Detail
    ) {
        _selection = selection
        self.footer = footer
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(SettingsTab.allCases, selection: $selection) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                Divider()
                VoiceBarStatusFooter(presentation: footer)
                    .padding(12)
            }
            .frame(width: 172)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

public enum SettingsDictionarySource: Hashable, Sendable {
    case user
    case included
    case unknown

    var title: String {
        switch self {
        case .user:
            "Your terms"
        case .included:
            "Included terms"
        case .unknown:
            "Terms"
        }
    }
}
