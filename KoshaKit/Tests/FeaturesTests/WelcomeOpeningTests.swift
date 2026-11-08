import Testing
import Model
@testable import Features

// The same cases as the Android app's welcome OpeningTest.kt.

@Test func aCardKeepsTheCreditLeft() {
    #expect(openingFigures(.credit, amount: 68357, extra: 200_000) == Opening(balance: 131_643, creditLimit: 200_000, gain: nil))
    // Without a limit it is minus what is owed, so its worth still counts the debt.
    #expect(openingFigures(.credit, amount: 68357, extra: nil) == Opening(balance: -68357, creditLimit: nil, gain: nil))
    #expect(accountWorth(.credit, balance: 131_643, creditLimit: 200_000, gain: nil) == -68357)
}

@Test func anInvestmentKeepsMoneyInAndItsGain() {
    #expect(openingFigures(.investment, amount: 1_890_000, extra: 2_107_703) == Opening(balance: 1_890_000, creditLimit: nil, gain: 217_703))
    // Only a value today: it all counts as money put in.
    #expect(openingFigures(.investment, amount: nil, extra: 2_107_703) == Opening(balance: 2_107_703, creditLimit: nil, gain: 0))
    #expect(accountWorth(.investment, balance: 1_890_000, creditLimit: nil, gain: 217_703) == 2_107_703)
}

@Test func netWorthPreviewMatchesTheDesign() {
    // 2,418.30 in the bank, 683.57 owed of 2,000.00, 18,900.00 put in worth 21,077.03 today: €22,811.76.
    let rows = [
        NewAccount(name: "N26 Main", type: .bank, currency: "eur", amount: 241_830),
        NewAccount(name: "Visa Card", type: .credit, currency: "eur", amount: 68357, extra: 200_000),
        NewAccount(name: "Trade Republic", type: .investment, currency: "eur", amount: 1_890_000, extra: 2_107_703),
    ]
    #expect(previewNetWorth(rows, to: "eur", perUsd: [:]) == 2_281_176)
}

@Test func netWorthPreviewConvertsAtTheServersRates() {
    let rows = [NewAccount(name: "HDFC", type: .bank, currency: "inr", amount: 946_000)]
    #expect(previewNetWorth(rows, to: "eur", perUsd: ["eur": 1.0, "inr": 94.6]) == 10000)
}
