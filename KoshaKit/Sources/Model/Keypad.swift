import Foundation

/// What an entry on Add is. It sets the amount's sign: money out, money in, or moved between accounts.
public enum EntryKind: String, Sendable, CaseIterable, Codable {
    case expense, income, transfer
}

/// The amount keypad's input: an expression such as `24.07+5.5`, built one key at a time. Ported from the Android
/// app's `Keypad.kt`, itself from the Add prototype (design/source/AddPrototype.dc.html).
///
/// The text always uses `.` for decimals and `+ - * /` for operators; `pretty` and `group` turn it into what the
/// person reads. `decimals` is how many the currency shows (2 for most, 0 for JPY and KRW). Amounts are still stored
/// ×100 for every currency, as the web does, so `minorUnits` multiplies by 100 whatever `decimals` is.
public enum Keypad {
    /// Digits allowed before the decimal point in one number: up to 99,999,999.
    public static let maxWholeDigits = 8

    public enum Op: Character, CaseIterable, Sendable {
        case divide = "/", multiply = "*", subtract = "-", add = "+"

        /// The sign the person reads.
        public var shown: String {
            switch self {
            case .divide: "÷"
            case .multiply: "×"
            case .subtract: "−"
            case .add: "+"
            }
        }
    }

    public enum Key: Equatable, Sendable {
        case digit(Int)
        case dot
        case op(Op)
        /// Backspace.
        case delete
        /// Holding backspace.
        case clear
    }

    private static let ops: Set<Character> = ["+", "-", "*", "/"]

    /// The number being typed: the text after the last operator.
    public static func lastSegment(_ input: String) -> String {
        guard let i = input.lastIndex(where: { ops.contains($0) }) else { return input }
        return String(input[input.index(after: i)...])
    }

    public static func hasOperator(_ input: String) -> Bool { input.contains { ops.contains($0) } }

    /// The operator the input ends with, which the keypad highlights.
    public static func pendingOperator(_ input: String) -> Op? { input.last.flatMap(Op.init(rawValue:)) }

    public static func press(_ input: String, _ key: Key, decimals: Int = 2) -> String {
        let seg = lastSegment(input)
        switch key {
        case .delete:
            return String(input.dropLast())
        case .clear:
            return ""
        case .op(let op):
            if input.isEmpty { return input }
            if let last = input.last, ops.contains(last) { return String(input.dropLast()) + String(op.rawValue) }
            return (input.hasSuffix(".") ? String(input.dropLast()) : input) + String(op.rawValue)
        case .dot:
            if decimals == 0 || seg.contains(".") { return input }
            return seg.isEmpty ? input + "0." : input + "."
        case .digit(let d):
            let add = String(d)
            if add == "0" && (seg.isEmpty || seg == "0") {
                // A first 0 types "0"; another zero on "0" does nothing.
                return seg.isEmpty ? input + "0" : input
            }
            if let dot = seg.firstIndex(of: ".") {
                let typed = seg.distance(from: seg.index(after: dot), to: seg.endIndex)
                return decimals - typed <= 0 ? input : input + add
            }
            if seg.count + 1 > maxWholeDigits { return input }
            return (seg == "0" ? String(input.dropLast()) : input) + add
        }
    }

    /// The value of the input, × and ÷ before + and −, ignoring a trailing operator or dot, rounded to `decimals`.
    /// Zero for no input; nil when it divides by zero, so the amount shows "…" and nothing can be saved.
    public static func evaluate(_ input: String, decimals: Int = 2) -> Decimal? {
        var expr = Substring(input)
        while let last = expr.last, ops.contains(last) || last == "." { expr = expr.dropLast() }
        if expr.isEmpty { return 0 }
        var tokens: [String] = []
        var number = ""
        for ch in expr {
            if ops.contains(ch) {
                tokens.append(number)
                tokens.append(String(ch))
                number = ""
            } else {
                number.append(ch)
            }
        }
        tokens.append(number)
        func value(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
        var terms: [Decimal] = []
        var signs: [String] = []
        var current = value(tokens[0])
        var i = 1
        while i + 1 < tokens.count {
            let v = value(tokens[i + 1])
            switch tokens[i] {
            case "*": current *= v
            case "/":
                if v == 0 { return nil }
                current /= v
            default:
                terms.append(current)
                signs.append(tokens[i])
                current = v
            }
            i += 2
        }
        terms.append(current)
        var result = terms[0]
        for (n, op) in signs.enumerated() { result = op == "+" ? result + terms[n + 1] : result - terms[n + 1] }
        return result.isNaN ? nil : result.rounded(decimals)
    }

    /// The amount to save, in minor units (×100 for every currency) and positive, or nil when it isn't above zero or
    /// can't be worked out. The kind of entry gives it its sign.
    public static func minorUnits(_ input: String, decimals: Int = 2) -> Int64? {
        guard let value = evaluate(input, decimals: decimals), value > 0 else { return nil }
        let minor = (value * 100).rounded(0)
        // The server accepts JavaScript safe integers; larger expressions cannot be saved exactly.
        guard !minor.isNaN, minor <= 9_007_199_254_740_991 else { return nil }
        return NSDecimalNumber(decimal: minor).int64Value
    }

    /// One typed number with grouping, as typed: `1204.5` reads `1,204.5`.
    public static func group(_ segment: String, grouping: String = ",", decimal: String = ".") -> String {
        if segment.isEmpty { return "0" }
        let parts = segment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var whole = String(parts[0].drop { $0 == "0" })
        if whole.isEmpty { whole = "0" }
        var groups: [String] = []
        var rest = Substring(whole)
        while rest.count > 3 {
            groups.insert(String(rest.suffix(3)), at: 0)
            rest = rest.dropLast(3)
        }
        groups.insert(String(rest), at: 0)
        let grouped = groups.joined(separator: grouping)
        return parts.count > 1 ? grouped + decimal + parts[1] : grouped
    }

    /// The expression as shown above the amount: `24.07 + 5.50` with ×, ÷ and a true minus.
    public static func pretty(_ input: String, grouping: String = ",", decimal: String = ".") -> String {
        var out = ""
        var number = ""
        for ch in input {
            if let op = Op(rawValue: ch) {
                if !number.isEmpty { out += group(number, grouping: grouping, decimal: decimal) }
                number = ""
                out += " \(op.shown) "
            } else {
                number.append(ch)
            }
        }
        if !number.isEmpty { out += group(number, grouping: grouping, decimal: decimal) }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

extension Decimal {
    /// Rounded half away from zero to `scale` decimals, like BigDecimal's HALF_UP.
    public func rounded(_ scale: Int) -> Decimal {
        var source = self
        var out = Decimal()
        NSDecimalRound(&out, &source, scale, .plain)
        return out
    }
}
