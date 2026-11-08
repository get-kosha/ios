import SwiftUI
import Model
import API
import Store
import Design

// Reconcile (06-accounts-ReconcileStart, ReconcileTick, ReconcileDone): check an account against the bank's statement,
// by its closing balance alone or line by line from the statement file, as the web's reconcile.tsx does. Matching,
// planning and the difference hints are the pure helpers in Statement.swift; reading the file happens on the server.
// Ported from the Android app's ReconcileModel.kt and ReconcileScreens.kt.

/// A statement file read for a reconciliation. A CSV keeps its text, so a changed column choice re-reads it.
struct Statement: Sendable {
    var name: String
    var source: String
    var lines: [Line]
    var withdrawn: [String] = []
    var file: Picked?
    var rows: [[String]] = []
    var layout: Layout?
    var signature: String?
    var remembered = false
    var byAi = false
    var confident = true
    /// The opening balance as printed, when the file gives one.
    var opening: Int64?
    /// For a PDF read by AI: how far its lines miss its closing balance.
    var off: Int64?
}

/// What the person chose for a line missing from Kosha. `category` is a category id or "transfer:<account id>".
struct LinePick: Sendable {
    var payee: String?
    var category: String?
    var skip = false
}

/// A reconciliation just finished, for the Done step.
struct DoneInfo: Sendable {
    let id: String
    let entries: Int
    let adjustment: Int64
    let day: String
}

/// One reconciliation, from picking the account to Done (the web's reconcile.tsx Session). The account's entries come
/// from GET /api/app/reconcile through the cache, and read again after every change.
/// ponytail: a half-done reconciliation lives as long as this screen; the web also keeps a draft in the browser.
@MainActor @Observable
final class ReconcileModel {
    enum Step { case start, tick, done }

    var step = Step.start
    private(set) var accountId: String?
    var data: Loaded<ReconcileData>?
    var day = ""
    /// The statement's closing balance as printed: for a card, what is owed.
    var balance: Int64?
    var ticks: [String: Bool] = [:]
    var statement: Statement?
    var reading: String?
    var picks: [String: LinePick] = [:]
    var tidy: [String: Tidy] = [:]
    @ObservationIgnored var tidyAsked: String?
    var notSame: Set<String> = []
    var openGroups: Set<String> = []
    var shownAll = false
    var focus: [String] = []
    var busy: String?
    var ai: Explained?
    var done: DoneInfo?
    /// The ids chosen for lines added to Kosha, by bank ref, so adding them again after a failure saves each once.
    @ObservationIgnored var added: [String: String] = [:]

    func select(_ id: String) {
        if id == accountId { return }
        accountId = id
        balance = nil
        ticks = [:]
        statement = nil
        picks = [:]
        tidy = [:]
        notSame = []
        ai = nil
        done = nil
        data = nil
    }

    /// A new statement replaces what the last one decided.
    func loaded(_ s: Statement?) {
        statement = s
        picks = [:]
        notSame = []
        ai = nil
    }

    /// A CSV's latest line sets the statement day, and its running balance the closing and opening balances.
    func openCsv(_ s: Statement, credit: Bool) {
        let b = csvBalances(s.lines, card: credit)
        var st = s
        st.opening = b.opening
        loaded(st)
        if s.lines.isEmpty { return }
        if let d = b.closingDay { day = d }
        if let c = b.closing { balance = c }
    }
}

/// Investments are valued, not reconciled: a broker statement shows market value, which Kosha keeps as gains.
private func reconcilable(_ type: AccountType) -> Bool { type != .investment }

struct ReconcileScreen: View {
    let accountId: String?
    @State private var model = ReconcileModel()
    @State private var picking = false
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts

    var body: some View {
        Group {
            switch model.step {
            case .start: ReconcileStart(model: model) { pick() }
            case .tick: ReconcileTick(model: model) { pick() }
            case .done: ReconcileDone(model: model)
            }
        }
        .onAppear {
            if model.day.isEmpty { model.day = kosha.today.text }
            if model.accountId == nil, let first = accountId
                ?? kosha.activeWallets.first(where: { reconcilable($0.kind) })?.id {
                model.select(first)
            }
        }
        .task(id: "\(model.accountId ?? "")/\(kosha.version)") {
            guard let id = model.accountId else { return }
            await kosha.load("reconcile/\(id)", into: { (l: Loaded<ReconcileData>) in
                if model.accountId == id { model.data = l }
            }) { api in try await api.get("/api/app/reconcile", query: ["walletId": id]) }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: statementTypes(pdf: kosha.meta?.aiFlags.statements == true)) { result in
            if case .success(let url) = result { Task { await readStatement(url) } }
        }
    }

    /// Reading a file is a request that only accounts which can change things may make.
    private func pick() {
        if kosha.canWrite { picking = true } else { toasts.show(L.common_demo_read_only(), warning: true) }
    }

    /// Reads one statement into the reconciliation, then shows the ticks.
    private func readStatement(_ url: URL) async {
        guard let d = model.data?.value, let m = kosha.meta else { return }
        let acc = d.account
        model.reading = url.lastPathComponent
        defer { model.reading = nil }
        do {
            let file = try Picked.read(url)
            if file.pdf && !m.aiFlags.statements {
                toasts.show(L.reconcile_pdf_unsupported(), warning: true)
                return
            }
            let r = try await kosha.api.read(file, card: acc.credit, walletId: acc.id)
            switch r.format {
            case "pdf":
                if let cur = r.currency, cur != acc.currency {
                    toasts.show(L.reconcile_currency_mismatch(statementCurrency: cur.uppercased(), account: acc.name,
                                                             currency: acc.currency.uppercased()), warning: true)
                }
                model.loaded(Statement(name: file.name, source: "pdf", lines: r.lines, byAi: true, opening: r.opening, off: r.off))
                if let to = r.to { model.day = to }
                if let c = r.closing { model.balance = c }
            case "ofx", "qfx":
                if r.lines.isEmpty {
                    toasts.show(L.reconcile_ofx_empty(), warning: true)
                    return
                }
                model.loaded(Statement(name: file.name, source: "ofx", lines: r.lines, withdrawn: r.withdrawn))
                if let day = r.closingDay { model.day = day }
                // Cards report what's owed as a negative balance.
                if let c = r.closing { model.balance = acc.credit ? -c : c }
            default:
                let remembered = r.signature.map { d.layouts[$0] != nil } ?? false
                var read = r
                var byAi = false
                if !remembered && !r.isConfident && m.aiFlags.statements, let l = await kosha.api.aiLayout(r) {
                    read = try await kosha.api.read(file, card: acc.credit, layout: l, walletId: acc.id)
                    byAi = true
                }
                model.openCsv(Statement(
                    name: file.name, source: "csv", lines: read.lines, file: file, rows: read.rows, layout: read.layout,
                    signature: read.signature, remembered: remembered, byAi: byAi, confident: read.isConfident || byAi
                ), credit: acc.credit)
            }
            model.step = .tick
        } catch KoshaError.api(_, let e) {
            toasts.show(e.message.isEmpty ? L.reconcile_read_failed() : e.message, warning: true)
        } catch let e as KoshaError where e.retryable {
            toasts.show(L.auth_error_offline(), warning: true)
        } catch {
            toasts.show(L.reconcile_read_failed(), warning: true)
        }
    }
}

