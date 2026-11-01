import SwiftUI

/// Bounded sibling panes. Neither transcript ideal height nor a long list can paint into the other pane.
/// All content and actions come from the caller; this component cannot open media or start capture.
struct SettingsHistoryWorkspace<List: View, Detail: View>: View {
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail
    @State private var listFraction: CGFloat = 0.32
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let regions = SettingsHistoryLayout.regions(size: geometry.size, listFraction: listFraction)
            // AnyLayout changes geometry without replacing the selected entry's state or scroll view.
            let usableLength = max(0, (regions.sideBySide ? geometry.size.width : geometry.size.height) - 8)
            let actualFraction = usableLength > 0
                ? (regions.sideBySide ? regions.list.width : regions.list.height) / usableLength : 0
            let layout = regions.sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                list().frame(width: regions.list.width, height: regions.list.height).clipped()
                separator(sideBySide: regions.sideBySide,
                          length: usableLength, actualFraction: actualFraction)
                    .frame(width: regions.divider.width, height: regions.divider.height)
                detail().frame(width: regions.detail.width, height: regions.detail.height).clipped()
            }
        }
        .clipped()
    }

    private func separator(sideBySide: Bool, length: CGFloat, actualFraction: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .separatorColor).opacity(0.45)
            Capsule().fill(.secondary.opacity(0.5))
                .frame(width: sideBySide ? 3 : 32, height: sideBySide ? 32 : 3)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            if dragStart == nil { dragStart = actualFraction }
            let delta = sideBySide ? value.translation.width : value.translation.height
            listFraction = SettingsHistoryLayout.clampFraction((dragStart ?? actualFraction) + delta / max(1, length), maximum: sideBySide ? 0.6 : 0.85)
        }.onEnded { _ in dragStart = nil })
        .accessibilityIdentifier("history-pane-divider")
        .accessibilityElement()
        .accessibilityLabel("Resize history list and transcript")
        .accessibilityValue("List \(Int(actualFraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: listFraction = SettingsHistoryLayout.clampFraction(actualFraction + 0.05, maximum: sideBySide ? 0.6 : 0.85)
            case .decrement: listFraction = SettingsHistoryLayout.clampFraction(actualFraction - 0.05, maximum: sideBySide ? 0.6 : 0.85)
            @unknown default: break
            }
        }
        .help("Drag to resize the list and selected transcript. Use VoiceOver adjust to resize with the keyboard.")
    }
}

/// Stable identity and action regions remain visible while only the transcript/details scroll.
struct SettingsHistoryDetailPane<Header: View, Content: View, Actions: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header().padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView(.vertical) {
                content().frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()
            Divider()
            actions().padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped()
    }
}
