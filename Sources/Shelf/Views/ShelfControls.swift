import AppKit
import SwiftUI

/// Tactile macOS button style with full rectangular hit-testing, crisp border in both Light & Dark mode,
/// smooth hover highlight, and responsive press feedback.
struct ShelfButtonStyle: ButtonStyle {
    enum Variant {
        case secondary
        case primary
        case destructive
        case subtle
    }

    var variant: Variant = .secondary
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 6
    var cornerRadius: CGFloat = 8
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ShelfButtonBody(
            configuration: configuration,
            variant: variant,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            cornerRadius: cornerRadius,
            fullWidth: fullWidth
        )
    }

    private struct ShelfButtonBody: View {
        let configuration: Configuration
        let variant: Variant
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let cornerRadius: CGFloat
        let fullWidth: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(foregroundColor)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: variant == .subtle ? 0 : 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(!reduceMotion && configuration.isPressed ? 0.972 : 1.0)
                .opacity(isEnabled ? 1.0 : 0.45)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: configuration.isPressed)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
                .onHover { hovering in
                    isHovered = isEnabled && hovering
                }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { isHovered = false }
                }
        }

        private var foregroundColor: Color {
            switch variant {
            case .primary:
                return .white
            case .destructive:
                return ShelfTheme.destructiveRed
            case .secondary:
                return .primary.opacity(0.92)
            case .subtle:
                return isHovered ? .primary : .secondary
            }
        }

        private var backgroundColor: Color {
            let isDark = colorScheme == .dark
            switch variant {
            case .primary:
                if configuration.isPressed {
                    return Color.accentColor.opacity(0.84)
                }
                return isHovered ? Color.accentColor.opacity(0.92) : Color.accentColor
            case .destructive:
                if configuration.isPressed {
                    return Color.red.opacity(0.22)
                }
                return isHovered ? Color.red.opacity(0.14) : Color.red.opacity(0.08)
            case .secondary:
                if configuration.isPressed {
                    return Color.primary.opacity(isDark ? 0.16 : 0.12)
                }
                return isHovered ? Color.primary.opacity(isDark ? 0.11 : 0.085) : Color.primary.opacity(isDark ? 0.065 : 0.048)
            case .subtle:
                if configuration.isPressed {
                    return Color.primary.opacity(0.11)
                }
                return isHovered ? Color.primary.opacity(0.065) : Color.clear
            }
        }

        private var borderColor: Color {
            let isDark = colorScheme == .dark
            switch variant {
            case .primary:
                return Color.white.opacity(isDark ? 0.22 : 0.18)
            case .destructive:
                return Color.red.opacity(0.26)
            case .secondary:
                return Color.primary.opacity(isHovered ? (isDark ? 0.20 : 0.16) : (isDark ? 0.12 : 0.10))
            case .subtle:
                return .clear
            }
        }
    }
}

/// Circular / rounded icon button with full hit target, smooth spring feedback, and optional frosted backdrop.
struct ShelfIconButton: View {
    let systemName: String
    var size: CGFloat = 26
    var iconSize: CGFloat = 11.5
    var helpText: String = ""
    var usesMaterial: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .background {
                    if usesMaterial {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0.03))
                            )
                    } else {
                        Circle()
                            .fill(Color.primary.opacity(isHovered ? 0.12 : 0.055))
                    }
                }
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(isHovered ? (isDark ? 0.20 : 0.14) : (isDark ? 0.11 : 0.08)),
                            lineWidth: 0.65
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(IconPressStyle(reduceMotion: reduceMotion))
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    private struct IconPressStyle: ButtonStyle {
        let reduceMotion: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(!reduceMotion && configuration.isPressed ? 0.91 : 1.0)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: configuration.isPressed)
        }
    }
}

/// Clean macOS recessed segmented control with a sliding elevated pill thumb that looks refined
/// in both Light & Dark Mode and guarantees 100% full-cell clickability.
struct ShelfSegmentedControl<Option: Hashable>: View {
    struct Segment: Identifiable {
        let value: Option
        let title: String
        var icon: String? = nil
        var dotColor: Color? = nil
        var count: Int? = nil
        var id: Option { value }
    }

    let segments: [Segment]
    @Binding var selection: Option
    var verticalPadding: CGFloat = 5.5
    var equalWidthSegments: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumbNamespace

