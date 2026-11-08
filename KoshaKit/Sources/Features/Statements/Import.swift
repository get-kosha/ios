import SwiftUI
import Model
import API
import Store
import Design

// Import (06-accounts-ImportChoose, ImportAccounts, ImportPayees, ImportDone): many statements from every bank and card
// at once, sorted into accounts, payees and transfers, as the web's import.tsx does. Ported from the Android app's
// ImportModel.kt and ImportScreens.kt.

/// A statement read from a file. Balances are as the bank prints them: for a card, what is owed.
struct Stmt: Sendable, Identifiable {
    let id: String
    let file: String
    let source: String
    var lines: [Line]
    var withdrawn: [String] = []
    /// A CSV's text and first rows, so a changed column choice re-reads it.
    var picked: Picked?
    var rows: [[String]] = []
    var layout: StatementLayout?
    var signature: String?
    var remembered = false
    var byAi = false
    var confident = true
    var opening: Int64?
    var closing: Int64?
    var closingDay: String?
    /// For a PDF read by AI: how far its lines miss its closing balance.
    var off: Int64?
    var currency: String?
    var type: AccountType?
    var last4: String?
    /// Which account it is from: statements with the same key go to the same account.
    let key: String
    /// A name for that account.
    let title: String
    var acct = ""
}

/// Where a group of statements goes: "new", or the id of an account the person has.
struct Acct: Sendable, Identifiable {
    let id: String
    var target: String
    var name: String
    var type: AccountType
    var currency: String
    var limit: Int64?
    /// The closing balance as typed, once the person changed it; nil clears it.
    var closing: Int64?
    var closingEdited = false
}

/// An account's details: from the wallet when it goes into one the person has.
struct AcctInfo { let name: String; let type: AccountType; let currency: String; let limit: Int64; let wallet: Wallet? }

/// A statement line in the review, keyed by its account and bank id.
struct ReviewRow: Sendable, Hashable { let line: Line; let key: String; let acct: String }

/// Lines grouped under one payee: a change applies to all of them.
struct PayeeGroup: Identifiable {
    let id: String
    let payee: String
    let income: Bool
    var raws: [String]
    var lines: [ReviewRow]
    var category: String
    var aiPayee: Bool
    var aiCategory: Bool
}

struct Review { let rows: [ReviewRow]; let pairs: [(ReviewRow, ReviewRow)]; let list: [PayeeGroup] }

struct Reading: Identifiable, Sendable { let id: String; let name: String; let pdf: Bool }

enum Fail: Sendable { case pdf, empty, offline, unreadable, server }

struct Failed: Identifiable, Sendable { let id: String; let name: String; let fail: Fail; var message: String? = nil }

/// What the save is doing, for its progress line.
enum Doing: Sendable {
    case setup(String), adding(Int, String), transfers, checking(String), finished
}

struct DoneAccount: Sendable { let name: String, walletId: String; let lines: Int; let reconciled: String?; let isNew: Bool, checkPdf: Bool }

struct ImportResult: Sendable { let accounts: [DoneAccount]; let lines: Int, transfers: Int; let recurring: [String] }

private let generic = try! NSRegularExpression(pattern: "^(account|current|checking|cheque|savings?|credit|card|bank|joint|main|personal|everyday)$")
private func words(_ s: String) -> [String] {
    descriptorKey(s).split(separator: " ").map(String.init).filter { !$0.isEmpty && !generic.contains($0) }
}
private let cardFile = try! NSRegularExpression(pattern: "card|credit|visa|amex|master", options: .caseInsensitive)

