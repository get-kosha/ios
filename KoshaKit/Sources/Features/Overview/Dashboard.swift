import Foundation
import Model

// GET /api/app/dashboard?month=&currency=: the web's own Overview read (finance.server.ts dashboard()), already
// converted to the display currency. The phone only picks and compares its figures, with the formulas from
// ../kosha-web/src/routes/_app/index.tsx cited on each function below; it never adds up rows itself. Ported from the
// Android app's feature/overview Dashboard.kt.

struct Dashboard: Codable, Sendable {
    var primary: String
    var month: String
    var current: Flows?
    var previous: Flows? = nil
    @D var series: [SeriesPoint] = []
    @D var categories: [DashCategory] = []
    var pace: Pace?
    var income: Income? = nil
    @D var upcoming: [Upcoming] = []

    struct Flows: Codable, Sendable {
        @Rounded var income: Int64
        @Rounded var expense: Int64
        @Rounded var net: Int64
    }

    struct SeriesPoint: Codable, Sendable {
        var month: String
        @Rounded var income: Int64
        @Rounded var expense: Int64
        @Rounded var netWorth: Int64
        @Rounded var gains: Int64
    }

    /// Spending in a category this month; `usualToDate` is the average by the same day over the 6 months before.
    struct DashCategory: Codable, Sendable, Hashable {
        var id: String
        @Rounded var total: Int64
        @D var count: Int = 0
        @D var fixed: Bool = false
        var usualToDate: Double? = nil
    }

    /// Cumulative spending by day: `current` up to today, `usual` the average month (nil without history). The usual
    /// curve is an average, so the server sends fractions of a cent; they are rounded for display only.
    struct Pace: Codable, Sendable, Hashable {
        var daysInMonth: Int?
        var today: Int?
        @D var current: [Double] = []
        var usual: [Double]? = nil

        var days: Int { daysInMonth ?? 30 }
    }

    struct Income: Codable, Sendable {
        var name: String
        var day: String
        @Rounded var amount: Int64
    }

    /// A payment due in the next 30 days: a recurring one (key "id|dueDay") or a one-off upcoming entry.
    struct Upcoming: Codable, Sendable, Hashable {
        var key: String
        var name: String
        var day: String
        @Rounded var amount: Int64
        var currency: String
        var kind: String
        var subscriptionId: String? = nil
        var categoryId: String? = nil
        var toWalletId: String? = nil

        var dueDay: String { key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }

        enum CodingKeys: String, CodingKey {
            case key, name, day, amount, currency, kind
            case subscriptionId = "subscription_id", categoryId = "category_id", toWalletId = "to_wallet_id"
        }
    }

    var flows: Flows { current ?? Flows(income: 0, expense: 0, net: 0) }
    var paceInfo: Pace { pace ?? Pace(daysInMonth: 30) }
}

/// Net worth from get_net_worth.
struct NetWorth: Codable, Sendable {
    @D var currency: String
    @Rounded var total: Int64
}

/// GET /api/app/recap: the recap Overview shows, if any (ai-tasks.server.ts getRecap).
struct RecapView: Codable, Sendable {
    var month: String
    @D var auto: Bool
    var recap: Recap?
}

/// A month's recap, from the recap read or recap_month.
struct Recap: Codable, Sendable {
    var month: String?
    @D var headline: String
    @D var summary: String
    @D var points: [Point]
    @D var writtenDay: String

    struct Point: Codable, Sendable, Hashable {
        var text: String
        var tone: String?
    }
}

private func cents(_ v: Double) -> Int64 { Int64(v.rounded()) }

extension Dashboard {
    /// The last day of the dashboard's month, "YYYY-MM-DD".
    var monthEnd: String { "\(month)-\(String(format: "%02d", paceInfo.days))" }

    /// The day the figures run to: today in this month, the last day in a past one.
    var dayN: Int { paceInfo.today ?? paceInfo.days }

    /// Usual spending by `dayN` and over the whole month (PaceCard: usualBy, usualMonth).
    var usualBy: Int64? { paceInfo.usual.flatMap { $0.indices.contains(dayN - 1) ? cents($0[dayN - 1]) : nil } }
    var usualMonth: Int64? {
        paceInfo.usual.flatMap { u in u.indices.contains(paceInfo.days - 1) ? cents(u[paceInfo.days - 1]) : nil }
    }

    /// PaceCard: projected = spent + max(0, usual whole month − usual by now), only while the month is live.
    var projected: Int64? {
        guard let by = usualBy, let whole = usualMonth, paceInfo.today != nil else { return nil }
        return flows.expense + max(0, whole - by)
    }

    /// PaceCard: how far under (positive) or over (negative) the usual by now, or nil without history.
    var underUsual: Int64? { usualBy.map { $0 - flows.expense } }

    /// Overview: what is still to pay before month end; only the current month has anything still to pay.
    func dueThisMonth(_ currentMonth: String) -> [Upcoming] {
        month == currentMonth ? upcoming.filter { $0.day <= monthEnd } : []
    }

