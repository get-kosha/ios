import Foundation
import Model

// The shapes behind Recurring, ported from the Android app's Schedule.kt. GET /api/app/subscriptions is the web's own
// read (finance.listSubscriptions plus recentIncome), so it keeps the web's snake_case rows; the public
// /api/v1/recurring operations are camelCase.

/// GET /api/app/subscriptions.
struct SubscriptionsData: Codable, Sendable {
    @D var subscriptions: [Sub]
    @D var income: [Income]

    /// Income over the last 365 days, per account currency (recentIncome).
    struct Income: Codable, Sendable {
        var currency: String
        @Rounded var total: Int64
    }
}

/// One schedule as db.server loadSubscriptions returns it (SubscriptionView).
struct Sub: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var walletId: String
    var categoryId: String
    @Rounded var amount: Int64
    @D var note: String
    var every: Int?
    var unit: String?
    var startDay: String
    var endDay: String?
    @D var autoPay: Int
    var kind: String?
    var toWalletId: String?
    var toAmount: Int64?
    @D var variable: Int
    var currency: String
    @D var ended: Bool
    /// Amount normalised to one month; the server doesn't round it.
    @D var monthly: Double
    @D var instances: [Instance]
    var next: Instance?
    /// Paid payments, newest first.
    @D var history: [Paid]
    /// Files attached to its payments: payslips for income, bills otherwise.
    @D var attachmentCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, amount, note, every, unit, kind, variable, currency, ended, monthly, instances, next, history
        case walletId = "wallet_id", categoryId = "category_id", startDay = "start_day", endDay = "end_day"
        case autoPay = "auto_pay", toWalletId = "to_wallet_id", toAmount = "to_amount", attachmentCount = "attachment_count"
    }

    var n: Int { every ?? 1 }
    var period: String { unit ?? "month" }
    var isTransfer: Bool { toWalletId != nil }
    var isVariable: Bool { variable != 0 }
    var auto: Bool { autoPay != 0 }
    /// core.ts monthlyCost, rounded to whole minor units for display.
    var perMonth: Int64 { Int64(monthly.rounded()) }

    /// Where it is listed, as the web groups them (subscriptions.tsx groupOf).
    var group: SubGroup {
        if toWalletId != nil { return .transfers }
        if amount > 0 { return .income }
        return kind == "repetitive" ? .bills : .subscriptions
    }

    /// Scheduled money going out: bills and subscriptions, never transfers or neutral categories.
    var isCost: Bool { amount < 0 && toWalletId == nil && !Categories.isNeutral(categoryId) }
}

/// One upcoming (or overdue, or edited) payment of a schedule (core.ts Instance).
struct Instance: Codable, Sendable, Hashable {
    var dueDay: String
    var day: String
    @Rounded var amount: Int64
    @D var note: String
    /// paid, skipped, overdue, due or upcoming.
    var status: String
    @D var edited: Bool
    var txId: String?
    /// The account its row uses, when changed for this payment or once it has a row; else the schedule's.
    var walletId: String?

    enum CodingKeys: String, CodingKey {
        case day, amount, note, status, edited
        case dueDay = "due_day", txId = "tx_id", walletId = "wallet_id"
    }
}

/// A paid payment: the transaction row.
struct Paid: Codable, Sendable, Hashable {
    var id: String
    var dueDay: String?
    var day: String
    @Rounded var amount: Int64
    @D var note: String
    @D var walletId: String
    var transferId: String?

    enum CodingKeys: String, CodingKey {
        case id, day, amount, note
        case dueDay = "due_day", walletId = "wallet_id", transferId = "transfer_id"
    }
}

/// GET /api/v1/recurring?includeSuggestions=true, for "Looks recurring".
struct RecurringList: Codable, Sendable { @D var suggestions: [Suggestion] }

struct Suggestion: Codable, Sendable, Hashable {
    var payee: String
    var amount: Int64
    @D var variable: Bool
    var every: Int?
    var unit: String?
    var nextDay: String
    var lastDay: String
    @D var count: Int
    var categoryId: String
    var accountId: String
    @D var transactionIds: [String]
}

/// A file attached to one of a schedule's payments (attachments.server scheduleAttachments).
struct ScheduleFile: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var transactionId: String
    var name: String
    @D var type: String
    @D var size: Int64
    var day: String
    var dueDay: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, size, day, dueDay
        case transactionId = "transaction_id"
    }
}

/// The answers of create_recurring and update_recurring_payment that the app reads.
struct Created: Codable, Sendable { var id: String }

struct PaymentResult: Codable, Sendable {
    var payment: Payment?
    struct Payment: Codable, Sendable { var transactionId: String? }
}

enum SubGroup: CaseIterable, Sendable { case bills, subscriptions, income, transfers }

