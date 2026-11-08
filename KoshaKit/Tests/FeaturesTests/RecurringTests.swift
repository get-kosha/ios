import Foundation
import Testing
import Model
@testable import Features

// The same cases as the Android app's ScheduleTest.kt, plus the zip the documents page shares.

private func d(_ s: String) -> Day { Day(s)! }

@Test func monthStepsKeepTheDayClampedToShortMonths() {
    #expect(Schedule.occurrence(d("2026-01-31"), every: 1, unit: "month", n: 1) == d("2026-02-28"))
    #expect(Schedule.occurrence(d("2026-01-31"), every: 1, unit: "month", n: 2) == d("2026-03-31"))
    #expect(Schedule.occurrence(d("2024-02-29"), every: 4, unit: "year", n: 1) == d("2028-02-29"))
    #expect(Schedule.occurrence(d("2026-01-01"), every: 2, unit: "week", n: 1) == d("2026-01-15"))
}

@Test func backfillCountsFromTheStartUntilToday() {
    // 10 Aug, 10 Sep, 10 Oct: "Kosha will record payments from 10 Aug until today: 3 payments."
    #expect(Schedule.backfill(d("2026-08-10"), every: 1, unit: "month", end: nil, today: d("2026-11-07")) == 3)
    #expect(Schedule.backfill(d("2026-08-07"), every: 1, unit: "month", end: nil, today: d("2026-11-07")) == 4)
    #expect(Schedule.backfill(d("2026-11-07"), every: 1, unit: "month", end: nil, today: d("2026-11-07")) == 0)
    #expect(Schedule.backfill(d("2026-08-10"), every: 1, unit: "month", end: d("2026-09-30"), today: d("2026-11-07")) == 2)
}

@Test func nextStopsAtTheEnd() {
    #expect(Schedule.next(d("2025-01-01"), every: 1, unit: "month", end: nil, from: d("2026-11-07")) == d("2026-12-01"))
    #expect(Schedule.next(d("2025-01-01"), every: 1, unit: "month", end: d("2026-10-31"), from: d("2026-11-07")) == nil)
    #expect(Schedule.next(d("2024-03-03"), every: 1, unit: "year", end: nil, from: d("2026-11-07")) == d("2027-03-03"))
}

@Test func archiveNamesNumberClashes() {
    #expect(Schedule.archiveNames([("2026-10-20", "bill.pdf"), ("2026-10-21", "bill.pdf"), ("2026-09-01", "a/b.pdf")])
        == ["2026-10 bill.pdf", "2026-10 bill (2).pdf", "2026-09 a-b.pdf"])
}

@Test func readsTheWebShape() throws {
    let json = #"""
    {"subscriptions":[{"id":"s1","name":"Netflix","wallet_id":"a1","category_id":"fun","amount":-1299,
    "every":1,"unit":"year","start_day":"2025-01-15","end_day":null,"auto_pay":1,"kind":"subscription",
    "to_wallet_id":null,"variable":0,"currency":"eur","ended":false,"monthly":-108.25,"created_at":1,
    "instances":[{"due_day":"2026-01-15","day":"2026-01-15","amount":-1299,"note":"","status":"upcoming","edited":false,"tx_id":null}],
    "next":null,"history":[{"id":"x","due_day":"2025-01-15","day":"2025-01-15","date":1,"amount":-1299,"paid":1,"wallet_id":"a1"}]}],
    "income":[{"currency":"eur","total":388800}]}
    """#
    let data = try KoshaJSON.decode(SubscriptionsData.self, Data(json.utf8))
    let s = try #require(data.subscriptions.first)
    #expect(s.perMonth == -108)
    #expect(s.group == .subscriptions)
    #expect(Schedule.inMonth(s, Month(2026, 1)) == [d("2026-01-15")])
    #expect(Schedule.inMonth(s, Month(2026, 2)).isEmpty)
}

@Test func storedZipIsReadable() throws {
    #expect(StoredZip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    let zip = StoredZip.make([("2026-10 bill.pdf", Data("hello".utf8)), ("2026-09 bill.pdf", Data("world!".utf8))])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kosha-test-\(UUID().uuidString).zip")
    try zip.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    // The system unzip checks the archive where there is one: on the Mac (`swift test`), not on the simulator.
    #if os(macOS)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-t", url.path]
    unzip.standardOutput = Pipe()
    try unzip.run()
    unzip.waitUntilExit()
    #expect(unzip.terminationStatus == 0)
    #endif
}
