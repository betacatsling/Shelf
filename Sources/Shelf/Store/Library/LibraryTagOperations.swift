import Foundation

extension LibraryStore {
    // MARK: - Tag Search & Filter Tokens

    func hasSearchTag(_ rawTag: String) -> Bool {
        searchTokens.contains { MediaCategory.tagsMatch($0.tag, rawTag) }
    }

    func addSearchTag(_ rawTag: String) {
        let resolved = resolveTagName(rawTag)
        guard !resolved.isEmpty, !hasSearchTag(resolved) else { return }
        filterUntaggedOnly = false
        searchTokens.append(SearchTagToken(tag: resolved))
    }

    func toggleSearchTag(_ rawTag: String) {
        if hasSearchTag(rawTag) {
            searchTokens.removeAll { MediaCategory.tagsMatch($0.tag, rawTag) }
        } else {
            addSearchTag(rawTag)
        }
    }

    /// Narrows an active ancestor filter when selecting one of its descendants, or intersects unrelated tags.
    func refineTagFilter(with rawTag: String) {
        let resolved = resolveTagName(rawTag)
        guard !resolved.isEmpty else { return }
        if hasSearchTag(resolved) {
            toggleSearchTag(resolved)
            return
        }
        filterUntaggedOnly = false
        if let ancestorIdx = searchTokens.firstIndex(where: {
            TagCatalog.isDescendant(resolved, of: $0.tag, in: tagNodes)
        }) {
            var next = searchTokens
            next[ancestorIdx] = SearchTagToken(tag: resolved)
            searchTokens = next
        } else {
            searchTokens.append(SearchTagToken(tag: resolved))
        }
    }

    func selectSingleTagFilter(_ rawTag: String, switchToAllIfEmptyInCurrentDestination: Bool = false) {
        let resolved = resolveTagName(rawTag)
        guard !resolved.isEmpty else { return }
        if switchToAllIfEmptyInCurrentDestination {
            let hasMatchInDestination = usageCount(forTag: resolved, in: selectedDestination,
                                                   includeDescendants: true) > 0
            if !hasMatchInDestination && usageCount(forTag: resolved, includeDescendants: true) > 0 {
                selectedDestination = .all
                statusFilter = .allShelves
                searchText = ""
            }
        }
        filterUntaggedOnly = false
        searchTokens = [SearchTagToken(tag: resolved)]
    }

    func selectUntaggedFilter(switchToAllIfEmptyInCurrentDestination: Bool = false) {
        if switchToAllIfEmptyInCurrentDestination {
            let hasUntaggedInDestination = containsUntaggedRecord(in: selectedDestination)
            if !hasUntaggedInDestination && totalUntaggedCount > 0 {
                selectedDestination = .all
                statusFilter = .allShelves
                searchText = ""
            }
        }
        searchTokens = []
        filterUntaggedOnly = true
    }

    func toggleUntaggedFilter() {
        filterUntaggedOnly.toggle()
    }

    func clearSearch() {
        searchText = ""
        searchTokens = []
        filterUntaggedOnly = false
    }

    func commitTypedHashTags() {
        let parsed = LibraryQuery.ParsedSearch(text: searchText)
        guard !parsed.tagTerms.isEmpty else { return }
        for term in parsed.tagTerms {
            addSearchTag(term)
        }
        searchText = parsed.nonTagText
    }

    // MARK: - Tag Catalog Queries

    func tagExists(_ rawTag: String) -> Bool {
        let canonical = MediaCategory.canonicalTag(rawTag)
        guard !canonical.isEmpty else { return false }
        return tagNodes.contains { MediaCategory.tagsMatch($0.name, canonical) }
    }

    func tagAncestors(of rawTag: String) -> [String] {
        TagCatalog.ancestors(of: rawTag, in: tagNodes)
    }

    func resolveCategoryName(_ rawCategory: String) -> String? {
        let canonical = MediaCategory.canonicalTag(rawCategory)
        guard !canonical.isEmpty else { return nil }
        return tagCategories.first { MediaCategory.tagsMatch($0, canonical) }
    }

