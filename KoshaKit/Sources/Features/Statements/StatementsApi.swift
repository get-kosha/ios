import Foundation
import Model
import API
import Store

// The shapes of /api/app/reconcile and /api/app/import (src/server/statements.server.ts, ai-tasks.server.ts and
// app-api.server.ts in the web repo), with only the fields these screens read. Rows keep the web's snake_case. Ported
// from the Android app's feature/statements Api.kt.

/// A CSV's columns (statement.ts Layout). Nullable columns are sent as null, never left out: the server needs them.
struct Layout: Codable, Sendable, Hashable {
    var header: Int
    var date: Int
    var dateFormat: DateFormatKind
    var description: [Int]
    var amount: Int?
    var debit: Int?
    var credit: Int?
    var invert: Bool
    var balance: Int?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(header, forKey: .header)
        try c.encode(date, forKey: .date)
        try c.encode(dateFormat, forKey: .dateFormat)
        try c.encode(description, forKey: .description)
        try c.encode(amount, forKey: .amount)
        try c.encode(debit, forKey: .debit)
        try c.encode(credit, forKey: .credit)
        try c.encode(invert, forKey: .invert)
        try c.encode(balance, forKey: .balance)
    }
}

/// A CSV layout remembered by its header, for /import/lines.
struct LayoutMemory: Encodable, Sendable {
    let signature: String
    let layout: Layout
}

// MARK: Reconcile

/// GET /api/app/reconcile?walletId= (reconcileData).
struct ReconcileData: Codable, Sendable {
    var account: Acc
    @D var history: [History]
    /// The balance the reconciled entries add up to.
    @Rounded var reconciled: Int64
    /// Entries not yet reconciled: paid, or due within a week.
    @D var open: [Row]
    /// Reconciled entries of the last two months, so a statement again finds them.
    @D var done: [Row]
    /// CSV layouts remembered by their header, so a statement from a known bank reads straight away.
    @D var layouts: [String: JSONValue]
    @D var aliases: [String: String]

    struct Acc: Codable, Sendable {
        var id: String
        var name: String
        var currency: String
        var type: AccountType?
        var creditLimit: Int64?
        @Rounded var balance: Int64
        var credit: Bool { type == .credit }

        enum CodingKeys: String, CodingKey {
            case id, name, currency, type, balance
            case creditLimit = "credit_limit"
        }
    }

    /// A past reconciliation. `printed` is the balance as the statement showed it (owed, for a card).
    struct History: Codable, Sendable, Identifiable {
        var id: String
        var statementDay: String
        @Rounded var balance: Int64
        @D var entries: Int
        @Rounded var adjustment: Int64
        @Rounded var printed: Int64

        enum CodingKeys: String, CodingKey {
            case id, balance, entries, adjustment, printed
            case statementDay = "statement_day"
        }
    }

    struct Row: Codable, Sendable, Identifiable, Hashable {
        var id: String
        var day: String
        @Rounded var amount: Int64
        @D var name: String
        @D var note: String
        @D var categoryId: String
        var paid: Int?
        var transferId: String?
        var counterWalletId: String?
        var bankRef: String?

        var isPaid: Bool { (paid ?? 1) == 1 }

        enum CodingKeys: String, CodingKey {
            case id, day, amount, name, note, paid
            case categoryId = "category_id", transferId = "transfer_id", counterWalletId = "counter_wallet_id"
            case bankRef = "bank_ref"
        }
    }
}

struct FinishBody: Encodable, Sendable {
    let walletId: String, statementDay: String
    let balance: Int64
    let ids: [String]
    let adjust: Bool
}

struct Finished: Codable, Sendable {
    var id: String
    @Rounded var adjustment: Int64
}

struct IdBody: Encodable, Sendable { let id: String }

struct ExplainBody: Encodable, Sendable {
    let statementDay: String
    let diff: Int64
    let currency: String
    let ticked: [ExplainItem]
    let unticked: [ExplainItem]
    let missing: [ExplainLine]
    let close: [ExplainClose]
}

struct ExplainItem: Encodable, Sendable { let id: String, day: String; let amount: Int64; let name: String }
struct ExplainLine: Encodable, Sendable { let day: String; let amount: Int64; let text: String }
struct ExplainClose: Encodable, Sendable { let id: String; let statementAmount: Int64 }