/// A file's name as an account name: "n26-statement-2026-10.csv" is "N26".
func fileTitle(_ name: String) -> String {
    var s = name.replacingOccurrences(of: #"\.[A-Za-z0-9]+$"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[\d_\-.()\[\]]+"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"(?i)\b(statement|export|transactions?|download|account)\b"#, with: " ", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

// Raw payee groups are the bank text's merchant words and the direction of the money.
private func rawKey(_ l: Line) -> String {
    let k = descriptorKey(l.description)
    let base = k.isEmpty ? String(l.description.lowercased().trimmingCharacters(in: .whitespaces).prefix(60)) : k
    return "\(base)|\(l.amount < 0 ? "out" : "in")"
}

/// Importing many statements at once, from choosing files to Done (the web's import.tsx): read each file on the server,
/// put statements with their accounts, check the payees and transfers, then save account by account. What is saved is
/// remembered, so trying again after a failure carries on rather than starting over.
@MainActor @Observable
final class ImportModel {
    enum Step { case files, accounts, review, saving, done }

    private let kosha: Kosha
    var step = Step.files
    private var memory = Memory()
    private(set) var reading: [Reading] = []
    /// Files read in this round, for "4 of 6 done".
    private(set) var batch = 0
    var failed: [Failed] = []
    var stmts: [Stmt] = []
    var accts: [Acct] = []
    private var already: [String: Set<String>] = [:]
    private(set) var busy = false
    var checkError: String?
    /// Payee and category chosen per raw payee group.
    private var edits: [String: (String?, String?)] = [:]
    /// Transfer pairs the person said aren't transfers, by the money-out line.
    private var unpaired: Set<String> = []
    /// Lines left out of the import.
    private var left: Set<String> = []
    private var tidy: [String: Tidy] = [:]
    private(set) var naming = false
    @ObservationIgnored private var tidyAsked = false
    private(set) var doing: Doing?
    private(set) var progress = 0.0
    private(set) var error: String?
    private(set) var result: ImportResult?

    init(kosha: Kosha) {
        self.kosha = kosha
        Task { if let m: Memory = try? await kosha.api.get("/api/app/import/memory") { memory = m } }
    }

    private var meta: Meta? { kosha.meta }

    func wallets() -> [Wallet] { kosha.activeWallets.filter { $0.kind != .investment } }

    func info(_ a: Acct) -> AcctInfo {
        if let w = wallets().first(where: { $0.id == a.target }) {
            return AcctInfo(name: w.name, type: w.kind, currency: w.currency, limit: w.creditLimit ?? 0, wallet: w)
        }
        let name = a.name.trimmingCharacters(in: .whitespaces)
        return AcctInfo(name: name.isEmpty ? L.import_new_account() : name, type: a.type, currency: a.currency, limit: a.limit ?? 0,
                        wallet: nil)
    }

    /// Accounts that still have a statement.
    var live: [Acct] { accts.filter { a in stmts.contains { $0.acct == a.id } } }

    func linesOf(_ a: Acct) -> [Line] {
        mergeStatements(stmts.filter { $0.acct == a.id }.map { StatementLines(lines: $0.lines, withdrawn: $0.withdrawn) })
    }

    /// The closing balance from the latest statement that gives one, as the bank prints it.
    struct Closing { let day: String; let balance: Int64?; let fromFile: Bool }

    func closingOf(_ a: Acct) -> Closing {
        let latest = stmts.filter { $0.acct == a.id && $0.closing != nil && $0.closingDay != nil }.max { $0.closingDay! < $1.closingDay! }
        let day = latest?.closingDay ?? span(linesOf(a))?.last ?? kosha.today.text
        return Closing(day: day, balance: a.closingEdited ? a.closing : latest?.closing, fromFile: !a.closingEdited && latest != nil)
    }

    // MARK: Reading files

    /// Reads files three at a time: a PDF read by AI takes a while, and a year of them shouldn't queue.
    func add(_ urls: [URL]) {
        let queue = urls.map { (Reading(id: UUID().uuidString, name: $0.lastPathComponent, pdf: Picked.isPdf($0)), $0) }
        if reading.isEmpty { batch = 0 }
        batch += queue.count
        reading += queue.map(\.0)
        Task {
            for chunk in stride(from: 0, to: queue.count, by: 3).map({ Array(queue[$0..<min($0 + 3, queue.count)]) }) {
                await withTaskGroup(of: Void.self) { group in
                    for (r, url) in chunk { group.addTask { await self.readOne(r, url) } }
                }
            }
        }
    }

    private func readOne(_ r: Reading, _ url: URL) async {
        defer { reading.removeAll { $0.id == r.id } }
        do {
            place(try await read(url, r.id))
        } catch let f as FailError {
            failed.append(Failed(id: r.id, name: r.name, fail: f.fail))
        } catch KoshaError.api(_, let e) {
            failed.append(Failed(id: r.id, name: r.name, fail: .server, message: e.message))
        } catch let e as KoshaError where e.retryable {
            failed.append(Failed(id: r.id, name: r.name, fail: .offline))
        } catch {
            failed.append(Failed(id: r.id, name: r.name, fail: .unreadable))
        }
    }

    private struct FailError: Error { let fail: Fail }

    private func read(_ url: URL, _ id: String) async throws -> Stmt {
        let ai = meta?.aiFlags.statements == true
        let file = try Picked.read(url)
        if file.pdf && !ai { throw FailError(fail: .pdf) }
        let card = !file.pdf && cardFile.contains(file.name)
        let r = try await kosha.api.read(file, card: card)
        func typeLabel(_ credit: Bool) -> String { credit ? L.import_type_card() : L.import_type_bank() }
        func named(_ base: String, _ last4: String?) -> String { base + (last4.map { " ••\($0)" } ?? "") }
        switch r.format {
        case "pdf":
            let credit = r.account?.type == "credit"
            let last4 = r.account?.last4
            let key = last4.map { "last4:\($0)" } ?? r.account?.name.map { "name:\($0.lowercased())" } ?? "file:\(id)"
            // The last four digits stay in the name, so next month's statement finds this account.
            return Stmt(id: id, file: file.name, source: "pdf", lines: r.lines, byAi: true, opening: r.opening, closing: r.closing,
                        closingDay: r.to ?? span(r.lines)?.last, off: r.off, currency: r.currency, type: credit ? .credit : .bank,
                        last4: last4, key: key, title: named(r.account?.name ?? typeLabel(credit), last4))
        case "ofx", "qfx":
            if r.lines.isEmpty { throw FailError(fail: .empty) }
            let credit = r.account?.type == "credit"
            let last4 = r.account?.id.map { String($0.suffix(4)) }
            // Cards report what's owed as a negative balance.
            return Stmt(id: id, file: file.name, source: "ofx", lines: r.lines, withdrawn: r.withdrawn,
                        closing: r.closing.map { credit ? -$0 : $0 }, closingDay: r.closingDay ?? span(r.lines)?.last,
                        currency: r.currency, type: credit ? .credit : .bank, last4: last4,
                        key: r.account?.id.map { "ofx:\($0)" } ?? "file:\(id)", title: named(typeLabel(credit), last4))
        default:
            let remembered = r.signature.map { memory.layouts[$0] != nil } ?? false
            var csv = r
            var byAi = false
            if !remembered && !r.isConfident && ai, let l = await kosha.api.aiLayout(r) {
                csv = try await kosha.api.read(file, card: card, layout: l)
                byAi = true
            }
            let layout = csv.layout
            // Some exports (Monzo, Revolut) have a currency column; its first value is the account's currency.
            var currency: String?
            if let l = layout, l.header >= 0, csv.rows.indices.contains(l.header),
               let ci = csv.rows[l.header].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "currency" }),
               csv.rows.indices.contains(l.header + 1), csv.rows[l.header + 1].indices.contains(ci) {
                let v = csv.rows[l.header + 1][ci].trimmingCharacters(in: .whitespaces).lowercased()
                if v.count == 3 && v.allSatisfy(\.isLetter) { currency = v }
            }
            let b = csvBalances(csv.lines, card: card)
            let last4 = csv.accountHint
            let title = fileTitle(file.name)
            return Stmt(id: id, file: file.name, source: "csv", lines: csv.lines, picked: file, rows: csv.rows, layout: layout,
                        signature: csv.signature, remembered: remembered, byAi: byAi, confident: csv.isConfident || byAi,
                        opening: b.opening, closing: b.closing, closingDay: b.closingDay, currency: currency,
                        type: card ? .credit : nil, last4: last4, key: last4.map { "last4:\($0)" } ?? "sig:\(csv.signature ?? "")",
                        title: named(title.isEmpty ? typeLabel(card) : title, last4))
        }
    }

    /// Two statements are of one account when they share a key and, for a CSV, overlap or share a line.
    private func sameAccount(_ a: Stmt, _ b: Stmt) -> Bool {
        if a.key != b.key { return false }
        if a.key.hasPrefix("ofx:") || a.key.hasPrefix("last4:") { return true }
        // Two exports in the same format that cover the same days without sharing a line are two accounts.
        guard let x = span(a.lines), let y = span(b.lines) else { return true }
        if x.last < y.first || y.last < x.first { return true }
        let refs = Set(a.lines.map(\.ref))
        return b.lines.contains { refs.contains($0.ref) }
    }

    /// Puts a statement with its account: one it shares a key with, else a new one, matched to a wallet if one fits.
    private func place(_ s: Stmt) {
        var s = s
        if let same = stmts.first(where: { sameAccount($0, s) }) {
            s.acct = same.acct
            stmts.append(s)
            return
        }
        let acct = UUID().uuidString
        let taken = Set(accts.map(\.target))
        let fits = wallets().filter { w in
            !taken.contains(w.id) && ((s.last4.map { w.name.contains($0) } ?? false)
                || (!words(w.name).isEmpty && Set(words(w.name)).isSubset(of: Set(words(s.title)))))
        }
        s.acct = acct
        stmts.append(s)
        accts.append(Acct(id: acct, target: fits.count == 1 ? fits[0].id : "new", name: s.title, type: s.type ?? .bank,
                          currency: s.currency ?? meta?.primaryCurrency ?? "eur"))
    }

    func dismiss(_ f: Failed) { failed.removeAll { $0.id == f.id } }

    // MARK: Accounts

    func patch(_ id: String, _ change: (inout Acct) -> Void) {
        if let i = accts.firstIndex(where: { $0.id == id }) { change(&accts[i]) }
    }

    /// A card's CSV often shows spending as positive: read it again as a card's, unless its columns were set.
    func setType(_ a: Acct, _ type: AccountType) {
        patch(a.id) { $0.type = type }
        for s in stmts where s.acct == a.id && s.source == "csv" && !s.remembered && !s.byAi && s.layout?.balance == nil {
            guard let picked = s.picked else { continue }
            Task {
                if let r = try? await kosha.api.read(picked, card: type == .credit) {
                    replaced(s, r, r.layout ?? s.layout, card: type == .credit)
                }
            }
        }
    }

    /// A CSV read again with columns the person set.
    func columns(_ s: Stmt, _ layout: StatementLayout) {
        let card = accts.first { $0.id == s.acct }.map { info($0).type } == .credit
        guard let picked = s.picked else { return }
        Task {
            do {
                let r = try await kosha.api.read(picked, card: card, layout: layout)
                replaced(s, r, layout, card: card, edited: true)
            } catch {
                checkError = (error as? KoshaError)?.errorDescription ?? ""
            }
        }
    }

    private func replaced(_ s: Stmt, _ r: Read, _ layout: StatementLayout?, card: Bool, edited: Bool = false) {
        guard let i = stmts.firstIndex(where: { $0.id == s.id }) else { return }
        let b = csvBalances(r.lines, card: card)
        stmts[i].lines = r.lines
        stmts[i].rows = r.rows
        stmts[i].layout = layout
        stmts[i].opening = b.opening
        stmts[i].closing = b.closing
        stmts[i].closingDay = b.closingDay
        if edited {
            stmts[i].remembered = false
            stmts[i].byAi = false
        }
    }

    func move(_ s: Stmt, to: String) {
        guard let i = stmts.firstIndex(where: { $0.id == s.id }) else { return }
        if to == "new" {
            let id = UUID().uuidString
            accts.append(Acct(id: id, target: "new", name: s.title, type: s.type ?? .bank, currency: s.currency ?? meta?.primaryCurrency ?? "eur"))
            stmts[i].acct = id
        } else {
            stmts[i].acct = to
        }
    }

    func remove(_ s: Stmt) { stmts.removeAll { $0.id == s.id } }

    /// Lines already in an account Kosha has are left out: by bank id, or the same amount within a few days.
    func toReview() {
        Task {
            busy = true
            checkError = nil
            defer { busy = false }
            do {
                var found: [String: Set<String>] = [:]
                for a in live {
                    guard let w = wallets().first(where: { $0.id == a.target }), w.entryCount > 0 else { continue }
                    let lines = linesOf(a)
                    guard let r = span(lines) else { continue }
                    // An entry the bank withdrew stays as it is, but matches nothing.
                    let gone = Set(stmts.filter { $0.acct == a.id }.flatMap(\.withdrawn))
                    let known: [KnownEntry] = try await kosha.api.get("/api/app/import/entries",
                                                                      query: ["walletId": w.id, "from": r.first, "to": r.last])
                    let entries = known.filter { !gone.contains($0.ref ?? "") }
                        .map { Entry(id: $0.id, day: $0.day, amount: $0.amount, name: $0.name, ref: $0.ref) }
                    let m = matchLines(lines, entries)
                    found[a.id] = Set(m.pairs.filter { $0.kind != .close }.compactMap { lines[$0.line].ref })
                }
                already = found
                step = .review
                askTidy()
            } catch KoshaError.api(_, let e) {
                checkError = e.message
            } catch {
                checkError = ""
            }
        }
    }

    // MARK: Review: payees, categories and transfers

    var categories: [MetaCategory] {
        (meta?.categories ?? []).filter { !$0.isArchived && $0.parentId == nil && !Categories.isNeutral($0.id) }
    }
    private var guessing: Bool { meta?.pref("suggest_category", "1") == "1" }

    struct Guess { let payee: String, category: String; let aiPayee: Bool, aiCategory: Bool }

    /// What Kosha would pick for a raw group by itself: remembered names, rules, AI, then well-known merchants.
    private func guess(_ l: Line) -> Guess {
        let key = descriptorKey(l.description)
        let income = l.amount > 0
        let ai = tidy[key]
        let own = memory.aliases[key] ?? l.payee.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let payee = own ?? ai?.payee ?? payeeFor(l.description, known: meta?.titles ?? [], aliases: memory.aliases)
        let cats = categories
        func fits(_ id: String?) -> String? { id.flatMap { x in cats.contains { $0.id == x && $0.isIncome == income } ? x : nil } }
        let rules = meta?.payeeMatches ?? []
        let ruled = guessing ? fits(guessCategory(payee, rules)) ?? fits(guessCategory(l.description, rules)) : nil
        let byAi = guessing && ruled == nil ? fits(ai?.categoryId) : nil
        let category = ruled ?? byAi
            ?? (guessing ? starterCategory("\(payee) \(l.description)", income: income, have: Set(cats.map(\.id))) : nil) ?? ""
        return Guess(payee: payee, category: category, aiPayee: own == nil && ai != nil, aiCategory: byAi != nil)
    }

    /// The review: lines not yet in Kosha, transfers between the accounts, and payee groups, most lines first.
    var review: Review? {
        if step == .files || step == .accounts { return nil }
        let liveAccts = live
        let rows = liveAccts.flatMap { a in
            linesOf(a).filter { !(already[a.id] ?? []).contains($0.ref ?? "") }
                .map { ReviewRow(line: $0, key: "\(a.id):\($0.ref ?? "")", acct: a.id) }
        }.filter { !left.contains($0.key) }
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // Money out of one account and into another on the same days is a transfer between them.
        let curOf = Dictionary(liveAccts.map { ($0.id, info($0).currency) }, uniquingKeysWith: { a, _ in a })
        let currencies = curOf.values.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let pairs = currencies.flatMap { cur in
            pairTransfers(rows.filter { curOf[$0.acct] == cur }.map { Leg(key: $0.key, account: $0.acct, day: $0.line.day, amount: $0.line.amount) })
        }
        .filter { !unpaired.contains($0.out) }
        .compactMap { p in byKey[p.out].flatMap { o in byKey[p.into].map { (o, $0) } } }
        let paired = Set(pairs.flatMap { [$0.0.key, $0.1.key] })
        var rawOrder: [String] = []
        var raws: [String: [ReviewRow]] = [:]
        for r in rows where !paired.contains(r.key) {
            let k = rawKey(r.line)
            if raws[k] == nil { rawOrder.append(k) }
            raws[k, default: []].append(r)
        }
        var groupOrder: [String] = []
        var groups: [String: PayeeGroup] = [:]
        for raw in rawOrder.stableSorted(by: { -(raws[$0]?.count ?? 0) }) {
            let lines = raws[raw]!
            let g = guess(lines[0].line)
            let edit = edits[raw]
            let typed = (edit?.0 ?? g.payee).trimmingCharacters(in: .whitespaces)
            let payee = typed.isEmpty ? g.payee : typed
            let income = lines[0].line.amount > 0
            let id = "\(payee.lowercased())|\(income)"
            if var group = groups[id] {
                group.raws.append(raw)
                group.lines += lines
                if group.category.isEmpty { group.category = edit?.1 ?? g.category }
                groups[id] = group
            } else {
                groupOrder.append(id)
                groups[id] = PayeeGroup(id: id, payee: payee, income: income, raws: [raw], lines: lines,
                                        category: edit?.1 ?? g.category, aiPayee: edit?.0 == nil && g.aiPayee,
                                        aiCategory: edit?.1 == nil && g.aiCategory)
            }
        }
        // A category chosen for any part of a merged group goes for all of it.
        for id in groupOrder {
            if let c = groups[id]!.raws.lazy.compactMap({ self.edits[$0]?.1 }).first {
                groups[id]!.category = c
                groups[id]!.aiCategory = false
            }
        }
        return Review(rows: rows, pairs: pairs, list: groupOrder.compactMap { groups[$0] }.stableSorted { -$0.lines.count })
    }

    func edit(_ g: PayeeGroup, payee: String? = nil, category: String? = nil) {
        for raw in g.raws {
            let was = edits[raw]
            edits[raw] = (payee ?? was?.0, category ?? was?.1)
        }
    }

    func unpair(_ pairs: [(ReviewRow, ReviewRow)]) { unpaired.formUnion(pairs.map(\.0.key)) }

    func leaveOut(_ pairs: [(ReviewRow, ReviewRow)]) { left.formUnion(pairs.flatMap { [$0.0.key, $0.1.key] }) }

    /// AI names payees and sorts what Kosha can't place itself, once, in chunks a model answers well.
    private func askTidy() {
        guard let m = meta, !tidyAsked, m.aiFlags.statements, m.pref("ai_share_payee", "1") == "1", let r = review else { return }
        tidyAsked = true
        var todo: [TidyItem] = []
        var seen: Set<String> = []
        for g in r.list {
            for raw in g.raws {
                guard let l = g.lines.first(where: { rawKey($0.line) == raw })?.line else { continue }
                let key = descriptorKey(l.description)
                if key.isEmpty || memory.aliases[key] != nil || seen.contains(key) { continue }
                if l.payee == nil || guess(l).category.isEmpty {
                    seen.insert(key)
                    todo.append(TidyItem(key: key, text: l.description, amount: l.amount))
                }
            }
        }
        if todo.isEmpty { return }
        naming = true
        Task {
            for start in stride(from: 0, to: todo.count, by: 150) {
                // Without it, Kosha's own names stand.
                let chunk = Array(todo[start..<min(start + 150, todo.count)])
                guard let got: [String: Tidy] = try? await kosha.api.post("/api/app/import/tidy", TidyBody(items: chunk)) else { break }
                tidy.merge(got) { $1 }
            }
            naming = false
        }
    }

    // MARK: Saving

    @ObservationIgnored private var savedIds: [String: String] = [:]
    @ObservationIgnored private var savedLines: [String: Int] = [:]
    @ObservationIgnored private var savedPairs = 0
    @ObservationIgnored private var remembered = false
    @ObservationIgnored private var finished: [String: ImportFinished] = [:]

    func save() {
        guard let plan = review else { return }
        step = .saving
        error = nil
        Task {
            let liveAccts = live
            var groupOf: [String: PayeeGroup] = [:]
            for g in plan.list { for l in g.lines { groupOf[l.key] = g } }
            @MainActor func payload(_ a: Acct) -> [NewLine] {
                plan.rows.filter { $0.acct == a.id && (groupOf[$0.key].map { $0.category != "skip" } ?? false) }.compactMap { l in
                    guard let g = groupOf[l.key], let ref = l.line.ref else { return nil }
                    let to: String? = g.category.hasPrefix("t:") ? savedIds[String(g.category.dropFirst(2))]
                        : g.category.hasPrefix("w:") ? String(g.category.dropFirst(2)) : nil
                    return NewLine(day: l.line.day, amount: l.line.amount, name: to != nil ? "" : g.payee, note: to != nil ? g.payee : "",
                                   categoryId: to == nil ? g.category : nil, transferWith: to, ref: ref)
                }
            }
            let total = liveAccts.count * 2 + plan.rows.count - plan.pairs.count * 2 + plan.pairs.count + 1
            var done = 0
            @MainActor func tick(_ n: Int, _ what: Doing) {
                done += n
                doing = what
                progress = min(1, Double(done) / Double(max(total, 1)))
            }
            do {
                for a in liveAccts {
                    let i = info(a)
                    tick(0, .setup(i.name))
                    if savedIds[a.id] == nil {
                        if a.target != "new" {
                            savedIds[a.id] = a.target
                        } else {
                            let credit = a.type == .credit
                            let c: StatementCreated = try await kosha.api.post("/api/v1/accounts", NewAccount(
                                name: i.name, type: credit ? "credit" : "bank", currency: a.currency, creditLimit: credit ? a.limit ?? 0 : nil))
                            savedIds[a.id] = c.id
                        }
                    }
                    tick(1, .setup(i.name))
                }
                // Kosha remembers each bank's columns and the payee names, so the next statement reads straight away.
                var sigs: Set<String> = []
                let layouts = stmts.compactMap { s -> LayoutMemory? in
                    guard s.source == "csv", let sig = s.signature, let l = s.layout, !sigs.contains(sig) else { return nil }
                    sigs.insert(sig)
                    return LayoutMemory(signature: sig, layout: l)
                }.prefix(50)
                var keys: Set<String> = []
                let aliases = plan.list.flatMap { g in g.raws.map { raw in
                    Alias(key: String(raw[..<(raw.lastIndex(of: "|") ?? raw.endIndex)]), payee: g.payee)
                } }.filter { a in
                    guard !keys.contains(a.key) else { return false }
                    keys.insert(a.key)
                    return !a.key.isEmpty && !a.payee.isEmpty && a.key == descriptorKey(a.key)
                }.prefix(2000)
                for a in liveAccts {
                    let list = payload(a)
                    let name = info(a).name
                    var i = savedLines[a.id] ?? 0
                    while i < list.count {
                        tick(0, .adding(list.count, name))
                        try await kosha.api.send("POST", "/api/app/import/lines", body: LinesBody(
                            walletId: savedIds[a.id]!, layouts: remembered ? [] : Array(layouts),
                            aliases: remembered ? [] : Array(aliases), lines: Array(list[i..<min(i + 500, list.count)])))
                        remembered = true
                        savedLines[a.id] = i + 500
                        tick(min(500, list.count - i), .adding(list.count, name))
                        i += 500
                    }
                }
                while savedPairs < plan.pairs.count {
                    tick(0, .transfers)
                    let chunk = plan.pairs[savedPairs..<min(savedPairs + 200, plan.pairs.count)]
                    try await kosha.api.send("POST", "/api/app/import/transfers", body: PairBody(pairs: chunk.map { o, n in
                        TransferBody(fromWalletId: savedIds[o.acct]!, toWalletId: savedIds[n.acct]!, sent: -o.line.amount,
                                     received: n.line.amount, day: o.line.day, refFrom: o.line.ref ?? "", refTo: n.line.ref ?? "")
                    }))
                    savedPairs += 200
                    tick(chunk.count, .transfers)
                }
                for a in liveAccts {
                    let i = info(a)
                    tick(0, .checking(i.name))
                    if finished[a.id] == nil {
                        let own = plan.rows.filter { $0.acct == a.id }.map(\.line)
                        let c = closingOf(a)
                        let credit = i.type == .credit
                        finished[a.id] = try await kosha.api.post("/api/app/import/finish", FinishImport(
                            walletId: savedIds[a.id]!, firstDay: span(own)?.first ?? c.day,
                            closing: c.balance.map { FinishImport.Closing(day: c.day, balance: credit ? i.limit - abs($0) : $0) },
                            keep: a.target == "new" ? nil : i.wallet?.balance ?? 0))
                    }
                    tick(1, .checking(i.name))
                }
                kosha.changed()
                let spotted = ((try? await kosha.api.get("/api/v1/recurring", query: ["includeSuggestions": "true"]) as RecurringSuggestions)?
                    .suggestions.map(\.payee)) ?? []
                tick(1, .finished)
                result = ImportResult(
                    accounts: liveAccts.map { a in
                        let i = info(a)
                        return DoneAccount(name: i.name, walletId: savedIds[a.id] ?? "", lines: plan.rows.filter { $0.acct == a.id }.count,
                                           reconciled: finished[a.id]?.reconciled == true ? closingOf(a).day : nil, isNew: a.target == "new",
                                           checkPdf: stmts.contains { $0.acct == a.id && ($0.off ?? 0) != 0 })
                    },
                    lines: plan.rows.count, transfers: plan.pairs.count, recurring: spotted
                )
                step = .done
            } catch KoshaError.api(_, let e) {
                self.error = e.message
            } catch {
                self.error = ""
            }
        }
    }
}

