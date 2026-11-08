import Foundation
import Testing
@testable import Model

@Test func calendarMathClampsMonthEndsAndCrossesLeapYears() {
    #expect(Day(2024, 1, 31).adding(months: 1) == Day(2024, 2, 29))
    #expect(Day(2024, 2, 29).adding(years: 1) == Day(2025, 2, 28))
    #expect(Day(2026, 3, 1).adding(days: -1) == Day(2026, 2, 28))
    #expect(Day(2026, 3, 28).days(to: Day(2026, 3, 30)) == 2)
    #expect(Month(2024, 2).dayCount == 29)
    #expect(Month(2026, 12).adding(1) == Month(2027, 1))
    #expect(Month(2026, 1).adding(-13) == Month(2024, 12))
}

@Test(arguments: ["2026-02-31", "2026-04-31", "2025-02-29", "2026-1-01", "2026--01-01", "x-2026-01-01", "0000-01-01"])
func invalidCalendarDaysAreRefused(text: String) throws {
    #expect(Day(text) == nil)
    #expect(throws: DecodingError.self) { try KoshaJSON.decode(Day.self, JSONEncoder().encode(text)) }
}

@Test(arguments: ["2026-1", "2026--01", "x-2026-01", "0000-01", "2026-13"])
func invalidMonthsAreRefused(text: String) { #expect(Month(text) == nil) }

@Test func publicContractExamplesDecode() throws {
    // src/lib/api-contract.ts: tx, account, category and recurring examples. No account data is used.
    let tx = try KoshaJSON.decode(Transaction.self, Data(#"{"id":"9b2f1c6e-5d3a-4f1b-8c7e-2a6d0e4f1b3c","day":"2026-11-04","time":"18:42","payee":"Tesco","amount":-2350,"currency":"eur","accountId":"a1","accountName":"Current account","categoryId":"groceries","categoryName":"Groceries","subcategoryId":null,"note":"","tags":[],"eventId":null,"status":"paid","recurringId":null,"dueDay":null,"transfer":null,"reconciled":false,"bankRef":null,"attachmentCount":0,"refundOf":null}"#.utf8))
    #expect(tx.amount == -2350 && tx.hhmm == "18:42" && tx.transfer == nil && !tx.isUpcoming)
    let account = try KoshaJSON.decode(Account.self, Data(#"{"id":"a1","name":"Current account","type":"bank","currency":"eur","balance":254300,"worth":254300,"creditLimit":null,"gain":null,"gainDay":null,"archived":false,"transactionCount":412,"reconciledTo":"2026-10-31"}"#.utf8))
    #expect(account.balance == 254300 && account.transactionCount == 412 && account.reconciledTo == "2026-10-31")
    let category = try KoshaJSON.decode(Category.self, Data(#"{"id":"groceries","name":"Groceries","icon":"🛒","type":"expense","parentId":null,"archived":false,"transactionCount":128,"recurringCount":0,"ruleCount":6}"#.utf8))
    #expect(category.ruleCount == 6 && !category.income)
    let recurring = try KoshaJSON.decode(Recurring.self, Data(#"{"id":"s1","name":"Netflix","accountId":"a1","categoryId":"entertainment","amount":-1299,"currency":"eur","note":"","every":1,"unit":"month","startDay":"2025-01-15","endDay":null,"autoPay":true,"kind":"subscription","toAccountId":null,"toAmount":null,"variable":false,"ended":false,"monthlyCost":-1299,"next":{"dueDay":"2026-11-15","day":"2026-11-15","amount":-1299,"note":"","status":"upcoming","edited":false,"transactionId":null,"accountId":"a1"},"payments":[]}"#.utf8))
    #expect(recurring.monthlyCost == -1299 && recurring.next?.accountId == "a1" && recurring.next?.transactionId == nil)
}

@Test func appMetaKeepsSnakeCaseAndDefaults() throws {
    let meta = try KoshaJSON.decode(Meta.self, Data(#"{"wallets":[{"id":"a1","name":"Current account","currency":"eur","type":"credit","credit_limit":50000,"gain_day":"2026-11-01","tx_count":12,"entry_count":10,"reconciled_day":"2026-10-31"}],"categories":[{"id":"c1","name":"Food","income":0,"parent_id":"c0"}],"rules":[{"title":"tesco","category_id":"c1","exact":1}],"events":[{"id":"e1","name":"Trip","start_day":"2026-10-10","end_day":null,"tx_count":23}],"ai":{"quick_add":true},"prefs":null,"ratesUpdated":1793900000,"user":{"id":"demo","name":"Demo","email":"demo@kosha.local"},"futureField":true}"#.utf8))
    #expect(meta.wallets.first?.creditLimit == 50000 && meta.wallets.first?.entryCount == 10)
    #expect(meta.wallets.first?.reconciledDay == "2026-10-31")
    #expect(meta.categories.first?.parentId == "c0" && meta.rules.first?.categoryId == "c1")
    #expect(meta.events.first?.txCount == 23 && meta.events.first?.endDay == nil)
    #expect(meta.aiFlags.quickAdd && !meta.aiFlags.ask && meta.prefs.isEmpty)
    #expect(meta.timeZone == "UTC" && meta.primaryCurrency == "eur")
    #expect(throws: DecodingError.self) { try KoshaJSON.decode(Transaction.self, Data(#"{"id":"t1"}"#.utf8)) }
    #expect(throws: DecodingError.self) { try KoshaJSON.decode(Account.self, Data(#"{"id":"a1","name":"Example","type":"bank","currency":"eur","balance":1.5,"worth":0}"#.utf8)) }
}

private struct Converted: Codable { @Rounded var amount: Int64 }

@Test func roundedReadsKeepExactIntegersAndFractions() throws {
    for (json, expected) in [("{}", Int64(0)), (#"{"amount":null}"#, 0),
                             (#"{"amount":12.6}"#, 13), (#"{"amount":-12.5}"#, -13),
                             (#"{"amount":9007199254740993}"#, 9_007_199_254_740_993)] {
        #expect(try KoshaJSON.decode(Converted.self, Data(json.utf8)).amount == expected)
    }
}

@Test func roundedReadsRefuseOverflowInsteadOfTrapping() {
    #expect(throws: DecodingError.self) {
        try KoshaJSON.decode(Converted.self, Data(#"{"amount":1e30}"#.utf8))
    }
    #expect(JSONValue.number(1e30).int == nil)
}
