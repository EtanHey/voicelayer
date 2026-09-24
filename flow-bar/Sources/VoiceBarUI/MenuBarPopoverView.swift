import SwiftUI

/// The production MenuBarExtra body, shared with the offscreen visual harness.
public struct MenuBarPopoverView: View {
    public let footer: VoiceBarFooterPresentation
    public let hotkeyHint: String
    public let microphoneName: String
    public let microphones: [MicrophoneDevice]
    public let selectedMicrophoneID: String?
    public let transcript: String
    public let degradationHint: String?
    public let onCopy: () -> Void
    public let onSettings: () -> Void
    public let onQuit: () -> Void
    public let onSelectMicrophone: (String) -> Void
    public let onLayout: ([String: CGRect]) -> Void

    public init(
        footer: VoiceBarFooterPresentation,
        hotkeyHint: String,
        microphoneName: String,
        microphones: [MicrophoneDevice] = [],
        selectedMicrophoneID: String? = nil,
        transcript: String,
        degradationHint: String? = nil,
        onCopy: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onSelectMicrophone: @escaping (String) -> Void = { _ in },
        onLayout: @escaping ([String: CGRect]) -> Void = { _ in }
    ) {
        self.footer = footer
        self.hotkeyHint = hotkeyHint
        self.microphoneName = microphoneName
        self.microphones = microphones
        self.selectedMicrophoneID = selectedMicrophoneID
        self.transcript = transcript
        self.degradationHint = degradationHint
        self.onCopy = onCopy
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.onSelectMicrophone = onSelectMicrophone
        self.onLayout = onLayout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let degradationHint {
                Label(degradationHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.orange)
                Divider()
            }
            HStack(spacing: 8) {
                VoiceBarStatusIndicator(presentation: footer)
                    .accessibilityIdentifier("popover-status")
                    .popoverFrame("status")
                Spacer(minLength: 0)
                Text(hotkeyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(hotkeyHint)
                    .accessibilityIdentifier("popover-hotkey")
                    .popoverFrame("hotkey")
            }
            HStack(spacing: 6) {
                Image(systemName: footer.privacySymbol)
                Text(footer.isLocalOnly ? "Transcribed on this Mac" : footer.privacy)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(footer.isLocalOnly ? "Audio and text never leave this Mac" : footer.privacy)
                if footer.isLocalOnly {
                    Image(systemName: "info.circle")
                        .help("Audio and text never leave this Mac")
                        .accessibilityLabel("Audio and text never leave this Mac")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .popoverFrame("locality")
            Menu {
                if microphones.isEmpty {
                    Text("No input devices found")
                } else {
                    ForEach(microphones, id: \.id) { device in
                        Button {
                            onSelectMicrophone(device.id)
                        } label: {
                            if device.id == selectedMicrophoneID {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                    Text(microphoneName)
                        .lineLimit(1)
                        .help(microphoneName)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Microphone: \(microphoneName)")
            .accessibilityIdentifier("popover-microphone")
            .popoverFrame("mic")
            if !transcript.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Text(popoverTranscriptPreview(transcript))
                        .accessibilityIdentifier("popover-transcript")
                        .popoverFrame("transcript")
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy last transcript")
                    .accessibilityLabel("Copy last transcript")
                    .accessibilityIdentifier("popover-copy")
                    .popoverFrame("copy")
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .popoverFrame("transcript-row")
            }
            Divider()
                .popoverFrame("divider")
            HStack(spacing: 8) {
                Button(action: onSettings) {
                    Text("Open Settings…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityIdentifier("popover-settings")
                .popoverFrame("settings")
                Button(action: onQuit) {
                    Text("Quit VoiceBar")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityIdentifier("popover-quit")
                .popoverFrame("quit")
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .popoverFrame("footer")
        }
        .frame(width: 276)
        .padding(12)
        .focusEffectDisabled()
        .coordinateSpace(name: "popover")
        .onPreferenceChange(PopoverFramesKey.self, perform: onLayout)
    }
}

func popoverTranscriptPreview(_ transcript: String) -> String {
    transcript.split(whereSeparator: \.isNewline).joined(separator: " ")
}

private struct PopoverFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func popoverFrame(_ id: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(
                key: PopoverFramesKey.self,
                value: [id: geometry.frame(in: .named("popover"))]
            )
        })
    }
}
