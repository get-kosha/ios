import Foundation
import Testing
@testable import Features

// The asserts of the web's src/lib/core.test.ts ("statements", "splits and bank corrections"), as in the Android app's
// StatementTest.kt, for the parts the phone runs itself; parsing CSV and OFX stays on the server.

private func line(_ day: String, _ amount: Int64, _ description: String, _ ref: String? = nil, _ replaces: String? = nil) -> Line {
    Line(day: day, amount: amount, description: description, ref: ref, replaces: replaces)
}

private func entry(_ id: String, _ day: String, _ amount: Int64, _ name: String, _ ref: String? = nil) -> Entry {
    Entry(id: id, day: day, amount: amount, name: name, ref: ref)
}

@Test func statementDates() {
    #expect(parseDay("03/11/2026", .dmy) == "2026-11-03")
    #expect(parseDay("11/03/2026", .mdy) == "2026-11-03")
    #expect(parseDay("2026-11-03T10:22:00", .ymd) == "2026-11-03")
    #expect(parseDay("3 Nov 2026", .text) == "2026-11-03")
    #expect(parseDay("Nov 3, 2026", .text) == "2026-11-03")
    #expect(parseDay("31/02/2026", .dmy) == nil)
    // A day over 12 decides; otherwise date order does.
    #expect(guessDateFormat(["13/10/2026", "01/11/2026"]) == .dmy)
    #expect(guessDateFormat(["10/13/2026", "11/01/2026"]) == .mdy)
    #expect(guessDateFormat(["01/10/2026", "05/10/2026", "02/11/2026"]) == .dmy)
    #expect(guessDateFormat(["2026-10-01"]) == .ymd)
}

@Test func statementPayees() {
    #expect(descriptorKey("CARD PAYMENT TO TESCO STORES 3211 ON 03 NOV") == "tesco stores")
    #expect(descriptorKey("PAYPAL *SPOTIFY P2B3C4") == "spotify")
    #expect(payeeFor("CARD PAYMENT TO TESCO STORES 3211", known: ["Tesco", "Uber"], aliases: [:]) == "Tesco")
    #expect(payeeFor("SQ *BLUE BOTTLE COFFEE", known: [], aliases: [:]) == "Blue Bottle Coffee")
    #expect(payeeFor("DD THAMES WATER 99", known: [], aliases: ["thames water": "Thames Water"]) == "Thames Water")
    #expect(similarity("TESCO STORES 3211", "Tesco") == 1)
    #expect(similarity("UBER TRIP", "Tesco") == 0)
}

@Test func statementMatching() {
    let m = matchLines(
        [line("2026-11-03", -1250, "TESCO STORES", "ofx:A1"), line("2026-11-05", -2000, "UBER TRIP"),
         line("2026-11-06", -2315, "BLUE BOTTLE"), line("2026-11-06", -999, "NETFLIX")],
        [entry("t1", "2026-11-01", -1250, "Tesco", "ofx:A1"), entry("u1", "2026-11-02", -2000, "Uber"),
         entry("b1", "2026-11-05", -2015, "Blue Bottle"), entry("x1", "2026-10-01", -2000, "Uber")]
    )
    #expect(m.pairs == [Matched(line: 0, entry: "t1", kind: .ref), Matched(line: 1, entry: "u1", kind: .exact),
                        Matched(line: 2, entry: "b1", kind: .close)])
    #expect(m.missing == [3])
    #expect(m.extra == ["x1"])
}

private let words = HintWords(
    anEntry: { "an entry" },
    exactUnticked: { "\($0) (\($1)) is exactly the difference. Is it on the statement?" },
    exactTicked: { "\($0) (\($1)) is exactly the difference. Is it really on the statement?" },
    wrongWayIn: { "\($0) is half the difference. Is it the wrong way round, money in rather than out?" },
    wrongWayOut: { "\($0) is half the difference. Is it the wrong way round, money out rather than in?" },
    swapped: { "Was \($0) \($1) rather than \($2)? Swapped digits are a common slip." },
    decimal: { "Was \($0) \($1) rather than \($2)? The decimal point may be in the wrong place." },
    pair: { "\($0) and \($1) together make the difference." },
    duplicate: { "\($0) appears twice. Is one a duplicate?" },
    late: { "Entries from the last days of the period can show on the next statement instead." },
    lookOut: { "Look on the statement for a fee, a charge or interest of \($0) that isn't in Kosha yet." },
    lookIn: { "Look on the statement for interest, a refund or a payment in of \($0) that isn't in Kosha yet." }
)

