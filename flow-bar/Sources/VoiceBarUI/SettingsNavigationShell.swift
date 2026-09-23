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
                VStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        ZStack {
                            Button {
                                selection = tab
                            } label: {
                                Color.clear.frame(height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tab.title)
                            HStack(spacing: 10) {
                                Image(systemName: tab.systemImage)
                                    .foregroundStyle(Color.primary)
                                    .frame(width: 18)
                                Text(tab.title)
                                    .foregroundStyle(Color.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                        .background(selection == tab ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
                Spacer(minLength: 0)

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
