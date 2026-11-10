import Foundation
import Testing
import Model
@testable import Features

// The same cases as the Android app's AccountsMathTest.kt.

@Test func exchangeCostAgainstTheMarket() {
    // €1,000 sent with a €1.67 fee, ₹93,693.27 received, market 94.60: about €9.58 cost.
    let fx = AccountsMath.exchange(100_000, fee: 167, received: 9_369_327, marketRate: 94.60)
    #expect(fx.converted == 99833)
    #expect(abs(fx.rate - 93.85) < 0.01)
    #expect(abs(fx.totalCost - 958) < 1)
    // Beating the market costs less than nothing.
    #expect(AccountsMath.exchange(20000, fee: 0, received: 17280, marketRate: 0.86).totalCost < 0)
    // Without a market rate, only the fee counts.
    let noMarket = AccountsMath.exchange(5000, fee: 120, received: 4000, marketRate: nil)
    #expect(noMarket.rateCost == nil)
    #expect(noMarket.totalCost == 120)
}

@Test func ratesKeepUsefulPrecision() {
    #expect(rateString(125.4012) == "125.40")
    #expect(rateString(93.8512) == "93.8512")
    #expect(rateString(1.16231) == "1.1623")
    #expect(rateString(0.00864) == "0.008640")
}

private func wallet(_ json: String) -> Wallet { try! KoshaJSON.decode(Wallet.self, Data(json.utf8)) }

@Test func worthFollowsTheAccountType() {
    let card = wallet(#"{"id":"c","name":"Visa","currency":"eur","balance":131643,"type":"credit","credit_limit":200000}"#)
    #expect(AccountsMath.shownWorth(card) == -68357)
    #expect(AccountsMath.worth(card) == -68357)
    let fund = wallet(#"{"id":"i","name":"TR","currency":"eur","balance":1890000,"type":"investment","gain":217703}"#)
    #expect(AccountsMath.worth(fund) == 2_107_703)
    // A card paid off beyond its limit owes nothing in lists.
    var paid = card
    paid.balance = 210_000
    #expect(AccountsMath.shownWorth(paid) == 0)
}

@Test func stacksCardDebtBelowZero() {
    let s = AccountsMath.stack([Layer(id: "a", values: [100, 120]), Layer(id: "card", values: [-30, -10]), Layer(id: "b", values: [50, 0])])
    #expect(s[0].map { [$0.0, $0.1] } == [[0, 100], [0, 120]])
    #expect(s[1].map { [$0.0, $0.1] } == [[-30, 0], [-10, 0]])
    #expect(s[2].map { [$0.0, $0.1] } == [[100, 150], [120, 120]])
}

@Test func readsTheOverview() throws {
    let json = #"""
    {"currency":"eur","month":"2026-11","today":"2026-11-07","ratesUpdated":1,
    "series":[{"month":"2026-10","netWorth":1000.5,"gains":0,"byAccount":{"a":1000.5}},{"month":"2026-11","netWorth":900,"gains":12,"byAccount":{"a":950,"c":-62}}],
    "days":[],"last6":[],"accounts":{"a":{"months":[1,2],"days":[],"lastEntry":"2026-11-07","in":324000,"out":-108620,"moved":20000}},"recent":[]}
    """#
    let o = try KoshaJSON.decode(AccountsOverview.self, Data(json.utf8))
    #expect(o.accounts["a"]?.inflow == 324_000)
    #expect(AccountsMath.layers(o.series, order: ["c", "a"]).map(\.id) == ["c", "a", nil])
    #expect(AccountsMath.range(o.series, 1).count == 1)
}

@Test func historicalLoanLayersUseEachPointsOwnBalance() throws {
    let overview = try KoshaJSON.decode(AccountsOverview.self, Data(#"{"currency":"eur","month":"2026-11","today":"2026-11-10","series":[{"month":"2026-10","netWorth":10000,"gains":0,"byAccount":{"bank":4000},"loans":6000},{"month":"2026-11","netWorth":10000,"gains":0,"byAccount":{"bank":7500},"loans":2500}]}"#.utf8))
    let layers = AccountsMath.layers(overview.series, order: ["bank"])
    #expect(layers.first { $0.id == Categories.loanPrincipal }?.values == [6000, 2500])
    #expect(layers.first { $0.id == "bank" }?.values == [4000, 7500])
    #expect(overview.series.map(\.netWorth) == [10000, 10000])
}
