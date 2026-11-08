import Foundation
import Model
import Design

// Add's money and date rules, ported from the Android app's feature/add Logic.kt (itself from the web's core.ts,
// add-defaults.ts and the transfer half of transaction-form.tsx). Pure, so FeaturesTests cover them.

/// The account Add starts on (add-defaults.ts startWallet): Settings › General › Default account when it names an
/// active account, else the last one used on this phone, else the first active one.
func startAccount(_ pref: String, active: [Wallet], last: String?) -> String? {
    if pref != "last", active.contains(where: { $0.id == pref }) { return pref }
    if let last, active.contains(where: { $0.id == last }) { return last }
    return active.first?.id
}

/// The event a new entry on `day` joins by default (core.ts eventFor): the one whose dates cover the day. No end means
/// it is still going. When events overlap, the one that started last wins.
func eventFor(_ day: String, _ events: [Event]) -> String? {
    var best: Event?
    for e in events {
        guard let start = e.startDay else { continue }
        if day < start { continue }
        if let end = e.endDay, day > end { continue }
        if best == nil || start > best!.startDay! { best = e }
    }
    return best?.id
}

/// An amount in minor units (×100) as keypad input: 2957 is "29.57", 1200 is "12", ¥1,200 (120000) is "1200".
func keypadInput(_ minor: Int64, decimals: Int) -> String {
    if minor == 0 { return "" }
    let value = (Decimal(minor.magnitude) / 100).rounded(decimals)
    return NSDecimalNumber(decimal: value).stringValue
}

/// A transfer's cost (core.ts exchange): `total` left From, `fee` of it was charged, the rest became `received`.
struct Exchange: Equatable {
    let converted: Int64
    let rate: Double
    let rateCost: Double?
    let totalCost: Double
    let costPct: Double
}

func exchange(total: Int64, fee: Int64, received: Int64, marketRate: Double?) -> Exchange {
    let converted = abs(total) - abs(fee)
    let rate = converted > 0 ? Double(abs(received)) / Double(converted) : 0
    // What the rate gap cost, in the source currency: the converted amount at market minus what arrived, valued at market.
    let rateCost = marketRate.flatMap { $0 == 0 ? nil : (Double(converted) * $0 - Double(abs(received))) / $0 }
    let totalCost = Double(abs(fee)) + (rateCost ?? 0)
    return Exchange(converted: converted, rate: rate, rateCost: rateCost, totalCost: totalCost,
                    costPct: total != 0 ? totalCost / Double(abs(total)) * 100 : 0)
}

/// A rate as the web writes it (core.ts fmtRate): 2 decimals from 100, 4 from 1, else 4 significant digits. Returned
/// as the number of decimals to show and the rounded value.
func fmtRate(_ r: Double) -> (value: Double, decimals: Int) {
    if r >= 100 { return ((r * 100).rounded() / 100, 2) }
    if r >= 1 { return ((r * 10000).rounded() / 10000, 4) }
    if r <= 0 { return (0, 0) }
    let digits = max(0, 3 - Int(floor(log10(r))))
    let p = pow(10.0, Double(digits))
    return ((r * p).rounded() / p, digits)
}

/// Units of `to` per unit of `from` at the server's rates (units per 1 USD). 1 when a rate is missing, as on the web.
func marketRate(_ from: String, _ to: String, _ perUsd: [String: Double]) -> Double {
    guard let f = perUsd[from], let t = perUsd[to], f != 0, t != 0 else { return 1 }
    return t / f
}

/// What the fee sheet holds as typed: keypad text for the fee, rate and amount received, and the provider.
struct FeeInput: Equatable {
    enum Typed { case rate, received }
    var fee = ""
    var received = ""
    var rate = ""
    /// Which of rate and received was typed last; the other follows from it. Nil: the market rate.
    var typed: Typed?
    var provider = ""
}

/// Decimals the rate field takes on the keypad.
let rateDecimals = 6

/// A transfer's sides from what was typed (transaction-form.tsx useExchange). `sent` leaves From and includes the fee.
/// Between currencies you type the rate or the amount received and the other follows; otherwise the market rate.
struct TransferSides: Equatable {
    let fee: Int64
    let converted: Int64
    let received: Int64
    let market: Double
    let cross: Bool

