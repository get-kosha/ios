import Foundation
import Testing
import Model
@testable import API

@Test func loanWriteKeepsExactUUIDAndCrossCurrencyBodyThroughAuthenticationRetry() async throws {
    let calls = Requests()
    let fixture = HTTPFixture { request in
        await calls.record(request)
        if request.url!.path == "/api/auth/oauth2/token" {
            return Reply(body: #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600,"token_type":"Bearer"}"#)
        }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-0" { return Reply(status: 401) }
        return Reply(body: #"{"id":"loan"}"#)
    }
    fixture.signIn()
    let request = LoanRequest(content: .object(["loanId": .string("loan"), "amount": .number(1200), "accountAmount": .number(1400),
                                               "accountId": .string("bank"), "day": .string("2026-11-01")]))
    try await fixture.api().send("POST", "/api/v1/loans/loan/repayments", body: request.body)
    let writes = await calls.all.filter { $0.url!.path.hasSuffix("repayments") }
    #expect(writes.count == 2)
    #expect(writes[0].httpBody == writes[1].httpBody)
    #expect(try KoshaJSON.decode(JSONValue.self, writes[1].httpBody!) == request.body)
}

@Test func loanConflictIsSurfacedWithoutOfflineQueueOrAutomaticReplay() async throws {
    let calls = Requests()
    let fixture = HTTPFixture { request in
        await calls.record(request)
        return Reply(status: 409, body: #"{"error":{"code":"conflict","message":"Remaining principal changed"}}"#)
    }
    fixture.signIn()
    do {
        try await fixture.api().send("POST", "/api/v1/loans/l/repayments", body: LoanRequest(content: .object(["amount": .number(100)])).body)
        Issue.record("Expected conflict")
    } catch KoshaError.api(let status, let error) {
        #expect(status == 409 && error.message == "Remaining principal changed")
    }
    #expect(await calls.all.count == 1)
}
