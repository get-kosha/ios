import Foundation

// The shapes Kosha's API speaks. Public operations (/api/v1, camelCase) follow ../kosha-web/src/lib/api-contract.ts;
// /api/app endpoints that mirror the web's own server functions keep the web's shapes (snake_case rows). Money is
// integer minor units, ×100 for every currency; the sign is the direction. Days are "YYYY-MM-DD" and months "YYYY-MM"
// in the user's time zone. Ported from the Android app's Api.kt.

/// An error as the API sends it: a message written for people, and invalid fields by path ("transactions.3.accountId").
public struct ApiError: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
    @D public var issues: [Issue]

    public struct Issue: Codable, Sendable, Hashable {
        public let path: String
        public let message: String
    }

    public init(code: String = "error", message: String, issues: [Issue] = []) {
        self.code = code
        self.message = message
        self.issues = issues
    }
}

public struct ErrorBody: Codable, Sendable { public let error: ApiError }

// MARK: Public operations

public enum AccountType: String, Codable, Sendable, CaseIterable {
    case bank, cash, credit, investment
}

public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var type: AccountType
    public var currency: String
    public var balance: Int64
    public var worth: Int64
    public var creditLimit: Int64?
    public var gain: Int64?
    public var gainDay: String?
    @D public var archived: Bool
    @D public var transactionCount: Int
    public var reconciledTo: String?
}

public struct Category: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var icon: String?
    public var type: String?
    public var parentId: String?
    @D public var archived: Bool
    @D public var transactionCount: Int
    @D public var recurringCount: Int
    @D public var ruleCount: Int
    public var income: Bool { type == "income" }
}

public struct Transaction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var day: String
    public var time: String?
    public var payee: String
    public var amount: Int64
    public var currency: String
    public var accountId: String
    @D public var accountName: String
    public var categoryId: String
    @D public var categoryName: String
    public var subcategoryId: String?
    @D public var note: String
    @D public var tags: [String]
    public var eventId: String?
    public var status: String?
    public var recurringId: String?
    public var dueDay: String?
    public var transfer: TransferLink?
    @D public var reconciled: Bool
    public var bankRef: String?
    @D public var attachmentCount: Int
    public var refundOf: String?

    public var hhmm: String { time ?? "12:00" }
    public var isUpcoming: Bool { status == "upcoming" }

    public struct TransferLink: Codable, Sendable, Hashable {
        public var id: String
        public var counterAccountId: String?
        public var counterAmount: Int64?
        @D public var fee: Int64
        /// Wise, Revolut, your bank… "" if not given.
        @D public var provider: String
        /// The day's mid-market rate between the two currencies, when they differ and it's known.
        public var marketRate: Double?
    }
}

public struct TransactionList: Codable, Sendable {
    public var transactions: [Transaction]
    @D public var total: Int
    public var nextOffset: Int?
    @D public var totals: [Totals]
    /// Only with a tag or eventId: paid spending and income per category and currency, net, most spent first.
    @D public var byCategory: [CategoryTotal]

    public struct CategoryTotal: Codable, Sendable, Hashable {
        public var categoryId: String
        @D public var categoryName: String
        public var currency: String
        public var amount: Int64
        @D public var count: Int
    }

    /// Money out, in and moved per currency for the filtered list.
    public struct Totals: Codable, Sendable, Hashable {
        public var currency: String
        public var spent: Int64
        public var received: Int64
        public var transferred: Int64
    }
}

/// A new entry for create_transactions. `id` is chosen here so a retry is saved once.
public struct NewTransaction: Codable, Sendable, Hashable {
    public var id: String
    public var accountId: String
    public var payee: String
    public var amount: Int64
    public var categoryId: String?
    public var subcategoryId: String?
    public var day: String?
    public var time: String?
    public var note: String
    public var tags: [String]
    public var eventId: String?

    public init(
        id: String = UUID().uuidString.lowercased(), accountId: String, payee: String, amount: Int64,
        categoryId: String? = nil, subcategoryId: String? = nil, day: String? = nil, time: String? = nil,
        note: String = "", tags: [String] = [], eventId: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.payee = payee
        self.amount = amount
        self.categoryId = categoryId
        self.subcategoryId = subcategoryId
        self.day = day
        self.time = time
        self.note = note
        self.tags = tags
        self.eventId = eventId
    }
}

public struct Transactions: Codable, Sendable { public var transactions: [Transaction] }

public struct Payee: Codable, Sendable, Hashable {
    public var payee: String
    @D public var count: Int
    public var categoryId: String?
    public var accountId: String?
    public var currency: String?
    public var averageAmount: Int64?
}

public struct Payees: Codable, Sendable { public var payees: [Payee] }

public struct Settings: Codable, Sendable {
    public var user: User
    public var primaryCurrency: String
    public var timeZone: String
    @D public var currencyOrder: [String]
    @D public var preferences: [String: JSONValue]
    public var exchangeRates: Rates?

    public struct User: Codable, Sendable { public var name: String; public var email: String }
    public struct Rates: Codable, Sendable {
        @D public var updatedAt: Int64
        @D public var perUsd: [String: Double]
    }
}

