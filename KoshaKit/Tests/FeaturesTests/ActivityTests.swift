import Foundation
import Testing
import Model
@testable import Features

// The same cases as the Android app's ActivityModelTest.kt.

private func tx(_ id: String, _ day: String, _ amount: Int64, category: String = "groceries", currency: String = "eur",
                fee: Int64? = nil) -> Model.Transaction {
    var o: [String: JSONValue] = [
        "id": .string(id), "day": .string(day), "payee": .string(id), "amount": .number(Double(amount)),
        "currency": .string(currency), "accountId": .string("a"), "categoryId": .string(category),
    ]
    if let fee {
        o["transfer"] = .object(["id": .string("t\(id)"), "counterAccountId": .string("b"),
                                 "counterAmount": .number(Double(-amount)), "fee": .number(Double(fee))])
    }
    return try! KoshaJSON.decode(Model.Transaction.self, KoshaJSON.encode(JSONValue.object(o)))
}

private let rates = ["eur": 0.5, "usd": 1.0]

@Test func groupsByDayAndLeavesNeutralOutOfDayTotals() {
    let list = [
        tx("rewe", "2026-11-07", -1840),
        tx("bvg", "2026-11-06", -350),
        tx("move", "2026-11-06", -20000, category: "transfer", fee: 120),
        tx("fix", "2026-11-06", 500, category: "0"),
        tx("pay", "2026-11-06", 1000, currency: "usd"),
    ]
    let days = byDay(list)
    #expect(days.map(\.day) == ["2026-11-07", "2026-11-06"])
    #expect(dayTotal(days[1].entries, to: "eur", rates: rates) == -350 + 500) // $10 is €5 at these rates
    #expect(list[2].sent == 20120)
}

@Test func summaryConvertsTheServerTotals() throws {
    let totals = try KoshaJSON.decode([TransactionList.Totals].self, Data("""
    [{"currency":"eur","spent":-131240,"received":324000,"transferred":20000},
     {"currency":"usd","spent":-2000,"received":0,"transferred":0}]
    """.utf8))
    let s = Summary(totals, to: "eur", rates: rates)
    #expect(s.out == -132_240)
    #expect(s.inn == 324_000)
    #expect(s.net == 191_760)
    #expect(s.moved == 20000)
}

@Test func paramsLeaveOutWhatIsNotSet() {
    let f = Filters(query: "  rewe ", type: "expense", minAmount: 2000)
    let p = f.params(Month(2026, 11))
    // A search covers every date unless a period is picked.
    #expect(p["month"] == .some(nil))
    #expect(p["from"] == .some(nil))
    #expect(p["query"] == "rewe")
    #expect(p["minAmount"] == "2000")
    #expect(p["includeCorrections"] == .some(nil))
    #expect(Filters(minAmount: 1).count == 1)
    // A search, tag or event covers every date; a type or account keeps the month.
    #expect(f.shown(Month(2026, 11)) == .all)
    #expect(Filters(type: "income").shown(Month(2026, 11)) == .month(Month(2026, 11)))
    #expect(f.key(Month(2026, 11)) == Filters(query: "  rewe ", type: "expense", minAmount: 2000).key(Month(2026, 11)))
    #expect(f.key(Month(2026, 11)) != Filters(query: "  rewe ", type: "expense", minAmount: 2000, period: .all).key(Month(2026, 11)))
}

/// month, from and to, as sent (nil when left out).
private func dates(_ p: [String: String?]) -> [String?] { ["month", "from", "to"].map { p[$0] ?? nil } }

@Test func periods() {
    let now = Month(2026, 11)
    #expect(Filters().params(now)["month"] == "2026-11")
    let year = Filters(query: "rewe", period: .year(2025)).params(now)
    #expect(dates(year) == [nil, "2025-01-01", "2025-12-31"])
    // Every date without a search starts at 1970: the server's default without dates is this month.
    let all = Filters(period: .all).params(now)
    #expect(dates(all) == [nil, "1970-01-01", nil])
    let found = Filters(tag: "trip", period: .all).params(now)
    #expect(dates(found) == [nil, nil, nil])
    let days = Filters(period: .range(Day(2026, 1, 5), Day(2026, 2, 10))).params(now)
    #expect(dates(days) == [nil, "2026-01-05", "2026-02-10"])
    #expect(Period.month(Month(2026, 12)).shift(1) == .month(Month(2027, 1)))
    #expect(Period.year(2026).shift(-1) == .year(2025))
    #expect(Period.range(Day(2026, 1, 5), Day(2026, 2, 10)).shift(1) == nil)
    #expect(Period.all.shift(-1) == nil)
    #expect(Period.month(Month(2026, 2)).days?.upperBound == Day(2026, 2, 28))
    // A link that names a month lists it; one without lists every date for a payee.
    #expect(Filters.of(ActivitySearch(query: "rewe", month: Month(2026, 3))).period == .month(Month(2026, 3)))
    #expect(Filters.of(ActivitySearch(query: "rewe")).shown(now) == .all)
}

@Test func exchangeCostAsOnTheWeb() {
    // core.test.ts: send €1,000 via Wise, €5 fee, €995 converted at 106.00 (market 106.50)
    let fx = exchange(total: 100_000, fee: 500, received: 10_547_000, marketRate: 106.5)
    #expect(fx.converted == 99500)
    #expect(fx.rateCost!.rounded() == 467)
    #expect(fx.totalCost.rounded() == 967)
    #expect(String(format: "%.2f", fx.costPct) == "0.97")
    #expect(exchange(total: 100_000, fee: 0, received: 100_000, marketRate: nil).totalCost == 0)
}

@Test func byHand() {
    let t = tx("tap", "2026-09-09", -41200)
    #expect(t.outsideEvent("2026-10-12", "2026-10-18"))
    #expect(!t.outsideEvent(nil, nil))
}

@Test func amountsAsTyped() {
    #expect(plainAmount(2000) == "20")
    #expect(plainAmount(-1250) == "12.5")
}

@Test func payeeHistoryUsualIsOptional() throws {
    let h = try KoshaJSON.decode(PayeeHistory.self, Data(#"{"count":3,"usual":{"amount":-2850,"currency":"eur"}}"#.utf8))
    #expect(h.usual?.amount == -2850 && h.usual?.currency == "eur")
    #expect(try KoshaJSON.decode(PayeeHistory.self, Data(#"{"count":3,"usual":null}"#.utf8)).usual == nil)
    #expect(try KoshaJSON.decode(PayeeHistory.self, Data(#"{"count":3,"thisYear":[]}"#.utf8)).usual == nil)
}
