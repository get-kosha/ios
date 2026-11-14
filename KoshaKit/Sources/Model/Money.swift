import Foundation
import os

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
/// 120000. Currency symbol, grouping and decimals follow the language (in English, the currency's home country's
/// grouping; see `locale(for:_:)`), and the currency sets how many decimals show (none for JPY). Negative amounts take
/// a true minus (U+2212), never a hyphen.
public enum Money {
    public static let minus = "−"

    /// The web formats English as British English (core.ts intlLocale): 07/11/2026, and yen as JP¥.
    public static func locale(_ language: String) -> Locale {
        language == "en" ? Locale(identifier: "en_GB") : Locale(identifier: language)
    }

    /// The locale to write amounts of `currency` in (core.ts moneyLocale). English takes the currency's home country's
    /// digit grouping and separators (₹1,36,78,281.76, CHF 1'234'567.89, 12 345,00 kr) when they differ from British
    /// English's, and otherwise stays British so symbols stay unambiguous (US$, CA$). The keypad keeps the language's.
    // ponytail: other languages keep their own number format for every currency; CLDR has no de_IN or fr_IN to borrow from
    public static func locale(for currency: String, _ locale: Locale) -> Locale {
        guard locale.identifier == "en_GB" else { return locale }
        let code = currency.uppercased()
        return homes.withLock { cache in
            if let l = cache[code] { return l }
            // A currency code starts with its country's code (INR, CHF); en_<country> falls back to plain English when
            // unknown.
            let home = Locale(identifier: "en_" + code.prefix(2))
            let l = digits(home, code) == digits(locale, code) ? locale : home
            cache[code] = l
            return l
        }
    }

    private static let homes = OSAllocatedUnfairLock(initialState: [String: Locale]())

    /// The digits, separators and grouping a locale writes 12,345,678.9 of `currency` with, without its symbol or the
    /// invisible direction marks some locales put around it.
    private static func digits(_ locale: Locale, _ currency: String) -> String {
        let f = formatter(currency, locale)
        f.currencySymbol = ""
        let text = f.string(from: 12_345_678.9) ?? ""
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespaces)
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
        let text = formatter(currency, Self.locale(for: currency, locale)).string(from: value as NSDecimalNumber) ?? ""
        if minor < 0 && sign != .none { return minus + text }
        if minor > 0 && sign == .always { return "+" + text }
        return text
    }

    /// What goes before and after the number for this currency and language: ("€", "") in English, ("", " €") in
    /// German. The keypad wraps the digits as typed in them, so these follow the language, not the currency's home.
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
        let style = Decimal.FormatStyle.Currency(code: currency.uppercased(), locale: Self.locale(for: currency, locale))
            .presentation(.fullName)
            .precision(.fractionLength(decimals(currency)))
        let text = value.formatted(style)
        return minor < 0 ? "\(minus)\(text)" : text
    }
}