    var rate: Double { cross && converted > 0 ? Double(received) / Double(converted) : 1 }
    var cost: Exchange { exchange(total: converted + fee, fee: fee, received: received, marketRate: cross ? market : nil) }
}

func transferSides(
    sent: Int64, _ input: FeeInput, from: String, to: String?, fromDecimals: Int, toDecimals: Int, perUsd: [String: Double]
) -> TransferSides {
    let cross = to != nil && to != from
    let fee = Keypad.minorUnits(input.fee, decimals: fromDecimals) ?? 0
    let converted = sent - fee
    let market = cross ? marketRate(from, to!, perUsd) : 1
    let received: Int64
    if !cross {
        received = converted
    } else if input.typed == .received {
        received = Keypad.minorUnits(input.received, decimals: toDecimals) ?? 0
    } else if input.typed == .rate {
        let r = Keypad.evaluate(input.rate, decimals: rateDecimals).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        received = Int64((Double(converted) * r).rounded())
    } else {
        received = Int64((Double(converted) * market).rounded())
    }
    return TransferSides(fee: fee, converted: converted, received: received, market: market, cross: cross)
}

/// How an entry repeats, which saves it as a schedule (create_recurring) as well as its first payment: every `every`
/// `unit`s from its day, until `endDay`. `kind` is "repetitive" for a bill and "subscription" for a subscription;
/// income and transfers use "repetitive", as the Recurring form does.
struct Repeat: Equatable {
    var every = 1
    var unit = "month"
    var kind = "repetitive"
    var endDay: Day?
    var autoPay = true

    /// Weekly, Monthly or Yearly: one of the sheet's presets, rather than a custom interval.
    var preset: Bool { every == 1 && unit != "day" }

    /// The day the next payment after `day` falls on.
    func next(after day: Day) -> Day {
        switch unit {
        case "day": day.adding(days: every)
        case "week": day.adding(days: 7 * every)
        case "year": day.adding(years: every)
        default: day.adding(months: every)
        }
    }
}

/// "every month", "every 2 weeks": the existing "every …" messages.
func everyText(_ r: Repeat) -> String {
    switch r.unit {
    case "day": L.subs_every_day(count: r.every)
    case "week": L.subs_every_week(count: r.every)
    case "year": L.subs_every_year(count: r.every)
    default: L.subs_every_month(count: r.every)
    }
}

/// What the Repeat tile says: Weekly, Monthly, Yearly, or "Every 2 weeks" for a custom interval.
func repeatLabel(_ r: Repeat, _ locale: Locale) -> String {
    if r.every == 1 {
        switch r.unit {
        case "week": return L.app_ios_add_weekly()
        case "month": return L.app_ios_add_monthly()
        case "year": return L.app_ios_add_yearly()
        default: break
        }
    }
    let text = everyText(r)
    return text.prefix(1).uppercased(with: locale) + text.dropFirst()
}

/// The rule read back from the entry's day: "Every week on Saturday", "Every month on the 7th", "Every year on
/// 7 November"; a custom interval reads as "Every 2 weeks".
func ruleText(_ r: Repeat, day: Day, _ locale: Locale) -> String {
    guard r.every == 1 else { return repeatLabel(r, locale) }
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = TimeZone(identifier: "UTC")
    switch r.unit {
    case "week":
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return L.app_ios_add_rule_week(weekday: f.string(from: day.date))
    case "year":
        f.setLocalizedDateFormatFromTemplate("dMMMM")
        return L.app_ios_add_rule_year(date: f.string(from: day.date))
    case "month":
        // English reads "the 7th"; other languages write the plain day into their own sentence.
        let n: String
        if locale.language.languageCode?.identifier == "en" {
            let o = NumberFormatter()
            o.numberStyle = .ordinal
            o.locale = locale
            n = o.string(from: NSNumber(value: day.day)) ?? "\(day.day)"
        } else {
            n = "\(day.day)"
        }
        return L.app_ios_add_rule_month(day: n)
    default:
        return repeatLabel(r, locale)
    }
}
