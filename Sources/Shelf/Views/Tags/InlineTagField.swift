import AppKit
import SwiftUI

/// Compact Things 3–style inline tag token field for `ItemEditorSheet`.
struct InlineTagField: View {
    let store: LibraryStore
    @Binding var selectedTags: [String]
    let language: AppLanguage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @State private var showPickerPopover: Bool = false

    private enum Suggestion: Identifiable {
        case existing(TagOutlineRow)
        case create(String)

        var id: String {
            switch self {
            case .existing(let row): return "existing:\(row.id)"
            case .create(let name): return "create:\(MediaCategory.tagMatchKey(name))"
            }
        }
    }

    private var trimmedQuery: String { query.trimmed }

    private var suggestions: [Suggestion] {
        guard !trimmedQuery.isEmpty else { return [] }
        let matched = TagCatalog.searchRows(matching: trimmedQuery, in: store.tagNodes)
            .filter { row in !selectedTags.contains { MediaCategory.tagsMatch($0, row.node.name) } }
            .prefix(6)
        var list = matched.map { Suggestion.existing($0) }
        if !store.tagExists(trimmedQuery) {
            list.append(.create(trimmedQuery))
        }
        return list
    }

    var body: some View {
        let currentSuggestions = suggestions
        let safeIdx = currentSuggestions.isEmpty ? 0 : min(max(highlightedIndex, 0), currentSuggestions.count - 1)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(language.tr("标签（可选）", "Tags (Optional)"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !selectedTags.isEmpty {
                    Button(language.tr("清空", "Clear")) {
                        selectedTags.removeAll()
                    }
                    .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 6, verticalPadding: 2, cornerRadius: 5))
                    .font(.system(size: 11))
                }

                Spacer()

                Button {
                    TagWindowController.shared.show(store: store)
                } label: {
                    Label(language.tr("管理标签…", "Manage Tags…"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 11))
                }
                .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 6, verticalPadding: 2, cornerRadius: 5))
            }

            HStack(alignment: .center, spacing: 6) {
                ShelfFlowLayout(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(selectedTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(MediaCategory.localizedTag(tag, in: language))
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)

                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 5)
                        .padding(.vertical, 3.5)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.7))
                    }

                    SearchCommandTextField(
                        placeholder: selectedTags.isEmpty
                            ? language.tr("输入添加标签，回车确认…", "Type tag & press Return…")
                            : language.tr("添加更多标签…", "Add tag…"),
                        text: $query,
                        autoFocus: false,
                        font: .systemFont(ofSize: 12),
                        onMoveUp: {
                            guard !currentSuggestions.isEmpty else { return }
                            highlightedIndex = (safeIdx - 1 + currentSuggestions.count) % currentSuggestions.count
                        },
                        onMoveDown: {
                            guard !currentSuggestions.isEmpty else { return }
                            highlightedIndex = (safeIdx + 1) % currentSuggestions.count
                        },
                        onSubmit: { _ in
                            if !currentSuggestions.isEmpty {
                                applySuggestion(currentSuggestions[safeIdx])
                            }
                        },
                        onEscape: { query = "" },
                        onDeleteBackwardWhenEmpty: {
                            if !selectedTags.isEmpty {
                                selectedTags.removeLast()
                            }
                        },
                        interceptSubmitWhenEmpty: false,
                        interceptEscapeWhenEmpty: false
                    )
                    .frame(minWidth: 125, maxWidth: 210, minHeight: 20, maxHeight: 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showPickerPopover.toggle()
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(language.tr("从标签列表选择", "Browse tags"))
                .popover(isPresented: $showPickerPopover, arrowEdge: .bottom) {
                    TagPickerContentView(
                        store: store,
                        selectedTags: $selectedTags,
                        language: language
                    ) {
                        showPickerPopover = false
                    }
                    .frame(width: 270)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
            .onChange(of: query) { _, _ in
                highlightedIndex = 0
            }
            .animation(reduceMotion ? nil : ShelfMotion.control, value: selectedTags)

            if !currentSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(currentSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionRow(suggestion, isHighlighted: index == safeIdx)
                    }
                }
                .padding(5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: Suggestion, isHighlighted: Bool) -> some View {
        Button {
            applySuggestion(suggestion)
        } label: {
            switch suggestion {
            case .existing(let row):
                HStack(spacing: 6) {
                    Image(systemName: row.hasChildren ? "tag.fill" : "tag")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(MediaCategory.localizedTag(row.node.name, in: language))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    let breadcrumb = row.fullBreadcrumb(in: language)
                    if !breadcrumb.isEmpty {
                        Text(breadcrumb)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())

            case .create(let raw):
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(language.tr("新建并添加「\(raw)」", "Create & add “\(raw)”"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func removeTag(_ tag: String) {
        selectedTags.removeAll { MediaCategory.tagsMatch($0, tag) }
    }

    private func applySuggestion(_ suggestion: Suggestion) {
        switch suggestion {
        case .existing(let row):
            selectedTags = MediaCategory.normalizeTags(selectedTags + [row.node.name])
        case .create(let raw):
            for piece in TagInputParser.splitBatchInput(raw) {
                if let created = store.addTag(piece) {
                    selectedTags = MediaCategory.normalizeTags(selectedTags + [created])
                }
            }
        }
        query = ""
    }
}
