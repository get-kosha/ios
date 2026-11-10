import SwiftUI
import Model
import Store
import Design

/// Every screen the app pushes. Sheets aren't routes: they live in the screen that opens them. Add is presented over
/// the tabs (`Navigator.add`), not pushed. Ported from the Android app's Routes.kt.
public enum Route: Hashable, Sendable {
    // Activity
    case tagView(tag: String?, eventId: String?)
    case txDetail(id: String)
    case transferDetail(id: String)

    // Recurring
    case recurringDetail(id: String)
    /// A new schedule, or an edit with `id`. `fromPayee` starts it from a "Looks recurring" suggestion,
    /// `fromTransaction` from an entry ("Make this recurring…").
    case recurringForm(id: String? = nil, fromPayee: String? = nil, fromTransaction: String? = nil)

    // Accounts
    case loans
    case loanDetail(id: String)
    case loanForm
    case accountDetail(id: String)
    case investmentDetail(id: String)
    case accountForm(id: String? = nil)
    case fixBalance(id: String)
    case exchanges
    case reconcile(accountId: String? = nil)
    case importStatements

    // Ask Kosha (AI)
    case ask(question: String? = nil)

    /// Settings. `page` names a section: "" for the list, then "profile", "security", "general", "appearance",
    /// "currencies", "categories", "category" (with `id`), "events", "rules", "recurring", "ai", "ai-provider" (with
    /// `id`), "ai-privacy", "ai-log", "data", "api", "delete".
    case settings(page: String = "", id: String? = nil)

    /// First run: name, currency and time zone, then accounts, then done.
    case welcome
}

/// What Add opens with. `kind` is expense, income or transfer; `scan` opens the receipt camera; `duplicateOf` copies an
/// entry; `toAccount` and `amount` prefill a transfer (a card's Pay).
public struct AddRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var kind: EntryKind?
    public var scan = false
    public var describe = false
    public var duplicateOf: String?
    public var fromAccount: String?
    public var toAccount: String?
    public var amount: Int64?

    public init(
        kind: EntryKind? = nil, scan: Bool = false, describe: Bool = false, duplicateOf: String? = nil,
        fromAccount: String? = nil, toAccount: String? = nil, amount: Int64? = nil
    ) {
        self.kind = kind
        self.scan = scan
        self.describe = describe
        self.duplicateOf = duplicateOf
        self.fromAccount = fromAccount
        self.toAccount = toAccount
        self.amount = amount
    }
}

/// A search for Activity to open with, from Overview, Ask, Search or a transaction ("At this payee").
public struct ActivitySearch: Hashable, Sendable {
    public var query: String?
    public var categoryId: String?
    public var accountId: String?
    public var tag: String?
    public var eventId: String?
    /// "expense", "income" or "transfer".
    public var type: String?
    public var minAmount: Int64?
    public var maxAmount: Int64?
    /// The month Activity lists. Without one, Activity keeps its default dates, so a search covers every date.
    public var month: Month?

    public init(
        query: String? = nil, categoryId: String? = nil, accountId: String? = nil, tag: String? = nil,
        eventId: String? = nil, type: String? = nil, minAmount: Int64? = nil, maxAmount: Int64? = nil, month: Month? = nil
    ) {
        self.query = query
        self.categoryId = categoryId
        self.accountId = accountId
        self.tag = tag
        self.eventId = eventId
        self.type = type
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.month = month
    }
}

/// Where the app is: the selected tab, each tab's stack, Add over the tabs, and searches handed to Activity. Any
/// screen opens any other through it (`@Environment(Navigator.self)`).
@MainActor @Observable
public final class Navigator {
    public var tab: MainTab = .overview
    public var paths: [MainTab: [Route]] = [:]
    /// Add, presented full screen over the tabs.
    public var add: AddRequest?
    /// A search for Activity to apply when it next appears; Activity clears it.
    public var activitySearch: ActivitySearch?
    /// Opens a URL in the browser; set by the root (ASWebAuthenticationSession for getkosha.app pages).
    public var openWeb: ((URL) -> Void)?

    public init() {}

    public func push(_ route: Route) { paths[tab, default: []].append(route) }

    public func pop() { _ = paths[tab]?.popLast() }

    /// Opens a main tab the way the tab bar does, keeping each tab's stack.
    public func open(_ tab: MainTab) { self.tab = tab }

    /// Opens Activity with a search applied.
    public func openActivity(_ search: ActivitySearch) {
        activitySearch = search
        paths[.activity] = []
        tab = .activity
    }

    public func openAdd(_ request: AddRequest = AddRequest()) { add = request }

    public func path(_ tab: MainTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }
}
