import Testing
@testable import Model

// "No event" survives the queue as an explicit null; otherwise the server picks the event by date. The body is built
// in Store; this checks the encoding it relies on: nil fields are left out.
@Test func nilFieldsAreLeftOut() throws {
    let entry = NewTransaction(id: "t1", accountId: "a1", payee: "Tesco", amount: -1250, categoryId: "c1")
    let json = try KoshaJSON.decode(JSONValue.self, KoshaJSON.encode(entry))
    #expect(json["eventId"] == nil)
    #expect(json["amount"]?.int == -1250)
}

@Test func defaultsFillMissingFields() throws {
    let a = try KoshaJSON.decode(Account.self, Data(#"{"id":"a","name":"N26","type":"bank","currency":"eur","balance":5,"worth":5}"#.utf8))
    #expect(a.archived == false)
    #expect(a.transactionCount == 0)
    let w = try KoshaJSON.decode(Wallet.self, Data(#"{"id":"a","name":"N26","currency":"eur","credit_limit":100}"#.utf8))
    #expect(w.creditLimit == 100)
    #expect(w.kind == .bank)
}

import Foundation