/// What the AI model makes of a difference.
struct Explained: Codable, Sendable {
    @D var summary: String
    @D var suggestions: [Suggestion]
    struct Suggestion: Codable, Sendable, Hashable {
        var text: String
        @D var ids: [String]
    }
}

// MARK: Reading a statement

/// POST /api/app/import/read: text for CSV, OFX and QFX, base64 for a PDF. `walletId` is the account it's for, when
/// known: a card's statement reads the other way, CSV or PDF.
struct ReadBody: Encodable, Sendable {
    let name: String
    let content: String
    let format: String?
    let card: Bool
    let layout: Layout?
    let walletId: String?
}

/// What /import/read gives: lines for every format, plus the CSV's rows and columns, or the OFX's or PDF's balances.
struct Read: Codable, Sendable {
    var format: String
    @D var lines: [Line]
    @D var withdrawn: [String]
    // CSV
    @D var rows: [[String]]
    var signature: String?
    var layout: Layout?
    var confident: Bool?
    var accountHint: String?
    // OFX and PDF
    var closing: Int64?
    var closingDay: String?
    var currency: String?
    var account: ReadAccount?
    // PDF
    var opening: Int64?
    var off: Int64?
    var to: String?

    var isConfident: Bool { confident ?? true }

    struct ReadAccount: Codable, Sendable {
        var id: String?
        var name: String?
        var type: String?
        var last4: String?
    }
}

/// The roles the AI model gave a CSV's columns (POST /import/layout).
struct Roles: Codable, Sendable {
    var header: Int
    var date: Int
    @D var description: [Int]
    var amount: Int?
    var debit: Int?
    var credit: Int?
    var balance: Int?
}

struct RowsBody: Encodable, Sendable { let rows: [[String]] }
struct TidyBody: Encodable, Sendable { let items: [TidyItem] }
struct TidyItem: Encodable, Sendable { let key: String, text: String; let amount: Int64 }

/// A payee name (and category) the AI model gave some bank text.
struct Tidy: Codable, Sendable, Hashable {
    var payee: String
    var categoryId: String?
}

// MARK: Import

/// GET /import/memory: CSV layouts remembered by their header, and payees remembered for bank text.
struct Memory: Codable, Sendable {
    @D var layouts: [String: JSONValue]
    @D var aliases: [String: String]
    init() {}
}

struct KnownEntry: Codable, Sendable {
    var id: String
    var day: String
    @Rounded var amount: Int64
    @D var name: String
    var ref: String?
}

/// One line to save with POST /import/lines: a category, or for a transfer the other account.
struct NewLine: Encodable, Sendable {
    let day: String
    let amount: Int64
    let name: String
    var note = ""
    var categoryId: String?
    var transferWith: String?
    let ref: String
}

struct Alias: Encodable, Sendable { let key: String, payee: String }

struct LinesBody: Encodable, Sendable {
    let walletId: String
    let layouts: [LayoutMemory]
    let aliases: [Alias]
    let lines: [NewLine]
}

struct PairBody: Encodable, Sendable { let pairs: [TransferBody] }

struct TransferBody: Encodable, Sendable {
    let fromWalletId: String, toWalletId: String
    let sent: Int64, received: Int64
    let day: String, refFrom: String, refTo: String
}

/// POST /import/finish. `closing` and `keep` are sent as null, never left out.
struct FinishImport: Encodable, Sendable {
    let walletId: String
    let firstDay: String
    let closing: Closing?
    let keep: Int64?

    struct Closing: Encodable, Sendable { let day: String; let balance: Int64 }

    enum CodingKeys: String, CodingKey { case walletId, firstDay, closing, keep }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(walletId, forKey: .walletId)
        try c.encode(firstDay, forKey: .firstDay)
        try c.encode(closing, forKey: .closing)
        try c.encode(keep, forKey: .keep)
    }
}

struct ImportFinished: Codable, Sendable {
    @Rounded var opening: Int64
    @D var reconciled: Bool
}

/// create_transactions with the statement line's bank id, and an id chosen here so a retry saves it once.
struct BankEntry: Encodable, Sendable {
    let id: String, accountId: String, payee: String
    let amount: Int64
    let categoryId: String, day: String, bankRef: String
}

