import Foundation

struct TagNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    var name: String
    var category: String?
    var parent: String?

    var id: String { name.lowercased() }

    init(name: String, category: String? = nil, parent: String? = nil) {
        let canonical = MediaCategory.canonicalTag(name)
        self.name = canonical
        let cleanCategory = category.map(MediaCategory.canonicalTag) ?? ""
        self.category = cleanCategory.isEmpty ? nil : cleanCategory
        let cleanParent = parent.map(MediaCategory.canonicalTag) ?? ""
        if !cleanParent.isEmpty && !MediaCategory.tagsMatch(canonical, cleanParent) {
            self.parent = cleanParent
        } else {
            self.parent = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, category, parent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decode(String.self, forKey: .name)
        let decodedCategory = try container.decodeIfPresent(String.self, forKey: .category)
        let decodedParent = try container.decodeIfPresent(String.self, forKey: .parent)
        self.init(name: decodedName, category: decodedCategory, parent: decodedParent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(parent, forKey: .parent)
    }
}

struct TagCatalogPayload: Codable, Equatable, Sendable {
    var version: Int = 3
    var categories: [String]
    var nodes: [TagNode]

    init(version: Int = 3, categories: [String] = [], nodes: [TagNode]) {
        self.version = version
        self.categories = categories
        self.nodes = nodes
    }

    private enum CodingKeys: String, CodingKey {
        case version, categories, nodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        self.categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.nodes = try container.decode([TagNode].self, forKey: .nodes)
    }
}

struct TagOutlineRow: Identifiable, Equatable {
    let node: TagNode
    let depth: Int
    let hasChildren: Bool
    let ancestors: [String]

    var id: String { node.id }
    var category: String? { node.category }
}

struct TagCategorySection: Identifiable, Equatable {
    let category: String?
    let rows: [TagOutlineRow]

    var id: String { category?.lowercased() ?? "__uncategorized__" }
}

enum TagCatalog {
    static let starterCategoryGroups: [(category: String, tags: [String])] = [
        ("平台", MediaCategory.game.presetTags),
        ("体裁", MediaCategory.novel.presetTags),
        ("形式", MediaCategory.video.presetTags)
    ]

    static let defaultStarterCategories: [String] = starterCategoryGroups.map(\.category)

    static let starterCategoryByTag: [String: String] = {
        var map: [String: String] = [:]
        for group in starterCategoryGroups {
            for tag in group.tags {
                map[MediaCategory.canonicalTag(tag).lowercased()] = group.category
            }
        }
        return map
    }()

    static let defaultStarterNodes: [TagNode] = {
        var result: [TagNode] = []
        for group in starterCategoryGroups {
            for tag in group.tags {
                result.append(TagNode(name: tag, category: group.category, parent: nil))
            }
        }
        return result
    }()

    static func normalizeCategories(_ rawCategories: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for raw in rawCategories {
            let canonical = MediaCategory.canonicalTag(raw)
            guard !canonical.isEmpty else { continue }
            let key = canonical.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(canonical)
        }
        return result
    }

    static func migrateLegacyTags(_ flatTags: [String]) -> (categories: [String], nodes: [TagNode]) {
        var categories: [String] = []
        var seenCategories: Set<String> = []
        var nodes: [TagNode] = []
        var seenTags: Set<String> = []
        let starterGroupIDs = Set(defaultStarterCategories.map { $0.lowercased() })

        for raw in flatTags {
            let canonical = MediaCategory.canonicalTag(raw)
            guard !canonical.isEmpty else { continue }
            let key = canonical.lowercased()
            if starterGroupIDs.contains(key) {
                if seenCategories.insert(key).inserted {
                    categories.append(canonical)
                }
                continue
            }
            guard seenTags.insert(key).inserted else { continue }

            if let cat = starterCategoryByTag[key] {
                if seenCategories.insert(cat.lowercased()).inserted {
                    categories.append(cat)
                }
                nodes.append(TagNode(name: canonical, category: cat, parent: nil))
            } else {
                nodes.append(TagNode(name: canonical, category: nil, parent: nil))
            }
        }

        return normalize(categories: categories, nodes: nodes)
    }

    static func migrateV2PayloadIfNeeded(_ payload: TagCatalogPayload) -> (categories: [String], nodes: [TagNode]) {
        guard payload.version < 3 else {
            return normalize(categories: payload.categories, nodes: payload.nodes)
        }

        let starterGroupMap = Dictionary(
            uniqueKeysWithValues: defaultStarterCategories.map { ($0.lowercased(), $0) }
        )
        var promotedCategoryByID: [String: String] = [:]
        var categories = payload.categories

        for node in payload.nodes where node.parent == nil {
            if let canonicalCat = starterGroupMap[node.id] {
                promotedCategoryByID[node.id] = canonicalCat
                categories.append(canonicalCat)
            }
        }

        guard !promotedCategoryByID.isEmpty else {
            return normalize(categories: categories, nodes: payload.nodes)
        }

        var migratedNodes: [TagNode] = []
        for var node in payload.nodes {
            if promotedCategoryByID[node.id] != nil {
                continue
            }
            if let parent = node.parent, let promotedCat = promotedCategoryByID[parent.lowercased()] {
                node.parent = nil
                node.category = promotedCat
            }
            migratedNodes.append(node)
        }

        return normalize(categories: categories, nodes: migratedNodes)
    }

    static func normalize(
        categories rawCategories: [String],
        nodes: [TagNode],
        mergingItemTags itemTags: [String] = []
    ) -> (categories: [String], nodes: [TagNode]) {
        let normalizedCategories = normalizeCategories(rawCategories)
        let categoryByID = Dictionary(
            uniqueKeysWithValues: normalizedCategories.map { ($0.lowercased(), $0) }
        )

        var result: [TagNode] = []
        var seen: Set<String> = []

        for node in nodes {
            let canonical = MediaCategory.canonicalTag(node.name)
            guard !canonical.isEmpty else { continue }
            let key = canonical.lowercased()
            guard seen.insert(key).inserted else { continue }
            let cleanCat = node.category.flatMap { categoryByID[MediaCategory.canonicalTag($0).lowercased()] }
            let cleanParent = node.parent.map(MediaCategory.canonicalTag)
            result.append(TagNode(name: canonical, category: cleanCat, parent: cleanParent))
        }

        for raw in itemTags {
            let canonical = MediaCategory.canonicalTag(raw)
            guard !canonical.isEmpty else { continue }
            let key = canonical.lowercased()
            guard seen.insert(key).inserted else { continue }
            if let starterCat = starterCategoryByTag[key],
               let validCat = categoryByID[starterCat.lowercased()] {
                result.append(TagNode(name: canonical, category: validCat, parent: nil))
            } else {
                result.append(TagNode(name: canonical, category: nil, parent: nil))
            }
        }

        var canonicalNameByID: [String: String] = [:]
        for node in result {
            canonicalNameByID[node.id] = node.name
        }

        for idx in result.indices {
            guard let parent = result[idx].parent else { continue }
            let parentID = parent.lowercased()
            if parentID == result[idx].id || canonicalNameByID[parentID] == nil {
                result[idx].parent = nil
            } else {
                result[idx].parent = canonicalNameByID[parentID]
            }
        }

        var indexByID: [String: Int] = [:]
        for (idx, node) in result.enumerated() {
            indexByID[node.id] = idx
        }

        for idx in result.indices {
            var visited: Set<String> = [result[idx].id]
            var currentParent = result[idx].parent
            while let parentName = currentParent {
                let parentID = parentName.lowercased()
                if !visited.insert(parentID).inserted {
                    result[idx].parent = nil
                    break
                }
                currentParent = indexByID[parentID].flatMap { result[$0].parent }
            }
        }

        // Sync child node category to its root ancestor's category.
        for idx in result.indices where result[idx].parent != nil {
            var cursor = result[idx]
            var visited: Set<String> = [cursor.id]
            while let parentName = cursor.parent,
                  let parentIdx = indexByID[parentName.lowercased()],
                  visited.insert(result[parentIdx].id).inserted {
                cursor = result[parentIdx]
            }
            result[idx].category = cursor.category
        }

        return (normalizedCategories, result)
    }

    static func children(of parentName: String?, in nodes: [TagNode]) -> [TagNode] {
        guard let parentName else {
            return nodes.filter { $0.parent == nil }
        }
        let targetID = MediaCategory.canonicalTag(parentName).lowercased()
        guard !targetID.isEmpty else { return [] }
        return nodes.filter { $0.parent?.lowercased() == targetID }
    }

    static func descendants(of tagName: String, in nodes: [TagNode]) -> [String] {
        let rootID = MediaCategory.canonicalTag(tagName).lowercased()
        guard !rootID.isEmpty else { return [] }
        var visited: Set<String> = [rootID]
        var result: [String] = []

        func walk(_ currentParent: String) {
            for child in children(of: currentParent, in: nodes) {
                guard visited.insert(child.id).inserted else { continue }
                result.append(child.name)
                walk(child.name)
            }
        }

        walk(tagName)
        return result
    }

    static func expandedFamily(for tagName: String, in nodes: [TagNode]) -> [String] {
        let canonical = nodes.first { MediaCategory.tagsMatch($0.name, tagName) }?.name
            ?? MediaCategory.canonicalTag(tagName)
        guard !canonical.isEmpty else { return [] }
        return [canonical] + descendants(of: canonical, in: nodes)
    }

    static func ancestors(of tagName: String, in nodes: [TagNode]) -> [String] {
        var lookup: [String: TagNode] = [:]
        for node in nodes {
            lookup[node.id] = node
        }
        let targetID = MediaCategory.canonicalTag(tagName).lowercased()
        guard var current = lookup[targetID] else { return [] }

        var chain: [String] = []
        var visited: Set<String> = [current.id]
        while let parentName = current.parent,
              let parentNode = lookup[parentName.lowercased()],
              visited.insert(parentNode.id).inserted {
            chain.append(parentNode.name)
            current = parentNode
        }
        return chain.reversed()
    }

    static func isDescendant(_ candidate: String, of ancestor: String, in nodes: [TagNode]) -> Bool {
        descendants(of: ancestor, in: nodes).contains { MediaCategory.tagsMatch($0, candidate) }
    }

    static func canSetParent(of tagName: String, to newParent: String?, in nodes: [TagNode]) -> Bool {
        let canonicalTag = MediaCategory.canonicalTag(tagName)
        guard !canonicalTag.isEmpty,
              nodes.contains(where: { MediaCategory.tagsMatch($0.name, canonicalTag) }) else {
            return false
        }
        guard let newParent else { return true }
        let canonicalParent = MediaCategory.canonicalTag(newParent)
        guard !canonicalParent.isEmpty,
              nodes.contains(where: { MediaCategory.tagsMatch($0.name, canonicalParent) }),
              !MediaCategory.tagsMatch(canonicalTag, canonicalParent) else {
            return false
        }
        return !isDescendant(canonicalParent, of: canonicalTag, in: nodes)
    }

    static func flattenedOutline(in nodes: [TagNode], collapsedIDs: Set<String> = []) -> [TagOutlineRow] {
        var result: [TagOutlineRow] = []
        var visited: Set<String> = []

        func walk(parentName: String?, depth: Int, ancestors: [String]) {
            for node in children(of: parentName, in: nodes) {
                guard visited.insert(node.id).inserted else { continue }
                let nodeChildren = children(of: node.name, in: nodes)
                result.append(
                    TagOutlineRow(
                        node: node,
                        depth: depth,
                        hasChildren: !nodeChildren.isEmpty,
                        ancestors: ancestors
                    )
                )
                if !nodeChildren.isEmpty && !collapsedIDs.contains(node.id) {
                    walk(parentName: node.name, depth: depth + 1, ancestors: ancestors + [node.name])
                }
            }
        }

        walk(parentName: nil, depth: 0, ancestors: [])
        return result
    }

    static func groupedOutline(
        categories: [String],
        nodes: [TagNode],
        collapsedTagIDs: Set<String> = [],
        includeEmptyCategories: Bool = false
    ) -> [TagCategorySection] {
        var sections: [TagCategorySection] = []
        let categoryIDs = Set(categories.map { $0.lowercased() })

        for category in categories {
            let key = category.lowercased()
            let catNodes = nodes.filter { $0.category?.lowercased() == key }
            let rows = flattenedOutline(in: catNodes, collapsedIDs: collapsedTagIDs)
            if !rows.isEmpty || includeEmptyCategories {
                sections.append(TagCategorySection(category: category, rows: rows))
            }
        }

        let uncategorizedNodes = nodes.filter { node in
            guard let cat = node.category else { return true }
            return !categoryIDs.contains(cat.lowercased())
        }
        let uncategorizedRows = flattenedOutline(in: uncategorizedNodes, collapsedIDs: collapsedTagIDs)
        if !uncategorizedRows.isEmpty {
            sections.append(TagCategorySection(category: nil, rows: uncategorizedRows))
        }

        return sections
    }

    static func searchRows(matching rawQuery: String, in nodes: [TagNode]) -> [TagOutlineRow] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let outline = flattenedOutline(in: nodes)
        guard !query.isEmpty else { return outline }

        var ranked: [(rank: Int, order: Int, row: TagOutlineRow)] = []
        for (idx, row) in outline.enumerated() {
            let names = [
                row.node.name,
                MediaCategory.localizedTag(row.node.name, in: .zh),
                MediaCategory.localizedTag(row.node.name, in: .en)
            ]
            if names.contains(where: { $0.hasCaseInsensitivePrefix(query) }) {
                ranked.append((0, idx, row))
            } else if names.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                ranked.append((1, idx, row))
            } else {
                var contextParts = row.ancestors.flatMap {
                    [$0, MediaCategory.localizedTag($0, in: .zh), MediaCategory.localizedTag($0, in: .en)]
                }
                if let cat = row.node.category {
                    contextParts.append(contentsOf: [
                        cat,
                        MediaCategory.localizedTag(cat, in: .zh),
                        MediaCategory.localizedTag(cat, in: .en)
                    ])
                }
                let contextText = contextParts.joined(separator: " ")
                if contextText.localizedCaseInsensitiveContains(query) {
                    ranked.append((2, idx, row))
                }
            }
        }

        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.order < rhs.order
        }.map(\.row)
    }

    static func formattedBreadcrumb(ancestors: [String], language: AppLanguage) -> String {
        ancestors
            .map { MediaCategory.localizedTag($0, in: language) }
            .joined(separator: " › ")
    }
}

extension String {
    func hasCaseInsensitivePrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
    }
}
