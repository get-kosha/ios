import SwiftUI
import Model
import API
import Store
import Design

private enum LoanPick: String, Identifiable {
    case amount, bankAmount, account, day, due, entry, currency
    var id: String { rawValue }
}

private struct LoanDraft: Codable, Equatable {
    var direction: String
    var source: String
    var person: String
    var purpose: String
    var note: String
    var amount: Int64?
    var bankAmount: Int64?
    var account: String
    var currency: String?
    var day: String?
    var due: String?
    var entry: Model.Transaction?
    var request: LoanRequest?
}

struct LoanForm: View {
    var loan: Loan? = nil
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @State private var direction = "lent"
    @State private var source = "new"
    @State private var person = ""
    @State private var purpose = ""
    @State private var note = ""
    @State private var amount: Int64?
    @State private var bankAmount: Int64?
    @State private var account = ""
    @State private var openingCurrency: String?
    @State private var day: Day?
    @State private var due: Day?
    @State private var entry: Model.Transaction?
    @State private var picker: LoanPick?
    @State private var busy = false
    // Retain the exact submitted payload after an uncertain failure; edits get a new request identity.
    @State private var request: LoanRequest?
    @State private var restored = false
    @State private var completed = false
    private var draftKey: String { "loan-draft/" + (loan?.id ?? "new") }
    private var draft: LoanDraft {
        LoanDraft(direction: direction, source: source, person: person, purpose: purpose, note: note,
                  amount: amount, bankAmount: bankAmount, account: account, currency: openingCurrency, day: day?.text, due: due?.text, entry: entry, request: request)
    }
    private func restore() {
        guard !restored else { return }
        if let d: LoanDraft = kosha.cache.read(draftKey) {
            direction = d.direction; source = d.source; person = d.person; purpose = d.purpose; note = d.note
            amount = d.amount; bankAmount = d.bankAmount; account = d.account; openingCurrency = d.currency
            day = (d.day ?? d.request?.content["day"]?.string).flatMap(Day.init) ?? kosha.today; due = d.due.flatMap(Day.init); entry = d.entry; request = d.request
        } else {
            account = kosha.activeWallets.first?.id ?? ""
            day = kosha.today
            openingCurrency = kosha.primary
        }
        restored = true
    }

    private var currency: String { loan?.currency ?? (source == "opening" ? openingCurrency ?? kosha.primary : source == "existing" ? entry?.currency ?? kosha.primary : kosha.wallet(account)?.currency ?? kosha.primary) }
    private var bankCurrency: String { (source == "existing" ? entry?.currency : kosha.wallet(account)?.currency) ?? currency }
    private var chosenDay: Day { day ?? kosha.today }
    private var income: Bool { loan.map { $0.direction == "lent" } ?? (direction == "borrowed") }