    func stillToPay(_ currentMonth: String, _ rates: [String: Double]) -> Int64 {
        dueThisMonth(currentMonth).reduce(0) { $0 + $1.outflow(primary, rates) }
    }

    /// Bills among what is still to pay, for "6 bills before 30 Nov".
    func billsDue(_ currentMonth: String, _ rates: [String: Double]) -> Int {
        dueThisMonth(currentMonth).filter { $0.outflow(primary, rates) > 0 }.count
    }

    /// ComingUp: what is due before the cutoff (month end, or the next 30 days with Settings › Recurring › Coming up),
    /// and its cutoff. A past month on screen uses this month's end.
    func comingUp(_ today: Day, thirtyDays: Bool) -> (end: String, items: [Upcoming]) {
        let end = month >= today.monthOf.text
            ? (thirtyDays ? today.adding(days: 30).text : monthEnd)
            : "\(today.monthOf.text)-31"
        return (end, upcoming.filter { $0.day <= end })
    }

    /// NetWorthCard: the change in net worth this month (nil for a future month) and over the last 12 months.
    var worthChange: (thisMonth: Int64?, growth: Double?) {
        func at(_ m: String) -> Int64? { series.first { $0.month == m }?.netWorth }
        let prev = Month(month).map { $0.adding(-1).text } ?? ""
        let thisMonth = at(month).map { $0 - (at(prev) ?? 0) }
        let line = Array(series.filter { $0.month <= month }.suffix(12))
        let yearAgo = line.count > 1 ? line.first?.netWorth : nil
        var growth: Double?
        if let y = yearAgo, y != 0, let last = line.last { growth = Double(last.netWorth - y) / Double(abs(y)) }
        return (thisMonth, growth)
    }

    /// NeedsAttention in index.tsx, with its thresholds, in the web's order: overdue bills, cards owed, categories above
    /// usual, old investment values.
    func attention(_ today: Day, _ wallets: [Wallet]) -> [Attention] {
        var items: [Attention] = []
        let t = today.text
        for u in upcoming where u.day < t && u.subscriptionId != nil { items.append(.overdue(u)) }
        for card in wallets where !card.isArchived && card.kind == .credit {
            let owed = (card.creditLimit ?? 0) - card.balance
            if owed > 0 { items.append(.cardOwed(card, owed)) }
        }
        // A category over 20% above its usual pace. Skip tiny baselines and overspends under 2% of the usual month so far.
        let usualSoFar = paceInfo.usual.flatMap { $0.indices.contains(dayN - 1) ? $0[dayN - 1] : nil } ?? 0
        for c in categories {
            guard !c.fixed, let u = c.usualToDate, u != 0 else { continue }
            let total = Double(c.total)
            if u * 10 < total || total <= u * 1.2 || total - u < usualSoFar * 0.02 { continue }
            items.append(.aboveUsual(c, cents(u)))
        }
        for w in wallets where !w.isArchived && w.kind == .investment {
            let age = w.gainDay.flatMap(Day.init).map { $0.days(to: today) }
            if let age, age <= staleDays { continue }
            items.append(.stale(w, age))
        }
        return items
    }
}

extension Dashboard.Upcoming {
    /// Money a still-unpaid bill takes out, converted; incoming money and transfers count nothing.
    func outflow(_ to: String, _ rates: [String: Double]) -> Int64 {
        amount < 0 && toWalletId == nil ? -convert(amount, from: currency, to: to, perUsd: rates) : 0
    }
}


/// A category's pill in Where it went (vsUsual): fixed, new, or the change against the usual by now.
enum VsUsual: Equatable {
    case fixed
    case new
    /// The change as a ratio, e.g. 0.24 for +24%. Warn above +20%, positive below −5%.
    case change(Double)

    var warn: Bool { if case .change(let r) = self { r > 0.2 } else { false } }
    var good: Bool { if case .change(let r) = self { r < -0.05 } else { false } }
}

func vsUsual(_ total: Int64, _ usual: Double?, fixed: Bool = false) -> VsUsual {
    if fixed { return .fixed }
    // "new", not "+3766%", when the baseline is under a tenth of this month's spend.
    guard let usual, usual != 0, usual * 10 >= Double(total) else { return .new }
    return .change((Double(total) - usual) / usual)
}

/// One item for Needs attention.
enum Attention: Identifiable {
    case overdue(Dashboard.Upcoming)
    case cardOwed(Wallet, Int64)
    case aboveUsual(Dashboard.DashCategory, Int64)
    /// An investment whose value is older than `staleDays`, or was never entered (age nil).
    case stale(Wallet, Int?)

    var id: String {
        switch self {
        case .overdue(let p): p.key
        case .cardOwed(let w, _): w.id
        case .aboveUsual(let c, _): c.id
        case .stale(let w, _): w.id
        }
    }
}

extension Wallet {
    /// What an account adds to net worth, in its own currency (core.ts accountWorth).
    var worth: Int64 {
        switch kind {
        case .credit: balance - (creditLimit ?? 0)
        case .investment: balance + (gain ?? 0)
        default: balance
        }
    }
}