    func tagCount(inCategory rawCategory: String?) -> Int {
        guard let rawCategory else {
            let validIDs = Set(tagCategories.map(MediaCategory.tagMatchKey))
            return tagNodes.filter { node in
                guard let cat = node.category else { return true }
                return !validIDs.contains(MediaCategory.tagMatchKey(cat))
            }.count
        }
        let targetID = MediaCategory.tagMatchKey(rawCategory)
        return tagNodes.filter { $0.category.map(MediaCategory.tagMatchKey) == targetID }.count
    }

    func availableTags(prioritizing category: MediaCategory? = nil, including extra: [String] = []) -> [String] {
        var all = tagNodes.map(\.name)
        for raw in extra {
            let canonical = MediaCategory.canonicalTag(raw)
            guard !canonical.isEmpty else { continue }
            if !all.contains(where: { MediaCategory.tagsMatch($0, canonical) }) {
                all.append(canonical)
            }
        }
        guard let category else { return all }

        var relevant: [String] = []
        var otherStarter: [String] = []
        for tag in all {
            let isPresetForCategory = category.presetTags.contains { MediaCategory.tagsMatch($0, tag) }
            let isDefaultStarter = MediaCategory.defaultStarterTags.contains { MediaCategory.tagsMatch($0, tag) }
            if isPresetForCategory || !isDefaultStarter || usageCount(forTag: tag, in: .category(category)) > 0 {
                relevant.append(tag)
            } else {
                otherStarter.append(tag)
            }
        }
        return relevant + otherStarter
    }

    // MARK: - Tag & Category Catalog Mutations

    @discardableResult
    func addTagCategory(_ rawName: String) -> String? {
        let canonical = MediaCategory.canonicalTag(rawName)
        guard !canonical.isEmpty else { return nil }
        if let existing = resolveCategoryName(canonical) {
            return existing
        }
        guard isReady else { return nil }
        let normalized = TagCatalog.normalize(categories: tagCategories + [canonical], nodes: tagNodes)
        let shown = MediaCategory.localizedTag(canonical, in: language)
        commitTagCatalogChange(
            categories: normalized.categories,
            nodes: normalized.nodes,
            toast: language.tr("已添加分类「\(shown)」", "Added category “\(shown)”")
        )
        return canonical
    }

    @discardableResult
    func renameTagCategory(from oldRaw: String, to newRaw: String) -> String? {
        guard isReady, let oldCategory = resolveCategoryName(oldRaw) else { return nil }
        let trimmedNew = MediaCategory.canonicalTag(newRaw)
        guard !trimmedNew.isEmpty else { return nil }

        let existingTarget = tagCategories.first {
            !MediaCategory.tagsMatch($0, oldCategory) && MediaCategory.tagsMatch($0, trimmedNew)
        }
        let target = existingTarget ?? trimmedNew
        let merging = existingTarget != nil

        var updatedCategories: [String] = []
        for cat in tagCategories {
            if MediaCategory.tagsMatch(cat, oldCategory) {
                if !merging { updatedCategories.append(target) }
            } else {
                updatedCategories.append(cat)
            }
        }

        let updatedNodes = tagNodes.map { node in
            var copy = node
            if let cat = copy.category, MediaCategory.tagsMatch(cat, oldCategory) {
                copy.category = target
            }
            return copy
        }

        let normalized = TagCatalog.normalize(categories: updatedCategories, nodes: updatedNodes)
        guard normalized.categories != tagCategories || normalized.nodes != tagNodes else { return target }
        let oldShown = MediaCategory.localizedTag(oldCategory, in: language)
        let newShown = MediaCategory.localizedTag(target, in: language)
        commitTagCatalogChange(
            categories: normalized.categories,
            nodes: normalized.nodes,
            toast: language.tr("已将分类「\(oldShown)」重命名为「\(newShown)」", "Renamed category “\(oldShown)” to “\(newShown)”")
        )
        return target
    }

    func deleteTagCategory(_ rawName: String) {
        guard isReady, let target = resolveCategoryName(rawName) else { return }
        let updatedCategories = tagCategories.filter { !MediaCategory.tagsMatch($0, target) }
        let updatedNodes = tagNodes.map { node in
            var copy = node
            if let cat = copy.category, MediaCategory.tagsMatch(cat, target) {
                copy.category = nil
            }
            return copy
        }
        let normalized = TagCatalog.normalize(categories: updatedCategories, nodes: updatedNodes)
        let shown = MediaCategory.localizedTag(target, in: language)
        commitTagCatalogChange(
            categories: normalized.categories,
            nodes: normalized.nodes,
            toast: language.tr("已删除分类「\(shown)」", "Deleted category “\(shown)”")
        )
    }

