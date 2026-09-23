import SwiftUI

/// The production MenuBarExtra body, shared with the offscreen visual harness.
public struct MenuBarPopoverView: View {
    public let footer: VoiceBarFooterPresentation
    public let hotkeyHint: String
    public let microphoneName: String
    public let transcript: String
    public let degradationHint: String?
    public let onCopy: () -> Void
    public let onSettings: () -> Void
    public let onQuit: () -> Void

    public init(
        footer: VoiceBarFooterPresentation,
        hotkeyHint: String,
        microphoneName: String,
        transcript: String,
        degradationHint: String? = nil,
        onCopy: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.footer = footer
        self.hotkeyHint = hotkeyHint
        self.microphoneName = microphoneName
        self.transcript = transcript
        self.degradationHint = degradationHint
        self.onCopy = onCopy
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let degradationHint {
                Label(degradationHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.orange)
                Divider()
            }
            VoiceBarStatusFooter(presentation: footer)
            Text(hotkeyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "mic")
                Text(microphoneName)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            if !transcript.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(transcript)
                        .font(.caption)
                        .lineLimit(3)
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy last transcript")
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }
            Divider()
            Button("Open Settings…", action: onSettings)
            Button("Quit VoiceBar", action: onQuit)
        }
        .frame(width: 310)
        .padding(12)
    }
}