struct BankEntries: Encodable, Sendable { let transactions: [BankEntry] }
struct AmountChange: Encodable, Sendable { let id: String; let amount: Int64 }
struct AmountChanges: Encodable, Sendable { let transactions: [AmountChange] }

struct NewAccount: Encodable, Sendable {
    let name: String, type: String, currency: String
    let creditLimit: Int64?
}

struct Created: Codable, Sendable { var id: String }

/// list_recurring with includeSuggestions: payees paid on a steady rhythm that aren't set up yet.
struct RecurringSuggestions: Codable, Sendable {
    @D var suggestions: [Suggestion]
    struct Suggestion: Codable, Sendable { var payee: String }
}

// MARK: Files

/// A file the person chose or shared, read for POST /import/read.
struct Picked: Sendable, Hashable {
    let name: String
    let pdf: Bool
    let content: String

    /// Reads a file: text for CSV, OFX and QFX (UTF-8, falling back to Windows-1252 for older bank exports, as the web's
    /// fileText does), base64 for a PDF, which the server hands to the AI model.
    static func read(_ url: URL) throws -> Picked {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        let pdf = name.lowercased().hasSuffix(".pdf") || data.prefix(4) == Data("%PDF".utf8)
        let content = pdf ? data.base64EncodedString()
            : String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        return Picked(name: name, pdf: pdf, content: content)
    }

    static func isPdf(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
}

/// Statements opened in Kosha from another app ("Open in Kosha"), waiting for Import to take them. The app puts the
/// URLs here and opens Import (`nav.push(.importStatements)`); Import takes them when it opens, or at once when it is
/// already open.
@MainActor @Observable
public final class ImportInbox {
    public static let shared = ImportInbox()
    public private(set) var files: [URL] = []

    public func put(_ urls: [URL]) { files += urls }

    func take() -> [URL] {
        defer { files = [] }
        return files
    }
}

extension KoshaAPI {
    /// Reads a file on the server (POST /api/app/import/read). A `layout` re-reads a CSV with the columns as set.
    /// `walletId` names the account when it exists already (Reconcile); Import's accounts may not exist yet.
    func read(_ file: Picked, card: Bool, layout: Layout? = nil, walletId: String? = nil) async throws -> Read {
        try await post("/api/app/import/read", ReadBody(
            name: file.name, content: file.content, format: file.pdf ? "pdf" : nil, card: card, layout: layout,
            walletId: walletId
        ))
    }

    /// A CSV layout with the columns the AI model worked out (POST /api/app/import/layout), for one Kosha couldn't read
    /// alone, with its date format worked out from that column. Nil when the model couldn't tell.
    func aiLayout(_ read: Read) async -> Layout? {
        guard var base = read.layout else { return nil }
        let rows = read.rows.prefix(12).map { Array($0.prefix(60)) }
        guard let roles: Roles = try? await post("/api/app/import/layout", RowsBody(rows: Array(rows))) else { return nil }
        let values = read.rows.dropFirst(roles.header + 1).map { $0.indices.contains(roles.date) ? $0[roles.date] : "" }
        base.header = roles.header
        base.date = roles.date
        base.description = roles.description
        base.amount = roles.amount
        base.debit = roles.debit
        base.credit = roles.credit
        base.balance = roles.balance
        base.dateFormat = guessDateFormat(Array(values)) ?? base.dateFormat
        return base
    }
}

/// A CSV's closing and opening balances from its running balance column (import.tsx csvStmt). A card's is ambiguous.
struct Balances: Sendable { let closing: Int64?, opening: Int64?; let closingDay: String? }

func csvBalances(_ lines: [Line], card: Bool) -> Balances {
    guard let first = lines.first, let last = lines.last else { return Balances(closing: nil, opening: nil, closingDay: nil) }
    let asc = lines.count > 1 && first.day <= last.day
    let latest = asc ? last : first
    let oldest = asc ? first : last
    return Balances(
        closing: card ? nil : latest.balance,
        opening: card || oldest.balance == nil ? nil : oldest.balance! - oldest.amount,
        closingDay: lines.map(\.day).max()
    )
}

/// The first and last day of some lines.
func span(_ lines: [Line]) -> (first: String, last: String)? {
    guard let a = lines.map(\.day).min(), let b = lines.map(\.day).max() else { return nil }
    return (a, b)
}
