import Foundation
import Testing
import SwiftUI
import Model
import Design
@testable import Features

// The same cases as the Android app's settings LogicTest.kt.

private func account(_ json: String) -> AccountSummary { try! KoshaJSON.decode(AccountSummary.self, Data(json.utf8)) }

@MainActor @Test func settingsRowKeepsControlsInItsTrailingContent() {
    let row = SRow("Export") { KButton("Download") {} }
    #expect(row.action == nil)
    #expect(type(of: row.trailing) == KButton.self)
    #expect(type(of: row.titleExtra) == EmptyView.self)

    var tapped = false
    let actionable = SRow("Event", action: { tapped = true }) { Text("3") }
    #expect(!tapped)
    #expect(type(of: actionable.trailing) == Text.self)
    actionable.action?()
    #expect(tapped)
}

@Test func securityStepsCountBackupCodesOnlyWithTwoFactor() {
    let none = account(#"{"hasPassword":true,"passkeys":0,"twoFactor":false}"#)
    #expect(securitySteps(none, backupCodesSaved: true).map(\.done) == [true, false, false, false])
    let all = account(#"{"hasPassword":true,"passkeys":2,"twoFactor":true}"#)
    #expect(securitySteps(all, backupCodesSaved: true).filter { !$0.done }.count == 0)
    #expect(securitySteps(all, backupCodesSaved: false).filter { !$0.done }.count == 1)
}

@Test func searchNeedsEveryWord() {
    #expect(matchesAll("time zo", "Time zone", "Months and days"))
    #expect(!matchesAll("time money", "Time zone"))
    #expect(!matchesAll("  ", "anything"))
}

@Test func currencyOrderKeepsDefaultFirstAndAddsAccountCurrencies() {
    #expect(currencyOrder(primary: "eur", order: ["inr", "eur", "usd"], used: ["usd", "gbp"]) == ["eur", "inr", "usd", "gbp"])
}

@Test func movedReorders() {
    #expect(["a", "b", "c"].moved(from: 0, to: 2) == ["b", "c", "a"])
    #expect(["a", "b", "c"].moved(from: 2, to: 0) == ["c", "a", "b"])
    #expect(["a", "b"].moved(from: 0, to: 5) == ["a", "b"])
}

@Test func ratesAreUnitsPerDefault() {
    let perUsd = ["usd": 1.0, "eur": 0.86, "inr": 81.36]
    #expect(abs(rate(from: "eur", to: "inr", perUsd: perUsd)! - 94.6) < 0.01)
    #expect(rate(from: "eur", to: "xyz", perUsd: perUsd) == nil)
    #expect(rateText(94.6012, 1) == "94.6012")
    #expect(rateText(123.456, 1) == "123.46")
    #expect(rateText(1.16234, 1) == "1.1623")
    #expect(rateText(0.010571, 1) == "0.01057")
}

@Test func zoneLabels() {
    #expect(zoneCity("America/New_York") == "New York")
    let july = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!
    #expect(zoneOffset("Asia/Kolkata", now: july) == "UTC+5:30")
    #expect(zoneOffset("America/New_York", now: july) == "UTC−4")
    #expect(zoneOffset("UTC", now: july) == "UTC+0")
}

@Test func payeeCodeMatchesTheWeb() {
    // Values from core.ts payeeCode, run in Node.
    #expect(payeeCode(uid: "u1", payee: "Pizza Hut") == "payee_11uj3ko")
    #expect(payeeCode(uid: "demo", payee: " Bonanza Coffee ") == "payee_p1vjvp")
}

@Test func samplePayloadFollowsTheShares() {
    let tx = SampleTx(payee: "Pizza Hut", amount: -2957, currency: "eur", day: "2026-11-04", note: "Delivery", account: "Visa Card")
    let open = samplePayload(tx, shares: ["amount": true, "payee": true, "date": true, "note": false, "account": false], uid: "u1")
    #expect(open[0].value == "\"Pizza Hut\"" && open[0].shown == .on)
    #expect(open[1].value == "-29.57" && open[1].shown == .on)
    #expect(open[2].value == "\"EUR\"")
    #expect(open[3].field == "date" && open[3].value == "\"2026-11-04\"")
    #expect(open[4].shown == .off)
    let masked = samplePayload(tx, shares: ["amount": false, "payee": false, "date": false], uid: "u1")
    #expect(masked[0].value == "\"payee_11uj3ko\"" && masked[0].shown == .masked)
    #expect(masked[1].value == "null" && masked[1].shown == .masked)
    #expect(masked[3].field == "month" && masked[3].value == "\"2026-11\"")
}
