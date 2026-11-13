import SwiftUI
import Model
import API
import Store
import Design

private enum LoanPicker: String, Identifiable {
    case amount, bank, account, currency, day, due, entry
    var id: String { rawValue }
}

/// A new loan, a repayment (`repayment` with the loan's `id`), or the loan's terms (`id` alone). A new loan or repayment
/// is a new bank movement, an existing entry linked to it, or (new loans only) a balance already outstanding. Saving
/// needs a connection; a request whose answer never came is kept as it was and sent again unchanged, with the same id,
/// so it is saved once. Ported from the Android app's LoanFormScreen and the web's LoanForm.
struct LoanFormScreen: View {
    let id: String?
    let repayment: Bool
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loan: Loan?
    @State private var loadError: String?
    @State private var filled = false
    @State private var direction = "lent"
    @State private var person = ""
    @State private var purpose = ""
    @State private var note = ""
    @State private var source = "new"
    @State private var accountId: String?
    @State private var currency = ""
    @State private var day = Day(2026, 1, 1)
    @State private var due: Day?
    @State private var amount: Int64?
    @State private var bankAmount: Int64?
    @State private var entry: Model.Transaction?
    @State private var picker: LoanPicker?
    /// A request whose answer never came, sent again unchanged (same id and body) by Try again.
    @State private var frozen: LoanRequest?
    @State private var busy = false
    @State private var error: String?

    private var editing: Bool { id != nil && !repayment }

    var body: some View {
        let c = theme.colors
        let title = editing ? L.loans_terms() : repayment ? L.loans_repayment() : L.loans_new()
        Group {
            if id != nil && loan == nil {
                FormPage(title) { EmptyView() } content: {
                    if let loadError { Text(loadError).kFont(.small).foregroundStyle(c.bad) } else { LoadingNote() }
                }
            } else {
                FormPage(title) {
                    KButton(frozen != nil ? L.common_try_again() : L.common_save()) { save() }
                        .disabled(busy || !kosha.canWrite || !(valid || frozen != nil))
                } content: {
                    if !kosha.online { HintLine(icon: "wifi-slash", text: L.loans_offline()) }
                    if let error { Text(error).kFont(.small).foregroundStyle(c.bad) }
                    fields.disabled(frozen != nil || busy)
                }
            }
        }
        .task(id: "\(id ?? "")/\(kosha.meta == nil)") { await fill() }
        .kSheet(item: $picker, scrolls: picker == .entry || picker == .currency) { sheet($0) }
    }

    private func fill() async {
        guard !filled, kosha.meta != nil else { return }
        if let id {
            await loadLoan(kosha, id) { l in
                if let v = l.value?.loan { loan = v } else if !l.refreshing { loadError = l.error ?? L.common_offline_body() }
            }
            guard let loan else { return }
            direction = loan.direction
            currency = loan.currency
            if editing {
                person = loan.person
                purpose = loan.purpose
                note = loan.note
                due = loan.dueDay.flatMap(Day.init)
            }
        }
        accountId = kosha.activeWallets.first { $0.kind != .investment }?.id ?? kosha.activeWallets.first?.id
        if loan == nil { currency = kosha.wallet(accountId)?.currency ?? kosha.primary }
        day = kosha.today
        filled = true
    }

    // MARK: Fields

    private var account: Wallet? { kosha.wallet(accountId) }
    /// A repayment from an account in another currency than the loan's: the bank amount is given apart.
    private var cross: Bool { repayment && account != nil && account?.currency != currency }
    /// Whether the bank movement brings money in.
    private var moneyIn: Bool { repayment ? direction == "lent" : direction == "borrowed" }

    private var valid: Bool {
        let p = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repayment || (!p.isEmpty && p.count <= 200), purpose.count <= 200, note.count <= 2000 else { return false }
        if editing { return true }
        guard let amount, amount > 0 else { return false }
        if repayment, let loan, !LoanMath.validRepayment(amount, remaining: loan.remaining) { return false }
        switch source {
        case "opening": return !repayment
        case "existing": return entry != nil
        default: return account.map { !$0.isArchived } == true && (!cross || (bankAmount ?? 0) > 0)
        }
    }

