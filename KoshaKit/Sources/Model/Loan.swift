import Foundation

public struct Loan: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var direction: String
    public var person: String
    public var purpose: String
    public var note: String
    public var currency: String
    public var principal: Int64
    public var repaid: Int64
    public var remaining: Int64
    public var day: String
    public var dueDay: String?
    public var opening: Bool
}

public struct LoanList: Codable, Sendable { public var loans: [Loan] }
public struct LoanDetail: Codable, Sendable {
    public var loan: Loan
    public var payments: [LoanPayment]
    public var canRemove: Bool { loan.opening && payments.isEmpty }
    public func canUnlink(_ payment: LoanPayment) -> Bool {
        payment.kind != "funding" || !payments.contains { $0.kind == "repayment" }
    }
}
public struct LoanPayment: Codable, Sendable, Hashable, Identifiable {
    public var id: String { transactionId }
    public var transactionId: String
    public var kind: String
    public var principal: Int64
    public var amount: Int64
    public var currency: String
    public var accountId: String
    public var accountName: String
    public var day: String
    public var note: String
    public var reconciled: Bool
}

extension Transaction {
    public func canLinkLoan(income: Bool, currency: String? = nil, since: String? = nil) -> Bool {
        loan == nil && !isUpcoming && transfer == nil && recurringId == nil && refundOf == nil && refunds.isEmpty
            && !Categories.isSystem(categoryId) && amount != 0 && (amount > 0) == income
            && (currency == nil || self.currency == currency) && (since == nil || day >= since!)
    }
}

/// Saved before sending: retry the same contents with the same UUID, including after process termination.
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
    public var body: JSONValue {
        guard case .object(var fields) = content else { return content }
        fields["id"] = .string(id)
        return .object(fields)
    }
}