    func setTagCategory(_ rawTag: String, category rawCategory: String?) {
        guard isReady else { return }
        guard let idx = tagNodes.firstIndex(where: { MediaCategory.tagsMatch($0.name, rawTag) }) else { return }
        let resolvedCat = rawCategory.flatMap { resolveCategoryName($0) }
        if rawCategory != nil && resolvedCat == nil { return }
        var updated = tagNodes
        updated[idx].category = resolvedCat
        if updated[idx].parent != nil {
            updated[idx].parent = nil
        }
        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: updated)
        guard normalized.nodes != tagNodes else { return }
        commitTagCatalogChange(categories: tagCategories, nodes: normalized.nodes)
    }

    @discardableResult
    func addTag(_ rawTag: String, category rawCategory: String? = nil, parent: String? = nil) -> String? {
        let canonical = MediaCategory.canonicalTag(rawTag)
        guard !canonical.isEmpty else { return nil }
        if let existing = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, canonical) }) {
            return existing.name
        }
        guard isReady else { return nil }
        let validParent: String?
        let resolvedCategory: String?
        if let parent {
            let resolvedParent = resolveTagName(parent)
            let parentNode = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, resolvedParent) })
            validParent = parentNode?.name
            resolvedCategory = parentNode?.category
        } else {
            validParent = nil
            resolvedCategory = rawCategory.flatMap { resolveCategoryName($0) }
        }
        let normalized = TagCatalog.normalize(
            categories: tagCategories,
            nodes: tagNodes + [TagNode(name: canonical, category: resolvedCategory, parent: validParent)]
        )
        let shown = MediaCategory.localizedTag(canonical, in: language)
        commitTagCatalogChange(
            categories: normalized.categories,
            nodes: normalized.nodes,
            toast: language.tr("已添加标签「\(shown)」", "Added tag “\(shown)”")
        )
        return canonical
    }

    @discardableResult
    func renameTag(from oldRaw: String, to newRaw: String) -> String? {
        guard isReady else { return nil }
        let canonicalNew = MediaCategory.canonicalTag(newRaw)
        guard !canonicalNew.isEmpty else { return nil }
        let oldCanonical = MediaCategory.canonicalTag(oldRaw)
        guard !oldCanonical.isEmpty else { return nil }

        let existingTarget = tagNodes.first {
            !MediaCategory.tagsMatch($0.name, oldRaw) && MediaCategory.tagsMatch($0.name, canonicalNew)
        }
        let target = existingTarget?.name ?? canonicalNew
        let mergingIntoExisting = existingTarget != nil

        var newNodes: [TagNode] = []
        var changed = false
        for var node in tagNodes {
            if MediaCategory.tagsMatch(node.name, oldRaw) {
                changed = true
                if mergingIntoExisting { continue }
                node.name = target
                if let p = node.parent, MediaCategory.tagsMatch(p, target) {
                    node.parent = nil
                }
            } else if let p = node.parent, MediaCategory.tagsMatch(p, oldRaw) {
                node.parent = target
                changed = true
            }
            newNodes.append(node)
        }
        if existingTarget == nil && !newNodes.contains(where: { MediaCategory.tagsMatch($0.name, target) }) {
            newNodes.append(TagNode(name: target, parent: nil))
            changed = true
        }
        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: newNodes)
        if normalized.nodes != tagNodes { changed = true }

        let recordsChanged = rewriteRecordTags { tags in
            guard tags.contains(where: { MediaCategory.tagsMatch($0, oldRaw) }) else { return nil }
            let mapped = tags.map { MediaCategory.tagsMatch($0, oldRaw) ? target : $0 }
            let deduped = MediaCategory.normalizeTags(mapped)
            return deduped == tags ? nil : deduped
        }

        let updatedTokens = Self.deduplicateTokens(
            searchTokens.map { token in
                MediaCategory.tagsMatch(token.tag, oldRaw) ? SearchTagToken(tag: target) : token
            }
        )
        if updatedTokens.map(\.tag) != searchTokens.map(\.tag) {
            searchTokens = updatedTokens
            changed = true
        }

        guard changed || recordsChanged else { return target }
        let oldShown = MediaCategory.localizedTag(oldRaw, in: language)
        let newShown = MediaCategory.localizedTag(target, in: language)
        commitTagCatalogChange(
            categories: tagCategories,
            nodes: normalized.nodes,
            toast: language.tr("已将「\(oldShown)」重命名为「\(newShown)」", "Renamed “\(oldShown)” to “\(newShown)”")
        )
        return target
    }

    func setTagParent(_ rawTag: String, parent newParent: String?) {
        guard isReady, TagCatalog.canSetParent(of: rawTag, to: newParent, in: tagNodes) else { return }
        let targetParent = newParent.map { resolveTagName($0) }
        var updated = tagNodes
        guard let idx = updated.firstIndex(where: { MediaCategory.tagsMatch($0.name, rawTag) }) else { return }
        guard updated[idx].parent != targetParent else { return }
        updated[idx].parent = targetParent
        if let targetParent,
           let parentNode = updated.first(where: { MediaCategory.tagsMatch($0.name, targetParent) }) {
            updated[idx].category = parentNode.category
        }
        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: updated).nodes
        commitTagCatalogChange(categories: tagCategories, nodes: normalized)
    }

    func moveTag(_ rawTag: String, toParent newParent: String?, before beforeSibling: String?) {
        guard isReady, TagCatalog.canSetParent(of: rawTag, to: newParent, in: tagNodes) else { return }
        guard let sourceIdx = tagNodes.firstIndex(where: { MediaCategory.tagsMatch($0.name, rawTag) }) else { return }
        var node = tagNodes[sourceIdx]
        let targetParent = newParent.map { resolveTagName($0) }
        node.parent = targetParent
        if let targetParent,
           let parentNode = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, targetParent) }) {
            node.category = parentNode.category
        } else if let beforeSibling,
                  let siblingNode = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, beforeSibling) }) {
            node.category = siblingNode.category
        }

        var remaining = tagNodes
        remaining.remove(at: sourceIdx)

        if let beforeSibling,
           !MediaCategory.tagsMatch(beforeSibling, rawTag),
           let destIdx = remaining.firstIndex(where: { MediaCategory.tagsMatch($0.name, beforeSibling) }) {
            remaining.insert(node, at: destIdx)
        } else {
            remaining.append(node)
        }

        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: remaining).nodes
        guard normalized != tagNodes else { return }
        commitTagCatalogChange(categories: tagCategories, nodes: normalized)
    }

    func deleteTag(_ rawTag: String) {
        guard isReady else { return }
        let family = expandedTagFamily(for: rawTag)
        guard !family.isEmpty else { return }

        let filteredNodes = tagNodes.filter { node in
            !family.contains { MediaCategory.tagsMatch($0, node.name) }
        }
        var changed = filteredNodes.count != tagNodes.count

        if rewriteRecordTags({ tags in
            guard tags.contains(where: { tag in family.contains { MediaCategory.tagsMatch($0, tag) } }) else {
                return nil
            }
            let filtered = tags.filter { tag in !family.contains { MediaCategory.tagsMatch($0, tag) } }
            return filtered == tags ? nil : filtered
        }) {
            changed = true
        }

        let remainingTokens = searchTokens.filter { token in
            !family.contains { MediaCategory.tagsMatch($0, token.tag) }
        }
        if remainingTokens.count != searchTokens.count {
            searchTokens = remainingTokens
            changed = true
        }

        guard changed else { return }
        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: filteredNodes).nodes
        let shown = MediaCategory.localizedTag(rawTag, in: language)
        commitTagCatalogChange(
            categories: tagCategories,
            nodes: normalized,
            toast: language.tr("已删除标签「\(shown)」", "Deleted tag “\(shown)”")
        )
    }

    func toggleItemTag(_ rawTag: String, for id: UUID) {
        guard isReady, let item = item(withID: id) else { return }
        if item.hasTag(rawTag) {
            let next = item.tags.filter { !MediaCategory.tagsMatch($0, rawTag) }
            updateTags(for: id, tags: next)
        } else {
            let resolved = resolveTagName(rawTag)
            guard !resolved.isEmpty else { return }
            updateTags(for: id, tags: item.tags + [resolved])
        }
    }
}