// MARK: Screens

struct ImportScreen: View {
    @Environment(Kosha.self) private var kosha
    @State private var model: ImportModel?

    var body: some View {
        Group {
            if let model { ImportFlow(model: model) } else { Color.clear }
        }
        .onAppear { if model == nil { model = ImportModel(kosha: kosha) } }
    }
}

private struct ImportFlow: View {
    let model: ImportModel
    private var inbox = ImportInbox.shared

    init(model: ImportModel) { self.model = model }

    var body: some View {
        Group {
            switch model.step {
            case .files: ImportChoose(model: model)
            case .accounts: ImportAccounts(model: model)
            case .review: ImportPayees(model: model)
            case .saving: ImportSaving(model: model)
            case .done: ImportDone(model: model)
            }
        }
        // Statements opened in Kosha wait in the inbox; take them now, and any opened while this screen is up.
        .onAppear { take() }
        .onChange(of: inbox.files) { _, _ in take() }
    }

    private func take() {
        let files = inbox.take()
        if !files.isEmpty { model.add(files) }
    }
}

/// "192 transactions in 4 accounts", made of one-count plurals (import_summary has two counts).
private func transactionsIn(_ lines: Int, _ accounts: Int) -> String {
    L.app_imp_summary(transactions: L.import_transactions(count: lines, n: "\(lines)"), accounts: L.app_imp_n_accounts(count: accounts))
}

