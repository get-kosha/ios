import SwiftUI
import Model

/// How sure a picked value is.
public enum Pick: Sendable {
    /// Nothing yet: dashed, in ink3.
    case empty
    /// Optional and unset (Repeat, Note): a solid line, in ink3.
    case unset
    /// Kosha's guess from history (or the AI's): the label in ink2. One tap accepts.
    case guess
    /// Picked or confirmed.
    case picked
}

/// One tile of the Add screen's tile row (category, date, repeat, note): 58 high, radius 14, an 18pt icon over a 12.5pt
/// label. `aiGuess` adds the sparkle corner.
public struct FieldTile: View {
    let label: String
    let icon: String
    let pick: Pick
    let aiGuess: Bool
    let description: String?
    let action: () -> Void
    @Environment(\.kosha) private var theme

    public init(
        _ label: String, icon: String, pick: Pick = .picked, aiGuess: Bool = false, description: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.pick = pick
        self.aiGuess = aiGuess
        self.description = description
        self.action = action
    }

    public var body: some View {
        let c = theme.colors
        let quiet = pick == .empty || pick == .unset
        Button(action: action) {
            VStack(spacing: 5) {
                PhIcon(icon, size: 18, color: quiet ? c.ink3 : c.ink2)
                Text(label)
                    .kFont(.sans(12.5, .regular))
                    .foregroundStyle(quiet ? c.ink3 : pick == .guess ? c.ink2 : c.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay {
                if pick == .empty {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(c.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(c.line)
                }
            }
            .overlay(alignment: .topTrailing) {
                if aiGuess { Sparkle(size: 10).padding(.top, 5).padding(.trailing, 7) }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(description ?? label)
    }
}

/// A category for the picker: its id, icon name (see `categoryIconName`) and label.
public struct CategoryTile: Identifiable, Hashable, Sendable {
    public let id: String
    public let icon: String
    public let label: String

    public init(id: String, icon: String, label: String) {
        self.id = id
        self.icon = icon
        self.label = label
    }
}

/// The category grid: five a row, gap 4, tiles 70 high. Picked: an outline in the selection colour. Guess: dashed, with
/// the sparkle when AI made it. Labels wrap at large text sizes rather than vanish.
public struct CategoryGrid: View {
    let categories: [CategoryTile]
    let picked: String?
    let guess: String?
    let aiGuess: Bool
    let onPick: (CategoryTile) -> Void
    @Environment(\.kosha) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        _ categories: [CategoryTile], picked: String?, guess: String? = nil, aiGuess: Bool = false,
        onPick: @escaping (CategoryTile) -> Void
    ) {
        self.categories = categories
        self.picked = picked
        self.guess = guess
        self.aiGuess = aiGuess
        self.onPick = onPick
    }

    public var body: some View {
        let c = theme.colors
        let perRow = typeSize.isAccessibilitySize ? 3 : 5
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: perRow), spacing: 4) {
            ForEach(categories) { cat in
                let on = cat.id == picked
                let guessed = !on && cat.id == guess
                Button { onPick(cat) } label: {
                    VStack(spacing: 6) {
                        PhIcon(cat.icon, size: 24, color: on ? c.selection : c.ink2)
                        Text(cat.label)
                            .kFont(on ? .sans(12, .medium) : .xs)
                            .foregroundStyle(on ? c.ink : c.ink2)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .overlay {
                        if on {
                            RoundedRectangle(cornerRadius: 14).strokeBorder(c.selection, lineWidth: 1.5)
                        } else if guessed {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(c.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if guessed && aiGuess { Sparkle(size: 11).padding(.top, 5).padding(.trailing, 7) }
                    }
                    .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The account pill under the amount: 36 high, a hairline, a 10pt colour square (a wallet icon in neutral mode), the
/// name truncated, and a caret. `guess` shows the name in ink2; `open` gives it an ink outline while its sheet is up.
public struct AccountPill: View {
    let name: String
    let color: Color
    let guess: Bool
    let open: Bool
    let caret: Bool
    let action: () -> Void
    @Environment(\.kosha) private var theme

    public init(
        _ name: String, color: Color, guess: Bool = false, open: Bool = false, caret: Bool = true,
        action: @escaping () -> Void
    ) {
        self.name = name
        self.color = color
        self.guess = guess
        self.open = open
        self.caret = caret
        self.action = action
    }

    public var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 8) {
                if c.accountColours {
                    AccountDot(color, size: 10)
                } else {
                    PhIcon("wallet", size: 16, color: c.ink2)
                }
                Text(name).kFont(.sans(14, .medium)).foregroundStyle(guess ? c.ink2 : c.ink).lineLimit(1)
                    .truncationMode(.tail)
                if caret { PhIcon("caret-down", size: 13, color: c.ink3) }
            }
            .padding(.leading, 13)
            .padding(.trailing, caret ? 10 : 13)
            .frame(minHeight: 36)
            .background(c.surface, in: .capsule)
            .overlay { Capsule().strokeBorder(open ? c.ink : c.line, lineWidth: open ? 1.5 : 1) }
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
    }
}

/// A transfer's From → To pills, the arrow between them swapping the two. Each pill takes at most half the row minus
/// the 34pt swap button, without the caret.
public struct TransferPills: View {
    let from: (name: String, color: Color)
    let to: (name: String, color: Color)?
    let toPlaceholder: String
    let swapLabel: String
    let onFrom: () -> Void
    let onTo: () -> Void
    let onSwap: () -> Void
    @Environment(\.kosha) private var theme

    public init(
        from: (name: String, color: Color), to: (name: String, color: Color)?, toPlaceholder: String, swapLabel: String,
        onFrom: @escaping () -> Void, onTo: @escaping () -> Void, onSwap: @escaping () -> Void
    ) {
        self.from = from
        self.to = to
        self.toPlaceholder = toPlaceholder
        self.swapLabel = swapLabel
        self.onFrom = onFrom
        self.onTo = onTo
        self.onSwap = onSwap
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            VStack(spacing: 4) { row }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            AccountPill(from.name, color: from.color, caret: false, action: onFrom)
            Button(action: onSwap) {
                PhIcon("arrow-right", size: 18, color: theme.colors.ink3).frame(width: 34, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(swapLabel)
            AccountPill(to?.name ?? toPlaceholder, color: to?.color ?? .clear, guess: to == nil, caret: false, action: onTo)
        }
    }
}
