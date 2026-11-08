import Foundation
import Model
import API
import Store
import Design

// What Activity reads and the pure helpers its screens share. Ported from the Android app's ActivityModel.kt.

/// What Activity shows: search_transactions filters (GET /api/v1/transactions). A search, tag or event covers every
/// date, as the web's Activity period does (core.ts parsePeriod); anything else is the app-wide month.
struct Filters: Codable, Hashable, Sendable {
    var query = ""
    /// "expense", "income" or "transfer".
    var type: String?
    var accountId: String?
    var categoryId: String?
    /// Minor units by absolute value, in each entry's own currency.
    var minAmount: Int64?
    var maxAmount: Int64?
    var tag: String?
    var eventId: String?
    var corrections = false

    static let page = 100

    /// Filters set in the Filters sheet, beyond the search and the segmented type.
    var count: Int {
        [accountId, categoryId, minAmount.map(String.init), maxAmount.map(String.init), tag, eventId]
            .compactMap { $0 }.count + (corrections ? 1 : 0)
    }

    var trimmedQuery: String { String(query.trimmingCharacters(in: .whitespaces).prefix(40)) }

    /// Anything beyond the plain month list: no waiting rows, and "No match" rather than the empty month.
    var searching: Bool { count > 0 || !trimmedQuery.isEmpty || type != nil }

    /// The month the list covers: none (every date) for a search, a tag or an event.
    func period(_ month: Month) -> Month? { !trimmedQuery.isEmpty || tag != nil || eventId != nil ? nil : month }

    func params(_ month: Month?, offset: Int = 0, limit: Int = Filters.page) -> [String: String?] {
        [
            "month": month?.text,
            "query": trimmedQuery.isEmpty ? nil : trimmedQuery,
            "type": type,
            "accountId": accountId,
            "categoryId": categoryId,
            "minAmount": minAmount.map(String.init),
            "maxAmount": maxAmount.map(String.init),
            "tag": tag,
            "eventId": eventId,
            "includeCorrections": corrections ? "true" : nil,
            "limit": String(limit),
            "offset": offset > 0 ? String(offset) : nil,
        ]
    }

    /// A cache key for this list, so each search keeps its own saved copy.
    func key(_ month: Month?) -> String {
        // FNV-1a of the filters: String.hashValue changes every launch, and the saved copy must outlive it.
        let body = (try? KoshaJSON.encode(self)) ?? Data()
        let hash = body.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return "activity/\(month?.text ?? "all")/\(String(hash, radix: 36))"
    }

    static func of(_ s: ActivitySearch) -> Filters {
        Filters(query: s.query ?? "", type: s.type, accountId: s.accountId, categoryId: s.categoryId,
                minAmount: s.minAmount, maxAmount: s.maxAmount, tag: s.tag, eventId: s.eventId)
    }
}

/// Entries grouped by day, newest first, as the list shows them (transactions.tsx).
func byDay(_ list: [Transaction]) -> [(day: String, entries: [Transaction])] {
    var groups: [(day: String, entries: [Transaction])] = []
    for t in list {
        if groups.last?.day == t.day { groups[groups.count - 1].entries.append(t) } else { groups.append((t.day, [t])) }
    }
    return groups
}

/// A day's total in the display currency, leaving out neutral categories (transactions.tsx dayTotal).
func dayTotal(_ list: [Transaction], to: String, rates: [String: Double]) -> Int64 {
    list.filter { !Categories.isNeutral($0.categoryId) }.reduce(0) { $0 + convert($1.amount, from: $1.currency, to: to, perUsd: rates) }
}

/// Out, in and moved for the whole filtered list, from the server's per-currency totals, converted at its rates.
struct Summary: Equatable {
    var out: Int64, inn: Int64, moved: Int64
    var net: Int64 { inn + out }

    init(_ totals: [TransactionList.Totals], to: String, rates: [String: Double]) {
        func sum(_ k: KeyPath<TransactionList.Totals, Int64>) -> Int64 {
            totals.reduce(0) { $0 + convert($1[keyPath: k], from: $1.currency, to: to, perUsd: rates) }
        }
        out = sum(\.spent)
        inn = sum(\.received)
        moved = sum(\.transferred)
    }
}

extension Transaction {
    /// A transfer's sent amount: the outgoing half plus its fee (transactions.tsx Row).
    var sent: Int64 { Int64(amount.magnitude) + (amount < 0 ? transfer?.fee ?? 0 : 0) }

    /// An entry dated outside its event's days was put in the event by hand.
    func outsideEvent(_ start: String?, _ end: String?) -> Bool {
        (start != nil && day < start!) || (end != nil && day > end!)
    }

    /// A row for an entry waiting in the outbox. Model has no public initialiser, so it is read from JSON.
    static func waiting(_ q: Queued, day: String) -> Transaction? {
        let e = q.entry
        var o: [String: JSONValue] = [
            "id": .string(e.id), "day": .string(day), "payee": .string(e.payee), "amount": .number(Double(e.amount)),
            "currency": .string(q.currency), "accountId": .string(e.accountId), "accountName": .string(q.accountName),
            "categoryId": .string(e.categoryId ?? ""), "categoryName": .string(q.categoryName),
            "tags": .array(e.tags.map(JSONValue.string)),
        ]
        if let time = e.time { o["time"] = .string(time) }
        return try? KoshaJSON.decode(Transaction.self, KoshaJSON.encode(JSONValue.object(o)))
    }
}

/// What an exchange cost against the market rate (core.ts exchange()), in the source currency's minor units.
struct FxCost: Equatable {
    var converted: Int64
    var rateCost: Double?
    var totalCost: Double
    var costPct: Double
}

func exchange(total: Int64, fee: Int64, received: Int64, marketRate: Double?) -> FxCost {
    let converted = abs(total) - abs(fee)
    let rateCost = marketRate.flatMap { $0 == 0 ? nil : (Double(converted) * $0 - Double(abs(received))) / $0 }
    let totalCost = rateCost.map { Double(abs(fee)) + $0 } ?? Double(abs(fee))
    return FxCost(converted: converted, rateCost: rateCost, totalCost: totalCost,
                  costPct: total != 0 ? totalCost / Double(abs(total)) * 100 : 0)
}

/// An amount as the keypad types it: 2000 minor units is "20" (decimals only when there are cents).
func plainAmount(_ minor: Int64) -> String {
    NSDecimalNumber(decimal: Decimal(minor.magnitude) / 100).stringValue
}

/// A file attached to a transaction (attachments.server.ts listAttachments).
struct Attachment: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    @D var type: String
    @D var size: Int64
}

/// GET /api/app/payee-history: how often this payee comes up and this year's payments (finance.server.ts payeeHistory).
struct PayeeHistory: Codable, Sendable {
    @D var count: Int
    @D var thisYear: [Row]
    struct Row: Codable, Sendable {
        @Rounded var amount: Int64
        var currency: String
    }
}

/// The body of update_transactions for one entry: its id and the fields that change.
func patchBody(_ id: String, _ change: [String: JSONValue]) -> JSONValue {
    var o = change
    o["id"] = .string(id)
    return .object(["transactions": .array([.object(o)])])
}

/// A day in the language's own short form: "5 Nov", with `weekday` "Thu 5 Nov", with `year` the year too.
func dayText(_ day: Day, _ locale: Locale, weekday: Bool = false, year: Bool = false) -> String {
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = TimeZone(identifier: "UTC")
    f.setLocalizedDateFormatFromTemplate((weekday ? "EEE" : "") + "dMMM" + (year ? "y" : ""))
    return f.string(from: day.date)
}

/// "240 KB", "1.2 MB".
func fileSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
