import Foundation
import Model

// Bank statements on the phone: matching statement lines to Kosha's entries, payee names from bank text, transfer pairs
// between accounts, the reconcile plan and the hints for a difference. Ported line for line from the Android app's
// Statement.kt, itself from the web's src/lib/statement.ts, so the phone ticks, matches and hints exactly as the web
// does; core.test.ts's asserts are in StatementTests. Parsing CSV, OFX and PDF stays on the server
// (POST /api/app/import/read).

/// One line of a statement, in the account's currency. Negative is money out. `replaces` is the ref of an earlier line
/// the bank corrected with this one (OFX's CORRECTFITID). A PDF read by AI also names the `payee`.
public struct Line: Codable, Sendable, Hashable {
    public var day: String
    @Rounded public var amount: Int64
    @D public var description: String
    public var balance: Int64?
    public var ref: String?
    public var replaces: String?
    public var payee: String?

    public init(day: String, amount: Int64, description: String = "", balance: Int64? = nil, ref: String? = nil,
                replaces: String? = nil, payee: String? = nil) {
        self.day = day
        self.amount = amount
        self.description = description
        self.balance = balance
        self.ref = ref
        self.replaces = replaces
        self.payee = payee
    }
}

/// A Kosha entry a statement line can match. `paid` is 1 for paid, 0 for a bill still due.
public struct Entry: Sendable, Hashable {
    public var id: String, day: String, amount: Int64, name: String, ref: String?
    public var paid = 1
}

public enum MatchKind: Sendable { case ref, exact, split, close, corrected }

/// A statement line matched to an entry (statement.ts Pair).
public struct Matched: Sendable, Hashable {
    public let line: Int
    public let entry: String
    public let kind: MatchKind
}

/// Lines and entries whose amounts add up, but which aren't matched on their own since another way could.
public struct Split: Sendable, Hashable {
    public let lines: [Int]
    public let entries: [String]
}

public struct Matching: Sendable {
    public let pairs: [Matched]
    public let missing: [Int]
    public let extra: [String]
    public let splits: [Split]
}

func addDays(_ day: String, _ n: Int) -> String { (Day(day) ?? Day(1970, 1, 1)).adding(days: n).text }

func dayDiff(_ a: String, _ b: String) -> Int { (Day(a) ?? Day(1970, 1, 1)).days(to: Day(b) ?? Day(1970, 1, 1)) }

extension Sequence {
    /// Sorted by a key, keeping the given order for equal keys (Kotlin's sortedBy).
    func stableSorted<K: Comparable>(by key: (Element) -> K) -> [Element] {
        enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka == kb ? a.offset < b.offset : ka < kb
        }.map(\.element)
    }
}

// MARK: Regex helpers

private func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

