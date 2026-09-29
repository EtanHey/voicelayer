import SwiftUI

/// F3 step 1: Settings' three permission rows, re-read every second so a grant in System Settings shows up here.
struct SetupWizardPermissionsBody: View {
    let dependencies: SetupWizardDependencies
    @State private var snapshot: SetupPermissionSnapshot?

    var body: some View {
        let step = SetupPermissionsStep(snapshot: snapshot ?? dependencies.permissionSnapshot())
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(Array(step.rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    permissionRow(row)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            if let note = step.restartNote {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                }
            } else if step.allGranted {
                Label("All three are allowed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("In the list that opens, turn VoiceBar on. This page updates by itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func permissionRow(_ row: SetupPermissionRow) -> some View {
        HStack(spacing: 10) {
            Text(row.label)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle()
                    .fill(row.isGranted ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(row.status).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let action = row.action {
                Button(action.title) { perform(action) }
                    .accessibilityLabel("\(action.title) \(row.label)")
            }
        }
        .frame(minHeight: 40)
    }

    private func perform(_ action: SetupPermissionAction) {
        SettingsPermissionActions.perform(
            action,
            openURL: dependencies.openURL,
            requestMicrophone: dependencies.onRequestMicrophone,
            refresh: refresh
        )
    }

    private func refresh() {
        snapshot = dependencies.permissionSnapshot()
    }
}
