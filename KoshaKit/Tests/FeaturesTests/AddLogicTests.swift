import Foundation
import Testing
@testable import Features
@testable import Model
import Design

// The same cases as the Android app's feature/add LogicTest.kt, plus Repeat's rules.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T { try! KoshaJSON.decode(T.self, Data(json.utf8)) }
private func w(_ id: String) -> Wallet { decode(Wallet.self, #"{"id":"\#(id)","name":"\#(id)","currency":"eur"}"#) }
private func e(_ id: String, _ start: String? = nil, _ end: String? = nil) -> Event {
    var o: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
    if let start { o["start_day"] = .string(start) }
    if let end { o["end_day"] = .string(end) }
    return try! KoshaJSON.decode(Event.self, KoshaJSON.encode(JSONValue.object(o)))
}

@Test func startAccountPrefersTheDefaultThenTheLastUsed() {
    let active = [w("a"), w("b"), w("c")]
    #expect(startAccount("b", active: active, last: "c") == "b")
    #expect(startAccount("last", active: active, last: "c") == "c")
    // A default or last account that was archived or deleted falls through.
    #expect(startAccount("gone", active: active, last: "c") == "c")
    #expect(startAccount("last", active: active, last: "gone") == "a")
    #expect(startAccount("last", active: [], last: nil) == nil)
}

@Test func eventForPicksTheLatestStartThatCoversTheDay() {
    let events = [e("trip", "2026-11-01", "2026-11-10"), e("weekend", "2026-11-04", "2026-11-06"), e("open", "2026-12-01"), e("undated")]
    #expect(eventFor("2026-11-05", events) == "weekend")
    #expect(eventFor("2026-11-08", events) == "trip")
    #expect(eventFor("2027-03-01", events) == "open")
    #expect(eventFor("2026-10-31", events) == nil)
}

@Test func keypadInputDropsTrailingZeros() {
    #expect(keypadInput(-2957, decimals: 2) == "29.57")
    #expect(keypadInput(1200, decimals: 2) == "12")
    #expect(keypadInput(1250, decimals: 2) == "12.5")
    #expect(keypadInput(120_000, decimals: 0) == "1200")
    #expect(keypadInput(0, decimals: 2) == "")
}

@Test func exchangeMatchesTheFeeSheet() {
    // €500.00 with a €4.10 fee becomes ₹46,850.00 at a market rate of 94.60: €4.76 (0.95%) against the market.
    let x = exchange(total: 50000, fee: 410, received: 4_685_000, marketRate: 94.60)
    #expect(x.converted == 49590)
    #expect(x.totalCost.rounded() == 476)
    #expect(String(format: "%.2f", x.costPct) == "0.95")
    // Same currency: the cost is the fee.
    #expect(exchange(total: 50000, fee: 410, received: 49590, marketRate: nil).totalCost == 410)
}

@Test func transferSidesFollowWhatWasTyped() {
    let rates = ["usd": 1.0, "eur": 0.92, "inr": 87.032]
    let market = transferSides(sent: 50000, FeeInput(fee: "4.1"), from: "eur", to: "inr", fromDecimals: 2, toDecimals: 2, perUsd: rates)
    #expect(market.fee == 410)
    #expect(market.converted == 49590)
    #expect(market.received == Int64((49590 * (87.032 / 0.92)).rounded()))
    let received = transferSides(sent: 50000, FeeInput(fee: "4.1", received: "46850", typed: .received), from: "eur", to: "inr",
                                 fromDecimals: 2, toDecimals: 2, perUsd: rates)
    #expect(received.received == 4_685_000)
    let rate = transferSides(sent: 50000, FeeInput(rate: "94.5", typed: .rate), from: "eur", to: "inr",
                             fromDecimals: 2, toDecimals: 2, perUsd: rates)
    #expect(rate.received == 4_725_000)
    // Same currency: what arrives is what was sent less the fee.
    #expect(transferSides(sent: 50000, FeeInput(fee: "4.10"), from: "eur", to: "eur", fromDecimals: 2, toDecimals: 2,
                          perUsd: rates).received == 49590)
}

@Test func fmtRateKeepsTheWebsPrecision() {
    #expect(fmtRate(160.5312) == (160.53, 2))
    #expect(fmtRate(94.47123) == (94.4712, 4))
    #expect(fmtRate(1.08702) == (1.087, 4))
    #expect(fmtRate(0.0062311) == (0.006231, 6))
}

@Test func repeatNextDue() {
    // A monthly subscription from Sat 7 Nov 2026 is next due Mon 7 Dec.
    #expect(Repeat().next(after: Day(2026, 11, 7)) == Day(2026, 12, 7))
    #expect(Repeat(every: 2, unit: "week").next(after: Day(2026, 11, 7)) == Day(2026, 11, 21))
    #expect(Repeat(unit: "year").next(after: Day(2026, 11, 7)) == Day(2027, 11, 7))
}

@Test func repeatReadsBack() {
    L.use(language: "en")
    let uk = Money.locale("en")
    #expect(ruleText(Repeat(), day: Day(2026, 11, 7), uk) == "Every month on the 7th")
    #expect(ruleText(Repeat(unit: "week"), day: Day(2026, 11, 7), uk) == "Every week on Saturday")
    #expect(ruleText(Repeat(unit: "year"), day: Day(2026, 11, 7), uk) == "Every year on 7 November")
    #expect(repeatLabel(Repeat(), uk) == "Monthly")
    #expect(repeatLabel(Repeat(every: 2, unit: "week"), uk) == "Every 2 weeks")
}
