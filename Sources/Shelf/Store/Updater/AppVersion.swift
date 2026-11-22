import Foundation

struct AppVersion: Comparable, Equatable, Hashable, CustomStringConvertible, Sendable {
    static let fallbackCurrent = "1.2.6"

    private enum PrereleasePart: Equatable, Hashable, Comparable, Sendable {
        case numeric(Int)
        case lexical(String)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let l), .numeric(let r)):
                return l < r
            case (.numeric, .lexical):
                return true
            case (.lexical, .numeric):
                return false
            case (.lexical(let l), .lexical(let r)):
                return l.compare(r, options: .literal) == .orderedAscending
            }
        }
    }

    let components: [Int]
    let prerelease: String?
    let rawCoreString: String

    private var normalizedComponents: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        return trimmed
    }

    private var normalizedPrerelease: [PrereleasePart]? {
        prerelease.map { value in
            value.split(separator: ".", omittingEmptySubsequences: false).map { part in
                if !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }), let num = Int(part) {
                    return .numeric(num)
                }
                return .lexical(String(part))
            }
        }
    }

    init?(parsing raw: String) {
        var text = raw.trimmed
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let plusIndex = text.firstIndex(of: "+") {
            text = String(text[..<plusIndex])
        }

        let coreString: String
        let prereleasePart: String?
        if let dashIndex = text.firstIndex(of: "-") {
            coreString = String(text[..<dashIndex])
            let suffix = String(text[text.index(after: dashIndex)...])
            guard !suffix.isEmpty else { return nil }
            prereleasePart = suffix
        } else {
            coreString = text
            prereleasePart = nil
        }

        let parts = coreString.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let number = Int(part)
            else {
                return nil
            }
            parsed.append(number)
        }

        self.components = parsed
        self.prerelease = prereleasePart
        self.rawCoreString = coreString
    }

    var description: String {
        if let prerelease {
            return "\(rawCoreString)-\(prerelease)"
        }
        return rawCoreString
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalizedComponents == rhs.normalizedComponents
            && lhs.normalizedPrerelease == rhs.normalizedPrerelease
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedComponents)
        hasher.combine(normalizedPrerelease)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r {
                return l < r
            }
        }

        switch (lhs.normalizedPrerelease, rhs.normalizedPrerelease) {
        case (nil, nil), (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let lParts), .some(let rParts)):
            for (l, r) in zip(lParts, rParts) where l != r {
                return l < r
            }
            return lParts.count < rParts.count
        }
    }
}
