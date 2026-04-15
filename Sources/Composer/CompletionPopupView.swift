import SwiftUI

// MARK: - CompletionItem protocol

/// Anything that can be shown as a row in `CompletionPopupView`.
/// Concrete conformers: `SlashCommand`, `FileEntry` (bash/@ completion).
protocol CompletionItem: Hashable {
    var name: String { get }
    var detail: String { get }
    var tagStyle: CompletionTagStyle { get }
}

/// Visual tag shown on the trailing edge of a row (e.g. "Built-in" / "File").
struct CompletionTagStyle: Equatable {
    let label: String
    let fg: Color
    let bg: Color
}

// MARK: - Generic completion popup

/// Floating completion popup, shown above the Composer text field.
/// Generic over any `CompletionItem` so the same visual language is shared
/// between slash-command completion, `@`-file completion, and bash-mode
/// Tab file completion.
struct CompletionPopupView<Item: CompletionItem>: View {
    let items: [Item]
    @Binding var selectedIndex: Int
    let onSelect: (Item) -> Void

    private static var maxVisibleHeight: CGFloat { 300 }
    private static var listWidth: CGFloat { 360 }
    private static var tooltipMaxWidth: CGFloat { 300 }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            commandList
            tooltipView
        }
        .padding(4)
    }

    // MARK: - Command List

    private var commandList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        CompletionRow(item: item, isSelected: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(item)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: Self.maxVisibleHeight)
            .frame(width: Self.listWidth)
            // Nudge the list only when keyboard nav moves selectedIndex to an
            // off-screen row. The hover feedback loop (hover -> selection ->
            // scrollTo(center) -> hover new row -> ...) is gone because we
            // stopped binding selectedIndex to hover events.
            .onChange(of: selectedIndex) { newIndex in
                proxy.scrollTo(newIndex, anchor: nil)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: - Tooltip

    @ViewBuilder
    private var tooltipView: some View {
        if let item = items[safe: selectedIndex],
           !item.detail.isEmpty {
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: Self.tooltipMaxWidth, alignment: .leading)
                .background(Color(nsColor: .darkGray))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .transition(.opacity)
        }
    }
}

// MARK: - Row

private struct CompletionRow<Item: CompletionItem>: View {
    let item: Item
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text(item.tagStyle.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(item.tagStyle.fg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(item.tagStyle.bg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
    }
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
