import Foundation
import Model

/// GET /api/app/accounts-overview?month=&currency= (finance.accountsOverview): the net worth series by account in the
/// display currency, and per account its month in, out and moved and its last entry, in its own currency. The server
/// doesn't round converted figures, so they arrive as decimals. Ported from AccountsData.kt.
struct AccountsOverview: Codable, Sendable {
    var currency: String
    var month: String
    var today: String
    /// Unix seconds of the last exchange-rate refresh.
    @D var ratesUpdated: Int64
    @D var series: [Point]
    @D var accounts: [String: Flow]
    /// What is still owed on personal loans, in the display currency at today's rates.
    var loans: LoanTotals?

    struct Point: Codable, Sendable, Hashable {
        var month: String
        var netWorth: Double
        @D var gains: Double
        @D var byAccount: [String: Double]
        /// Loans' net worth at the month's end: owed to you less what you owe.
        @D var loans: Double
    }

    struct LoanTotals: Codable, Sendable {
        @D var lent: Int64
        @D var borrowed: Int64
    }

    struct Flow: Codable, Sendable {
        @D var inflow: Double
        @D var out: Double
        @D var moved: Double
        var lastEntry: String?

        enum CodingKeys: String, CodingKey {
            case out, moved, lastEntry
            case inflow = "in"
        }
    }
}

/// GET /api/v1/exchanges (list_currency_exchanges). `sent` includes the fee.
struct Exchanges: Codable, Sendable { @D var exchanges: [Exchange] }

struct Exchange: Codable, Sendable, Identifiable {
    var id: String
    var day: String
    var fromAccountId: String
    var toAccountId: String
    var sent: Int64
    var received: Int64
    @D var fee: Int64
    @D var provider: String
    var fromCurrency: String
    var toCurrency: String
    var marketRate: Double?
}

/// GET /api/v1/gains?accountId= (list_gains), newest first.
struct Gains: Codable, Sendable { @D var gains: [Gain] }

/// The answer of create_account that the app reads.
struct CreatedAccount: Codable, Sendable { var id: String }

/// Investments whose value is older than this ask to be updated (accounts.tsx STALE_DAYS).
let staleDays = 60

/// A net worth chart layer: an account's part, or all unrealized gains on top (`id` nil).
struct Layer: Equatable {
    var id: String?
    var values: [Double]
}

enum AccountsMath {
    /// `total` left the source account, `fee` of it was charged, and the rest became `received` (core.ts exchange).
    static func exchange(_ total: Int64, fee: Int64, received: Int64, marketRate: Double?) -> FxCost {
        Model.exchange(total: total, fee: fee, received: received, marketRate: marketRate)
    }

    /// What an account is worth in lists, in its currency (core.ts accountWorth); a card shows what it owes.
    static func shownWorth(_ w: Wallet) -> Int64 {
        switch w.kind {
        case .credit: -max(0, (w.creditLimit ?? 0) - w.balance)
        case .investment: w.balance + (w.gain ?? 0)
        default: w.balance
        }
    }

    /// What an account adds to net worth (core.ts accountWorth).
    static func worth(_ w: Wallet) -> Int64 {
        switch w.kind {
        case .credit: w.balance - (w.creditLimit ?? 0)
        case .investment: w.balance + (w.gain ?? 0)
        default: w.balance
        }
    }

    /// The last `months` points of the series: 13 for a year, 25 for two, all for nil.
    static func range(_ series: [AccountsOverview.Point], _ months: Int?) -> [AccountsOverview.Point] {
        months.map { Array(series.suffix($0)) } ?? series
    }

    /// The chart layer for personal loans: owed to you less what you owe.
    static let loansLayer = "loans"

    /// One layer per account in the given order (only those with any value), then loans and gains if they have any.
    /// A layer that is above zero in some months and below in others (loans, an overdrawn account) is split into its
    /// positive and negative parts, so each part stays in its own stack instead of cutting across the chart.

    static func layers(_ points: [AccountsOverview.Point], order: [String]) -> [Layer] {
        var ids = order
        for p in points { for k in p.byAccount.keys.sorted() where !ids.contains(k) { ids.append(k) } }
        let accounts = ids.map { id in Layer(id: id, values: points.map { $0.byAccount[id] ?? 0 }) }
            .filter { $0.values.contains { $0.rounded() != 0 } }
        let loans = Layer(id: loansLayer, values: points.map(\.loans))
        let gains = Layer(id: nil, values: points.map(\.gains))
        return (accounts + [loans, gains].filter { $0.values.contains { $0.rounded() != 0 } }).flatMap { l in
            l.values.contains { $0.rounded() > 0 } && l.values.contains { $0.rounded() < 0 }
                ? [Layer(id: l.id, values: l.values.map { max($0, 0) }), Layer(id: l.id, values: l.values.map { min($0, 0) })]
                : [l]
        }
    }

    /// Stacks layers by sign, as recharts' stackOffset "sign": positive values pile up from zero, negative ones (card
    /// debt) pile down from it. Returns each layer's (lower, upper) per point.
    static func stack(_ layers: [Layer]) -> [[(Double, Double)]] {
        let n = layers.first?.values.count ?? 0
        var up = [Double](repeating: 0, count: n)
        var down = [Double](repeating: 0, count: n)
        return layers.map { l in
            l.values.enumerated().map { i, v in
                if v >= 0 {
                    defer { up[i] += v }
                    return (up[i], up[i] + v)
                }
                defer { down[i] += v }
                return (down[i] + v, down[i])
            }
        }
    }
}
