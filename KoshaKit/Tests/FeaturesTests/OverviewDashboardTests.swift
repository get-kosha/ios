import Foundation
import Testing
import Model
@testable import Features

// The Android app's DashboardTest.kt: the Overview formulas from index.tsx.

private let d = Dashboard(
    primary: "eur", month: "2026-11",
    current: .init(income: 324_000, expense: 131_240, net: 0),
    categories: [
        .init(id: "rent", total: 95000, count: 1, fixed: true, usualToDate: 95000),
        .init(id: "dining", total: 8620, count: 4, usualToDate: 6950),
        .init(id: "groceries", total: 14230, count: 6, usualToDate: 15500),
        .init(id: "shopping", total: 3990, count: 1, usualToDate: 300),
    ],
    pace: .init(daysInMonth: 30, today: 7, current: Array(repeating: 131_240, count: 7), usual: (1...30).map { Double($0) * 8000 }),
    upcoming: [
        .init(key: "o2|2026-11-05", name: "O2", day: "2026-11-05", amount: -5200, currency: "eur", kind: "repetitive", subscriptionId: "o2"),
        .init(key: "sp|2026-11-10", name: "Spotify", day: "2026-11-10", amount: -1099, currency: "eur", kind: "subscription", subscriptionId: "sp"),
        .init(key: "hd|2026-11-30", name: "HDFC", day: "2026-11-30", amount: -50000, currency: "eur", kind: "transfer",
              subscriptionId: "hd", toWalletId: "hdfc"),
        .init(key: "x|2026-12-01", name: "Later", day: "2026-12-01", amount: -1000, currency: "usd", kind: "subscription", subscriptionId: "x"),
    ]
)
private let rates = ["eur": 0.9, "usd": 1.0]

@Test func pace() {
    #expect(d.usualBy == 56000)
    #expect(d.usualMonth == 240_000)
    // spent + (usual month − usual by now)
    #expect(d.projected == 315_240)
    #expect(d.underUsual == -75_240)
}

@Test func stillToPayLeavesOutTransfersAndNextMonth() {
    #expect(d.stillToPay("2026-11", rates) == 6299)
    #expect(d.billsDue("2026-11", rates) == 2)
    #expect(d.stillToPay("2026-12", rates) == 0)
}

@Test func pills() {
    #expect(vsUsual(95000, 95000, fixed: true) == .fixed)
    #expect(vsUsual(3990, 300) == .new)
    #expect(vsUsual(8620, 6950).warn)
    #expect(vsUsual(14230, 15500).good)
}

@Test func needsAttention() throws {
    let wallets = try KoshaJSON.decode([Wallet].self, Data("""
    [{"id":"visa","name":"Visa Card","currency":"eur","balance":131643,"type":"credit","credit_limit":200000},
     {"id":"tr","name":"Trade Republic","currency":"eur","balance":1890000,"type":"investment","gain_day":"2026-08-27"},
     {"id":"old","name":"Old ETF","currency":"eur","archived":1,"type":"investment"}]
    """.utf8))
    let items = d.attention(Day(2026, 11, 7), wallets)
    #expect(items.map(\.id) == ["o2|2026-11-05", "visa", "dining", "tr"])
    if case .cardOwed(_, let owed) = items[1] { #expect(owed == 68357) } else { Issue.record("not a card") }
    if case .stale(_, let age) = items[3] { #expect(age == 72) } else { Issue.record("not stale") }
}
