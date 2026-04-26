import SwiftUI

struct SettingsView: View {
    let hotkeyEnabled: Bool
    let missingPermissions: [HotkeyPermission]
    let availableDevices: () -> [MicrophoneDevice]
    let selectedDeviceID: () -> String?
    let onSelectDevice: (String) -> Void

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            audioTab
                .tabItem { Label("Audio", systemImage: "mic.fill") }
        }
        .frame(width: 420, height: 260)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Shortcut") {
                    Text(VoiceBarHotkeyContract.primaryShortcutLabel)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hotkeyEnabled ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(hotkeyStatusText)
                    }
                }
                if !missingPermissions.isEmpty {
                    LabeledContent("Fix") {
                        Button("Open System Settings") {
                            openAccessibilitySettings()
                        }
                    }
                }
            }

            Section("Gestures") {
                LabeledContent("Single tap") {
                    Text(VoiceBarHotkeyContract.singleTapDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hold") {
                    Text(VoiceBarHotkeyContract.holdDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Double-tap") {
                    Text(VoiceBarHotkeyContract.doubleTapDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(VoiceBarHotkeyContract.repasteShortcutLabel) {
                    Text(VoiceBarHotkeyContract.repasteDescription)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Input Device") {
                let devices = availableDevices()
                let selected = selectedDeviceID()

                if devices.isEmpty {
                    Text("No input devices found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Microphone", selection: Binding(
                        get: { selected ?? "" },
                        set: { onSelectDevice($0) }
                    )) {
                        ForEach(devices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var hotkeyStatusText: String {
        if hotkeyEnabled { return "Active" }
        let names = missingPermissions.map {
            switch $0 {
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            }
        }
        return "Missing: \(names.joined(separator: ", "))"
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
