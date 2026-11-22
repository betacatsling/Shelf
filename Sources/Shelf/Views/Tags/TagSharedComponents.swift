import AppKit
import SwiftUI

enum TagInputParser {
    private static let separators = CharacterSet(charactersIn: ",，;；")

    static func splitBatchInput(_ raw: String) -> [String] {
        raw.components(separatedBy: separators)
            .map(\.trimmed)
            .filter { !$0.isEmpty }
    }

    /// Returns the trimmed replacement only when the user actually changed the label
    /// away from both the canonical key and its current localized display string.
    static func validatedRename(from original: String, draft: String, in language: AppLanguage) -> String? {
        let trimmed = draft.trimmed
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != original && trimmed != MediaCategory.localizedTag(original, in: language) else {
            return nil
        }
        return trimmed
    }
}

extension TagOutlineRow {
    func fullBreadcrumb(in language: AppLanguage) -> String {
        let parts = (category.map { [$0] } ?? []) + ancestors
        return TagCatalog.formattedBreadcrumb(ancestors: parts, language: language)
    }
}

/// Shared inline creation row for new categories, top-level tags, and nested subtags.
struct TagInlineCreateRow: View {
    let icon: String
    let placeholder: String
    @Binding var draft: String
    let language: AppLanguage
    var leadingIndent: CGFloat = 0
    var compact: Bool = false
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if leadingIndent > 0 {
                Spacer().frame(width: leadingIndent)
            }

            Image(systemName: icon)
                .font(.system(size: compact ? 11 : 11.5))
                .foregroundStyle(Color.accentColor)
                .frame(width: compact ? 14 : 15)

            SearchCommandTextField(
                placeholder: placeholder,
                text: $draft,
                autoFocus: true,
                font: .systemFont(ofSize: compact ? 12 : 12.5),
                onSubmit: { _ in onCommit() },
                onEscape: onCancel
            )
            .frame(height: compact ? 18 : 19)

            Button(language.tr("创建", "Add"), action: onCommit)
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .primary,
                        horizontalPadding: compact ? 7 : 8,
                        verticalPadding: compact ? 2.5 : 3,
                        cornerRadius: 5
                    )
                )
                .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
                .disabled(draft.trimmed.isEmpty)

            Button(language.tr("取消", "Cancel"), action: onCancel)
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: compact ? 5 : 6,
                        verticalPadding: compact ? 2.5 : 3,
                        cornerRadius: 5
                    )
                )
                .font(.system(size: compact ? 10.5 : 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
    }
}

/// Shared destructive confirmation banner used by `TagManagerView` for tag & category deletion.
struct TagDeleteConfirmationBanner: View {
    let message: String
    let language: AppLanguage
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ShelfTheme.destructiveRed)
                .font(.system(size: 13))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(language.tr("删除", "Delete"), action: onConfirm)
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .destructive,
                        horizontalPadding: 10,
                        verticalPadding: 4.5,
                        cornerRadius: 6
                    )
                )
                .font(.system(size: 12, weight: .semibold))

            Button(language.tr("取消", "Cancel"), action: onCancel)
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: 8,
                        verticalPadding: 4.5,
                        cornerRadius: 6
                    )
                )
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.08))
    }
}
