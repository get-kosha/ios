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
    #expect(p["month"] == "2026-11")
    #expect(p["query"] == "rewe")
    #expect(p["minAmount"] == "2000")
    #expect(p["includeCorrections"] == .some(nil))
    #expect(Filters(minAmount: 1).count == 1)
    // A search, tag or event covers every date; a type or account keeps the month.
    #expect(f.period(Month(2026, 11)) == nil)
    #expect(Filters(type: "income").period(Month(2026, 11)) == Month(2026, 11))
    #expect(f.key(nil) == Filters(query: "  rewe ", type: "expense", minAmount: 2000).key(nil))
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
