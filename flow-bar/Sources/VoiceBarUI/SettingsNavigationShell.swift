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
                List(SettingsTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.systemImage)
                                .symbolRenderingMode(.monochrome)
                                .foregroundColor(selection == tab ? .white : .secondary)
                                .frame(width: 20)
                            Text(tab.title)
                                .foregroundColor(selection == tab ? .white : .primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(selection == tab ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
                .onMoveCommand { selection = selection.moved($0) }

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
