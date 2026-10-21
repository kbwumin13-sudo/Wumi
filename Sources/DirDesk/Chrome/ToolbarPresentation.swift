import Foundation
import DirDeskCore

/// A single, pure-memory layout pass. Widths include the native menu's own label insets.
/// Keep the configured prefix on screen; the rest stays in order in More.
struct ToolbarPresentation {
    static let iconWidth: CGFloat = 32
    static let viewModeWidth: CGFloat = 140
    static let spacing: CGFloat = 4
    static let horizontalInset: CGFloat = 12
    static let separatorWidth: CGFloat = 17
    static let trailingGap: CGFloat = 8

    struct Item {
        let command: ToolbarCommand
        let width: CGFloat
        let expandedWidth: CGFloat
    }

    let visible: [Item]
    let overflow: [ToolbarCommand]
    let expandedStates: Set<ToolbarCommand>
    let searchWidth: CGFloat

    static func utilityWidth(split: Bool) -> CGFloat {
        // Two or three 32 pt buttons, a 1 pt separator, and 2 pt between controls.
        split ? 103 : 69
    }

    init(width: CGFloat, items: [Item], split: Bool) {
        let fixedWidth = Self.horizontalInset * 2 + Self.separatorWidth + Self.iconWidth
            + Self.trailingGap + Self.utilityWidth(split: split) + Self.trailingGap
        let capacity = max(0, width - fixedWidth - Self.iconWidth)
        var used: CGFloat = 0
        var count = 0
        for item in items {
            let next = item.width + (count == 0 ? 0 : Self.spacing)
            guard used + next <= capacity else { break }
            used += next
            count += 1
        }

        var slack = capacity - used
        var expanded: Set<ToolbarCommand> = []
        // Current sort/group state is useful even when ordinary command names are disabled.
        for item in items.prefix(count) where item.command == .sort || item.command == .grouping {
            let extra = max(0, item.expandedWidth - item.width)
            if extra <= slack {
                expanded.insert(item.command)
                slack -= extra
            }
        }
        visible = items.prefix(count).map { item in
            Item(command: item.command, width: expanded.contains(item.command) ? item.expandedWidth : item.width,
                 expandedWidth: item.expandedWidth)
        }
        overflow = items.dropFirst(count).map(\.command)
        expandedStates = expanded
        searchWidth = slack >= 200 - Self.iconWidth ? 200 : Self.iconWidth
    }
}