extension NSRegularExpression {
    func replace(_ s: String, with t: String) -> String {
        stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    func groups(_ s: String) -> [String]? {
        guard let m = firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    func contains(_ s: String) -> Bool { firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
}

// MARK: Dates in a CSV (for the column editor)

private let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
private func fullYear(_ y: Int) -> Int { y < 100 ? 2000 + y : y }
private func valid(_ y: Int, _ m: Int, _ d: Int) -> String? {
    guard (1990...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
    let day = Day(y, m, d)
    // Day's calendar maths rolls 31 Feb over; a real date reads back the same.
    return Day(date: day.date) == day ? day.text : nil
}
private let textA = re(#"^(\d{1,2})[\s\-./]*([a-z]{3})[a-z]*\.?[\s\-./,]*(\d{2,4})"#)
private let textB = re(#"^([a-z]{3})[a-z]*\.?[\s\-./]*(\d{1,2})(?:st|nd|rd|th)?,?[\s\-./]*(\d{2,4})"#)
private let partsRe = re(#"^(\d{1,4})[-./ ](\d{1,2})[-./ ](\d{1,4})"#)

public enum DateFormatKind: String, CaseIterable, Sendable, Codable { case ymd, dmy, mdy, text }

/// Reads a statement date in the given format, ignoring any time after it. Returns YYYY-MM-DD or nil.
public func parseDay(_ raw: String, _ format: DateFormatKind) -> String? {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if format == .text {
        let d: String, mon: String, y: String
        if let a = textA.groups(s) { (d, mon, y) = (a[1], a[2], a[3]) } else if let b = textB.groups(s) {
            (d, mon, y) = (b[2], b[1], b[3])
        } else { return nil }
        guard let m = months.firstIndex(of: mon) else { return nil }
        return valid(fullYear(Int(y)!), m + 1, Int(d)!)
    }
    if format == .ymd, s.count >= 8, s.prefix(8).allSatisfy(\.isNumber) {
        let c = Array(s)
        return valid(Int(String(c[0..<4]))!, Int(String(c[4..<6]))!, Int(String(c[6..<8]))!)
    }
    guard let p = partsRe.groups(s) else { return nil }
    let (x, y, z) = (Int(p[1])!, Int(p[2])!, Int(p[3])!)
    if format == .ymd { return p[1].count == 4 ? valid(x, y, z) : nil }
    if p[3].count != 4 && p[3].count != 2 { return nil }
    return format == .dmy ? valid(fullYear(z), y, x) : valid(fullYear(z), x, y)
}

/// The date format that reads every value. Between day-first and month-first, a part over 12 decides; when nothing
/// does, the one that keeps the rows in date order wins, then day-first.
public func guessDateFormat(_ values: [String]) -> DateFormatKind? {
    let list = Array(values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(200))
    if list.isEmpty { return nil }
    let ok = DateFormatKind.allCases.filter { f in list.allSatisfy { parseDay($0, f) != nil } }
    if ok.count < 2 { return ok.first }
    func ordered(_ f: DateFormatKind) -> Int {
        let days = list.map { parseDay($0, f)! }
        var up = 0, down = 0
        for i in 1..<days.count {
            if days[i] > days[i - 1] { up += 1 }
            if days[i] < days[i - 1] { down += 1 }
        }
        return min(up, down)
    }
    return ok.stableSorted(by: ordered).first
}

// MARK: Bank text to payees

// Card processors and wallets that prefix the merchant: "PAYPAL *SPOTIFY", "SQ *BLUE BOTTLE".
private let processor = re(#"^(paypal|pp|sq|sqr|tst|sp|sumup|zettle|iz|izettle|google|gpay|apple pay|amzn mktp|crv|wpy|pay)\s?\*\s?"#, .caseInsensitive)

// Words banks add around the merchant, in English, German, French, Spanish and Dutch.
private let noise = Set([
    "card payment purchase pos debit credit visa mastercard maestro contactless cnp direct dd so standing order",
    "faster payments fps fpi fpo bacs transfer trf tfr to from on at via ref reference gb gbr uk usa us ie de fr nl",
    "es it eur usd gbp ltd limited inc plc llc gmbh bv sarl www com net org co the and",
    "kartenzahlung lastschrift basislastschrift gutschrift überweisung ueberweisung dauerauftrag sepa",
    "paiement carte cb prelevement prélèvement virement achat compra pago tarjeta transferencia recibo",
    "betaalautomaat pinbetaling incasso overboeking",
].joined(separator: " ").split(separator: " ").map(String.init))

private let onDate = re(#"\b(on|date)\s+\d{1,2}\s*[a-z]{3}\b.*$"#)
private let withDigit = re(#"\S*\d\S*"#)
private let notLetter = re(#"[^\p{L}\s]+"#)

/// Bank text reduced to the words that name the merchant, for matching and for remembering payees.
public func descriptorKey(_ text: String) -> String {
    var s = text.lowercased()
    s = processor.replace(s, with: "")
    s = onDate.replace(s, with: "") // "… ON 03 NOV …" to the end
    s = withDigit.replace(s, with: " ") // card numbers, references and amounts: any word with a digit in it
    s = notLetter.replace(s, with: " ")
    return s.split(whereSeparator: \.isWhitespace).map(String.init).filter { !noise.contains($0) }.prefix(3)
        .joined(separator: " ")
}

private let word = re(#"\p{L}[\p{L}']*"#)
private func title(_ s: String) -> String {
    var out = s
    for m in word.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
        guard let r = Range(m.range, in: out) else { continue }
        let w = String(out[r])
        out.replaceSubrange(r, with: w.prefix(1).uppercased() + w.dropFirst().lowercased())
    }
    return out
}

/// The payee for a statement line: a remembered alias first, then a past payee the text names, then the text itself
/// tidied ("CARD PAYMENT TO TESCO STORES 3211 ON 03 NOV" is "Tesco Stores").
public func payeeFor(_ description: String, known: [String], aliases: [String: String]) -> String {
    let key = descriptorKey(description)
    if let a = aliases[key] { return a }
    let words = " \(key) "
    var best = ""
    for name in known {
        let k = descriptorKey(name)
        if !k.isEmpty && words.contains(" \(k) ") && k.count > descriptorKey(best).count { best = name }
    }
    if !best.isEmpty { return best }
    // "Boots · BOOTS 1123" names the merchant twice.
    var seen: [String] = []
    for w in key.split(separator: " ").map(String.init) where !seen.contains(w) { seen.append(w) }
    let t = title(seen.joined(separator: " "))
    return t.isEmpty ? String(description.trimmingCharacters(in: .whitespaces).prefix(60)) : t
}

/// How alike two payee texts are, from 0 to 1: the share of the shorter one's words found in the other.
public func similarity(_ a: String, _ b: String) -> Double {
    let x = Set(descriptorKey(a).split(separator: " ").map(String.init))
    let y = Set(descriptorKey(b).split(separator: " ").map(String.init))
    if x.isEmpty || y.isEmpty { return 0 }
    let common = x.filter { w in y.contains(w) || y.contains { v in v.count > 3 && (v.hasPrefix(w) || w.hasPrefix(v)) } }.count
    return Double(common) / Double(min(x.count, y.count))
}

// MARK: Matching

/// Groups of 2 or 3 items whose values add up to `total`.
private func sums<T>(_ items: [T], _ total: Int64, _ value: (T) -> Int64) -> [[T]] {
    var out: [[T]] = []
    for a in items.indices {
        for b in (a + 1)..<max(a + 1, items.count) {
            let ab = value(items[a]) + value(items[b])
            if ab == total { out.append([items[a], items[b]]) }
            for c in (b + 1)..<max(b + 1, items.count) where ab + value(items[c]) == total {
                out.append([items[a], items[b], items[c]])
            }
        }
    }
    return out
}

private func sign(_ x: Int64) -> Int { x > 0 ? 1 : x < 0 ? -1 : 0 }

/// Pairs statement lines with Kosha entries, each used once. A bank id that Kosha stored matches first, also through a
/// bank's correction of it. Then the same amount within `before` days before or `after` days after the entry, closest
/// and most alike first. Then splits: a line that is 2 or 3 entries together, or the other way round, matched only when
/// it is the one way to make that sum and the names agree; other ways come back in `splits`. Lines left over that look
/// like an entry with a different amount become "close" pairs to confirm.
public func matchLines(_ lines: [Line], _ entries: [Entry], before: Int = 3, after: Int = 7) -> Matching {
    var pairs: [Matched] = []
    var usedLine: Set<Int> = []
    var usedEntry: Set<String> = []
    func take(_ line: Int, _ entry: String, _ kind: MatchKind) {
        pairs.append(Matched(line: line, entry: entry, kind: kind))
        usedLine.insert(line)
        usedEntry.insert(entry)
    }
    var byRef: [String: Entry] = [:]
    for e in entries { if let r = e.ref { byRef[r] = e } }
    for (i, l) in lines.enumerated() {
        let own = l.ref.flatMap { byRef[$0] }
        guard let e = own ?? l.replaces.flatMap({ byRef[$0] }), !usedEntry.contains(e.id) else { continue }
        take(i, e.id, own != nil || l.amount == e.amount ? .ref : .corrected)
    }
    func near(_ l: Line, _ e: Entry) -> Bool { let d = dayDiff(e.day, l.day); return d >= -before && d <= after }
    struct Candidate { let line: Int; let entry: String; let score: Double }
    func scored(_ kind: MatchKind) {
        var list: [Candidate] = []
        for (i, l) in lines.enumerated() where !usedLine.contains(i) {
            for e in entries where !usedEntry.contains(e.id) && near(l, e) {
                let d = dayDiff(e.day, l.day)
                let sim = similarity(l.description, e.name)
                if kind == .exact {
                    if l.amount != e.amount { continue }
                    list.append(Candidate(line: i, entry: e.id, score: Double(abs(d)) + (1 - sim) * 4))
                } else {
                    let off = abs(l.amount - e.amount)
                    let same = sign(l.amount) == sign(e.amount)
                    if !same || sim < 0.5 || abs(d) > 3 || Double(off) > max(Double(abs(e.amount)) * 0.25, 500) { continue }
                    list.append(Candidate(line: i, entry: e.id, score: Double(abs(d)) + Double(off) / Double(abs(e.amount))))
                }
            }
        }
        for c in list.stableSorted(by: \.score) where !usedLine.contains(c.line) && !usedEntry.contains(c.entry) {
            take(c.line, c.entry, kind)
        }
    }
    scored(.exact)

    // Parts have the same sign and are smaller than their whole. ponytail: only the 12 nearest parts are tried, so a
    // split with a part further off stays unmatched.
    func parts<T>(_ whole: Int64, _ list: [T], _ amount: (T) -> Int64, _ gap: (T) -> Int) -> [T] {
        Array(list.filter { sign(amount($0)) == sign(whole) && abs(amount($0)) < abs(whole) }.stableSorted(by: gap).prefix(12))
    }
    struct Group { let lines: [Int]; let entries: [String]; let alike: Bool }
    let open = entries.filter { !usedEntry.contains($0.id) }
    let free = lines.enumerated().filter { !usedLine.contains($0.offset) }
    var groups: [Group] = []
    for (i, l) in free {
        let list = parts(l.amount, open.filter { near(l, $0) }, { $0.amount }, { abs(dayDiff($0.day, l.day)) })
        for g in sums(list, l.amount, { $0.amount }) {
            groups.append(Group(lines: [i], entries: g.map(\.id), alike: g.allSatisfy { similarity(l.description, $0.name) >= 0.5 }))
        }
    }
    for e in open {
        let list = parts(e.amount, free.filter { near($0.element, e) }, { $0.element.amount }, { abs(dayDiff(e.day, $0.element.day)) })
        for g in sums(list, e.amount, { $0.element.amount }) {
            groups.append(Group(lines: g.map(\.offset), entries: [e.id],
                                alike: g.allSatisfy { similarity($0.element.description, e.name) >= 0.5 }))
        }
    }
    // A group is sure when nothing it holds could be part of another group.
    func keys(_ g: Group) -> [String] { g.lines.map { "l\($0)" } + g.entries.map { "e\($0)" } }
    var uses: [String: Int] = [:]
    for g in groups { for k in keys(g) { uses[k, default: 0] += 1 } }
    let sureIdx = Set(groups.indices.filter { i in groups[i].alike && keys(groups[i]).allSatisfy { uses[$0] == 1 } })
    for i in sureIdx.sorted() { for l in groups[i].lines { for id in groups[i].entries { take(l, id, .split) } } }

    scored(.close)
    return Matching(
        pairs: pairs,
        missing: lines.indices.filter { !usedLine.contains($0) },
        extra: entries.filter { !usedEntry.contains($0.id) }.map(\.id),
        splits: groups.indices
            .filter { i in !sureIdx.contains(i) && groups[i].lines.allSatisfy { !usedLine.contains($0) } }
            .filter { i in groups[i].entries.allSatisfy { !usedEntry.contains($0) } }
            .map { Split(lines: groups[$0].lines, entries: groups[$0].entries) }
    )
}

// MARK: Finding a difference

/// A hint: what to check, and the entries it is about.
public struct Hint: Sendable, Hashable {
    public let text: String
    public let ids: [String]
}

/// One entry, for the difference checks.
public struct Item: Sendable, Hashable {
    public let id: String
    public let amount: Int64
    public let day: String
    public let name: String
}

/// The words of the difference hints (the reconcile_hint_* messages), so the checks stay pure.
public struct HintWords: Sendable {
    public var anEntry: @Sendable () -> String
    public var exactUnticked: @Sendable (_ name: String, _ amount: String) -> String
    public var exactTicked: @Sendable (_ name: String, _ amount: String) -> String
    public var wrongWayIn: @Sendable (_ name: String) -> String
    public var wrongWayOut: @Sendable (_ name: String) -> String
    public var swapped: @Sendable (_ name: String, _ meant: String, _ amount: String) -> String
    public var decimal: @Sendable (_ name: String, _ meant: String, _ amount: String) -> String
    public var pair: @Sendable (_ first: String, _ second: String) -> String
    public var duplicate: @Sendable (_ name: String) -> String
    public var late: @Sendable () -> String
    public var lookOut: @Sendable (_ amount: String) -> String
    public var lookIn: @Sendable (_ amount: String) -> String
}

/// Every amount made by swapping two neighbouring digits of `cents`, e.g. 5400 gives 4500 and 5040.
private func swaps(_ cents: Int64) -> [Int64] {
    var s = Array(String(abs(cents)))
    while s.count < 3 { s.insert("0", at: 0) }
    var out: [Int64] = []
    for i in 0..<(s.count - 1) where s[i] != s[i + 1] {
        var t = s
        t.swapAt(i, i + 1)
        let v = Int64(String(t))! * Int64(sign(cents))
        if !out.contains(v) { out.append(v) }
    }
    return out
}

/// Bookkeepers' checks for a reconciliation that is out by `diff` (statement minus what's ticked), most specific first.
/// Each hint names the entries it is about. `money` formats cents for the text.
public func differenceHints(
    _ diff: Int64, ticked: [Item], unticked: [Item], statementDay: String, money: (Int64) -> String, words: HintWords
) -> [Hint] {
    if diff == 0 { return [] }
    var out: [Hint] = []
    func name(_ e: Item) -> String { e.name.isEmpty ? words.anEntry() : e.name }
    // Ticking one more entry, or unticking one, closes it.
    for e in unticked where e.amount == diff { out.append(Hint(text: words.exactUnticked(name(e), money(e.amount)), ids: [e.id])) }
    for e in ticked where e.amount == -diff { out.append(Hint(text: words.exactTicked(name(e), money(e.amount)), ids: [e.id])) }
    // An entry with the wrong sign is off by twice its amount.
    if diff % 2 == 0 {
        for e in ticked where e.amount == -diff / 2 {
            out.append(Hint(text: e.amount < 0 ? words.wrongWayIn(name(e)) : words.wrongWayOut(name(e)), ids: [e.id]))
        }
    }
    // Two digits swapped while typing always leave a difference divisible by 9.
    if abs(diff) % 9 == 0 {
        for e in ticked {
            if let meant = swaps(e.amount).first(where: { $0 - e.amount == diff }) {
                out.append(Hint(text: words.swapped(name(e), money(meant), money(e.amount)), ids: [e.id]))
            }
        }
    }
    // A misplaced decimal point (164.67 for 1,646.70) is off by the entry times 9, 99 or 999.
    for e in ticked {
        for k: Int64 in [10, 100, 1000] {
            if diff == e.amount * (k - 1) {
                out.append(Hint(text: words.decimal(name(e), money(e.amount * k), money(e.amount)), ids: [e.id]))
            } else if diff * k == -e.amount * (k - 1) && e.amount % k == 0 {
                out.append(Hint(text: words.decimal(name(e), money(e.amount / k), money(e.amount)), ids: [e.id]))
            }
        }
    }
    // Two unticked entries that together make the difference.
    let small = Array(unticked.prefix(80))
    var i = 0
    while i < small.count && out.count < 6 {
        for j in (i + 1)..<max(i + 1, small.count) where small[i].amount + small[j].amount == diff {
            out.append(Hint(text: words.pair(name(small[i]), name(small[j])), ids: [small[i].id, small[j].id]))
            break
        }
        i += 1
    }
    // The same payment entered twice.
    for e in ticked {
        for f in ticked where e.id < f.id && e.amount == f.amount && e.amount == -diff && abs(dayDiff(e.day, f.day)) <= 3
            && similarity(e.name, f.name) >= 0.5 {
            out.append(Hint(text: words.duplicate(name(e)), ids: [e.id, f.id]))
        }
    }
    // Entries at the very end of the period often reach the bank on the next statement.
    let from = addDays(statementDay, -3)
    let late = ticked.filter { $0.day > from && $0.day <= statementDay }
    if !late.isEmpty && out.isEmpty { out.append(Hint(text: words.late(), ids: late.map(\.id))) }
    if out.isEmpty {
        out.append(Hint(text: diff < 0 ? words.lookOut(money(abs(diff))) : words.lookIn(money(abs(diff))), ids: []))
    }
    return Array(out.prefix(6))
}

// MARK: Planning a reconciliation

/// What a reconciliation starts from (statement.ts planReconciliation): which statement lines match Kosha's entries,
/// which are missing, and which entries count as ticked. With a statement, its period starts at its first line; an
/// entry from before then that matches no line was on an earlier statement, so it counts as ticked, and in the period
/// only matched entries are. A close match or a bank's correction to another amount is never ticked until settled.
/// Without a statement, every paid entry up to the statement day is ticked.
public struct Plan: Sendable {
    public let pairs: [Matched]
    public let missing: [Int]
    public let matched: Set<String>
    public let close: [Matched]
    public let splits: [Split]
    public let withdrawn: [String]
    public let periodStart: String
    let statementDay: String
    let hasLines: Bool

    public func inPeriod(_ e: Entry) -> Bool {
        e.day <= statementDay && (e.day >= periodStart || matched.contains(e.id) || withdrawn.contains(e.id))
    }

    public func ticks(_ e: Entry) -> Bool {
        e.day <= statementDay && (hasLines ? !inPeriod(e) || matched.contains(e.id) : e.paid == 1)
    }
}

public func planReconciliation(
    lines: [Line], open: [Entry], done: [Entry], statementDay: String, lastDay: String?,
    rejected: Set<String> = [], withdrawn: [String] = []
) -> Plan {
    let gone = Set(withdrawn)
    let entries = (open + done).filter { $0.ref == nil || !gone.contains($0.ref!) }
    let match = lines.isEmpty ? nil : matchLines(lines, entries)
    let openIds = Set(open.map(\.id))
    func settle(_ p: Matched) -> Bool { p.kind == .close || p.kind == .corrected }
    let pairs = (match?.pairs ?? []).filter { !(settle($0) && rejected.contains(lines[$0.line].ref ?? "")) }
    let paired = Set(pairs.map(\.line))
    let matched = Set(pairs.filter { !settle($0) && openIds.contains($0.entry) }.map(\.entry))
    let close = pairs.filter { settle($0) && openIds.contains($0.entry) }
    let out = open.filter { $0.ref != nil && gone.contains($0.ref!) }.map(\.id)
    let firstLine = lines.map(\.day).min() ?? "9999-12-31"
    let periodStart = !lines.isEmpty ? firstLine : lastDay.map { addDays($0, 1) } ?? addDays(statementDay, -45)
    return Plan(
        pairs: pairs, missing: lines.indices.filter { !paired.contains($0) }, matched: matched, close: close,
        splits: (match?.splits ?? []).filter { $0.entries.allSatisfy(openIds.contains) }, withdrawn: out,
        periodStart: periodStart, statementDay: statementDay, hasLines: !lines.isEmpty
    )
}

// MARK: Getting started: many statements at once

// Common merchants and words, mapped to Kosha's starting categories, so a first import sorts much of itself even without
// AI or any rules yet. Only categories the person still has are used.
private let starter: [(NSRegularExpression, String, Bool)] = [
    (re(#"\b(tesco|sainsbury|asda|aldi|lidl|morrisons|waitrose|co ?op|ocado|rewe|edeka|kaufland|netto|penny|carrefour|auchan|leclerc|intermarche|mercadona|albert heijn|jumbo|whole foods|trader joe|safeway|kroger|publix|supermarket|grocer)"#), "groceries", false),
    (re(#"\b(restaurant|cafe|caffe|coffee|starbucks|costa|pret|mcdonald|burger king|kfc|subway|nando|pizza|domino|deliveroo|uber ?eats|just ?eat|doordash|grubhub|wolt|bistro|sushi|trattoria|bakery|pub)"#), "dining", false),
    (re(#"\b(amazon|amzn|ebay|etsy|zara|primark|uniqlo|ikea|argos|john lewis|decathlon|zalando|asos|apple store|best buy|target)"#), "shopping", false),
    (re(#"\b(uber|lyft|bolt|free ?now|taxi|tfl|transport for london|trainline|railway|deutsche bahn|sncf|renfe|metro|bus|shell|esso|texaco|fuel|petrol|parking|citymapper)"#), "transit", false),
    (re(#"\b(rent|landlord|mortgage|letting)"#), "home", false),
    (re(#"\b(electric|energy|octopus|british gas|edf|eon|water|council tax|broadband|vodafone|o2|ee|three|verizon|t mobile|insurance|account fee|monthly fee|service charge|overdraft)"#), "bills", false),
    (re(#"\b(netflix|spotify|disney|hbo|prime video|youtube|apple tv|audible|cinema|odeon|steam|playstation|xbox|nintendo|ticketmaster)"#), "entertainment", false),
    (re(#"\b(pharmacy|boots|chemist|apotheke|doctor|dentist|hospital|clinic|optician|gym|puregym|fitness)"#), "health", false),
    (re(#"\b(airline|airways|ryanair|easyjet|wizz|lufthansa|klm|air france|vueling|hotel|airbnb|booking com|expedia|hostel)"#), "travel", false),
    (re(#"\b(salary|payroll|wages|gehalt|salaire)"#), "salary", true),
    (re(#"\b(interest|refund|cashback|dividend|reimburse)"#), "other_income", true),
]
private let notWord = re(#"[^\p{L}\p{N}&]+"#)

/// A starting category for a payee from a few well-known names and words, or nil.
public func starterCategory(_ text: String, income: Bool, have: Set<String>) -> String? {
    let t = " \(notWord.replace(text.lowercased(), with: " ")) "
    return starter.first { r, id, way in way == income && have.contains(id) && r.contains(t) }?.1
}

/// A line of one account, for finding transfers between accounts.
public struct Leg: Sendable, Hashable {
    public let key: String, account: String, day: String
    public let amount: Int64
}

public struct TransferPair: Sendable, Hashable {
    public let out: String
    public let into: String
}

/// Lines of different accounts that look like one transfer: money out of one and the same amount into the other within
/// `days` days, closest first, each line used once. Returns pairs of line keys, out first.
public func pairTransfers(_ lines: [Leg], days: Int = 3) -> [TransferPair] {
    struct Candidate { let o: String, i: String, d: Int }
    var cands: [Candidate] = []
    for o in lines where o.amount < 0 {
        for i in lines where i.amount > 0 && i.account != o.account && i.amount == -o.amount {
            let d = abs(dayDiff(o.day, i.day))
            if d <= days { cands.append(Candidate(o: o.key, i: i.key, d: d)) }
        }
    }
    var used: Set<String> = []
    var out: [TransferPair] = []
    for c in cands.stableSorted(by: \.d) where !used.contains(c.o) && !used.contains(c.i) {
        used.insert(c.o)
        used.insert(c.i)
        out.append(TransferPair(out: c.o, into: c.i))
    }
    return out
}

/// One statement of an account, for `statementGaps`. Balances are as printed.
public struct Span: Sendable {
    public let name: String, from: String, to: String
    public let opening: Int64?, closing: Int64?
}

public enum Gap: Sendable, Equatable {
    /// No statement covers these days.
    case uncovered(from: String, to: String)
    /// `next` doesn't open where `previous` closed.
    case opening(next: String, opening: Int64, previous: String, closing: Int64)
}

/// Checks one account's statements join up: a gap of more than a few days between one and the next, or a statement that
/// doesn't open where the one before closed, means one is likely missing.
public func statementGaps(_ files: [Span]) -> [Gap] {
    let sorted = files.stableSorted(by: \.from)
    var out: [Gap] = []
    for i in sorted.indices.dropFirst() {
        let a = sorted[i - 1], b = sorted[i]
        if dayDiff(a.to, b.from) > 5 {
            out.append(.uncovered(from: addDays(a.to, 1), to: addDays(b.from, -1)))
        } else if let c = a.closing, let o = b.opening, c != o {
            out.append(.opening(next: b.name, opening: o, previous: a.name, closing: c))
        }
    }
    return out
}

/// A statement's lines and the refs a bank's correction in it withdrew.
public struct StatementLines: Sendable {
    public var lines: [Line]
    public var withdrawn: [String] = []
}

/// One account's lines from several statements, each line once. Statements that overlap share lines: the same bank id,
/// or in days an earlier statement covers, the same day and amount. Within one statement, two equal lines are two
/// payments. A line another statement's bank correction replaced or withdrew is left out.
public func mergeStatements(_ files: [StatementLines]) -> [Line] {
    let corrected = Set(files.flatMap { f in f.withdrawn + f.lines.compactMap(\.replaces) })
    func num(_ l: Line) -> Int { Int(l.day.replacingOccurrences(of: "-", with: "")) ?? 0 }
    func span(_ f: StatementLines) -> (Int, Int) { (f.lines.map(num).min()!, f.lines.map(num).max()!) }
    let sorted = files.filter { !$0.lines.isEmpty }.stableSorted { span($0).0 }
    var refs: Set<String> = []
    var counts: [String: Int] = [:]
    var covered: [(Int, Int)] = []
    var out: [Line] = []
    for f in sorted {
        var kept: [Line] = []
        for l in f.lines {
            let k = "\(l.day)|\(l.amount)"
            let d = num(l)
            let seen = covered.contains { $0.0...$0.1 ~= d } ? counts[k] ?? 0 : 0
            if seen > 0 { counts[k] = seen - 1 }
            if seen > 0 || (l.ref.map { refs.contains($0) || corrected.contains($0) } ?? false) { continue }
            kept.append(l)
        }
        for l in kept {
            if let r = l.ref { refs.insert(r) }
            counts["\(l.day)|\(l.amount)", default: 0] += 1
        }
        covered.append(span(f))
        out += kept
    }
    return out
}
