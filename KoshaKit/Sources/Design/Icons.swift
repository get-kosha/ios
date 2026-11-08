import SwiftUI

/// Phosphor's icon names and code points (Resources/phosphor.txt, from scripts/phosphor-codes.py). Icons are drawn by
/// name, so a category's `ph:<name>` icon from the server works without a code change.
enum PhosphorCodes {
    static let codes: [String: String] = {
        guard let url = Bundle.module.url(forResource: "phosphor", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let code = UInt32(parts[1], radix: 16), let scalar = Unicode.Scalar(code) {
                out[String(parts[0])] = String(Character(scalar))
            }
        }
        return out
    }()

    static func glyph(_ name: String) -> String { codes[name] ?? codes["tag"] ?? "?" }
    static func has(_ name: String) -> Bool { codes[name] != nil }
}

/// A Phosphor icon by name, such as "shopping-cart": regular weight, or fill for selected tabs and the AI sparkle.
/// Decorative unless it has a label. Icons keep their size at every Dynamic Type size, as on Android.
public struct PhIcon: View {
    let name: String
    let size: CGFloat
    let fill: Bool
    let color: Color?
    let label: String?

    public init(_ name: String, size: CGFloat = 20, fill: Bool = false, color: Color? = nil, label: String? = nil) {
        self.name = name
        self.size = size
        self.fill = fill
        self.color = color
        self.label = label
    }

    @Environment(\.kosha) private var theme

    public var body: some View {
        let glyph = Text(PhosphorCodes.glyph(name))
            .font(.custom(fill ? "Phosphor-Fill" : "Phosphor", fixedSize: size))
            .foregroundStyle(color ?? theme.colors.ink2)
            .frame(width: size, height: size)
        if let label {
            glyph.accessibilityLabel(label)
        } else {
            glyph.accessibilityHidden(true)
        }
    }
}

/// The AI sparkle, in the accent colour. Only drawn where AI is on.
public struct Sparkle: View {
    var size: CGFloat
    @Environment(\.kosha) private var theme

    public init(size: CGFloat = 14) { self.size = size }

    public var body: some View { PhIcon("sparkle", size: size, fill: true, color: theme.colors.brand) }
}

/// A category's icon name. The server stores an emoji, or `ph:<name>` for one picked from Phosphor; each emoji maps to
/// the closest Phosphor icon, as on the web (src/components/category-icon.tsx). Unknown ones show a tag.
public func categoryIconName(_ icon: String?) -> String {
    guard let icon else { return "tag" }
    if icon.hasPrefix("ph:") {
        let name = String(icon.dropFirst(3))
        return PhosphorCodes.has(name) ? name : "tag"
    }
    return categoryIconsByEmoji[icon.replacingOccurrences(of: "\u{FE0F}", with: "")] ?? "tag"
}

/// Icons a category can take, in the picker's order (category-icon.tsx CATEGORY_ICONS).
public let categoryIcons = [
    "shopping-cart", "basket", "storefront", "fork-knife", "coffee", "hamburger", "pizza", "cookie", "cake", "wine",
    "beer-stein", "martini", "shopping-bag", "t-shirt", "sneaker", "package", "house", "house-line", "couch", "bed",
    "lightbulb", "lightning", "drop", "flame", "wifi-high", "globe-simple", "device-mobile", "laptop", "television",
    "game-controller", "music-notes", "film-slate", "popcorn", "ticket", "book-open", "graduation-cap", "baby", "dog",
    "paw-print", "heartbeat", "pill", "first-aid", "tooth", "barbell", "soccer-ball", "bicycle", "car", "gas-pump",
    "taxi", "bus", "tram", "train", "airplane-tilt", "suitcase", "map-pin", "umbrella", "gift", "heart", "flower",
    "plant", "tree", "sparkle", "scissors", "paint-brush", "camera", "fish-simple", "church", "cigarette", "wrench",
    "hammer", "shield-check", "receipt", "file-text", "scales", "bank", "credit-card", "piggy-bank", "coins", "money",
    "hand-coins", "briefcase", "chart-line", "currency-circle-dollar", "arrows-left-right", "arrow-u-up-left", "tag",
]

// ponytail: fixed emoji table, unknown emoji fall back to a tag, as on the web.
let categoryIconsByEmoji: [String: String] = [
    "↔": "arrows-left-right", "💱": "currency-circle-dollar", "🍽": "fork-knife", "🛒": "shopping-cart",
    "🥤": "martini", "📊": "chart-line", "🛍": "shopping-bag", "🚋": "tram", "🌐": "globe-simple",
    "⚡": "lightning", "💊": "pill", "👕": "t-shirt", "✈": "airplane-tilt", "🛋": "couch",
    "🎮": "game-controller", "📄": "file-text", "📱": "device-mobile", "🎁": "gift", "↩": "arrow-u-up-left",
    "🏧": "money", "🍿": "popcorn", "🏠": "house", "🪙": "coins", "💸": "hand-coins", "🏛": "bank",
    "💵": "money", "🐷": "piggy-bank", "🌸": "flower", "🍼": "baby", "🎣": "fish-simple",
    "⚽": "soccer-ball", "🧾": "receipt", "💼": "briefcase", "🚗": "car", "⚖": "scales", "☕": "coffee",
    "💻": "laptop",
]