// MARK: ReconcileStart

private struct ReconcileStart: View {
    let model: ReconcileModel
    let read: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: StartSheet?

    enum StartSheet: String, Identifiable { case day, balance; var id: String { rawValue } }

    var body: some View {
        let c = theme.colors
        let wallets = kosha.activeWallets.filter { reconcilable($0.kind) }
        StepPage(L.reconcile_title(), subtitle: L.reconcile_picker_sub(), onBack: { dismiss() }) {
            if wallets.isEmpty {
                Card { Text(L.reconcile_picker_empty()).kFont(.small).foregroundStyle(c.ink2) }
            } else {
                Card(tight: true) {
                    ForEach(Array(wallets.enumerated()), id: \.element.id) { i, w in
                        if i > 0 { Hairline() }
                        let on = w.id == model.accountId
                        ListRow(action: { model.select(w.id) }) {
                            AccountDot(c.account(kosha.colorIndex(w.id)), size: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.name)
                                Text(w.reconciledDay.map { L.reconcile_reconciled_to(day: shortDay($0, kosha, theme.locale)) }
                                     ?? L.reconcile_never_reconciled())
                                    .kFont(.small).foregroundStyle(c.ink3)
                            }
                            Spacer(minLength: 8)
                            Radio(on)
                        }
                        .frame(minHeight: 60)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                if let d = model.data?.value {
                    figures(d)
                } else if model.data?.offline == true {
                    Note(text: L.common_offline_body(), icon: "cloud-slash", tone: c.ink2)
                } else {
                    Skeleton(height: 120)
                }
            }
        }
        .kSheet(item: $sheet) { s in
            if let acc = model.data?.value?.account {
                switch s {
                case .day: DaySheet(title: L.reconcile_statement_date(), day: Binding(get: { model.day }, set: { model.day = $0 })) { sheet = nil }
                case .balance:
                    SignedAmountSheet(title: balanceLabel(acc), start: model.balance, currency: acc.currency, signed: true,
                                      onDone: { model.balance = $0 }) { sheet = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func figures(_ d: ReconcileData) -> some View {
        let c = theme.colors
        let money = moneyWords(theme)
        let acc = d.account
        let limit = acc.creditLimit ?? 0
        let fromKosha = { (v: Int64) in acc.credit ? limit - v : v }
        let today = kosha.today.text
        // The quick check: the bank shows the same balance as Kosha, so everything up to today is reconciled.
        let upToToday = d.open.filter { $0.isPaid && $0.day <= today }
        let quick = d.reconciled + upToToday.reduce(0) { $0 + $1.amount }
        Card {
            Text(L.app_rcn_quick_title()).kFont(.head)
            Text(acc.credit ? L.reconcile_quick_owed(amount: money(fromKosha(quick), acc.currency))
                 : L.reconcile_quick_balance(amount: money(fromKosha(quick), acc.currency)))
                .kFont(.small).foregroundStyle(c.ink2)
            HStack(spacing: 8) {
                KButton(L.reconcile_same_as_bank(), style: .secondary, size: .medium) {
                    Task {
                        model.busy = "finish"
                        let body = FinishBody(walletId: acc.id, statementDay: today, balance: quick, ids: upToToday.map(\.id), adjust: false)
                        if let f: Finished = await kosha.write(toasts, offline: L.auth_error_offline(), {
                            try await kosha.api.post("/api/app/reconcile/finish", body)
                        }) {
                            model.done = DoneInfo(id: f.id, entries: upToToday.count, adjustment: f.adjustment, day: today)
                            model.step = .done
                        }
                        model.busy = nil
                    }
                }
                .disabled(model.busy != nil || !kosha.canWrite)
                KButton(L.accounts_fix_balance(), style: .secondary, size: .medium) { nav.push(.fixBalance(id: acc.id)) }
                    .fixedSize()
            }
        }
        Card {
            Text(L.app_rcn_statement_title()).kFont(.head)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.reconcile_statement_date()).kFont(.small).foregroundStyle(c.ink3).lineLimit(1)
                    PickField(value: shortDay(model.day, kosha, theme.locale), icon: "calendar-blank") { sheet = .day }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(balanceLabel(acc)).kFont(.small).foregroundStyle(c.ink3).lineLimit(1)
                    PickField(value: money(model.balance ?? fromKosha(quick), acc.currency), muted: model.balance == nil, mono: true) {
                        sheet = .balance
                    }
                }
            }
            KButton(L.app_rcn_tick_off(), size: .medium) { model.step = .tick }
            KButton(model.reading.map { L.reconcile_reading(file: $0) } ?? L.app_rcn_import_instead(), style: .soft,
                    size: .medium, icon: "file-arrow-up", action: read)
                .disabled(model.reading != nil)
            Text(kosha.meta?.aiFlags.statements == true ? L.app_rcn_formats_pdf() : L.app_rcn_formats())
                .kFont(.xs).foregroundStyle(c.ink3)
        }
    }
}

private func balanceLabel(_ acc: ReconcileData.Acc) -> String {
    acc.credit ? L.reconcile_owed_label(currency: acc.currency.uppercased())
        : L.reconcile_balance_label(currency: acc.currency.uppercased())
}

/// The hint words, from the reconcile_hint_* messages.
private let hintWords = HintWords(
    anEntry: { L.reconcile_hint_an_entry() },
    exactUnticked: { L.reconcile_hint_exact_unticked(name: $0, amount: $1) },
    exactTicked: { L.reconcile_hint_exact_ticked(name: $0, amount: $1) },
    wrongWayIn: { L.reconcile_hint_wrong_way_in(name: $0) },
    wrongWayOut: { L.reconcile_hint_wrong_way_out(name: $0) },
    swapped: { L.reconcile_hint_swapped(name: $0, meant: $1, amount: $2) },
    decimal: { L.reconcile_hint_decimal(name: $0, meant: $1, amount: $2) },
    pair: { L.reconcile_hint_pair(first: $0, second: $1) },
    duplicate: { L.reconcile_hint_duplicate(name: $0) },
    late: { L.reconcile_hint_late() },
    lookOut: { L.reconcile_hint_look_out(amount: $0) },
    lookIn: { L.reconcile_hint_look_in(amount: $0) }
)

// MARK: ReconcileTick

private let page = 5

private enum TickSheet: Identifiable {
    case day, balance
    case payee(ref: String, value: String)
    case category(ref: String, income: Bool, value: String)

    var id: String {
        switch self {
        case .day: "day"
        case .balance: "balance"
        case .payee(let r, _): "p" + r
        case .category(let r, _, _): "c" + r
        }
    }
}

/// What the tick screen works out from the account's entries, the statement and the person's choices.
@MainActor
private struct TickCalc {
    let m: Meta
    let d: ReconcileData
    let model: ReconcileModel
    let plan: Plan
    let lines: [Line]
    let missing: [Line]
    let earlier: [ReconcileData.Row]
    let period: [ReconcileData.Row]
    let after: [ReconcileData.Row]
    let ticked: [ReconcileData.Row]
    let cleared: Int64
    let statement: Int64?
    var diff: Int64? { statement.map { $0 - cleared } }
    let categories: [MetaCategory]
    let guessing: Bool

    init(m: Meta, d: ReconcileData, model: ReconcileModel) {
        self.m = m
        self.d = d
        self.model = model
        let a = d.account
        let limit = a.creditLimit ?? 0
        // Statement figures are as the bank prints them: a balance, or for a card what is owed.
        statement = model.balance.map { a.credit ? limit - $0 : $0 }
        let lines = model.statement?.lines ?? []
        self.lines = lines
        categories = m.categories.filter { !$0.isArchived && $0.parentId == nil && !Categories.isNeutral($0.id) }
        guessing = m.pref("suggest_category", "1") == "1"
        let day = model.day
        // What matches, what's missing and what counts as ticked: the same plan the public API uses.
        let entry = { (e: ReconcileData.Row) in TickCalc.entry(e, m) }
        let plan = planReconciliation(
            lines: lines, open: d.open.map(entry), done: d.done.map(entry), statementDay: day,
            lastDay: d.history.first?.statementDay, rejected: model.notSame, withdrawn: model.statement?.withdrawn ?? []
        )
        self.plan = plan
        missing = plan.missing.map { lines[$0] }
        earlier = d.open.filter { $0.day <= day && !plan.inPeriod(entry($0)) }
        period = d.open.filter { plan.inPeriod(entry($0)) }
        after = d.open.filter { $0.day > day }
        let ticked = d.open.filter { model.ticks[$0.id] ?? plan.ticks(entry($0)) }
        self.ticked = ticked
        cleared = d.reconciled + ticked.reduce(0) { $0 + $1.amount }
    }

    static func name(_ e: ReconcileData.Row, _ m: Meta) -> String {
        if e.transferId == nil {
            let n = e.name.isEmpty ? m.categories.first { $0.id == e.categoryId }?.name ?? "" : e.name
            return n.isEmpty ? L.reconcile_no_payee() : n
        }
        if let account = m.wallets.first(where: { $0.id == e.counterWalletId })?.name {
            return e.amount < 0 ? L.reconcile_transfer_to_name(account: account) : L.reconcile_transfer_from_name(account: account)
        }
        return e.amount < 0 ? L.reconcile_transfer_to_other() : L.reconcile_transfer_from_other()
    }

    static func entry(_ e: ReconcileData.Row, _ m: Meta) -> Entry {
        Entry(id: e.id, day: e.day, amount: e.amount, name: name(e, m), ref: e.bankRef, paid: e.paid ?? 1)
    }

    func name(_ e: ReconcileData.Row) -> String { TickCalc.name(e, m) }
    func isTicked(_ e: ReconcileData.Row) -> Bool { model.ticks[e.id] ?? plan.ticks(TickCalc.entry(e, m)) }

    struct RowPick { let payee: String, category: String; let skip: Bool, aiPayee: Bool, aiCategory: Bool }

    func basePayee(_ l: Line) -> String {
        if let p = l.payee, !p.trimmingCharacters(in: .whitespaces).isEmpty { return p }
        return payeeFor(l.description, known: m.titles, aliases: d.aliases)
    }

    func row(_ l: Line) -> RowPick {
        let p = model.picks[l.ref ?? ""] ?? LinePick()
        let key = descriptorKey(l.description)
        let ai = model.tidy[key]
        let payee = p.payee ?? (d.aliases[key] != nil ? basePayee(l) : ai?.payee ?? basePayee(l))
        func fits(_ id: String?) -> String? {
            id.flatMap { x in categories.contains { $0.id == x && $0.isIncome == (l.amount > 0) } ? x : nil }
        }
        let ruled = guessing ? fits(guessCategory(payee, m.payeeMatches)) ?? fits(guessCategory(l.description, m.payeeMatches)) : nil
        let category = p.category ?? ruled ?? (guessing ? fits(ai?.categoryId) : nil) ?? ""
        return RowPick(
            payee: payee, category: category, skip: p.skip,
            aiPayee: p.payee == nil && ai != nil && payee == ai?.payee && ai?.payee != basePayee(l),
            aiCategory: p.category == nil && ruled == nil && !category.isEmpty && category == ai?.categoryId
        )
    }

    func hints(_ fmt: (Int64) -> String) -> [Hint] {
        guard let diff, diff != 0 else { return [] }
        var out: [Hint] = []
        let st = model.statement
        let last = d.history.first
        let missingTotal = missing.filter { !row($0).skip }.reduce(0) { $0 + $1.amount }
        let openingGap: Int64 = {
            guard let o = st?.opening, let last, !d.account.credit, o != last.printed else { return 0 }
            return o - last.printed
        }()
        if openingGap != 0, let o = st?.opening, let last {
            out.append(Hint(text: L.reconcile_hint_opening_gap(opening: fmt(o), closing: fmt(last.printed)), ids: []))
        }
        if let single = missing.first(where: { $0.amount == diff }), missing.count > 1 {
            out.append(Hint(text: L.reconcile_hint_single_missing(payee: row(single).payee, amount: fmt(single.amount)), ids: []))
        }
        if !missing.isEmpty {
            out.append(Hint(text: missingTotal == diff ? L.reconcile_hint_missing_closes(count: missing.count)
                            : L.reconcile_hint_missing_count(count: missing.count, amount: fmt(missingTotal)), ids: []))
        }
        for id in plan.withdrawn {
            if let e = d.open.first(where: { $0.id == id }) {
                out.append(Hint(text: L.reconcile_hint_withdrawn(name: name(e), amount: fmt(e.amount)), ids: [id]))
            }
        }
        for g in plan.splits {
            let entries = g.entries.compactMap { id in d.open.first { $0.id == id } }
            guard let first = entries.first else { continue }
            out.append(Hint(
                text: g.lines.count == 1
                    ? L.reconcile_hint_split(amount: fmt(lines[g.lines[0]].amount), names: entries.map(name).joined(separator: " + "))
                    : L.reconcile_hint_split_lines(name: name(first), amounts: g.lines.map { fmt(lines[$0].amount) }.joined(separator: " + ")),
                ids: g.entries
            ))
        }
        for p in plan.close {
            if let e = d.open.first(where: { $0.id == p.entry }) {
                out.append(Hint(text: L.reconcile_hint_close(name: name(e), kosha: fmt(e.amount), statement: fmt(lines[p.line].amount)),
                                ids: [e.id]))
            }
        }
        let item = { (e: ReconcileData.Row) in Item(id: e.id, amount: e.amount, day: e.day, name: name(e)) }
        // Its last-resort "look for a fee" only helps when nothing above already explains the gap.
        out += differenceHints(diff, ticked: ticked.map(item), unticked: (earlier + period).filter { !isTicked($0) }.map(item),
                               statementDay: model.day, money: fmt, words: hintWords)
            .filter { !$0.ids.isEmpty || (missing.isEmpty && plan.close.isEmpty && openingGap == 0) }
        return Array(out.prefix(6))
    }
}

private struct ReconcileTick: View {
    let model: ReconcileModel
    let read: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var sheet: TickSheet?

    var body: some View {
        if let m = kosha.meta, let d = model.data?.value {
            content(TickCalc(m: m, d: d, model: model))
        } else {
            Skeleton(height: 120).padding(16).frame(maxHeight: .infinity, alignment: .top).background(theme.colors.bg)
        }
    }

    private func content(_ t: TickCalc) -> some View {
        let c = theme.colors
        let a = t.d.account
        let cur = a.currency
        let money = moneyWords(theme)
        let fmt = { (v: Int64) in money(v, cur) }
        let limit = a.creditLimit ?? 0
        let fromKosha = { (v: Int64) in a.credit ? limit - v : v }
        let last = t.d.history.first
        let st = model.statement
        let hints = t.hints(fmt)
        let canAskAi = t.m.aiFlags.statements && t.m.pref("ai_share_payee", "1") == "1" && t.m.pref("ai_share_amount", "1") == "1"
        // Reconciled entries should still add up to the last statement, unless one was changed since.
        let drift = last.map { t.d.reconciled - $0.balance } ?? 0
        return StepPage(
            L.reconcile_account_title(account: a.name),
            subtitle: last.map { L.reconcile_last_reconciled(day: shortDay($0.statementDay, kosha, theme.locale)) } ?? L.reconcile_check_each(),
            onBack: { model.step = .start },
            footer: { footer(t) }
        ) {
            fileRow(st)
            if let st, st.source == "csv", let layout = st.layout, let file = st.file {
                Card {
                    Columns(rows: st.rows, layout: layout, count: st.lines.count,
                            status: columnsStatus(remembered: st.remembered, byAi: st.byAi, confident: st.confident),
                            byAi: st.byAi, startOpen: !st.remembered && !st.confident) { layout in
                        Task {
                            do {
                                let r = try await kosha.api.read(file, card: a.credit, layout: layout, walletId: a.id)
                                var next = st
                                next.lines = r.lines
                                next.rows = r.rows
                                next.layout = layout
                                next.remembered = false
                                next.byAi = false
                                model.openCsv(next, credit: a.credit)
                            } catch {
                                toasts.show((error as? KoshaError)?.errorDescription ?? L.auth_error_offline(), warning: true)
                            }
                        }
                    }
                }
            }
            if drift != 0, let last {
                Note(text: L.reconcile_drift(day: shortDay(last.statementDay, kosha, theme.locale), amount: fmt(a.credit ? -drift : drift)))
            }
            if let off = st?.off, off != 0 { Note(text: L.reconcile_pdf_off(amount: fmt(abs(off)))) }

            // Statement, ticked and difference.
            Card {
                HStack(alignment: .top, spacing: 8) {
                    figure(a.credit ? L.reconcile_figure_statement_owed() : L.reconcile_figure_statement(),
                           sub: shortDay(model.day, kosha, theme.locale), onTap: { sheet = .balance }, onSub: { sheet = .day }) {
                        if let s = t.statement { MoneyText(fromKosha(s), cur) } else { Text("—").kFont(.num) }
                    }
                    figure(a.credit ? L.reconcile_figure_ticked_owed() : L.reconcile_figure_ticked(),
                           sub: L.reconcile_ticked_count(count: countText(t.ticked.count, theme.locale))) {
                        MoneyText(fromKosha(t.cleared), cur)
                    }
                    figure(L.reconcile_figure_difference()) {
                        switch t.diff {
                        case nil: Text("—").kFont(.num)
                        case 0: Text(L.reconcile_figure_none()).kFont(.num).foregroundStyle(c.pos)
                        case let diff?: MoneyText(a.credit ? -diff : diff, cur, color: c.bad)
                        }
                    }
                }
            }

            // Finding the difference.
            if let diff = t.diff, diff != 0, !hints.isEmpty || canAskAi {
                Card {
                    HStack {
                        Text(L.reconcile_finding_title()).kFont(.head).frame(maxWidth: .infinity, alignment: .leading)
                        if canAskAi {
                            Chip(L.reconcile_ask_ai(), small: true, action: { if model.busy == nil { askAi(t) } }) {
                                if model.busy == "ai" { ProgressView().controlSize(.mini) } else { Sparkle() }
                            }
                        }
                    }
                    if let ai = model.ai {
                        HStack(alignment: .top, spacing: 8) {
                            Sparkle().padding(.top, 2)
                            Text(ai.summary).kFont(.small)
                        }
                        ForEach(ai.suggestions, id: \.self) { s in hintRow(s.text, s.ids, icon: nil, t) }
                    }
                    ForEach(hints, id: \.self) { h in hintRow(h.text, h.ids, icon: "magnifying-glass", t) }
                }
            }

            if !t.missing.isEmpty { missingSection(t, fmt: fmt) }
            if !t.plan.close.isEmpty { closeSection(t, fmt: fmt) }
            entriesSection(t, fmt: fmt)
        }
        .task(id: "\(st?.name ?? ""):\(t.lines.count):\(t.missing.count)") { await askTidy(t) }
        .kSheet(item: $sheet, scrolls: { if case .category = sheet { true } else { false } }()) { s in sheetView(s, t) }
    }

    // MARK: Pieces

    @ViewBuilder
    private func fileRow(_ st: Statement?) -> some View {
        let c = theme.colors
        HStack(spacing: 8) {
            if let reading = model.reading {
                Chip(L.reconcile_reading(file: reading), soft: true, small: true)
            } else if let st {
                Chip(st.name + " · " + L.reconcile_file_lines(count: st.lines.count), soft: true, small: true) {
                    if st.byAi { Sparkle(size: 12) } else { PhIcon(fileIcon(st.source), size: 16) }
                }
                .layoutPriority(-1)
                Button(L.reconcile_another_file(), action: read).kFont(.small).foregroundStyle(c.ink2)
                    .frame(minHeight: 48).buttonStyle(PressStyle())
                IconButton("x", label: L.common_remove()) { model.loaded(nil) }
            } else {
                Chip(L.app_rcn_import_instead(), soft: true, small: true, action: read) { PhIcon("file-arrow-up", size: 16) }
            }
            Spacer(minLength: 0)
        }
    }

    private func figure<V: View>(_ label: String, sub: String? = nil, onTap: (() -> Void)? = nil, onSub: (() -> Void)? = nil,
                                 @ViewBuilder value: () -> V) -> some View {
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).kFont(.xs).foregroundStyle(c.ink3)
            value().contentShape(Rectangle()).onTapGesture { onTap?() }
            if let sub {
                Text(sub).kFont(.xs).foregroundStyle(c.ink3).onTapGesture { onSub?() }
                    .accessibilityAddTraits(onSub != nil ? .isButton : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAction { onTap?() }
    }

    private func hintRow(_ text: String, _ ids: [String], icon: String?, _ t: TickCalc) -> some View {
        let c = theme.colors
        return HStack(alignment: .top, spacing: 8) {
            if let icon { PhIcon(icon, size: 16, color: c.ink3).padding(.top, 2) }
            Text(text).kFont(.small).frame(maxWidth: .infinity, alignment: .leading)
            if !ids.isEmpty {
                Button(L.reconcile_show()) { show(ids, t) }.kFont(.small).foregroundStyle(c.ink2)
                    .frame(minHeight: 44).buttonStyle(PressStyle())
            }
        }
    }

    @Environment(\.scrollTo) private var scrollTo

    /// A hinted entry can sit in a collapsed group, so Show opens that group first.
    private func show(_ ids: [String], _ t: TickCalc) {
        if t.earlier.contains(where: { ids.contains($0.id) }) { model.openGroups.insert("earlier") }
        if t.after.contains(where: { ids.contains($0.id) }) { model.openGroups.insert("after") }
        if t.period.dropFirst(page).contains(where: { ids.contains($0.id) }) { model.shownAll = true }
        model.focus = ids
    }

    private func missingSection(_ t: TickCalc, fmt: @escaping (Int64) -> String) -> some View {
        let c = theme.colors
        let count = t.missing.filter { !t.row($0).skip }.count
        return Section(title: L.reconcile_missing_title(count: "\(t.missing.count)"),
                       aside: model.busy == "tidy" ? L.reconcile_naming_payees() : nil) {
            Card {
                ForEach(Array(t.missing.enumerated()), id: \.offset) { i, l in
                    if i > 0 { Hairline() }
                    let r = t.row(l)
                    let ref = l.ref ?? ""
                    let cat = t.m.categories.first { $0.id == r.category }
                    let other = r.category.hasPrefix("transfer:")
                        ? t.m.wallets.first { $0.id == String(r.category.dropFirst("transfer:".count)) } : nil
                    VStack(alignment: .leading, spacing: 8) {
                        Button { pick(ref) { $0.skip.toggle() } } label: {
                            HStack(spacing: 10) {
                                Tick(!r.skip)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(l.description) · \(shortDay(l.day, kosha, theme.locale))").kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                                    Text(r.payee).kFont(.head).foregroundStyle(r.skip ? c.ink3 : c.ink)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                MoneyText(l.amount, t.d.account.currency, color: l.amount > 0 ? c.pos : c.ink)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityHint(r.skip ? L.reconcile_include_line() : L.reconcile_leave_out_line())
                        if !r.skip {
                            HStack(spacing: 8) {
                                Chip(L.reconcile_payee(), small: true, action: { sheet = .payee(ref: ref, value: r.payee) }) {
                                    PhIcon("pencil-simple", size: 16)
                                }
                                Chip(cat?.name ?? other.map {
                                    l.amount < 0 ? L.reconcile_transfer_to(account: $0.name) : L.reconcile_transfer_from(account: $0.name)
                                } ?? L.reconcile_pick_category(), small: true,
                                     action: { sheet = .category(ref: ref, income: l.amount > 0, value: r.category) }) {
                                    PhIcon(cat.map { categoryIconName($0.icon) } ?? (other != nil ? "arrows-left-right" : "plus"), size: 16,
                                           color: r.category.isEmpty ? c.warn : c.ink2)
                                }
                                if r.aiCategory || r.aiPayee { Sparkle(size: 11) }
                            }
                            .padding(.leading, 32)
                        }
                    }
                }
                Text(L.reconcile_saving_teaches()).kFont(.xs).foregroundStyle(c.ink3)
                KButton(L.reconcile_add_to_kosha(count: "\(count)"), size: .medium) { Task { await addMissing(t) } }
                    .disabled(count == 0 || model.busy != nil || !kosha.canWrite)
            }
        }
    }

    private func closeSection(_ t: TickCalc, fmt: @escaping (Int64) -> String) -> some View {
        Section(title: L.reconcile_close_title(count: "\(t.plan.close.count)")) {
            ForEach(t.plan.close, id: \.self) { p in
                if let e = t.d.open.first(where: { $0.id == p.entry }) {
                    let l = t.lines[p.line]
                    Card {
                        HStack(spacing: 10) {
                            IconTile(e.transferId != nil ? "arrows-left-right"
                                     : categoryIconName(t.m.categories.first { $0.id == e.categoryId }?.icon))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name(e)).kFont(.head)
                                Text(p.kind == .corrected
                                     ? L.reconcile_corrected_detail(statement: fmt(l.amount), statementDay: shortDay(l.day, kosha, theme.locale),
                                                                    kosha: fmt(e.amount))
                                     : L.reconcile_close_detail(kosha: fmt(e.amount), koshaDay: shortDay(e.day, kosha, theme.locale),
                                                                statement: fmt(l.amount), statementDay: shortDay(l.day, kosha, theme.locale)))
                                    .kFont(.xs).foregroundStyle(theme.colors.ink3)
                            }
                        }
                        HStack(spacing: 8) {
                            if e.transferId == nil {
                                KButton(L.reconcile_use_amount(amount: fmt(l.amount)), size: .medium) {
                                    Task {
                                        model.busy = e.id
                                        let body = AmountChanges(transactions: [AmountChange(id: e.id, amount: l.amount)])
                                        await kosha.write(toasts, offline: L.auth_error_offline(), {
                                            try await kosha.api.send("PATCH", "/api/v1/transactions", body: body)
                                        })
                                        model.busy = nil
                                    }
                                }
                                .disabled(model.busy != nil || !kosha.canWrite)
                            }
                            KButton(L.reconcile_not_same(), style: .secondary, size: .medium) { model.notSame.insert(l.ref ?? "") }
                        }
                    }
                }
            }
        }
    }

    private func entriesSection(_ t: TickCalc, fmt: @escaping (Int64) -> String) -> some View {
        let c = theme.colors
        let closeIds = Set(t.plan.close.map(\.entry))
        let withdrawn = Set(t.plan.withdrawn)
        var splitLines: [String: [Int]] = [:]
        for p in t.plan.pairs where p.kind == .split { splitLines[p.entry, default: []].append(p.line) }
        let shown = model.shownAll ? t.period : Array(t.period.prefix(page))
        let st = model.statement
        let day = model.day
        func note(_ e: ReconcileData.Row) -> String? {
            if closeIds.contains(e.id) { return L.reconcile_note_amount_differs() }
            if withdrawn.contains(e.id) { return L.reconcile_note_withdrawn() }
            if let ls = splitLines[e.id] {
                return ls.count == 1 ? L.reconcile_note_part_of(amount: fmt(t.lines[ls[0]].amount)) : L.reconcile_note_split_lines()
            }
            if st != nil && !t.plan.matched.contains(e.id) {
                return e.day > addDays(day, -3) ? L.reconcile_note_next_statement() : L.reconcile_note_not_on_statement()
            }
            return e.isPaid ? nil : L.reconcile_note_still_due()
        }
        return Group {
            Section(title: st != nil ? L.reconcile_in_kosha() : L.reconcile_tick_title(),
                    aside: L.reconcile_ticked_count(count: countText(t.ticked.count, theme.locale))) {
                Card(tight: true) {
                    if !t.earlier.isEmpty {
                        let open = model.openGroups.contains("earlier")
                        MoreRow(text: L.reconcile_before_group(count: "\(t.earlier.count)"), sub: L.reconcile_before_hint(),
                                open: open, head: true) { toggleGroup("earlier") }
                        if open { ForEach(t.earlier) { e in Hairline(); entryRow(e, t, note: nil) } }
                    }
                    if t.period.isEmpty && t.earlier.isEmpty {
                        Text(L.reconcile_nothing(day: shortDay(day, kosha, theme.locale))).kFont(.small).foregroundStyle(c.ink3).padding(16)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                        if i > 0 || !t.earlier.isEmpty { Hairline() }
                        entryRow(e, t, note: note(e))
                    }
                    if t.period.count > shown.count {
                        Hairline()
                        MoreRow(text: L.import_show_more(n: countText(t.period.count - shown.count, theme.locale))) { model.shownAll = true }
                    }
                }
            }
            if !t.after.isEmpty {
                let open = model.openGroups.contains("after")
                Card(tight: true) {
                    MoreRow(text: L.reconcile_after_group(day: shortDay(day, kosha, theme.locale), count: "\(t.after.count)"),
                            sub: L.reconcile_after_hint(), open: open, head: true) { toggleGroup("after") }
                    if open { ForEach(t.after) { e in Hairline(); entryRow(e, t, note: nil) } }
                }
            }
        }
    }

    private func toggleGroup(_ g: String) {
        if model.openGroups.contains(g) { model.openGroups.remove(g) } else { model.openGroups.insert(g) }
    }

    /// An entry to tick: tick, payee and day (or a note in warn), amount. A hinted one is highlighted and scrolled to.
    private func entryRow(_ e: ReconcileData.Row, _ t: TickCalc, note: String?) -> some View {
        let c = theme.colors
        let ticked = t.isTicked(e)
        let focus = model.focus.contains(e.id)
        return Button { model.ticks[e.id] = !ticked } label: {
            HStack(spacing: 12) {
                Tick(ticked)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name(e))
                    Text(note ?? shortDay(e.day, kosha, theme.locale)).kFont(.xs).foregroundStyle(note != nil ? c.warn : c.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MoneyText(e.amount, t.d.account.currency,
                          color: !ticked ? c.ink3 : e.transferId != nil ? c.ink2 : e.amount > 0 ? c.pos : c.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: theme.dims.row)
            .background(focus ? c.warn.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .id(e.id)
        .accessibilityAddTraits(ticked ? .isSelected : [])
        .onChange(of: model.focus) { _, f in if f.first == e.id { scrollTo?.action(e.id) } }
    }

    @ViewBuilder
    private func footer(_ t: TickCalc) -> some View {
        let busy = model.busy != nil
        if t.statement == nil {
            KButton(L.reconcile_enter_balance()) { sheet = .balance }
        } else if t.diff == 0 {
            KButton(L.reconcile_finish()) { Task { await finish(t, adjust: false) } }.disabled(busy || !kosha.canWrite)
        } else if let diff = t.diff {
            let cur = t.d.account.currency
            KButton(L.reconcile_finish_with_correction(amount: moneyWords(theme)(diff, cur)), style: .secondary) {
                Task { await finish(t, adjust: true) }
            }
            .disabled(busy || !kosha.canWrite)
        }
    }

    @ViewBuilder
    private func sheetView(_ s: TickSheet, _ t: TickCalc) -> some View {
        let a = t.d.account
        switch s {
        case .day: DaySheet(title: L.reconcile_statement_date(), day: Binding(get: { model.day }, set: { model.day = $0 })) { sheet = nil }
        case .balance:
            SignedAmountSheet(title: balanceLabel(a), start: model.balance, currency: a.currency, signed: true,
                              onDone: { model.balance = $0 }) { sheet = nil }
        case .payee(let ref, let value):
            TextSheet(title: L.reconcile_payee(), start: value, onSave: { v in pick(ref) { $0.payee = v } }) { sheet = nil }
        case .category(let ref, let income, let value):
            let others = t.m.wallets.filter { !$0.isArchived && $0.id != a.id }
            ListPicker(
                L.reconcile_pick_category(),
                choices: t.categories.filter { $0.isIncome == income }.map { Choice(id: $0.id, title: $0.name) }
                    + others.map { Choice(id: "transfer:\($0.id)", title: income ? L.reconcile_transfer_from(account: $0.name)
                                          : L.reconcile_transfer_to(account: $0.name)) },
                selected: value,
                onPick: { v in pick(ref) { $0.category = v }; sheet = nil },
                onClose: { sheet = nil }
            )
        }
    }

    // MARK: Actions

    private func pick(_ ref: String, _ change: (inout LinePick) -> Void) {
        var p = model.picks[ref] ?? LinePick()
        change(&p)
        model.picks[ref] = p
    }

    /// AI tidies the payee names and categories Kosha couldn't work out itself, once per statement.
    private func askTidy(_ t: TickCalc) async {
        let m = t.m
        guard m.aiFlags.statements, m.pref("ai_share_payee", "1") == "1", let st = model.statement, !t.missing.isEmpty else { return }
        let sig = "\(st.name):\(t.lines.count)"
        if model.tidyAsked == sig { return }
        model.tidyAsked = sig
        var todo: [String: TidyItem] = [:]
        var order: [String] = []
        for l in t.missing {
            let key = descriptorKey(l.description)
            if key.isEmpty || t.d.aliases[key] != nil { continue }
            let r = t.row(l)
            let unknownPayee = l.payee == nil && !m.titles.contains(r.payee)
            if (unknownPayee || r.category.isEmpty) && todo[key] == nil {
                todo[key] = TidyItem(key: key, text: l.description, amount: l.amount)
                order.append(key)
            }
        }
        if todo.isEmpty { return }
        model.busy = "tidy"
        // Without it, Kosha's own names stand.
        if let got: [String: Tidy] = try? await kosha.api.post("/api/app/import/tidy",
                                                               TidyBody(items: order.prefix(300).compactMap { todo[$0] })) {
            model.tidy = got
        }
        if model.busy == "tidy" { model.busy = nil }
    }

    private func askAi(_ t: TickCalc) {
        guard let diff = t.diff else { return }
        Task {
            model.busy = "ai"
            let near = addDays(t.plan.periodStart, -30)
            let ex = { (e: ReconcileData.Row) in ExplainItem(id: e.id, day: e.day, amount: e.amount, name: t.name(e)) }
            let body = ExplainBody(
                statementDay: model.day, diff: diff, currency: t.d.account.currency,
                ticked: t.ticked.filter { $0.day >= near }.suffix(400).map(ex),
                unticked: (t.earlier + t.period).filter { !t.isTicked($0) && $0.day >= near }.suffix(400).map(ex),
                missing: t.missing.prefix(400).map { ExplainLine(day: $0.day, amount: $0.amount, text: $0.description) },
                close: t.plan.close.map { ExplainClose(id: $0.entry, statementAmount: t.lines[$0.line].amount) }
            )
            do {
                model.ai = try await kosha.api.post("/api/app/reconcile/explain", body)
            } catch KoshaError.api(_, let e) {
                toasts.show(e.message.isEmpty ? L.reconcile_ask_failed() : e.message, warning: true)
            } catch {
                toasts.show(L.auth_error_offline(), warning: true)
            }
            model.busy = nil
        }
    }

    private func addMissing(_ t: TickCalc) async {
        let a = t.d.account
        let chosen = t.missing.filter { !t.row($0).skip }
        let unsorted = chosen.filter { t.row($0).category.isEmpty }.count
        if unsorted > 0 {
            toasts.show(L.reconcile_pick_category_first(count: unsorted), warning: true)
            return
        }
        model.busy = "add"
        let plain = chosen.filter { !t.row($0).category.hasPrefix("transfer:") }
        let moves = chosen.filter { t.row($0).category.hasPrefix("transfer:") }
        let entries = plain.compactMap { l -> BankEntry? in
            guard let ref = l.ref else { return nil }
            let r = t.row(l)
            let id = model.added[ref] ?? UUID().uuidString.lowercased()
            model.added[ref] = id
            return BankEntry(id: id, accountId: a.id, payee: r.payee.trimmingCharacters(in: .whitespaces), amount: l.amount,
                             categoryId: r.category, day: l.day, bankRef: ref)
        }
        // Transfers, the payee names and the CSV's columns go through the import endpoint, which remembers them.
        let aliases = chosen.map { Alias(key: descriptorKey($0.description), payee: t.row($0).payee.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.key.isEmpty && !$0.payee.isEmpty }
        let st = model.statement
        let layouts = st.flatMap { s in
            s.source == "csv" ? s.layout.flatMap { l in s.signature.map { [LayoutMemory(signature: $0, layout: l)] } } : nil
        } ?? []
        let newLines = moves.compactMap { l -> NewLine? in
            guard let ref = l.ref else { return nil }
            let r = t.row(l)
            return NewLine(day: l.day, amount: l.amount, name: "", note: r.payee.trimmingCharacters(in: .whitespaces),
                           transferWith: String(r.category.dropFirst("transfer:".count)), ref: ref)
        }
        let ok: Bool? = await kosha.write(toasts, offline: L.auth_error_offline(), {
            if !entries.isEmpty { try await kosha.api.send("POST", "/api/v1/transactions", body: BankEntries(transactions: entries)) }
            if !newLines.isEmpty || !aliases.isEmpty || !layouts.isEmpty {
                try await kosha.api.send("POST", "/api/app/import/lines",
                                         body: LinesBody(walletId: a.id, layouts: layouts, aliases: aliases, lines: newLines))
            }
            return true
        })
        if ok != nil { toasts.show(L.reconcile_added(count: chosen.count, account: a.name)) }
        model.busy = nil
    }

    private func finish(_ t: TickCalc, adjust: Bool) async {
        guard let bal = t.statement else { return }
        let a = t.d.account
        model.busy = "finish"
        let ids = t.ticked.map(\.id)
        let body = FinishBody(walletId: a.id, statementDay: model.day, balance: bal, ids: ids, adjust: adjust)
        if let f: Finished = await kosha.write(toasts, offline: L.auth_error_offline(), {
            try await kosha.api.post("/api/app/reconcile/finish", body)
        }) {
            model.done = DoneInfo(id: f.id, entries: ids.count, adjustment: f.adjustment, day: model.day)
            model.statement = nil
            model.ticks = [:]
            model.step = .done
        }
        model.busy = nil
    }
}

// MARK: ReconcileDone

private struct ReconcileDone: View {
    let model: ReconcileModel
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let d = model.data?.value
        let money = moneyWords(theme)
        let cur = d?.account.currency ?? ""
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    PhIcon("seal-check", size: 32, fill: true, color: c.pos)
                        .frame(width: 72, height: 72)
                        .background(c.pos.opacity(0.12), in: .rect(cornerRadius: 24))
                        .padding(.top, 72)
                    Text(L.reconcile_done_title(account: d?.account.name ?? "")).kFont(.title).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if let done = model.done {
                        Text([
                            L.reconcile_done_checked(count: done.entries, day: shortDay(done.day, kosha, theme.locale),
                                                     n: countText(done.entries, theme.locale)),
                            done.adjustment != 0 ? L.reconcile_done_correction(amount: money(done.adjustment, cur)) : nil,
                            L.reconcile_done_marked(),
                        ].compactMap { $0 }.joined(separator: " "))
                            .kFont(.small).foregroundStyle(c.ink2).multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    if let d, !d.history.isEmpty {
                        Card(tight: true) {
                            Text(L.reconcile_past()).kFont(.head).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                            ForEach(Array(d.history.enumerated()), id: \.element.id) { i, h in
                                Hairline()
                                ListRow {
                                    PhIcon("seal-check", size: 18, color: i == 0 ? c.pos : c.ink3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortDay(h.statementDay, kosha, theme.locale))
                                        Text([
                                            L.reconcile_history_entries(count: h.entries),
                                            h.adjustment != 0 ? L.reconcile_corrected_by(amount: money(h.adjustment, cur)) : nil,
                                        ].compactMap { $0 }.joined(separator: " · ")).kFont(.xs).foregroundStyle(c.ink3)
                                    }
                                    Spacer(minLength: 8)
                                    // Only the latest can be undone.
                                    if i == 0 {
                                        KButton(L.common_undo(), style: .secondary, size: .small) { undo(h.id) }
                                            .disabled(model.busy != nil || !kosha.canWrite)
                                    }
                                }
                            }
                        }
                        .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 16)
            }
            KButton(L.reconcile_back_to_accounts()) {
                nav.paths[nav.tab] = []
                nav.open(.accounts)
            }
            .padding(16)
        }
        .background(c.bg)
        .hideNavigationBar()
        .navigationBarBackButtonHidden(true)
    }

    private func undo(_ id: String) {
        Task {
            model.busy = "undo"
            let ok: Bool? = await kosha.write(toasts, offline: L.auth_error_offline(), {
                try await kosha.api.send("POST", "/api/app/reconcile/undo", body: IdBody(id: id))
                return true
            })
            if ok != nil {
                toasts.show(L.reconcile_undone())
                model.done = nil
                model.step = .start
            }
            model.busy = nil
        }
    }
}