    var body: some View {
        let isDark = colorScheme == .dark
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                SegmentCell(
                    segment: segment,
                    isSelected: selection == segment.value,
                    verticalPadding: verticalPadding,
                    equalWidth: equalWidthSegments,
                    namespace: thumbNamespace
                ) {
                    if selection != segment.value { selection = segment.value }
                }
            }
        }
        .animation(reduceMotion ? nil : ShelfMotion.control, value: selection)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.075 : 0.052))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDark ? 0.11 : 0.08), lineWidth: 0.75)
        )
    }

    private struct SegmentCell: View {
        let segment: Segment
        let isSelected: Bool
        let verticalPadding: CGFloat
        let equalWidth: Bool
        let namespace: Namespace.ID
        let onTap: () -> Void

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            let isDark = colorScheme == .dark
            Button(action: onTap) {
                HStack(spacing: 5) {
                    if let dotColor = segment.dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                            .opacity(isSelected ? 1.0 : (isHovered ? 0.92 : 0.78))
                    } else if let icon = segment.icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }

                    Text(segment.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let count = segment.count {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .fixedSize()
                            .foregroundStyle(
                                isSelected
                                    ? Color.secondary
                                    : Color.secondary.opacity(0.68)
                            )
                    }
                }
                .frame(maxWidth: equalWidth ? .infinity : nil)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, equalWidth ? 8 : 9)
                .fixedSize(horizontal: !equalWidth, vertical: false)
                .foregroundStyle(
                    isSelected
                        ? Color.primary
                        : Color.primary.opacity(isHovered ? 0.88 : 0.68)
                )
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(isDark ? 0.16 : 0.65),
                                                Color.primary.opacity(isDark ? 0.10 : 0.08)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.65
                                    )
                            )
                            .shadow(color: .black.opacity(isDark ? 0.28 : 0.08), radius: 2.5, x: 0, y: 1)
                            .matchedGeometryEffect(id: "selectedSegment", in: namespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color.primary.opacity(isDark ? 0.065 : 0.045))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// Native single-level Sort Menu + 1-click Ascending/Descending toggle control.
/// Fixes SwiftUI Menu+Picker nested submenu bug and guarantees 100% full-bounds clickability and hover feedback.
struct ShelfSortControl: View {
    let sortField: LibrarySortField
    let sortAscending: Bool
    var language: AppLanguage = .zh
    let onSelectField: (LibrarySortField) -> Void
    let onSetAscending: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFieldHovered = false
    @State private var isDirHovered = false
    @State private var anchorNSView: NSView? = nil

    var body: some View {
        let isDark = colorScheme == .dark
        HStack(spacing: 0) {
            Button {
                presentFlatNativeMenu()
            } label: {
                HStack(spacing: 5) {
                    Text(sortField.menuTitle(in: language))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary.opacity(0.88))
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .background(isFieldHovered ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isFieldHovered)
            .onHover { isFieldHovered = $0 }
            .accessibilityLabel(language.tr("排序方式", "Sort By"))
            .help(language.tr("选择排序方式", "Choose sort field"))

            Rectangle()
                .fill(Color.primary.opacity(isDark ? 0.13 : 0.10))
                .frame(width: 0.75, height: 15)

            Button {
                onSetAscending(!sortAscending)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .rotationEffect(.degrees(sortAscending ? 180 : 0))
                    .animation(reduceMotion ? nil : ShelfMotion.control, value: sortAscending)
                    .frame(width: 27)
                    .padding(.vertical, 6)
                    .background(isDirHovered ? Color.primary.opacity(0.06) : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isDirHovered)
            .onHover { isDirHovered = $0 }
            .accessibilityLabel(sortAscending ? sortField.ascendingLabel(in: language) : sortField.descendingLabel(in: language))
            .help(sortAscending ? sortField.ascendingLabel(in: language) : sortField.descendingLabel(in: language))
        }
        .fixedSize()
        .background(
            MenuAnchorRepresentable(nsView: $anchorNSView)
                .allowsHitTesting(false)
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.065 : 0.048))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(
                        isFieldHovered || isDirHovered
                            ? (isDark ? 0.20 : 0.16)
                            : (isDark ? 0.12 : 0.09)
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        )
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isFieldHovered || isDirHovered)
    }

    private func presentFlatNativeMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for field in LibrarySortField.allCases {
            menu.addItem(ClosureMenuItem(
                title: field.menuTitle(in: language),
                state: field == sortField ? .on : .off
            ) {
                onSelectField(field)
            })
        }

        menu.addItem(.separator())

        // Put the natural primary order first (e.g. A->Z first for title, newest/highest first for others)
        let options: [(title: String, asc: Bool)] = sortField == .title
            ? [(sortField.ascendingLabel(in: language), true), (sortField.descendingLabel(in: language), false)]
            : [(sortField.descendingLabel(in: language), false), (sortField.ascendingLabel(in: language), true)]

        for opt in options {
            menu.addItem(ClosureMenuItem(
                title: opt.title,
                state: sortAscending == opt.asc ? .on : .off
            ) {
                onSetAscending(opt.asc)
            })
        }

        if let anchor = anchorNSView {
            let yPos: CGFloat = anchor.isFlipped ? (anchor.bounds.height + 4) : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: yPos), in: anchor)
        } else if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

private struct MenuAnchorRepresentable: NSViewRepresentable {
    @Binding var nsView: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            self.nsView = v
        }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        if nsView !== view {
            DispatchQueue.main.async {
                self.nsView = view
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
}
