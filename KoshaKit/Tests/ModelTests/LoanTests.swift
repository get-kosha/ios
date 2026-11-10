import Foundation
import Testing
@testable import Model

@Test func loanPrincipalIsNeutralAndCannotBeRefundedOrLinkedTwice() throws {
    let data = Data(#"{"id":"t","day":"2026-11-01","payee":"Sam","amount":-12000,"currency":"eur","accountId":"a","categoryId":"loan_principal","refunded":0,"loan":{"id":"l","kind":"funding","principal":12000,"person":"Sam","direction":"lent"}}"#.utf8)
    let t = try KoshaJSON.decode(Transaction.self, data)
    #expect(Categories.isNeutral(t.categoryId) && Categories.isSystem(t.categoryId))
    #expect(!t.canRefund && !t.canLinkLoan(income: false))
    #expect(t.loan?.principal == 12000 && t.loan?.id == "l")
}

@Test func eligibleLoanEntriesRespectCashDirectionCurrencyAndDate() throws {
    var t = try KoshaJSON.decode(Transaction.self, Data(#"{"id":"t","day":"2026-11-01","payee":"Sam","amount":500,"currency":"usd","accountId":"a","categoryId":"salary"}"#.utf8))
    #expect(t.canLinkLoan(income: true, since: "2026-11-01"))
    #expect(!t.canLinkLoan(income: false))
    #expect(!t.canLinkLoan(income: true, currency: "eur"))
    #expect(!t.canLinkLoan(income: true, since: "2026-11-02"))
    t.recurringId = "r"
    #expect(!t.canLinkLoan(income: true))
    t.recurringId = nil; t.refundOf = "original"
    #expect(!t.canLinkLoan(income: true))
    t.refundOf = nil; t.categoryId = Categories.correction
    #expect(!t.canLinkLoan(income: true))
}

@Test func retryIdentitySurvivesSerializationAndChangesOnlyForNewContents() throws {
    let content = JSONValue.object(["amount": .number(12000), "accountAmount": .number(13500), "loanId": .string("loan")])
    let first = LoanRequest(content: content)
    var restored = try KoshaJSON.decode(LoanRequest.self, KoshaJSON.encode(first))
    restored.update(content)
    #expect(restored.id == first.id && restored.body == first.body)
    restored.update(.object(["amount": .number(10000)]))
    #expect(restored.id != first.id)
}

@Test func loanDetailKeepsPrincipalAndActualCashSeparate() throws {
    let detail = try KoshaJSON.decode(LoanDetail.self, Data(#"{"loan":{"id":"l","direction":"lent","person":"Sam","purpose":"Deposit","note":"","currency":"eur","principal":10000,"repaid":2500,"remaining":7500,"day":"2026-10-01","dueDay":null,"opening":true},"payments":[{"transactionId":"p","kind":"repayment","principal":2500,"amount":2800,"currency":"usd","accountId":"a","accountName":"Synthetic bank","day":"2026-11-01","note":"","reconciled":true}]}"#.utf8))
    #expect(detail.loan.remaining == detail.loan.principal - detail.loan.repaid)
    #expect(detail.payments[0].amount == 2800 && detail.payments[0].principal == 2500)
    #expect(detail.payments[0].reconciled)
}

@Test func fundingUnlinkWaitsForRepaymentsAndOpeningRemovalWaitsForAllLinks() throws {
    var detail = try KoshaJSON.decode(LoanDetail.self, Data(#"{"loan":{"id":"l","direction":"borrowed","person":"Sam","purpose":"","note":"","currency":"eur","principal":10000,"repaid":2500,"remaining":7500,"day":"2026-10-01","dueDay":null,"opening":false},"payments":[{"transactionId":"f","kind":"funding","principal":10000,"amount":10000,"currency":"eur","accountId":"a","accountName":"Synthetic bank","day":"2026-10-01","note":"","reconciled":false},{"transactionId":"p","kind":"repayment","principal":2500,"amount":-2500,"currency":"eur","accountId":"b","accountName":"Other bank","day":"2026-11-01","note":"","reconciled":true}]}"#.utf8))
    #expect(!detail.canRemove && !detail.canUnlink(detail.payments[0]))
    #expect(detail.canUnlink(detail.payments[1]))
    detail.payments.removeLast()
    #expect(detail.canUnlink(detail.payments[0]))
    detail.loan.opening = true
    #expect(!detail.canRemove)
    detail.payments = []
    #expect(detail.canRemove)
}