    var body: some View {
        FormPage(loan == nil ? L.loans_new() : L.loans_repayment()) {
            KButton(L.common_save()) { save() }.disabled(busy || !kosha.canWrite)
        } content: {
            if loan == nil {
                Segmented([("lent", L.loans_lent()), ("borrowed", L.loans_borrowed())], selection: Binding(get: { direction }, set: { direction = $0; entry = nil; amount = nil }))
                KField(L.loans_person(), text: $person)
                KField(L.loans_purpose(), text: $purpose)
            }
            Segmented(([ ("new", L.loans_new_movement()), ("existing", L.loans_existing()) ]
                + (loan == nil ? [("opening", L.loans_opening())] : [])), selection: Binding(get: { source }, set: { source = $0; entry = nil; amount = nil }))
            Text(source == "opening" ? L.loans_opening_note() : source == "existing" ? L.loans_link_note() : L.loans_neutral()).kFont(.small)
            if source == "existing" {
                KButton(entry.map { $0.payee + " · " + $0.day } ?? L.loans_choose_entry(), style: .secondary) { picker = .entry }
            } else if source == "opening" {
                KButton(L.accounts_currency() + " · " + currency.uppercased(), style: .secondary) { picker = .currency }
            } else {
                KButton(kosha.wallet(account)?.name ?? L.loans_choose_account(), style: .secondary) { picker = .account }
            }
            KButton(L.loans_principal() + " · " + Money.format(amount ?? 0, currency, Locale(identifier: L.language)), style: .secondary) { picker = .amount }
                .disabled(source == "existing" && (loan == nil || entry?.currency == currency))
            if let loan {
                KButton(L.loans_full(), style: .secondary) { amount = loan.remaining }
                    .disabled(source == "existing" && entry?.currency == currency)
                if let amount, amount <= loan.remaining {
                    Text(L.loans_after(amount: Money.format(loan.remaining - amount, currency, Locale(identifier: L.language))))
                }
                if bankCurrency != currency && source == "new" {
                    KButton(L.loans_account_amount() + " · " + Money.format(bankAmount ?? 0, bankCurrency, Locale(identifier: L.language)), style: .secondary) { picker = .bankAmount }
                }
            }
            if source != "existing" {
                KButton(chosenDay.text, style: .secondary) { picker = .day }
            }
            if loan == nil {
                KButton(due?.text ?? L.loans_due(), style: .secondary) { picker = .due }
                if due != nil { KButton(L.loans_no_due(), style: .secondary) { due = nil } }
                if source == "new" {
                    let value = Money.format(amount ?? 0, currency, Locale(identifier: L.language))
                    Text(direction == "lent"
                         ? L.loans_lent_effect(amount: value, account: kosha.wallet(account)?.name ?? "", person: person, principal: value)
                         : L.loans_borrowed_effect(amount: value, account: kosha.wallet(account)?.name ?? "", person: person, principal: value)).kFont(.small)
                }
            }
            KField(L.tx_note(), text: $note)
        }
        .task { restore() }
        .onChange(of: draft) { _, value in
            if restored && !completed { kosha.cache.write(draftKey, value) }
        }
        .kSheet(item: $picker) { p in
            switch p {
            case .amount, .bankAmount:
                KeypadSheet(p == .amount ? L.loans_principal() : L.loans_account_amount(), minor: p == .amount ? amount : bankAmount,
                            currency: p == .amount ? currency : bankCurrency,
                            onDone: { if p == .amount { amount = $0 } else { bankAmount = $0 }; picker = nil }, close: { picker = nil })
            case .currency:
                ListPicker(L.accounts_currency(), choices: (kosha.meta?.rates.keys.sorted() ?? [kosha.primary]).map {
                    Choice(id: $0, title: $0.uppercased(), detail: currencyName($0, Locale(identifier: L.language)))
                }, selected: currency, onPick: { openingCurrency = $0; picker = nil }, onClose: { picker = nil })
            case .account:
                AccountSheet(title: L.loans_choose_account(), selected: account, onPick: { account = $0; picker = nil }, close: { picker = nil })
            case .day:
                DateSheet(title: L.tx_date(), day: Binding(get: { chosenDay }, set: { day = $0 }), close: { picker = nil })
            case .due:
                DateSheet(title: L.loans_due(), day: Binding(get: { due ?? chosenDay }, set: { due = $0 }), close: { picker = nil })
            case .entry:
                LoanEntrySheet(income: income, currency: nil, since: loan?.day) { t in
                    entry = t; day = Day(t.day); account = t.accountId
                    if loan == nil || t.currency == currency { amount = abs(t.amount) } else { amount = nil }
                    picker = nil
                } close: { picker = nil }
            }
        }
    }

    private func save() {
        guard kosha.canWrite, !busy else { return }
        guard kosha.online else { return toasts.show(L.loans_offline(), warning: true) }
        guard let amount, amount > 0, amount <= 9_007_199_254_740_991 else { return toasts.show(L.loans_invalid_payment(), warning: true) }
        if let loan, amount > loan.remaining { return toasts.show(L.loans_overpaid(), warning: true) }
        guard chosenDay <= kosha.today, loan == nil || chosenDay.text >= loan!.day, due == nil || due! >= chosenDay else {
            return toasts.show(L.loans_invalid_date(), warning: true)
        }
        if source == "existing" {
            guard let entry, entry.canLinkLoan(income: income, currency: loan == nil ? currency : nil, since: loan?.day),
                  (loan != nil && entry.currency != currency) || abs(entry.amount) == amount else {
                return toasts.show(L.loans_invalid_payment(), warning: true)
            }
        }
        if source == "new" && !kosha.activeWallets.contains(where: { $0.id == account }) { return toasts.show(L.loans_choose_account(), warning: true) }
        if loan != nil && source == "new" && bankCurrency != currency && (bankAmount ?? 0) <= 0 {
            return toasts.show(L.loans_invalid_payment(), warning: true)
        }
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        if loan == nil && (name.isEmpty || name.count > 200 || purpose.count > 200) { return toasts.show(L.loans_invalid_payment(), warning: true) }
        guard note.count <= 2000 else { return toasts.show(L.loans_invalid_payment(), warning: true) }
        var fields: [String: JSONValue?] = ["amount": .int(amount), "day": .string(chosenDay.text), "note": .string(note)]
        if source == "existing" { fields["transactionId"] = entry.map { .string($0.id) } }
        if source == "new" { fields["accountId"] = .string(account) }
        if let loan {
            fields["loanId"] = .string(loan.id)
            if bankCurrency != currency && source == "new" { fields["accountAmount"] = bankAmount.map(JSONValue.int) }
        } else {
            fields.merge(["person": .string(name), "purpose": .string(purpose), "direction": .string(direction),
                          "source": .string(source), "currency": .string(currency), "dueDay": due.map { .string($0.text) } ?? .null]) { _, new in new }
        }
        let content = jsonBody(fields)
        var next = request ?? LoanRequest(content: content)
        next.update(content)
        request = next
        kosha.cache.write(draftKey, draft)
        let payload = next.body
        let path = loan.map { "/api/v1/loans/\($0.id)/repayments" } ?? "/api/v1/loans"
        busy = true
        Task {
            let result = await kosha.write(toasts, offline: L.loans_offline()) {
                try await kosha.api.send("POST", path, body: payload); return true
            }
            busy = false
            if result == true {
                completed = true
                kosha.cache.write(draftKey, Optional<LoanDraft>.none)
                close()
            }
        }
    }
}