private struct ImportChoose: View {
    let model: ImportModel
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        let c = theme.colors
        let pdf = kosha.meta?.aiFlags.statements == true
        let lines = model.live.reduce(0) { $0 + model.linesOf($1).count }
        let empty = model.stmts.isEmpty && model.reading.isEmpty
        StepPage(L.import_title(), subtitle: L.import_sub(), onBack: { dismiss() }, footer: {
            VStack(spacing: 8) {
                if lines > 0 && model.reading.isEmpty {
                    Text(transactionsIn(lines, model.live.count)).kFont(.xs).foregroundStyle(c.ink3)
                }
                KButton(L.app_imp_check_accounts()) { model.step = .accounts }
                    .disabled(!model.reading.isEmpty || lines == 0)
            }
        }) {
            Button {
                if kosha.canWrite { picking = true } else { toasts.show(L.common_demo_read_only(), warning: true) }
            } label: {
                VStack(spacing: 8) {
                    PhIcon("files", size: 22).frame(width: 44, height: 44).background(c.soft, in: .rect(cornerRadius: 14))
                    Text(empty ? L.app_imp_choose() : L.app_imp_choose_more()).kFont(.head)
                    Text(pdf ? L.app_imp_formats_pdf() : L.app_imp_formats()).kFont(.xs).foregroundStyle(c.ink3)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(c.surface, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(PressStyle())
            .disabled(!kosha.online)
            if !kosha.online { Note(text: L.app_imp_offline(), icon: "cloud-slash", tone: c.ink2) }
            HStack(spacing: 6) {
                PhIcon("share-network", size: 14, color: c.ink3)
                Text(L.app_imp_share_hint()).kFont(.xs).foregroundStyle(c.ink3)
            }
            if !empty || !model.failed.isEmpty { fileList }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: statementTypes(pdf: pdf), allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.add(urls) }
        }
    }

    private var fileList: some View {
        let c = theme.colors
        let total = model.stmts.count + model.reading.count
        let readingNow = !model.reading.isEmpty
        return StatementSection(
            title: readingNow ? L.import_reading_files(count: model.batch, n: "\(model.batch)") : L.app_imp_n_files(count: total),
            aside: readingNow ? L.app_imp_read_progress(done: "\(model.batch - model.reading.count)", total: "\(model.batch)") : nil
        ) {
            Card(tight: true) {
                ForEach(Array(model.stmts.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Hairline() }
                    ListRow {
                        PhIcon(fileIcon(s.source), size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.file).lineLimit(1)
                            Text(stmtLines(s.lines)).kFont(.xs).foregroundStyle(c.ink3)
                        }
                        Spacer(minLength: 8)
                        PhIcon("check-circle", size: 18, color: c.pos)
                    }
                }
                ForEach(model.reading) { r in
                    Hairline()
                    ListRow {
                        PhIcon(r.pdf ? "file-pdf" : "file-text", size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).lineLimit(1)
                            HStack(spacing: 4) {
                                if r.pdf { Sparkle(size: 11) }
                                Text(r.pdf ? L.app_imp_reading_ai() : L.app_imp_reading()).kFont(.xs).foregroundStyle(c.ink3)
                            }
                        }
                        Spacer(minLength: 8)
                        ProgressView().controlSize(.small)
                    }
                }
                ForEach(model.failed) { f in
                    Hairline()
                    ListRow {
                        PhIcon("warning", size: 18, color: c.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).lineLimit(1)
                            Text(failText(f)).kFont(.xs).foregroundStyle(c.warn)
                        }
                        Spacer(minLength: 8)
                        IconButton("x", label: L.import_dismiss(name: f.name)) { model.dismiss(f) }
                    }
                }
            }
        }
    }

    private func failText(_ f: Failed) -> String {
        switch f.fail {
        case .pdf: L.import_error_pdf()
        case .empty: L.import_error_no_transactions()
        case .offline: L.auth_error_offline()
        case .server: f.message.flatMap { $0.isEmpty ? nil : $0 } ?? L.import_error_unreadable()
        case .unreadable: L.import_error_unreadable()
        }
    }

    private func stmtLines(_ lines: [Line]) -> String {
        guard let r = span(lines) else { return L.import_stmt_no_lines() }
        return L.import_stmt_lines(count: lines.count, n: countText(lines.count, theme.locale),
                                   from: shortDay(r.first, kosha, theme.locale), to: shortDay(r.last, kosha, theme.locale))
    }
}