    @ViewBuilder
    private var fields: some View {
        let c = theme.colors
        let loc = theme.locale
        if !repayment {
            if !editing {
                Segmented([("lent", L.loans_lent()), ("borrowed", L.loans_borrowed())], selection: Binding(get: { direction }, set: {
                    direction = $0
                    if source == "existing" { clearEntry() }
                }), small: true)
            }
            labelled(L.loans_person()) { KField(L.loans_person(), text: $person) }
            labelled(L.loans_purpose()) { KField(loanFieldLabel(L.loans_purpose()), text: $purpose) }
        }
        if editing {
            Card(tight: true) { dueRow }
        } else {
            sourceCard
            HintLine(icon: "info", text: source == "opening" ? L.loans_opening_note() : source == "existing" ? L.loans_link_note()
                     : L.loans_neutral())
            if source == "existing" {
                KButton(L.loans_choose_entry(), style: .secondary, size: .medium, icon: "link") { picker = .entry }
            }
            Card(tight: true) { movementRows(c, loc) }
            if repayment, let loan {
                let left = loan.remaining - (amount ?? 0)
                HStack(spacing: 12) {
                    let shown = inText(max(0, left), currency, theme)
                    Text(figured(L.loans_after(amount: shown), [shown], size: 13, theme)).foregroundStyle(c.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KButton(L.loans_full(), style: .secondary, size: .small) { amount = loan.remaining }
                        .disabled(source == "existing" && !cross)
                }
                if let amount, !LoanMath.validRepayment(amount, remaining: loan.remaining) {
                    Text(L.loans_overpaid()).kFont(.small).foregroundStyle(c.bad)
                }
            }
            if !repayment && source == "new", let amount, let account {
                let money = inText(amount, currency, theme)
                let who = person.trimmingCharacters(in: .whitespaces)
                HintLine(icon: "arrows-left-right", text: direction == "lent"
                         ? L.loans_lent_effect(amount: money, account: account.name, person: who, principal: money)
                         : L.loans_borrowed_effect(amount: money, account: account.name, person: who, principal: money))
            }
        }
        labelled(L.tx_note()) { KField(L.tx_note(), text: $note) }
    }

    /// New movement · Use existing entry · Already outstanding, as radio rows.
    private var sourceCard: some View {
        let sources = [("new", L.loans_new_movement()), ("existing", L.loans_existing())]
            + (repayment ? [] : [("opening", L.loans_opening())])
        return Card(tight: true) {
            ForEach(Array(sources.enumerated()), id: \.element.0) { i, s in
                if i > 0 { Hairline() }
                ListRow(action: {
                    guard source != s.0 else { return }
                    source = s.0
                    clearEntry()
                }) {
                    Text(s.1).frame(maxWidth: .infinity, alignment: .leading)
                    Radio(source == s.0)
                }
                .accessibilityAddTraits(source == s.0 ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func movementRows(_ c: KColors, _ loc: Locale) -> some View {
        let existing = source == "existing"
        if existing, let entry {
            DetailRow(L.loans_account_amount()) {
                Text(entry.accountName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                MoneyText(Int64(entry.amount.magnitude), entry.currency)
            }
            Hairline()
        }
        if source == "new" {
            DetailRow(moneyIn ? L.loans_received_into() : L.loans_paid_from(), action: { picker = .account }) {
                if let account {
                    AccountDot(c.account(kosha.colorIndex(account.id)))
                    Text(account.name).lineLimit(1)
                } else {
                    Text(L.loans_choose_account()).foregroundStyle(c.ink3)
                }
            }
            Hairline()
        }
        if !repayment && source == "opening" {
            DetailRow(L.accounts_currency(), action: { picker = .currency }) { Text(currency.uppercased()).kFont(.num) }
            Hairline()
        }
        let amountLabel = repayment ? (cross ? L.loans_applied() : L.tx_amount())
            : source == "opening" ? L.loans_starting() : L.loans_principal()
        DetailRow(amountLabel, action: existing && !cross ? nil : { picker = .amount }) { amountText(amount, currency) }
        if repayment && source == "new" && cross, let account {
            Hairline()
            DetailRow(L.loans_account_amount(), action: { picker = .bank }) { amountText(bankAmount, account.currency) }
        }
        Hairline()
        DetailRow(L.tx_date(), action: existing ? nil : { picker = .day }) { Text(fmtDay(day, "dMMMy", loc)) }
        if !repayment {
            Hairline()
            dueRow
        }
    }

    private func amountText(_ minor: Int64?, _ currency: String) -> some View {
        Group {
            if let minor { MoneyText(minor, currency) } else {
                Text(Money.format(0, currency, theme.locale)).kFont(.num).foregroundStyle(theme.colors.ink3)
            }
        }
    }

    private var dueRow: some View {
        DetailRow(loanFieldLabel(L.loans_due()), action: { picker = .due }) {
            Text(due.map { fmtDay($0, "dMMMy", theme.locale) } ?? L.loans_no_due())
                .foregroundStyle(due == nil ? theme.colors.ink3 : theme.colors.ink)
        }
    }

    private func labelled(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
            field()
        }
    }

    private func clearEntry() {
        entry = nil
        if source == "existing" {
            amount = nil
            bankAmount = nil
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheet(_ p: LoanPicker) -> some View {
        switch p {
        case .amount:
            KeypadSheet(repayment && cross ? L.loans_applied() : repayment ? L.tx_amount() : L.loans_principal(),
                        minor: amount, currency: currency, onDone: { amount = $0; picker = nil }, close: { picker = nil })
        case .bank:
            KeypadSheet(L.loans_account_amount(), minor: bankAmount, currency: account?.currency ?? currency,
                        onDone: { bankAmount = $0; picker = nil }, close: { picker = nil })
        case .account:
            AccountSheet(title: L.tx_account(), selected: accountId, onPick: { picked in
                accountId = picked
                if !repayment { currency = kosha.wallet(picked)?.currency ?? currency }
                bankAmount = nil
                picker = nil
            }, close: { picker = nil })
        case .currency:
            let codes = Array(Set((kosha.meta?.rates ?? [:]).keys).union([currency])).sorted()
            ListPicker(L.accounts_currency(), choices: codes.map { Choice(id: $0, title: $0.uppercased(), detail: currencyName($0, theme.locale)) },
                       selected: currency, onPick: { currency = $0; picker = nil }, onClose: { picker = nil })
        case .day:
            DateSheet(title: L.tx_date(), day: $day, earliest: repayment ? loan.flatMap { Day($0.day) } : nil, close: { picker = nil })
        case .due:
            VStack(spacing: 8) {
                DateSheet(title: loanFieldLabel(L.loans_due()), day: Binding(get: { due ?? day }, set: { due = $0 }),
                          earliest: Day(loan?.day ?? "") ?? day, close: { picker = nil })
                KButton(L.loans_no_due(), style: .secondary) { due = nil; picker = nil }
            }
        case .entry:
            EntryPicker(moneyIn: moneyIn, after: repayment ? loan?.day : nil, close: { picker = nil }) { t in
                entry = t
                accountId = t.accountId
                day = Day(t.day) ?? day
                bankAmount = Int64(t.amount.magnitude)
                if !repayment { currency = t.currency }
                amount = t.currency == currency ? Int64(t.amount.magnitude) : nil
                picker = nil
            }
        }
    }

    // MARK: Saving

    private func save() {
        guard kosha.canWrite else { return toasts.show(L.common_demo_read_only(), warning: true) }
        guard kosha.online else { error = L.loans_offline(); return }
        let today = kosha.today
        if frozen == nil {
            let start = Day(loan?.day ?? "") ?? day
            let badDay = !editing && (day > today || (repayment && day < start))
            if badDay || (due.map { $0 < start } ?? false) { error = L.loans_invalid_date(); return }
        }
        let request = editing ? nil : frozen ?? LoanRequest(content: makeBody())
        let body = request?.body ?? editBody()
        if case .object(let fields) = body, editing && fields.count <= 1 { return dismiss() }
        frozen = request
        busy = true
        error = nil
        let created = id == nil ? request?.id : nil
        Task {
            do {
                if editing, let id {
                    try await kosha.api.send("PATCH", "/api/v1/loans/\(id)", body: body)
                } else {
                    try await kosha.api.send("POST", repayment ? "/api/v1/loans/\(id ?? "")/repayments" : "/api/v1/loans", body: body)
                }
                busy = false
                kosha.changed()
                toasts.show(L.loans_saved())
                dismiss()
                if let created { nav.push(.loanDetail(id: created)) }
            } catch KoshaError.api(let status, let e) {
                busy = false
                error = e.message
                // A refusal is final: the next save is a new request. A server failure may have saved it.
                if status < 500 { frozen = nil }
            } catch {
                busy = false
                self.error = L.loans_offline()
            }
        }
    }

    /// Only what changed, so an edit never overwrites terms changed elsewhere since.
    private func editBody() -> JSONValue {
        guard let loan, let id else { return .object([:]) }
        var fields: [String: JSONValue?] = ["id": .string(id)]
        let p = person.trimmingCharacters(in: .whitespacesAndNewlines)
        let pu = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if p != loan.person { fields["person"] = .string(p) }
        if pu != loan.purpose { fields["purpose"] = .string(pu) }
        if n != loan.note { fields["note"] = .string(n) }
        if due?.text != loan.dueDay { fields["dueDay"] = due.map { .string($0.text) } ?? .null }
        return jsonBody(fields)
    }

    /// A new loan or repayment; LoanRequest adds its id.
    private func makeBody() -> JSONValue {
        func text(_ s: String) -> JSONValue { .string(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var fields: [String: JSONValue?] = [
            "amount": .int(amount ?? 0), "day": .string(day.text), "note": text(note),
        ]
        if repayment {
            fields["loanId"] = id.map(JSONValue.string)
            if source == "existing" {
                fields["transactionId"] = entry.map { .string($0.id) }
                if cross { fields["accountAmount"] = bankAmount.map(JSONValue.int) }
            } else {
                fields["accountId"] = accountId.map(JSONValue.string)
                if cross { fields["accountAmount"] = bankAmount.map(JSONValue.int) }
            }
        } else {
            fields["direction"] = .string(direction)
            fields["person"] = text(person)
            fields["purpose"] = text(purpose)
            fields["dueDay"] = due.map { .string($0.text) } ?? .null
            fields["source"] = .string(source)
            fields["currency"] = .string(currency)
            if source == "new" { fields["accountId"] = accountId.map(JSONValue.string) }
            if source == "existing" { fields["transactionId"] = entry.map { .string($0.id) } }
        }
        return jsonBody(fields)
    }
}

/// Choose an existing entry: a search, and the entries that can be linked (the right direction, paid, not a transfer,
/// recurring payment, refund or another loan's), newest first.
private struct EntryPicker: View {
    let moneyIn: Bool
    /// A repayment can't come before its loan.
    let after: String?
    let close: () -> Void
    let onPick: (Model.Transaction) -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var query = ""
    @State private var list: [Model.Transaction]?
    @State private var error: String?

    var body: some View {
        let c = theme.colors
        let eligible = (list ?? []).filter { t in t.canLinkLoan(income: moneyIn, since: after) }
        VStack(alignment: .leading, spacing: 8) {
            SheetHeader(L.loans_choose_entry(), onClose: close)
            KField(L.loans_find(), text: $query, icon: "magnifying-glass")
            if let error { Text(error).kFont(.small).foregroundStyle(c.bad) }
            if list == nil && error == nil { LoadingNote() }
            if list != nil && eligible.isEmpty { Text(L.loans_invalid_payment()).kFont(.small).foregroundStyle(c.ink3) }
            VStack(spacing: 0) {
                ForEach(eligible) { t in
                    ListRow(action: { onPick(t) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.payee.isEmpty ? L.tx_untitled() : t.payee).lineLimit(1)
                            Text(loanDay(t.day, theme.locale) + " · " + t.accountName).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        MoneyText(t.amount, t.currency, sign: .always, color: t.amount > 0 ? c.pos : c.ink)
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let page: TransactionList = try await kosha.api.get("/api/v1/transactions", query: [
                    "query": query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(query.prefix(40)),
                    "from": after ?? "2000-01-01", "limit": "100",
                ])
                list = page.transactions
                error = nil
            } catch {
                self.error = (error as? KoshaError)?.errorDescription ?? L.loans_offline()
            }
        }
    }
}
