import AppKit
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
                // AIDEV-NOTE: Native List(selection:) owns ↑/↓ and the AX selected row; the label keeps P07's
                // explicit white-on-accent pill so the selected icon stays readable (R5) in every focus state.
                List(SettingsTab.allCases, selection: Binding<SettingsTab?>(
                    get: { selection },
                    set: { if let tab = $0 { selection = tab } }
                )) { tab in
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
                    .background(SidebarNativeHighlightSuppressor())
                    .tag(tab)
                    .listRowSeparator(.hidden)
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

/// Keeps the native table selection (arrow keys, the AX selected row) but stops the table drawing its own
/// highlight, which would ring the row's white-on-accent pill (P07 R5) with a second, darker one.
private struct SidebarNativeHighlightSuppressor: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var ancestor = superview
            while let view = ancestor, !(view is NSTableView) {
                ancestor = view.superview
            }
            (ancestor as? NSTableView)?.selectionHighlightStyle = .none
        }
    }

    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
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
