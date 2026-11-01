import SwiftUI

/// One stock segmented control. The system owns its material, sliding selection,
/// radio accessibility, focus and keyboard behavior. No extra material is painted
/// over (or behind) its selected label.
struct SettingsHistoryScopePicker: View {
    @Binding var selection: SettingsHistoryScope
    var body: some View {
        Picker("History scope", selection: $selection) {
            ForEach(SettingsHistoryScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .frame(width: 274, alignment: .leading)
        .accessibilityLabel("History scope")
        .accessibilityIdentifier("history-scope-picker")
    }
}
