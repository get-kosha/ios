import SwiftUI
import Model

/// What the amount line reads for a keypad input: `−€29.57`, `€0`, or `…` when it divides by zero.
public func amountText(_ input: String, currency: String, kind: EntryKind, locale: Locale) -> String {
    let sign = switch kind {
    case .expense: Money.minus
    case .income: "+"
    case .transfer: ""
    }
    let (prefix, suffix) = Money.affixes(currency, locale)
    if input.isEmpty { return prefix + "0" + suffix }
    let decimals = Money.decimals(currency)
    if Keypad.hasOperator(input) {
        guard let value = Keypad.evaluate(input, decimals: decimals) else { return "…" }
        let minor = NSDecimalNumber(decimal: (value * 100).rounded(0)).int64Value
        if minor == 0 { return prefix + "0" + suffix }
        let text = Money.format(minor, currency, locale, sign: .none)
        return minor > 0 ? sign + text : Money.minus + text
    }
    let (grouping, decimal) = Money.separators(locale)
    return sign + prefix + Keypad.group(input, grouping: grouping, decimal: decimal) + suffix
}

/// The amount being entered: the expression above it when it has an operator, the amount (60, or 46 when longer than 8
/// characters), and a note below. Backspace is on the keypad.
public struct AmountDisplay: View {
    let input: String
    let currency: String
    let kind: EntryKind
    let note: String?
    @Environment(\.kosha) private var theme

    public init(input: String, currency: String, kind: EntryKind, note: String? = nil) {
        self.input = input
        self.currency = currency
        self.kind = kind
        self.note = note
    }

    public var body: some View {
        let c = theme.colors
        let text = amountText(input, currency: currency, kind: kind, locale: theme.locale)
        let (grouping, decimal) = Money.separators(theme.locale)
        VStack(spacing: 0) {
            Text(Keypad.hasOperator(input) ? Keypad.pretty(input, grouping: grouping, decimal: decimal) : " ")
                .kFont(.expr)
                .foregroundStyle(c.ink3)
                .lineLimit(1)
                .frame(minHeight: 20)
                .accessibilityHidden(!Keypad.hasOperator(input))
            Text(text)
                .kFont(text.count > 8 ? .amountLong : .amount)
                .foregroundStyle(input.isEmpty ? c.ink3 : kind == .income ? c.pos : c.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentTransition(.numericText())
                .accessibilityAddTraits(.updatesFrequently)
            if let note {
                Text(note).kFont(.small).foregroundStyle(c.ink2).multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The 4×4 keypad: digits, `.`, `0` and backspace (hold to clear), and a column of ÷ × − + on soft keys. A light
/// haptic tick on each press. The decimal key follows the currency: hidden for currencies without decimals.
public struct AmountKeypad: View {
    @Binding var input: String
    let decimals: Int
    @State private var taps = 0
    @State private var cleared = 0
    @Environment(\.kosha) private var theme

    public init(input: Binding<String>, decimals: Int = 2) {
        _input = input
        self.decimals = decimals
    }

    private func press(_ key: Keypad.Key) {
        taps += 1
        input = Keypad.press(input, key, decimals: decimals)
    }

    public var body: some View {
        let rows: [[Keypad.Key]] = [
            [.digit(1), .digit(2), .digit(3), .op(.divide)],
            [.digit(4), .digit(5), .digit(6), .op(.multiply)],
            [.digit(7), .digit(8), .digit(9), .op(.subtract)],
            [.dot, .digit(0), .delete, .op(.add)],
        ]
        let pending = Keypad.pendingOperator(input)
        VStack(spacing: 2) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        key(rows[r][i], pending: pending).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sensoryFeedback(.impact(weight: .medium), trigger: cleared)
    }

    @ViewBuilder
    private func key(_ key: Keypad.Key, pending: Keypad.Op?) -> some View {
        let c = theme.colors
        switch key {
        case .op(let op):
            let on = pending == op
            Button { press(key) } label: {
                Text(op.shown)
                    .font(.custom("Geist-Regular", size: 26, relativeTo: .title))
                    .foregroundStyle(on ? c.onSelection : c.ink2)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(on ? c.selection : c.soft, in: .rect(cornerRadius: 12))
                    .padding(.leading, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeyStyle())
            .accessibilityLabel(opLabel(op))
            .accessibilityAddTraits(on ? .isSelected : [])
        case .delete:
            PhIcon("backspace", size: 28, color: c.ink2)
                .frame(maxWidth: .infinity, minHeight: 60)
                .contentShape(Rectangle())
                .onTapGesture { press(.delete) }
                .onLongPressGesture(minimumDuration: 0.5) {
                    cleared += 1
                    input = ""
                }
                .accessibilityElement()
                .accessibilityLabel(L.app_key_delete())
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { press(.delete) }
                .accessibilityAction(named: L.tx_clear()) { input = "" }
                .disabled(input.isEmpty)
                .opacity(input.isEmpty ? 0.4 : 1)
        case .dot where decimals == 0:
            Color.clear.frame(height: 60).accessibilityHidden(true)
        default:
            let label = if case .digit(let d) = key { "\(d)" } else { "." }
            Button { press(key) } label: {
                Text(label)
                    .kFont(.key)
                    .foregroundStyle(c.ink)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeyStyle())
            .accessibilityLabel(key == .dot ? L.add_key_decimal() : label)
        }
    }

    private func opLabel(_ op: Keypad.Op) -> String {
        switch op {
        case .divide: L.app_key_divide()
        case .multiply: L.app_key_multiply()
        case .subtract: L.app_key_subtract()
        case .add: L.app_key_add()
        }
    }
}

/// A key that shows a soft ground while pressed, like the design's `.key.pressed`.
struct KeyStyle: ButtonStyle {
    @Environment(\.kosha) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? theme.colors.soft : .clear, in: .rect(cornerRadius: 14))
    }
}
