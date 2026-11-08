import Foundation
import Model

// The welcome screen's arithmetic, ported from the web (core.ts openingFigures, accountWorth, netWorth). It is a preview
// before any account exists, so it can't come from the server's reports yet.

/// An account being set up on Welcome, with the two figures people know (minor units, ×100), nil when not typed.
struct NewAccount: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var type: AccountType
    var currency: String
    /// The balance, what a card owes, or what was put into an investment.
    var amount: Int64?
    /// A card's credit limit or an investment's value today.
    var extra: Int64?

    init(id: UUID = UUID(), name: String, type: AccountType, currency: String, amount: Int64? = nil, extra: Int64? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.currency = currency
        self.amount = amount
        self.extra = extra
    }
}

/// What a new account stores. A card keeps the credit left; an investment keeps the money put in and its gain.
struct Opening: Equatable {
    var balance: Int64
    var creditLimit: Int64?
    var gain: Int64?
}

/// core.ts openingFigures: a card's balance is the credit left (limit minus what is owed; without a limit, minus what is
/// owed). An investment with only a value today counts it all as money put in.
func openingFigures(_ type: AccountType, amount: Int64?, extra: Int64?) -> Opening {
    switch type {
    case .credit:
        return Opening(balance: (extra ?? 0) - abs(amount ?? 0), creditLimit: extra, gain: nil)
    case .investment:
        let put = amount ?? extra ?? 0
        return Opening(balance: put, creditLimit: nil, gain: extra.map { $0 - put })
    default:
        return Opening(balance: amount ?? 0, creditLimit: nil, gain: nil)
    }
}

extension NewAccount {
    var opening: Opening {
        openingFigures(type, amount: amount, extra: type == .credit || type == .investment ? extra : nil)
    }
}

/// core.ts accountWorth: a card counts what it owes as debt, an investment its money in plus its gain.
func accountWorth(_ type: AccountType, balance: Int64, creditLimit: Int64?, gain: Int64?) -> Int64 {
    switch type {
    case .credit: balance - (creditLimit ?? 0)
    case .investment: balance + (gain ?? 0)
    default: balance
    }
}

/// core.ts netWorth(...).total for accounts not saved yet, converted at the server's rates (units per 1 USD).
func previewNetWorth(_ accounts: [NewAccount], to: String, perUsd: [String: Double]) -> Int64 {
    accounts.reduce(0) { sum, a in
        let o = a.opening
        return sum + convert(accountWorth(a.type, balance: o.balance, creditLimit: o.creditLimit, gain: o.gain),
                             from: a.currency, to: to, perUsd: perUsd)
    }
}
