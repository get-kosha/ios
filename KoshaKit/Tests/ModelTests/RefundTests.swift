import Foundation
import Testing
@testable import Model

// Refunds (kosha-web 683a199): a spending entry's refunds and refunded total, and when it is refunded in part or in
// full. No account data is used.

private func tx(_ extra: String, amount: Int64 = -5000, category: String = "shopping", status: String = "paid") throws -> Transaction {
    try KoshaJSON.decode(Transaction.self, Data(#"{"id":"t1","day":"2026-11-04","payee":"Shop","amount":\#(amount),"currency":"eur","accountId":"a1","categoryId":"\#(category)","status":"\#(status)"\#(extra)}"#.utf8))
}

@Test func refundsDecodeFromTheContract() throws {
    let t = try tx(#","refundOf":null,"refunds":[{"id":"r1","accountId":"a2","amount":2000,"currency":"usd","day":"2026-11-06"}],"refunded":1850"#)
    #expect(t.refunds == [Transaction.Refund(id: "r1", accountId: "a2", amount: 2000, currency: "usd", day: "2026-11-06")])
    #expect(t.refunded == 1850 && t.refundState == .part && t.refundLeft == 3150 && t.canRefund)
}

@Test func aServerWithoutRefundsDecodesAndOffersNone() throws {
    // Before the server sends refunds, a refundOf it doesn't know would be saved as plain income.
    let t = try tx("")
    #expect(t.refunds.isEmpty && t.refunded == nil && t.refundState == .none && !t.canRefund)
    let nulls = try tx(#","refunds":null,"refunded":null"#)
    #expect(nulls.refunds.isEmpty && !nulls.canRefund)
}

@Test func refundedInFullOnceTheRefundsReachTheSpending() throws {
    #expect(try tx(#","refunded":0"#).refundState == .none)
    #expect(try tx(#","refunded":4999"#).refundState == .part)
    #expect(try tx(#","refunded":5000"#).refundState == .full)
    // Another currency at today's rate can come back a little over.
    let over = try tx(#","refunded":5003"#)
    #expect(over.refundState == .full && over.refundLeft == 0)
}

@Test func onlyPaidOrdinarySpendingCanBeRefunded() throws {
    #expect(try tx(#","refunded":0"#).canRefund)
    #expect(try !tx(#","refunded":0"#, amount: 5000).canRefund)
    #expect(try !tx(#","refunded":0,"refundOf":"t0""#, amount: 5000).canRefund)
    #expect(try !tx(#","refunded":0"#, category: Categories.correction).canRefund)
    #expect(try !tx(#","refunded":0"#, category: Categories.transfer).canRefund)
    #expect(try !tx(#","refunded":0"#, status: "upcoming").canRefund)
    #expect(try !tx(#","refunded":0,"transfer":{"id":"x"}"#).canRefund)
    // A refund's own detail never shows refund badges for itself.
    #expect(try tx(#","refunded":0,"refundOf":"t0""#, amount: 2000).refundState == .none)
}

@Test func aRefundIsSentWithRefundOfAndOtherEntriesWithout() throws {
    let refund = NewTransaction(id: "r1", accountId: "a2", payee: "Shop", amount: 2000, day: "2026-11-06", refundOf: "t1")
    let plain = NewTransaction(id: "n1", accountId: "a1", payee: "Shop", amount: -100)
    #expect(String(decoding: try KoshaJSON.encode(refund), as: UTF8.self).contains(#""refundOf":"t1""#))
    #expect(!String(decoding: try KoshaJSON.encode(plain), as: UTF8.self).contains("refundOf"))
}