private struct LoanEntrySheet: View {
    let income: Bool
    let currency: String?
    let since: String?
    let pick: (Model.Transaction) -> Void
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @State private var query = ""
    @State private var loaded = Loaded<TransactionList>()
    var body: some View {
        VStack(spacing: 12) {
            SheetHeader(L.loans_choose_entry(), onClose: close)
            KField(L.loans_find(), text: $query)
            ScrollView {
                if let list = loaded.value {
                    ForEach(list.transactions.filter { $0.canLinkLoan(income: income, currency: currency, since: since) && $0.day <= kosha.today.text }) { t in
                        ListRow(action: { pick(t) }) {
                            Text(t.payee + " · " + t.day + " · " + t.accountName)
                            Spacer()
                            MoneyText(t.amount, t.currency)
                        }
                    }
                }
                if let error = loaded.error { Text(error) }
                if loaded.offline { Text(L.common_offline_body()) }
            }
        }
        .task(id: query) {
            let q = query
            await kosha.load("loan-entries/\(q)", into: { loaded = $0 }) {
                try await $0.get("/api/v1/transactions", query: ["query": q, "limit": "100"])
            }
        }
    }
}

struct LoanTerms: View {
    let loan: Loan
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @State private var person = ""
    @State private var purpose = ""
    @State private var note = ""
    @State private var due: Day?
    @State private var date = false
    @State private var filled = false
    @State private var busy = false
    var body: some View {
        VStack(spacing: 12) {
            SheetHeader(L.loans_terms(), onClose: close)
            KField(L.loans_person(), text: $person)
            KField(L.loans_purpose(), text: $purpose)
            KField(L.tx_note(), text: $note)
            KButton(due?.text ?? L.loans_due(), style: .secondary) { date = true }
            KButton(L.loans_no_due(), style: .secondary) { due = nil }
            KButton(L.common_save()) {
                guard !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      person.count <= 200, purpose.count <= 200, note.count <= 2000,
                      due == nil || due!.text >= loan.day else { return toasts.show(L.loans_invalid_payment(), warning: true) }
                var fields: [String: JSONValue?] = [:]
                if person != loan.person { fields["person"] = .string(person) }
                if purpose != loan.purpose { fields["purpose"] = .string(purpose) }
                if note != loan.note { fields["note"] = .string(note) }
                if due?.text != loan.dueDay { fields["dueDay"] = due.map { .string($0.text) } ?? .null }
                let payload = jsonBody(fields)
                busy = true
                Task {
                    let result = await kosha.write(toasts, offline: L.loans_offline()) {
                        try await kosha.api.send("PATCH", "/api/v1/loans/\(loan.id)", body: payload); return true
                    }
                    busy = false
                    if result == true { close() }
                }
            }.disabled(busy || !kosha.canWrite)
        }
        .onAppear {
            guard !filled else { return }
            person = loan.person; purpose = loan.purpose; note = loan.note; due = loan.dueDay.flatMap(Day.init); filled = true
        }
        .kSheet(isPresented: $date) { DateSheet(title: L.loans_due(), day: Binding(get: { due ?? kosha.today }, set: { due = $0 }), close: { date = false }) }
    }
}

struct LoanFormScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { LoanForm { dismiss() } }
}