private func hint(_ diff: Int64, _ ticked: [(String, Int64)], _ unticked: [(String, Int64)] = []) -> [Hint] {
    differenceHints(
        diff, ticked: ticked.map { Item(id: $0.0, amount: $0.1, day: "2026-11-10", name: $0.0) },
        unticked: unticked.map { Item(id: $0.0, amount: $0.1, day: "2026-11-10", name: $0.0) },
        statementDay: "2026-11-30", money: { String(format: "%.2f", Double($0) / 100) }, words: words
    )
}

@Test func statementHints() {
    #expect(hint(0, []).isEmpty)
    #expect(hint(-1250, [], [("a", -1250)])[0].ids == ["a"])
    #expect(hint(-2000, [("a", 1000)])[0].text.contains("wrong way round, money out rather than in"))
    // Typed 54.00 for 45.00: off by 9.00, divisible by 9.
    #expect(hint(900, [("a", -5400)])[0].text.contains("Was a -45.00 rather than -54.00"))
    #expect(hint(-3000, [], [("a", -1000), ("b", -2000)])[0].ids == ["a", "b"])
    #expect(hint(-777, [])[0].text.contains("a fee, a charge or interest of 7.77"))
    // Typed 164.67 for 1,646.70: a slid decimal point.
    #expect(hint(-148_203, [("a", -16467)])[0].text.contains("Was a -1646.70 rather than -164.67? The decimal point"))
    #expect(hint(148_203, [("a", -164_670)])[0].text.contains("Was a -164.67 rather than -1646.70"))
}

@Test func statementSplits() {
    // One bank charge of 50.00 entered as 30 + 20: the one way to make it, named alike, so it matches.
    let split = matchLines(
        [line("2026-11-05", -5000, "TESCO STORES 3211"), line("2026-11-06", -999, "NETFLIX")],
        [entry("s1", "2026-11-04", -3000, "Tesco"), entry("s2", "2026-11-04", -2000, "Tesco")]
    )
    #expect(split.pairs == [Matched(line: 0, entry: "s1", kind: .split), Matched(line: 0, entry: "s2", kind: .split)])
    #expect(split.missing == [1])
    #expect(split.extra.isEmpty)
    #expect(split.splits.isEmpty)
    // The other way round: two bank lines that Kosha has as one entry.
    let halves = matchLines(
        [line("2026-11-05", -1500, "IKEA"), line("2026-11-07", -2500, "IKEA")], [entry("k1", "2026-11-05", -4000, "Ikea")]
    )
    #expect(halves.pairs == [Matched(line: 0, entry: "k1", kind: .split), Matched(line: 1, entry: "k1", kind: .split)])
    // Two ways to make 50.00: nothing is matched, and both come back to suggest.
    let twoWays = matchLines(
        [line("2026-11-05", -5000, "TESCO")],
        [entry("a", "2026-11-04", -3000, "Tesco"), entry("b", "2026-11-04", -2000, "Tesco"), entry("c", "2026-11-05", -2000, "Tesco")]
    )
    #expect(twoWays.pairs.isEmpty)
    #expect(twoWays.splits.map { $0.entries.sorted() } == [["a", "c"], ["a", "b"]])
    // One way, but the names don't agree: suggested, not matched. Out of the date window: neither.
    let unalike = matchLines(
        [line("2026-11-05", -5000, "TESCO")], [entry("a", "2026-11-04", -3000, "Uber"), entry("b", "2026-11-04", -2000, "Tesco")]
    )
    #expect(unalike.pairs.isEmpty)
    #expect(unalike.splits == [Split(lines: [0], entries: ["a", "b"])])
    let far = matchLines(
        [line("2026-11-20", -5000, "TESCO")], [entry("a", "2026-11-04", -3000, "Tesco"), entry("b", "2026-11-04", -2000, "Tesco")]
    )
    #expect(far.splits.isEmpty)
    #expect(far.missing == [0])
    // An exact match wins over a split.
    let exactFirst = matchLines(
        [line("2026-11-05", -5000, "TESCO")],
        [entry("a", "2026-11-04", -3000, "Tesco"), entry("b", "2026-11-04", -2000, "Tesco"), entry("x", "2026-11-05", -5000, "Tesco")]
    )
    #expect(exactFirst.pairs == [Matched(line: 0, entry: "x", kind: .exact)])
    // A reconciliation ticks every entry of a split.
    let plan = planReconciliation(
        lines: [line("2026-11-05", -5000, "TESCO STORES")],
        open: [entry("s1", "2026-11-04", -3000, "Tesco"), entry("s2", "2026-11-04", -2000, "Tesco")],
        done: [], statementDay: "2026-11-30", lastDay: nil
    )
    #expect(plan.matched == ["s1", "s2"])
    #expect(plan.missing.isEmpty)
    #expect(plan.ticks(entry("s1", "2026-11-04", 0, "")) && plan.ticks(entry("s2", "2026-11-04", 0, "")))
}