public struct Recurring: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var accountId: String
    public var categoryId: String
    public var amount: Int64
    public var currency: String
    @D public var note: String
    public var every: Int
    public var unit: String
    public var startDay: String
    public var endDay: String?
    @D public var autoPay: Bool
    public var kind: String
    public var toAccountId: String?
    public var toAmount: Int64?
    @D public var variable: Bool
    @D public var ended: Bool
    @D public var monthlyCost: Int64
    public var next: Payment?
    @D public var payments: [Payment]

    public struct Payment: Codable, Sendable, Hashable {
        public var dueDay: String
        public var day: String
        public var amount: Int64
        @D public var note: String
        public var status: String
        @D public var edited: Bool
        public var transactionId: String?
        /// The account it's paid from: the schedule's, unless changed for this payment.
        @D public var accountId: String
    }
}

public struct Gain: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var accountId: String
    public var day: String
    public var gain: Int64
    public var invested: Int64
    @D public var note: String
}

public struct PayeeRule: Codable, Sendable, Hashable {
    public var payee: String
    public var categoryId: String
    public var match: String
    public var source: String
    @D public var matches: Int
}

public struct KoshaEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var startDay: String?
    public var endDay: String?
    @D public var transactionCount: Int
}

// MARK: /api/app

/// What every screen needs, from GET /api/app/meta (the web's getMeta).
public struct Meta: Codable, Sendable {
    @D public var wallets: [Wallet]
    @D public var categories: [MetaCategory]
    @D public var rules: [Rule]
    @D public var titles: [String]
    @D public var events: [Event]
    @D public var tags: [String]
    /// Units per 1 USD.
    @D public var rates: [String: Double]
    public var primary: String?
    @D public var order: [String]
    public var tz: String?
    @D public var prefs: [String: JSONValue]
    @D public var ratesUpdated: Int64
    /// Which AI features are live. Off means no trace in the UI.
    public var ai: AiFlags?
    public var aiModel: AiModel?
    public var user: User?
    /// The demo account: read-only.
    @D public var demo: Bool
    @D public var avatars: Bool
    @D public var attachments: Bool
    @D public var version: Int

    public var primaryCurrency: String { primary ?? "eur" }
    public var timeZone: String { tz ?? "UTC" }
    public var aiFlags: AiFlags { ai ?? AiFlags() }

    public struct User: Codable, Sendable {
        public var id: String
        public var name: String
        public var email: String
        public var image: String?
    }

    public struct AiModel: Codable, Sendable {
        public var provider: String
        public var model: String
    }

    /// A preference as text, or its default.
    public func pref(_ key: String, _ fallback: String) -> String { prefs[key]?.string ?? fallback }
    public func pref(_ key: String, _ fallback: Bool) -> Bool {
        if let b = prefs[key]?.bool { return b }
        if let s = prefs[key]?.string { return s == "1" || s == "true" || s == "on" }
        return fallback
    }

    /// Payee rules as guessCategory reads them.
    public var payeeMatches: [PayeeMatch] { rules.map { PayeeMatch(title: $0.title, exact: $0.exact != 0, categoryId: $0.categoryId) } }
}

public struct AiFlags: Codable, Sendable, Hashable {
    @D public var categorise: Bool
    @D public var quickAdd: Bool
    @D public var receipts: Bool
    @D public var recap: Bool
    @D public var ask: Bool
    @D public var statements: Bool

    public init() {}

    enum CodingKeys: String, CodingKey {
        case categorise, receipts, recap, ask, statements
        case quickAdd = "quick_add"
    }

    public var any: Bool { categorise || quickAdd || receipts || recap || ask || statements }
}

/// An account as the web's own reads give it (snake_case).
public struct Wallet: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var currency: String
    @D public var archived: Int
    @D public var balance: Int64
    public var type: AccountType?
    public var creditLimit: Int64?
    public var gain: Int64?
    public var gainDay: String?
    @D public var txCount: Int
    @D public var entryCount: Int
    public var reconciledDay: String?

    public var isArchived: Bool { archived != 0 }
    public var kind: AccountType { type ?? .bank }

    enum CodingKeys: String, CodingKey {
        case id, name, currency, archived, balance, type, gain
        case creditLimit = "credit_limit", gainDay = "gain_day", txCount = "tx_count", entryCount = "entry_count"
        case reconciledDay = "reconciled_day"
    }
}

public struct MetaCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var icon: String?
    @D public var income: Int
    public var parentId: String?
    @D public var uses: Int
    @D public var archived: Int

    public var isIncome: Bool { income != 0 }
    public var isArchived: Bool { archived != 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, income, uses, archived
        case parentId = "parent_id"
    }
}

public struct Rule: Codable, Sendable, Hashable {
    public var title: String
    public var categoryId: String
    @D public var exact: Int

    enum CodingKeys: String, CodingKey {
        case title, exact
        case categoryId = "category_id"
    }
}

public struct Event: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var startDay: String?
    public var endDay: String?
    @D public var txCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case startDay = "start_day", endDay = "end_day", txCount = "tx_count"
    }
}

/// Days of a month with entries (GET /api/app/days).
public struct Days: Codable, Sendable { @D public var days: [String] }