// MARK: ImportAccounts

private enum AcctSheet: Identifiable {
    case target(String), currency(String), limit(String), closing(String), move(String)
    var id: String {
        switch self {
        case .target(let s): "t" + s
        case .currency(let s): "c" + s
        case .limit(let s): "l" + s
        case .closing(let s): "b" + s
        case .move(let s): "m" + s
        }
    }
}

private struct ImportAccounts: View {
    let model: ImportModel
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var sheet: AcctSheet?

    var body: some View {
        let live = model.live
        let lines = live.reduce(0) { $0 + model.linesOf($1).count }
        let unnamed = live.contains { $0.target == "new" && $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        StepPage(
            L.app_imp_check_accounts(),
            subtitle: [L.app_imp_n_files(count: model.stmts.count), L.import_transactions(count: lines, n: countText(lines, theme.locale)),
                       L.app_imp_n_accounts(count: live.count)].joined(separator: " · "),
            onBack: { model.step = .files },
            footer: {
                KButton(L.import_check_payees()) { model.toReview() }
                    .disabled(model.busy || !model.reading.isEmpty || lines == 0 || unnamed)
            }
        ) {
            ForEach(Array(live.enumerated()), id: \.element.id) { i, a in
                AccountCard(model: model, a: a, index: i) { sheet = $0 }
            }
        }
        .onChange(of: model.checkError) { _, e in
            if let e {
                toasts.show(e.isEmpty ? L.import_error_check() : e, warning: true)
                model.checkError = nil
            }
        }
        .kSheet(item: $sheet, scrolls: { if case .currency = sheet { true } else { false } }()) { s in sheetView(s) }
    }

    @ViewBuilder
    private func sheetView(_ s: AcctSheet) -> some View {
        let close = { sheet = nil }
        switch s {
        case .target(let id):
            if let a = model.accts.first(where: { $0.id == id }) {
                let taken = Set(model.live.filter { $0.id != a.id }.map(\.target))
                ChoiceSheet(title: L.import_into(),
                            options: [("new", L.import_new_account_option())]
                                + model.wallets().filter { !taken.contains($0.id) }.map { ($0.id, L.import_into_wallet(name: $0.name)) },
                            selected: a.target, onPick: { t in model.patch(a.id) { $0.target = t } }, close: close)
            }
        case .currency(let id):
            if let a = model.accts.first(where: { $0.id == id }), let m = kosha.meta {
                let list = ([m.primaryCurrency] + m.wallets.map(\.currency) + ["eur", "inr", "usd", "gbp", a.currency])
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                ListPicker(L.import_field_currency(),
                           choices: list.map { Choice(id: $0, title: currencyName($0, theme.locale), detail: $0.uppercased()) },
                           selected: a.currency, onPick: { v in model.patch(a.id) { $0.currency = v }; close() }, onClose: close)
            }
        case .limit(let id):
            if let a = model.accts.first(where: { $0.id == id }) {
                SignedAmountSheet(title: L.import_credit_limit(currency: a.currency.uppercased()), start: a.limit, currency: a.currency,
                                  signed: false, onDone: { v in model.patch(a.id) { $0.limit = v } }, close: close)
            }
        case .closing(let id):
            if let a = model.accts.first(where: { $0.id == id }) {
                let i = model.info(a)
                let credit = i.type == .credit
                let cl = model.closingOf(a)
                let day = shortDay(cl.day, kosha, theme.locale)
                SignedAmountSheet(
                    title: credit ? L.import_owed_on(day: day, currency: i.currency.uppercased())
                        : L.import_balance_on(day: day, currency: i.currency.uppercased()),
                    start: cl.balance, currency: i.currency, signed: !credit,
                    onDone: { v in model.patch(a.id) { $0.closing = v; $0.closingEdited = true } }, close: close)
            }
        case .move(let sid):
            if let st = model.stmts.first(where: { $0.id == sid }) {
                ChoiceSheet(title: L.import_move_label(file: st.file),
                            options: model.live.filter { $0.id != st.acct }.map { ($0.id, model.info($0).name) }
                                + [("new", L.import_new_account_option())],
                            selected: nil, onPick: { model.move(st, to: $0) }, close: close)
            }
        }
    }
}

private struct AccountCard: View {
    let model: ImportModel
    let a: Acct
    let index: Int
    let open: (AcctSheet) -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let money = moneyWords(theme)
        let i = model.info(a)
        let wallet = i.wallet
        let credit = i.type == .credit
        let stmts = model.stmts.filter { $0.acct == a.id }
        let lines = model.linesOf(a)
        let range = span(lines)
        let read = stmts.reduce(0) { $0 + $1.lines.count }
        let closing = model.closingOf(a)
        // A new account takes the next colour after the person's accounts.
        let colour = wallet.map { kosha.colorIndex($0.id) } ?? ((kosha.meta?.wallets.count ?? 0) + index)
        let gaps = statementGaps(stmts.compactMap { s in
            span(s.lines).map { Span(name: s.file, from: $0.first, to: $0.last, opening: s.opening, closing: s.closing) }
        })
        let foreign = stmts.first { $0.currency != nil && $0.currency != i.currency }
        let matches = wallet != nil && closing.fromFile && closing.balance.map { (credit ? i.limit - abs($0) : $0) == wallet?.balance } == true
        let day = shortDay(closing.day, kosha, theme.locale)
        Card {
            HStack(spacing: 8) {
                AccountDot(c.account(colour), size: 10)
                Text(wallet.map { L.import_into_wallet(name: $0.name) } ?? L.import_new_account_option()).kFont(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L.settings_profile_change()) { open(.target(a.id)) }.kFont(.small).foregroundStyle(c.ink2)
                    .frame(minHeight: 44).buttonStyle(PressStyle())
            }
            if let range {
                Text(L.import_account_range(count: lines.count, n: countText(lines.count, theme.locale),
                                            from: shortDay(range.first, kosha, theme.locale), to: shortDay(range.last, kosha, theme.locale))
                     + (read > lines.count ? " " + L.import_account_dupes(count: read - lines.count, n: countText(read - lines.count, theme.locale)) : ""))
                    .kFont(.xs).foregroundStyle(c.ink3)
            }
            if matches {
                HStack(spacing: 4) {
                    PhIcon("check", size: 14, color: c.pos)
                    Text(L.app_imp_closing_matches()).kFont(.xs).foregroundStyle(c.pos)
                }
                .padding(.horizontal, 8).frame(minHeight: 22).background(c.soft, in: .capsule)
            }
            if wallet == nil {
                KField(L.import_field_name(), text: Binding(get: { a.name }, set: { v in model.patch(a.id) { $0.name = v } }))
                Segmented([(AccountType.bank, L.import_type_bank()), (.credit, L.import_type_card())],
                          selection: Binding(get: { a.type }, set: { model.setType(a, $0) }), small: true)
                HStack(spacing: 8) {
                    StatementPickField(value: a.currency.uppercased(), label: L.import_field_currency(), mono: true) { open(.currency(a.id)) }
                    if a.type == .credit {
                        StatementPickField(value: a.limit.map { money($0, a.currency) } ?? L.import_optional(), label: L.accounts_credit_limit(),
                                  muted: a.limit == nil, mono: a.limit != nil) { open(.limit(a.id)) }
                    }
                }
            }
            Button { open(.closing(a.id)) } label: {
                HStack {
                    Text(credit ? L.import_owed_on(day: day, currency: i.currency.uppercased())
                         : L.import_balance_on(day: day, currency: i.currency.uppercased()))
                        .kFont(.small).foregroundStyle(c.ink3).frame(maxWidth: .infinity, alignment: .leading)
                    if let b = closing.balance { MoneyText(b, i.currency) } else {
                        Text(L.import_optional()).kFont(.small).foregroundStyle(c.ink3)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            Text(closing.fromFile ? L.import_closing_from_file() : L.import_closing_hint()).kFont(.xs).foregroundStyle(c.ink3)
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, g in
                switch g {
                case .uncovered(let from, let to):
                    Note(text: L.reconcile_gap_uncovered(from: shortDay(from, kosha, theme.locale), to: shortDay(to, kosha, theme.locale)))
                case .opening(let next, let opening, let previous, let closing):
                    Note(text: L.reconcile_gap_opening(next: next, opening: money(opening, i.currency), previous: previous,
                                                       closing: money(closing, i.currency)))
                }
            }
            if let f = foreign, let cur = f.currency {
                Note(text: L.import_foreign(file: f.file, from: cur.uppercased(), to: i.currency.uppercased()))
            }
            ForEach(stmts.filter { ($0.off ?? 0) != 0 }) { s in
                Note(text: L.import_off(file: s.file, amount: money(abs(s.off ?? 0), i.currency)))
            }
            ForEach(stmts) { s in
                Hairline()
                HStack(spacing: 8) {
                    PhIcon(fileIcon(s.source), size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(s.file).kFont(.small).lineLimit(1)
                            if s.byAi && s.source == "pdf" {
                                Sparkle(size: 11)
                                Text(L.reconcile_read_by_ai()).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                            }
                        }
                        Text(span(s.lines).map {
                            L.import_stmt_lines(count: s.lines.count, n: countText(s.lines.count, theme.locale),
                                                from: shortDay($0.first, kosha, theme.locale), to: shortDay($0.last, kosha, theme.locale))
                        } ?? L.import_stmt_no_lines()).kFont(.xs).foregroundStyle(c.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton("arrows-left-right", label: L.import_move_label(file: s.file)) { open(.move(s.id)) }
                    IconButton("x", label: L.import_remove(file: s.file)) { model.remove(s) }
                }
                if s.source == "csv", let layout = s.layout, s.picked != nil {
                    Columns(rows: s.rows, layout: layout, count: s.lines.count,
                            status: columnsStatus(remembered: s.remembered, byAi: s.byAi, confident: s.confident),
                            byAi: s.byAi, startOpen: !s.remembered && !s.confident) { model.columns(s, $0) }
                }
            }
        }
    }
}

// MARK: ImportPayees

private let payeePage = 60

private enum PayeeSheet: Identifiable {
    case name(String), category(String), rest
    var id: String {
        switch self {
        case .name(let g): "n" + g
        case .category(let g): "c" + g
        case .rest: "rest"
        }
    }
}

private struct ImportPayees: View {
    let model: ImportModel
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var tab: String?
    /// Rows sorted while on "To check" stay in view until the tab changes, so a choice doesn't make its row jump away.
    @State private var kept: Set<String> = []
    @State private var shown = payeePage
    @State private var sheet: PayeeSheet?
    @State private var rest = ""

    var body: some View {
        let c = theme.colors
        if let plan = model.review {
            let list = plan.list
            let pairs = plan.pairs
            let total = plan.rows.count
            let open = list.filter { $0.category.isEmpty }
            let tab = self.tab ?? (open.isEmpty ? "all" : "check")
            let rows = tab == "check" ? list.filter { g in g.category.isEmpty || g.raws.contains(where: kept.contains) }
                : tab == "all" ? list : []
            let counted = list.filter { $0.category != "skip" }.reduce(0) { $0 + $1.lines.count } + pairs.count * 2
            let n = { (x: Int) in countText(x, theme.locale) }
            StepPage(
                L.import_check_payees(),
                subtitle: total == 0 ? L.import_review_nothing()
                    : ([L.app_imp_n_new(count: total), L.app_imp_n_payees(count: list.count)]
                       + (pairs.isEmpty ? [] : [L.app_imp_n_transfers(count: pairs.count)])).joined(separator: " · "),
                onBack: { model.step = .accounts },
                footer: {
                    VStack(spacing: 8) {
                        Text(total == 0 ? L.import_nothing_new() : !open.isEmpty
                             ? L.import_without_category(count: open.count, n: n(open.count)) : L.import_ready())
                            .kFont(.xs).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                        KButton(L.import_button(count: counted, n: n(counted))) { model.save() }
                            .disabled(!open.isEmpty || counted == 0 || !kosha.canWrite)
                    }
                }
            ) {
                if total > 0 {
                    Segmented(
                        [("check", L.import_tab_check(n: n(open.count))), ("all", L.import_tab_all(n: n(list.count)))]
                            + (pairs.isEmpty ? [] : [("transfers", L.import_tab_transfers(n: n(pairs.count)))]),
                        selection: Binding(get: { tab }, set: { go($0) }), small: true
                    )
                    if model.naming {
                        HStack(spacing: 6) {
                            Sparkle(size: 12)
                            Text(L.import_naming()).kFont(.xs).foregroundStyle(c.ink3)
                        }
                    }
                    if tab != "transfers" {
                        if rows.isEmpty {
                            HStack(spacing: 8) {
                                PhIcon("check-circle", size: 16, color: c.pos)
                                Text(L.import_all_sorted()).kFont(.small).foregroundStyle(c.ink3)
                            }
                        } else {
                            Card(tight: true) {
                                ForEach(Array(rows.prefix(shown).enumerated()), id: \.element.id) { i, g in
                                    if i > 0 { Hairline() }
                                    PayeeRow(model: model, g: g, onName: { sheet = .name(g.id) }, onCategory: { sheet = .category(g.id) })
                                }
                                if rows.count > shown {
                                    Hairline()
                                    MoreRow(text: L.import_show_more(n: n(min(payeePage, rows.count - shown)))) { shown += payeePage }
                                }
                            }
                        }
                    }
                    if !pairs.isEmpty && tab != "all" {
                        StatementSection(title: L.subs_group_transfers()) {
                            let routes = pairs.reduce(into: [String]()) { r, p in
                                let k = "\(p.0.acct)>\(p.1.acct)"
                                if !r.contains(k) { r.append(k) }
                            }
                            ForEach(routes, id: \.self) { route in
                                let group = pairs.filter { "\($0.0.acct)>\($0.1.acct)" == route }
                                TransferCard(model: model, pairs: group)
                            }
                        }
                    }
                    if tab == "check" && !open.isEmpty { restCard(open) }
                }
            }
            .kSheet(item: $sheet, scrolls: { if case .name = sheet { false } else { true } }()) { s in sheetView(s, list) }
        }
    }

    private func go(_ t: String) {
        tab = t
        kept = []
        shown = payeePage
    }

    private func choose(_ g: PayeeGroup, _ category: String) {
        if (tab ?? "check") == "check" { kept.formUnion(g.raws) }
        model.edit(g, category: category)
    }

    private func restCard(_ open: [PayeeGroup]) -> some View {
        let c = theme.colors
        let cat = model.categories.first { $0.id == rest }
        return Card {
            Text(L.import_rest()).kFont(.head)
            HStack(spacing: 8) {
                StatementPickField(value: cat?.name ?? L.import_rest_placeholder(), icon: cat.map { categoryIconName($0.icon) } ?? "squares-four",
                          muted: rest.isEmpty) { sheet = .rest }
                KButton(L.import_apply(), size: .small) {
                    if let cat { for g in open where cat.isIncome == g.income { choose(g, rest) } }
                    rest = ""
                }
                .disabled(rest.isEmpty)
            }
            Button(L.import_leave_them_out()) { for g in open { choose(g, "skip") } }
                .kFont(.small).foregroundStyle(c.ink2).frame(minHeight: 44).buttonStyle(PressStyle())
        }
    }

    @ViewBuilder
    private func sheetView(_ s: PayeeSheet, _ list: [PayeeGroup]) -> some View {
        let close = { sheet = nil }
        switch s {
        case .name(let id):
            if let g = list.first(where: { $0.id == id }) {
                StatementTextSheet(title: L.import_payee_for(text: g.lines[0].line.description), start: g.payee,
                          onSave: { v in if v != g.payee { model.edit(g, payee: v) } }, close: close)
            }
        case .category(let id):
            if let g = list.first(where: { $0.id == id }) {
                let label = { (name: String) in g.income ? L.import_transfer_from(name: name) : L.import_transfer_to(name: name) }
                let accounts = model.live
                let choices: [Choice<String>] = model.categories.filter { $0.isIncome == g.income }.map { Choice(id: $0.id, title: $0.name) }
                    + accounts.filter { a in !g.lines.contains { $0.acct == a.id } }.map { Choice(id: "t:\($0.id)", title: label(model.info($0).name)) }
                    + model.wallets().filter { w in !accounts.contains { $0.target == w.id } }.map { Choice(id: "w:\($0.id)", title: label($0.name)) }
                    + [Choice(id: "skip", title: L.import_leave_out())]
                ListPicker(L.import_category_for(payee: g.payee), choices: choices, selected: g.category,
                           onPick: { v in choose(g, v); close() }, onClose: close)
            }
        case .rest:
            ListPicker(L.import_rest_label(), choices: model.categories.map { Choice(id: $0.id, title: $0.name) }, selected: rest,
                       onPick: { rest = $0; close() }, onClose: close)
        }
    }
}

private struct PayeeRow: View {
    let model: ImportModel
    let g: PayeeGroup
    let onName: () -> Void
    let onCategory: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let r = span(g.lines.map(\.line))
        let sample = g.lines[0].line.description
        let cat = kosha.meta?.categories.first { $0.id == g.category }
        let transferTo: String? = g.category.hasPrefix("t:")
            ? model.live.first { $0.id == String(g.category.dropFirst(2)) }.map { model.info($0).name }
            : g.category.hasPrefix("w:") ? kosha.wallet(String(g.category.dropFirst(2)))?.name : nil
        HStack(alignment: .top, spacing: 12) {
            Button(action: onName) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(g.payee).kFont(.head).foregroundStyle(g.category == "skip" ? c.ink3 : c.ink)
                        if g.aiPayee { Sparkle(size: 11) }
                    }
                    if sample.lowercased() != g.payee.lowercased() {
                        Text(sample).kFont(.figure(12, .regular)).foregroundStyle(c.ink3).lineLimit(1)
                    }
                    if let r {
                        Text(g.lines.count > 1 ? L.import_payments_range(count: g.lines.count, n: countText(g.lines.count, theme.locale),
                                                                         from: shortDay(r.first, kosha, theme.locale),
                                                                         to: shortDay(r.last, kosha, theme.locale))
                             : shortDay(r.first, kosha, theme.locale)).kFont(.xs).foregroundStyle(c.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if g.category.isEmpty {
                Button(action: onCategory) {
                    HStack(spacing: 6) {
                        PhIcon("plus", size: 16, color: c.warn)
                        Text(L.import_pick_category()).kFont(.small).foregroundStyle(c.warn).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .overlay(Capsule().strokeBorder(c.warn))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            } else {
                Chip(g.category == "skip" ? L.import_leave_out()
                     : transferTo.map { g.income ? L.import_transfer_from(name: $0) : L.import_transfer_to(name: $0) } ?? cat?.name ?? g.category,
                     small: true, action: onCategory) {
                    HStack(spacing: 4) {
                        PhIcon(g.category == "skip" ? "x" : transferTo != nil ? "arrows-left-right" : categoryIconName(cat?.icon), size: 16)
                    }
                }
                .padding(.top, 2)
                if g.aiCategory { Sparkle(size: 11).padding(.top, 10) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The transfers found between two accounts: Not a transfer, or Leave out.
private struct TransferCard: View {
    let model: ImportModel
    let pairs: [(ReviewRow, ReviewRow)]
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let accts = model.live
        let from = pairs[0].0.acct
        let to = pairs[0].1.acct
        let r = span(pairs.map(\.0.line))
        func name(_ acct: String) -> String { accts.first { $0.id == acct }.map { model.info($0).name } ?? "" }
        func colour(_ acct: String) -> Int {
            guard let a = accts.first(where: { $0.id == acct }) else { return 0 }
            return model.info(a).wallet.map { kosha.colorIndex($0.id) } ?? ((kosha.meta?.wallets.count ?? 0) + (accts.firstIndex { $0.id == acct } ?? 0))
        }
        let toCard = accts.first { $0.id == to }.map { model.info($0).type } == .credit
        return Card {
            HStack(spacing: 8) {
                AccountDot(c.account(colour(from)))
                Text(name(from)).kFont(.head)
                PhIcon("arrow-right", size: 14, color: c.ink3)
                AccountDot(c.account(colour(to)))
                Text(name(to)).kFont(.head)
            }
            if let r {
                Text(([pairs.count > 1 ? L.import_payments_range(count: pairs.count, n: countText(pairs.count, theme.locale),
                                                                 from: shortDay(r.first, kosha, theme.locale), to: shortDay(r.last, kosha, theme.locale))
                       : shortDay(r.first, kosha, theme.locale)] + (toCard ? [L.app_imp_card_bill()] : [])).joined(separator: " · "))
                    .kFont(.xs).foregroundStyle(c.ink3)
            }
            HStack(spacing: 8) {
                KButton(L.import_not_transfer(), style: .secondary, size: .small) { model.unpair(pairs) }
                KButton(L.import_leave_out(), style: .secondary, size: .small) { model.leaveOut(pairs) }
            }
        }
    }
}

// MARK: Saving and Done

private struct ImportSaving: View {
    let model: ImportModel
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        StepPage(L.import_importing(), onBack: nil) {
            Card {
                if let error = model.error {
                    Note(text: L.import_failed(error: error.isEmpty ? L.auth_error_offline().trimmingCharacters(in: CharacterSet(charactersIn: ".")) : error))
                    HStack(spacing: 8) {
                        KButton(L.common_try_again(), size: .medium) { model.save() }
                        KButton(L.import_back_to_review(), style: .secondary, size: .medium) { model.step = .review }
                    }
                } else {
                    Text(doingText + "…").kFont(.small)
                    GeometryReader { p in
                        ZStack(alignment: .leading) {
                            Capsule().fill(c.soft)
                            Capsule().fill(c.brand).frame(width: p.size.width * model.progress)
                        }
                    }
                    .frame(height: 6)
                    .accessibilityElement()
                    .accessibilityValue(percent(model.progress, theme.locale, signed: false))
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var doingText: String {
        switch model.doing {
        case .setup(let n): L.import_progress_setup(name: n)
        case .adding(let count, let n): L.import_progress_adding(count: count, n: countText(count, theme.locale), name: n)
        case .transfers: L.import_progress_transfers()
        case .checking(let n): L.import_progress_checking(name: n)
        case .finished, nil: L.common_done()
        }
    }
}

private struct ImportDone: View {
    let model: ImportModel
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var recurring = false

    var body: some View {
        let c = theme.colors
        if let result = model.result {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        VStack(spacing: 12) {
                            PhIcon("tray-arrow-down", size: 32, fill: true, color: c.pos)
                                .frame(width: 72, height: 72)
                                .background(c.pos.opacity(0.12), in: .rect(cornerRadius: 24))
                            Text(L.import_done_title()).kFont(.title).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                            let lines = L.import_transactions(count: result.lines, n: countText(result.lines, theme.locale))
                            let accounts = L.app_imp_n_accounts(count: result.accounts.count)
                            Text(result.transfers > 0
                                 ? L.app_imp_done_summary_transfers(transactions: lines, accounts: accounts,
                                                                    transfers: L.app_imp_n_transfers(count: result.transfers))
                                 : L.app_imp_done_summary(transactions: lines, accounts: accounts))
                                .kFont(.small).foregroundStyle(c.ink2).multilineTextAlignment(.center).padding(.horizontal, 24)
                        }
                        .padding(.top, 56)
                        .padding(.bottom, 12)
                        Card(tight: true) {
                            ForEach(Array(result.accounts.enumerated()), id: \.offset) { i, a in
                                if i > 0 { Hairline() }
                                ListRow {
                                    AccountDot(c.account(kosha.meta?.wallets.firstIndex { $0.id == a.walletId } ?? i), size: 10)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(a.name).lineLimit(1)
                                            if a.isNew { Pill(L.overview_chip_new()) }
                                        }
                                        if let day = a.reconciled {
                                            HStack(spacing: 4) {
                                                PhIcon("seal-check", size: 14, color: c.pos)
                                                Text(L.import_done_matches(day: shortDay(day, kosha, theme.locale))).kFont(.xs).foregroundStyle(c.pos)
                                            }
                                        } else if a.checkPdf {
                                            Text(L.app_imp_check_pdf()).kFont(.xs).foregroundStyle(c.warn)
                                        } else {
                                            Text(L.import_transactions(count: a.lines, n: countText(a.lines, theme.locale))).kFont(.xs).foregroundStyle(c.ink3)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(countText(a.lines, theme.locale)).kFont(.figure(13, .regular)).foregroundStyle(c.ink2)
                                }
                            }
                        }
                        if !result.recurring.isEmpty {
                            Button {
                                if result.recurring.count == 1 { nav.push(.recurringForm(fromPayee: result.recurring[0])) } else { recurring = true }
                            } label: {
                                Card {
                                    HStack(spacing: 12) {
                                        IconTile("arrows-clockwise")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(L.app_imp_recurring(count: result.recurring.count)).kFont(.head)
                                            Text(result.recurring.prefix(3).joined(separator: ", ")).kFont(.xs).foregroundStyle(c.ink3).lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        PhIcon("caret-right", size: 16, color: c.ink3)
                                    }
                                }
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                VStack(spacing: 8) {
                    KButton(L.import_done_overview()) {
                        nav.paths[nav.tab] = []
                        nav.open(.overview)
                    }
                    KButton(L.import_done_transactions(), style: .secondary) {
                        nav.paths[nav.tab] = []
                        nav.openActivity(ActivitySearch())
                    }
                }
                .padding(16)
            }
            .background(c.bg)
            .hideNavigationBar()
            .navigationBarBackButtonHidden(true)
            .kSheet(isPresented: $recurring, scrolls: true) {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(L.app_imp_recurring(count: result.recurring.count)) { recurring = false }
                    ForEach(result.recurring, id: \.self) { payee in
                        ListRow(action: {
                            recurring = false
                            nav.push(.recurringForm(fromPayee: payee))
                        }) {
                            Text(payee).frame(maxWidth: .infinity, alignment: .leading)
                            PhIcon("caret-right", size: 16, color: c.ink3)
                        }
                    }
                }
            }
        }
    }
}
