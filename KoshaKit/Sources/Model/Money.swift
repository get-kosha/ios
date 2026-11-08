import Foundation

/// How an amount's direction is shown.
public enum Sign: Sendable {
    /// −€12.50 for money out, €12.50 for money in: lists of balances.
    case natural
    /// −€12.50 and +€3,240.00: entries, where the direction matters.
    case always
    /// €12.50 either way: transfers and neutral amounts.
    case none
}

/// Formats amounts held as integer minor units: ×100 for every currency, as the web stores them, so ¥1,200 is
/// 120000. Currency symbol, grouping and decimals follow the language, and the currency sets how many decimals show
/// (none for JPY). Negative amounts take a true minus (U+2212), never a hyphen.
public enum Money {
    public static let minus = "−"

    /// The web formats English as British English (core.ts intlLocale): 07/11/2026, and yen as JP¥.
    public static func locale(_ language: String) -> Locale {
        language == "en" ? Locale(identifier: "en_GB") : Locale(identifier: language)
    }

    /// How many decimals the currency shows, such as 2 for EUR and 0 for JPY.
    public static func decimals(_ currency: String) -> Int {
        formatter(currency, Locale(identifier: "en_US_POSIX")).maximumFractionDigits
    }

    private static func formatter(_ currency: String, _ locale: Locale) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency.uppercased()
        // The currency code sets its own digits; read them back after setting it.
        let digits = max(0, f.maximumFractionDigits)
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }

    public static func format(_ minor: Int64, _ currency: String, _ locale: Locale, sign: Sign = .natural) -> String {
        let value = Decimal(minor.magnitude) / 100
        let text = formatter(currency, locale).string(from: value as NSDecimalNumber) ?? ""
        if minor < 0 && sign != .none { return minus + text }
        if minor > 0 && sign == .always { return "+" + text }
        return text
    }

    /// What goes before and after the number for this currency and language: ("€", "") in English, ("", " €") in
    /// German. The keypad wraps the digits as typed in them.
    public static func affixes(_ currency: String, _ locale: Locale) -> (prefix: String, suffix: String) {
        let f = formatter(currency, locale)
        return (f.positivePrefix, f.positiveSuffix)
    }

    /// The grouping and decimal characters the keypad shows numbers with.
    public static func separators(_ locale: Locale) -> (grouping: String, decimal: String) {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        return (f.groupingSeparator, f.decimalSeparator)
    }

    /// The amount as a screen reader says it, with the currency's name: "minus 29.57 euros". (NumberFormatter's plural
    /// currency style reads the locale's own currency whatever code it's given, so it said "pounds" for euros.)
    public static func spoken(_ minor: Int64, _ currency: String, _ locale: Locale) -> String {
        let value = Decimal(minor.magnitude) / 100
        let style = Decimal.FormatStyle.Currency(code: currency.uppercased(), locale: locale)
            .presentation(.fullName)
            .precision(.fractionLength(decimals(currency)))
        let text = value.formatted(style)
        return minor < 0 ? "\(minus)\(text)" : text
    }
}
