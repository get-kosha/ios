import Foundation

// Personal loans (../kosha-web/src/lib/loans.ts): money lent to or borrowed from a person, repaid in any number of parts.
// Principal is neutral, as transfers are: it moves account balances and counts in net worth, never as income or
// spending. Amounts are integer minor units in the loan's own currency.

/// One agreement from list_loans or get_loan. `opening` tracks a balance already outstanding, with no bank movement.
public struct Loan: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// "lent" (owed to you) or "borrowed" (you owe).
    public var direction: String
    public var person: String
    @D public var purpose: String = ""
    @D public var note: String = ""
    public var currency: String
    public var principal: Int64
    public var repaid: Int64
    public var remaining: Int64
    public var day: String
    public var dueDay: String?
    @D public var opening: Bool = false

    public var lent: Bool { direction == "lent" }
    public var open: Bool { remaining > 0 }
    /// Still owed and past its due date (`today` as YYYY-MM-DD).
    public func overdue(_ today: String) -> Bool { open && (dueDay.map { $0 < today } ?? false) }
    /// loans.ts loanStatus.
    public var status: Status { remaining == 0 ? .paid : repaid > 0 ? .partial : .unpaid }
    /// The share paid back, 0…1.
    public var repaidShare: Double { principal > 0 ? min(1, max(0, Double(repaid) / Double(principal))) : 0 }

    public enum Status: Sendable { case paid, partial, unpaid }
}

/// A bank movement linked to a loan: the funding (lent or borrowed) or a repayment. `principal` is what it did to the
/// loan, in the loan's currency; `amount` is the entry itself, in its account's currency.
public struct LoanPayment: Codable, Sendable, Hashable, Identifiable {
    public var transactionId: String
    public var kind: String
    public var principal: Int64
    public var amount: Int64
    public var currency: String
    public var accountId: String
    @D public var accountName: String
    public var day: String
    @D public var note: String = ""
    @D public var reconciled: Bool

    public var id: String { transactionId }
    public var funding: Bool { kind == "funding" }
}

public struct Loans: Codable, Sendable { @D public var loans: [Loan] }

public struct LoanDetail: Codable, Sendable {
    public var loan: Loan
    @D public var payments: [LoanPayment]

    /// A balance already outstanding can be removed while nothing is linked to it.
    public var canRemove: Bool { loan.opening && payments.isEmpty }
    /// The funding can be unlinked only once its repayments are.
    public func canUnlink(_ payment: LoanPayment) -> Bool { !payment.funding || !payments.contains { !$0.funding } }
}

/// Set on a transaction that is a loan's funding or repayment.
public struct LoanLink: Codable, Sendable, Hashable {
    public var id: String
    public var kind: String
    public var principal: Int64
    @D public var person: String
    public var direction: String

    public var funding: Bool { kind == "funding" }
}

public enum LoanMath {
    /// Owed to you and you owe, in `to` at the given rates (loans.ts loanTotals).
    public static func totals(_ loans: [Loan], to: String, perUsd: [String: Double]) -> (lent: Int64, borrowed: Int64) {
        var lent: Int64 = 0, borrowed: Int64 = 0
        for l in loans {
            let v = convert(l.remaining, from: l.currency, to: to, perUsd: perUsd)
            if l.lent { lent += v } else { borrowed += v }
        }
        return (lent, borrowed)
    }

    /// A repayment must be positive and no more than what is still owed; the server checks again.
    public static func validRepayment(_ amount: Int64?, remaining: Int64) -> Bool {
        guard let amount else { return false }
        return amount > 0 && amount <= remaining
    }

    /// Open loans first by overdue, then by due date (none last), then newest; matches the web's list order.
    public static func sorted(_ loans: [Loan], today: String) -> [Loan] {
        loans.sorted { a, b in
            let (ao, bo) = (a.overdue(today), b.overdue(today))
            if ao != bo { return ao }
            let (ad, bd) = (a.dueDay ?? "9999", b.dueDay ?? "9999")
            if ad != bd { return ad < bd }
            return a.day > b.day
        }
    }
}

extension Transaction {
    /// An entry a loan can link: paid, the right direction (and currency and date, when given), and not a transfer, a
    /// recurring payment, a refund (or refunded), already a loan's, or one of Kosha's own categories. The server checks
    /// it again.
    public func canLinkLoan(income: Bool, currency: String? = nil, since: String? = nil) -> Bool {
        loan == nil && !isUpcoming && transfer == nil && recurringId == nil && refundOf == nil && refunds.isEmpty
            && !Categories.isSystem(categoryId) && amount != 0 && (amount > 0) == income
            && (currency.map { self.currency == $0 } ?? true) && (since.map { day >= $0 } ?? true)
    }
}

/// A loan write's body and the UUID it is saved under: the same contents keep the same id, so a retry (after an answer
/// that never came, or the app being closed) is saved once; new contents get a new id.
public struct LoanRequest: Codable, Sendable, Equatable {
    public private(set) var id: String
    public private(set) var content: JSONValue

    public init(content: JSONValue) {
        id = UUID().uuidString.lowercased()
        self.content = content
    }

    public mutating func update(_ content: JSONValue) {
        guard self.content != content else { return }
        self = LoanRequest(content: content)
    }

    /// The contents with the request's id.
    public var body: JSONValue {
        guard case .object(var fields) = content else { return content }
        fields["id"] = .string(id)
        return .object(fields)
    }
}