/// The four kinds the form offers, and how each is stored (subscription-form.tsx).
enum FormKind: Hashable, Sendable { case bill, subscription, income, transfer }

/// Schedule maths ported from ../kosha-web/src/lib/core.ts (occurrence, occurrencesBetween, nextOccurrence). Days are
/// plain dates in the user's time zone; month steps keep the start's day, clamped to short months.
enum Schedule {
    /// The n-th payment day, where 0 is `start`.
    static func occurrence(_ start: Day, every: Int, unit: String, n: Int) -> Day {
        switch unit {
        case "day": return start.adding(days: n * every)
        case "week": return start.adding(days: n * every * 7)
        default:
            let months = n * every * (unit == "year" ? 12 : 1)
            let m = start.monthOf.adding(months)
            return Day(m.year, m.month, min(start.day, m.dayCount))
        }
    }

    /// Payment days within from…to, never past `end`.
    static func between(_ start: Day, every: Int, unit: String, end: Day?, from: Day, to: Day, limit: Int = 2000) -> [Day] {
        var out: [Day] = []
        for n in 0..<limit {
            let day = occurrence(start, every: every, unit: unit, n: n)
            if day > to || (end.map { day > $0 } ?? false) { break }
            if day >= from { out.append(day) }
        }
        return out
    }

    /// The next payment on or after `from`, or nil once the schedule has ended.
    static func next(_ start: Day, every: Int, unit: String, end: Day?, from: Day) -> Day? {
        between(start, every: every, unit: unit, end: end, from: from,
                to: from.adding(days: 366 * max(1, unit == "year" ? every : 1)), limit: 5000).first
    }

    /// How many payments Kosha records at once for a new schedule that starts in the past: settle() in db.server books
    /// every day from the start until today when payments are recorded automatically.
    static func backfill(_ start: Day, every: Int, unit: String, end: Day?, today: Day) -> Int {
        start >= today ? 0 : between(start, every: every, unit: unit, end: end, from: start, to: today).count
    }

    /// The days of `month` a schedule pays on.
    static func inMonth(_ s: Sub, _ month: Month) -> [Day] {
        guard let start = Day(s.startDay) else { return [] }
        return between(start, every: s.n, unit: s.period, end: s.endDay.flatMap(Day.init), from: month.first, to: month.last)
    }

    /// Zip entry names: "2026-10 payslip.pdf", numbered when two would clash (core.ts archiveNames).
    static func archiveNames(_ files: [(day: String, name: String)]) -> [String] {
        var seen: [String: Int] = [:]
        return files.map { day, name in
            let clean = String(name.map { "\\/:*?\"<>|".contains($0) ? "-" : $0 })
            let base = "\(day.prefix(7)) \(clean)"
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            if n == 1 { return base }
            if let dot = base.lastIndex(of: "."), base.distance(from: base.startIndex, to: dot) > 8 {
                return "\(base[..<dot]) (\(n))\(base[dot...])"
            }
            return "\(base) (\(n))"
        }
    }
}

/// Payments per month for each unit (core.ts PER_MONTH).
func perMonthFactor(_ unit: String) -> Double {
    switch unit {
    case "day": 365.25 / 12
    case "week": 52.18 / 12
    case "year": 1.0 / 12
    default: 1
    }
}

/// A zip that stores its files uncompressed: photos and PDFs are compressed already, as on Android.
/// ponytail: stored entries only and no zip64, so every file and the whole archive must stay under 4 GB.
enum StoredZip {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func make(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int, into d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: UInt32, into d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            // Local file header; flag 0x0800 marks the name as UTF-8. Time and date are 1980-01-01 00:00.
            u32(0x0403_4B50, into: &out); u16(20, into: &out); u16(0x0800, into: &out); u16(0, into: &out)
            u16(0, into: &out); u16(0x21, into: &out); u32(crc, into: &out)
            u32(UInt32(data.count), into: &out); u32(UInt32(data.count), into: &out)
            u16(nameBytes.count, into: &out); u16(0, into: &out)
            out.append(nameBytes)
            out.append(data)
            u32(0x0201_4B50, into: &central); u16(20, into: &central); u16(20, into: &central); u16(0x0800, into: &central)
            u16(0, into: &central); u16(0, into: &central); u16(0x21, into: &central); u32(crc, into: &central)
            u32(UInt32(data.count), into: &central); u32(UInt32(data.count), into: &central)
            u16(nameBytes.count, into: &central); u16(0, into: &central); u16(0, into: &central); u16(0, into: &central)
            u16(0, into: &central); u32(0, into: &central); u32(offset, into: &central)
            central.append(nameBytes)
        }
        let start = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, into: &out); u16(0, into: &out); u16(0, into: &out)
        u16(entries.count, into: &out); u16(entries.count, into: &out)
        u32(UInt32(central.count), into: &out); u32(start, into: &out); u16(0, into: &out)
        return out
    }
}
