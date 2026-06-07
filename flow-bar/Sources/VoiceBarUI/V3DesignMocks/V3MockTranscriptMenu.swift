// V3MockTranscriptMenu.swift — FUNCTIONAL transcript menu (R3 redo, Etan 16:25).
//
// Real components, real interaction — no daemon/socket wiring:
//   • rows highlight on HOVER and reveal the re-transcribe affordance
//   • CLICK a row → inline TextField, edit in place, Enter commits
//     (AIDEV-NOTE: commit feeds the correction log at wiring time)
//   • "Transcribe now" is a live Button → row flips to "Transcribing…"
// The black shell + outward-flare silhouette belong to the CONTAINER
// (V3IslandContainerView) — this view is the dark content surface only
// (glass/black never on content).

import SwiftUI

// MARK: - Model (mutable — inline fixes persist for the session)

struct V3TranscriptItem: Identifiable {
    let id: Int
    var firstLine: String
    let when: String
    let isHebrew: Bool

    init(_ id: Int, _ firstLine: String, when: String, isHebrew: Bool = false) {
        self.id = id
        self.firstLine = firstLine
        self.when = when
        self.isHebrew = isHebrew
    }
}

// MARK: - The menu

public struct V3TranscriptMenuView: View {
    @State private var items: [V3TranscriptItem] = [
        .init(0, "Fix the daemon launch agent so it restarts after sleep instead of…", when: "2m"),
        .init(1, "Send the Theo candidates to the Drive folder and label round two…", when: "14m"),
        .init(2, "הוסף את המונח VoiceLayer למילון התעתיק ותוודא שזה נשמר", when: "31m", isHebrew: true),
        .init(3, "Merge the settings PR once the verify artifact is copied into the…", when: "1h"),
    ]
    @State private var hoveredID: Int?
    @State private var editingID: Int?
    @State private var transcribingPending = false
    @FocusState private var focusedField: Int?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ForEach($items) { $item in
                row($item)
                if item.id != items.last?.id {
                    Divider().overlay(Color.white.opacity(0.06))
                        .padding(.leading, V3Theme.menuRowHPad)
                }
            }

            Divider().overlay(Color.white.opacity(0.06))

            // Untranscribed audio row (Etan spec item 2) — live button.
            HStack {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(V3Theme.wingTextSecondary)
                Text(transcribingPending ? "Transcribing…" : "1:07 untranscribed")
                    .font(.callout)
                    .foregroundStyle(V3Theme.wingTextSecondary)
                Spacer()
                if !transcribingPending {
                    Button {
                        withAnimation(V3Theme.springOpen) { transcribingPending = true }
                    } label: {
                        Text("Transcribe now")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(V3Theme.wingText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // R4: KeyablePanel made this button first responder -> AppKit
                    // drew a candy-blue focus ring. Quiet capsule only (S18).
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, V3Theme.menuRowHPad)
            .padding(.vertical, V3Theme.menuRowVPad)
        }
        .padding(.vertical, 6)
        .background(V3Theme.menuContentSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: Binding<V3TranscriptItem>) -> some View {
        let value = item.wrappedValue
        let hovered = hoveredID == value.id
        let editing = editingID == value.id

        let rowContent = HStack(spacing: 8) {
            VStack(alignment: value.isHebrew ? .trailing : .leading, spacing: 2) {
                if editing {
                    // Inline click-to-fix: real TextField, Enter commits.
                    TextField("", text: item.firstLine)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(V3Theme.wingText)
                        .focused($focusedField, equals: value.id)
                        .onSubmit { editingID = nil }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        )
                } else {
                    Text(value.firstLine)
                        .font(.callout)
                        .foregroundStyle(V3Theme.wingText)
                        .lineLimit(1)
                }
                Text(value.when + " ago")
                    .font(.footnote)
                    .foregroundStyle(V3Theme.wingTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: value.isHebrew ? .trailing : .leading)
            .environment(\.layoutDirection, value.isHebrew ? .rightToLeft : .leftToRight)

            // Hover-revealed re-transcribe affordance — hidden at rest (restraint).
            if hovered, !editing {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 12))
                    .foregroundStyle(V3Theme.wingTextSecondary)
                    .transition(.opacity)
            }
        }

        Group {
            if editing {
                rowContent
            } else {
                Button {
                    editingID = value.id
                    focusedField = value.id
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, V3Theme.menuRowHPad)
        .padding(.vertical, V3Theme.menuRowVPad)
        .background(hovered ? Color.white.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredID = inside ? value.id : (hoveredID == value.id ? nil : hoveredID)
        }
    }
}

#Preview("Functional transcript menu") {
    V3TranscriptMenuView()
        .frame(width: V3Theme.menuWidth - 2 * V3Theme.radiiExpanded.top)
        .padding(30)
        .background(Color.black)
}
