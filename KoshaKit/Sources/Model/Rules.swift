import Foundation

/// Money rules shared by every screen, ported from ../kosha-web/src/lib/core.ts. Category "0" (balance corrections)
/// and "transfer" are neutral: neither income nor spending. "transfer_fee" counts as spending.
public enum Categories {
    public static let correction = "0"
    public static let transfer = "transfer"
    public static let transferFee = "transfer_fee"

    public static func isNeutral(_ id: String) -> Bool { id == correction || id == transfer }

    /// Kosha's own categories, which the person can't pick for an ordinary entry.
    public static func isSystem(_ id: String) -> Bool { isNeutral(id) || id == transferFee }
}

/// Converts at rates held as units per 1 USD (core.ts convert), rounded to whole minor units.
/// ponytail: an unknown currency passes through unconverted, as on the web.
public func convert(_ minor: Int64, from: String, to: String, perUsd: [String: Double]) -> Int64 {
    if from == to { return minor }
    guard let f = perUsd[from], let t = perUsd[to], f != 0, t != 0 else { return minor }
    return Int64((Double(minor) / f * t).rounded())
}

/// A payee rule as guessCategory reads it: the payee text, whether it must match exactly, and its category.
public struct PayeeMatch: Sendable {
    public let title: String
    public let exact: Bool
    public let categoryId: String

    public init(title: String, exact: Bool, categoryId: String) {
        self.title = title
        self.exact = exact
        self.categoryId = categoryId
    }
}

/// The category the payee rules give (core.ts guessCategory): the longest rule that matches wins.
public func guessCategory(_ payee: String, _ rules: [PayeeMatch]) -> String? {
    let n = payee.trimmingCharacters(in: .whitespaces).lowercased()
    if n.isEmpty { return nil }
    var best: PayeeMatch?
    for r in rules {
        let t = r.title.lowercased()
        let hit = r.exact ? n == t : n.contains(t)
        if hit && (best == nil || t.count > best!.title.count) { best = r }
    }
    return best?.categoryId
}

public let maxTags = 20

/// One hashtag as stored (core.ts cleanTag): lowercase, no '#', letters, digits, '-' and '_' only.
public func cleanTag(_ tag: String) -> String {
    var t = Substring(tag.trimmingCharacters(in: .whitespaces))
    while t.first == "#" { t = t.dropFirst() }
    let kept = t.lowercased().unicodeScalars.filter {
        CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            || CharacterSet.decimalDigits.contains($0) || $0 == "_" || $0 == "-"
    }
    return String(String.UnicodeScalarView(kept).prefix(32))
}

/// Typed text ("#trip, food rome") as unique stored tags in the order typed (core.ts parseTags).
public func parseTags(_ text: String) -> [String] {
    var seen: [String] = []
    for part in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
        let t = cleanTag(String(part))
        if !t.isEmpty && !seen.contains(t) { seen.append(t) }
    }
    return Array(seen.prefix(maxTags))
}
