import Testing
import Model
@testable import Store

private let entry = NewTransaction(id: "t1", accountId: "a1", payee: "Tesco", amount: -1250, categoryId: "c1")
private func tx(_ noEvent: Bool) -> JSONValue? { createTransactions(entry, noEvent: noEvent)["transactions"]?.array?.first }

@Test func noEventIsSentAsNull() { #expect(tx(true)?["eventId"] == .null) }
@Test func otherwiseTheEventIsLeftOut() { #expect(tx(false)?["eventId"] == nil) }
