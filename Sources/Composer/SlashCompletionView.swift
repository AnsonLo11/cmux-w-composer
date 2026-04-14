import SwiftUI

/// Floating completion popup for slash commands, shown above the Composer text field.
struct SlashCompletionView: View {
    let commands: [SlashCommand]
    @Binding var selectedIndex: Int
    let onSelect: (SlashCommand) -> Void

    private static let maxVisibleHeight: CGFloat = 300
    private static let listWidth: CGFloat = 360
    private static let tooltipMaxWidth: CGFloat = 300

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
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                        CommandRow(
                            command: command,
                            isSelected: index == selectedIndex
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(command)
                        }
                        .onHover { hovering in
                            if hovering {
                                selectedIndex = index
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: Self.maxVisibleHeight)
            .frame(width: Self.listWidth)
            .onChange(of: selectedIndex) { newIndex in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: - Tooltip

    @ViewBuilder
    private var tooltipView: some View {
        if let command = commands[safe: selectedIndex],
           !command.description.isEmpty {
            Text(command.description)
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

// MARK: - Command Row with category tag

private struct CommandRow: View {
    let command: SlashCommand
    let isSelected: Bool

    private var categoryStyle: (label: String, fg: Color, bg: Color) {
        switch command.source {
        case .builtin:
            return (
                "Built-in",
                Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0),       // #10B981
                Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0).opacity(0.10)
            )
        case .plugin:
            return (
                "Skill",
                Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0),       // #3B82F6
                Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0).opacity(0.12)
            )
        case .userCommand, .projectCommand:
            return (
                "Custom",
                Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0),       // #A855F7
                Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0).opacity(0.12)
            )
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(command.name)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text(categoryStyle.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(categoryStyle.fg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryStyle.bg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
