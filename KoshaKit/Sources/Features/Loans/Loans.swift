import SwiftUI
import Model
import API
import Store
import Design

struct LoansCard: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @State private var loaded = Loaded<LoanList>()
    var body: some View {
        Card {
            LinkRow(icon: "hand-coins", title: L.loans_title(), detail: L.loans_current()) { nav.push(.loans) }
            if let list = loaded.value {
                ForEach(["lent", "borrowed"], id: \.self) { direction in
                    HStack {
                        Text(direction == "lent" ? L.loans_owed_to_you() : L.loans_you_owe())
                        Spacer()
                        MoneyText(list.loans.filter { $0.direction == direction }.reduce(Int64(0)) {
                            $0 + convert($1.remaining, from: $1.currency, to: kosha.display, perUsd: kosha.meta?.rates ?? [:])
                        }, kosha.display)
                    }
                }
                ForEach(list.loans.filter { $0.remaining > 0 && $0.dueDay != nil }.sorted { $0.dueDay! < $1.dueDay! }.prefix(3)) { loan in
                    LinkRow(icon: "calendar-blank", title: loan.person,
                            detail: loan.dueDay.map { $0 < kosha.today.text ? L.loans_overdue(date: $0) : L.loans_due_on(date: $0) }) {
                        nav.push(.loanDetail(id: loan.id))
                    }
                }
            } else if loaded.refreshing { LoadingNote() }
            if let error = loaded.error { Text(error).kFont(.small) }
            if loaded.offline { Text(L.common_offline_body()).kFont(.small) }
        }
        .task(id: kosha.version) {
            await kosha.load("loans", into: { loaded = $0 }) { try await $0.get("/api/v1/loans") }
        }
    }
}

struct LoansScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @State private var loaded = Loaded<LoanList>()
    @State private var status = "open"
    @State private var direction = "all"
    @State private var query = ""
    var body: some View {
        FormPage(L.loans_title()) {
            KButton(L.loans_new()) { nav.push(.loanForm) }.disabled(!kosha.canWrite)
        } content: {
            KField(L.common_search(), text: $query)
            Segmented([("open", L.loans_open()), ("paid", L.loans_paid()), ("all", L.loans_all())], selection: $status)
            Segmented([("all", L.loans_all()), ("lent", L.loans_lent()), ("borrowed", L.loans_borrowed())], selection: $direction)
            Text(L.loans_currency_note()).kFont(.small)
            if let list = loaded.value {
                let loans = list.loans.filter {
                    (status == "all" || ($0.remaining == 0) == (status == "paid")) && (direction == "all" || $0.direction == direction)
                        && (query.isEmpty || ($0.person + " " + $0.purpose + " " + $0.note).localizedCaseInsensitiveContains(query))
                }
                if loans.isEmpty { Text(L.loans_empty()) }
                ForEach(loans) { loan in
                    Card {
                        LinkRow(icon: "hand-coins", title: loan.person, detail: loan.purpose) { nav.push(.loanDetail(id: loan.id)) }
                        Text(loan.direction == "lent" ? L.loans_owed_to_you() : L.loans_you_owe()).kFont(.small)
                        MoneyText(loan.remaining, loan.currency)
                        Text(loan.day).kFont(.small)
                        if let due = loan.dueDay {
                            Text(due < kosha.today.text && loan.remaining > 0 ? L.loans_overdue(date: due) : L.loans_due_on(date: due))
                        }
                    }
                }
            } else if loaded.refreshing { LoadingNote() }
            if let error = loaded.error { Text(error) }
            if loaded.offline { Text(L.common_offline_body()) }
        }
        .task(id: kosha.version) { await kosha.load("loans", into: { loaded = $0 }) { try await $0.get("/api/v1/loans") } }
    }
}

struct LoanDetailScreen: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = Loaded<LoanDetail>()
    @State private var editing = false
    @State private var repaying = false
    @State private var unlink: LoanPayment?
    @State private var removing = false
    @State private var busy = false
    var body: some View {
        FormPage(loaded.value?.loan.person ?? L.loans_title()) { EmptyView() } content: {
            if let d = loaded.value {
                let l = d.loan
                Text(l.purpose)
                Text(l.direction == "lent" ? L.loans_owed_to_you() : L.loans_you_owe())
                Card {
                    figure(l.opening ? L.loans_starting() : L.loans_original(), l.principal, l.currency)
                    figure(L.loans_repaid(), l.repaid, l.currency)
                    figure(L.loans_remaining(), l.remaining, l.currency)
                    Text(l.opening ? L.loans_tracked_since(date: l.day) : l.day)
                    Text(l.dueDay.map { L.loans_due_on(date: $0) } ?? L.loans_no_due())
                    Text(l.note)
                }
                if kosha.canWrite {
                    KButton(L.loans_terms(), style: .secondary) { editing = true }
                    if l.remaining > 0 { KButton(l.direction == "lent" ? L.loans_received() : L.loans_made()) { repaying = true } }
                    if d.canRemove { KButton(L.loans_remove(), style: .secondary) { removing = true } }
                }
                Caption(L.loans_history())
                ForEach(d.payments.sorted { ($0.day, $0.id) < ($1.day, $1.id) }) { p in
                    Card {
                        Text(p.kind == "funding" ? L.loans_original() : L.loans_repayment())
                        Text(p.day + " · " + p.accountName)
                        MoneyText(p.amount, p.currency)
                        figure(L.loans_applied(), p.principal, l.currency)
                        Text(p.note)
                        if kosha.canWrite {
                            KButton(L.loans_unlink(), style: .secondary) { unlink = p }
                                .disabled(busy || !d.canUnlink(p))
                        }
                    }
                }
            } else if loaded.refreshing { LoadingNote() }
            if let error = loaded.error { Text(error) }
            if loaded.offline { Text(L.common_offline_body()) }
        }
        .task(id: kosha.version) { await kosha.load("loan/\(id)", into: { loaded = $0 }) { try await $0.get("/api/v1/loans/\(id)") } }
        .kSheet(isPresented: $editing) {
            if let l = loaded.value?.loan { LoanTerms(loan: l) { editing = false } }
        }
        .kSheet(isPresented: $repaying) {
            if let l = loaded.value?.loan { LoanForm(loan: l) { repaying = false } }
        }
        .kSheet(item: $unlink) { p in
            VStack(spacing: 12) {
                Text(L.loans_unlink_warning())
                CategorySheet(title: L.loans_choose_category(), income: p.amount > 0, picked: nil, onPick: { top, _ in
                    guard !Categories.isSystem(top), !busy else { return }
                    busy = true
                    Task {
                        let result = await kosha.write(toasts, offline: L.loans_offline()) {
                            try await kosha.api.send("POST", "/api/v1/loan-payments/\(p.id)/unlink", body: jsonBody(["categoryId": .string(top)]))
                            return true
                        }
                        busy = false
                        if result == true { unlink = nil; if p.kind == "funding" { dismiss() } }
                    }
                }, close: { unlink = nil })
            }
        }
        .confirmationDialog(L.loans_delete_warning(), isPresented: $removing, titleVisibility: .visible) {
            Button(L.loans_remove(), role: .destructive) {
                Task {
                    let result = await kosha.write(toasts, offline: L.loans_offline()) {
                        try await kosha.api.send("DELETE", "/api/v1/loans/\(id)"); return true
                    }
                    if result == true { dismiss() }
                }
            }
        }
    }
    private func figure(_ label: String, _ value: Int64, _ currency: String) -> some View {
        HStack { Text(label); Spacer(); MoneyText(value, currency) }
    }
}