@Test func statementCorrections() {
    // What parseOfx gives for a file that replaces A1 and withdraws B0 (core.test.ts).
    let lines = [line("2026-11-03", -1500, "TESCO", "ofx:A1b", "ofx:A1"), line("2026-11-05", -400, "KIOSK", "ofx:C1")]
    let fix = planReconciliation(
        lines: lines,
        open: [entry("t1", "2026-11-03", -1250, "Tesco", "ofx:A1"), entry("n1", "2026-11-04", -999, "Netflix", "ofx:B0"),
               entry("k1", "2026-11-05", -400, "Kiosk", "ofx:C1")],
        done: [], statementDay: "2026-11-30", lastDay: nil, withdrawn: ["ofx:B0"]
    )
    #expect(fix.close == [Matched(line: 0, entry: "t1", kind: .corrected)])
    #expect(fix.matched == ["k1"])
    #expect(fix.missing.isEmpty)
    #expect(fix.withdrawn == ["n1"])
    // The withdrawn entry stays, unticked and in the period, even dated before the statement's first line.
    #expect(!fix.ticks(entry("n1", "2026-11-04", 0, "")))
    #expect(!fix.ticks(entry("t1", "2026-11-03", 0, "")))
    var same = lines[0]
    same.amount = -1250
    #expect(matchLines([same], [entry("t1", "2026-11-03", -1250, "Tesco", "ofx:A1")]).pairs
        == [Matched(line: 0, entry: "t1", kind: .ref)])
}

@Test func statementImporting() {
    #expect(starterCategory("Lidl LIDL SAGT DANKE", income: false, have: ["groceries"]) == "groceries")
    #expect(starterCategory("Lidl", income: true, have: ["groceries"]) == nil)
    // Out of one account and into another within three days, closest first, each line once.
    let pairs = pairTransfers([
        Leg(key: "a1", account: "a", day: "2026-11-01", amount: -5000), Leg(key: "b1", account: "b", day: "2026-11-03", amount: 5000),
        Leg(key: "b2", account: "b", day: "2026-11-01", amount: 5000), Leg(key: "a2", account: "a", day: "2026-11-02", amount: 5000),
    ])
    #expect(pairs == [TransferPair(out: "a1", into: "b2")])
    // Overlapping statements share lines; within one statement two equal lines are two payments.
    let merged = mergeStatements([
        StatementLines(lines: [line("2026-10-30", -500, "X"), line("2026-10-30", -500, "X"), line("2026-10-31", -100, "Y")]),
        StatementLines(lines: [line("2026-10-30", -500, "X"), line("2026-11-02", -700, "Z")]),
    ])
    #expect(merged.map(\.amount) == [-500, -500, -100, -700])
    let gaps = statementGaps([
        Span(name: "oct", from: "2026-10-01", to: "2026-10-31", opening: 0, closing: 1000),
        Span(name: "nov", from: "2026-11-01", to: "2026-11-30", opening: 900, closing: 0),
        Span(name: "jan", from: "2027-01-01", to: "2027-01-31", opening: nil, closing: nil),
    ])
    #expect(gaps == [.opening(next: "nov", opening: 900, previous: "oct", closing: 1000),
                     .uncovered(from: "2026-12-01", to: "2026-12-31")])
}
