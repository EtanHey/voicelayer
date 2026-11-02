import AppKit
import SwiftUI

/// Native settings navigation shared by the production app and the isolated development host.
struct SettingsNavigationShell<Detail: View>: View {
    @Binding var selection: SettingsTab
    @State private var isFooterHovered = false
    @State private var showsErrorDetails = false
    let footer: VoiceBarFooterPresentation
    let installedVersion: VoiceBarInstalledVersion
    let versionStatus: VoiceBarVersionStatus?
    @ViewBuilder let detail: Detail

    init(
        selection: Binding<SettingsTab>,
        footer: VoiceBarFooterPresentation,
        installedVersion: VoiceBarInstalledVersion = .current(),
        versionStatus: VoiceBarVersionStatus? = nil,
        @ViewBuilder detail: () -> Detail
    ) {
        _selection = selection
        self.footer = footer
        self.installedVersion = installedVersion
        self.versionStatus = versionStatus
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
                Button {
                    if footer.errorDetails != nil {
                        showsErrorDetails = true
                    } else {
                        selection = .general
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        VoiceBarStatusIndicator(presentation: footer)
                        SettingsVersionFooter(installed: installedVersion, status: versionStatus)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(isFooterHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isFooterHovered = $0 }
                .accessibilityLabel(footer.errorDetails != nil ? "Show error details" : "Open General settings")
                .accessibilityValue("\(footer.status). VoiceBar \(installedVersion.label). \(versionStatus?.message ?? "")")
                .help("VoiceBar \(installedVersion.label). \(versionStatus?.message ?? "")\n" +
                      (footer.errorDetails != nil ? "Show full current error details" : "Open General settings for permissions and setup"))
                .popover(isPresented: $showsErrorDetails) {
                    if let details = footer.errorDetails {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Error details").font(.headline)
                                Spacer()
                                SettingsCopyButton(text: details, label: "error details")
                            }
                            ScrollView {
                                Text(verbatim: details)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 280)
                        }
                        .padding(16)
                        .frame(width: 380)
                    }
                }
                .onChange(of: footer.errorDetails) { _, _ in showsErrorDetails = false }
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

/// A single secondary status line; full release provenance and update copy stay available on hover.
struct SettingsVersionFooter: View {
    let installed: VoiceBarInstalledVersion
    let status: VoiceBarVersionStatus?

    var body: some View {
        HStack(spacing: 4) {
            Text(installed.version.map { "v\($0)" } ?? "Unknown")
                .monospacedDigit()
                .fixedSize()
            if let status {
                Text("·")
                Image(systemName: status.symbolName)
                    .foregroundStyle(tint(status))
                Text(status.sidebarMessage)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .help("VoiceBar \(installed.label). \(status?.message ?? "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VoiceBar \(installed.label)")
        .accessibilityValue(status?.message ?? "")
    }

    private func tint(_ status: VoiceBarVersionStatus) -> Color {
        switch status {
        case .latest, .ahead: .green
        case .available: .accentColor
        case .checking, .couldNotCheck: .secondary
        }
    }
}

extension VoiceBarVersionStatus {
    var sidebarMessage: String {
        switch self {
        case .checking: "Checking…"
        case .latest: "Up to date"
        case .ahead: "Ahead of release"
        case .available: "Update available"
        case .couldNotCheck: "Check failed"
        }
    }
}
