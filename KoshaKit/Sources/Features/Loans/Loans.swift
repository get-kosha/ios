import SwiftUI
import Model
import API
import Store
import Design

/// The cached loans list (list_loans), every date, repaid ones included.
@MainActor
func loadLoans(_ kosha: Kosha, into update: @MainActor (Loaded<Loans>) -> Void) async {
    await kosha.load("loans", into: update) { try await $0.get("/api/v1/loans") }
}

/// The cached loan and its bank history (get_loan).
@MainActor
func loadLoan(_ kosha: Kosha, _ id: String, into update: @MainActor (Loaded<LoanDetail>) -> Void) async {
    await kosha.load("loan/\(id)", into: update) { try await $0.get("/api/v1/loans/\(id)") }
}

/// Loans: the Accounts | Loans switch, the all-date totals, All · Owed to you · You owe, Open · Paid back · All, and
/// one card of loans, overdue first. Ported from the Android app's Loans.kt and the web's routes/_app/loans.tsx.
struct LoansScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var loaded = Loaded<Loans>()
    @State private var direction = "all"
    @State private var status = "open"
    @State private var query = ""

    var body: some View {
        let c = theme.colors
        let today = kosha.today.text
        Page(L.loans_title(), actions: {
            IconButton("plus", label: L.loans_new(), solid: true, color: c.ink) { nav.push(.loanForm()) }
        }) {
            AccountLoansSwitch(loans: true)
            if loaded.offline { Text(L.common_offline_body()).kFont(.small).foregroundStyle(c.ink3) }
            if let error = loaded.error { Text(error).kFont(.small).foregroundStyle(c.bad) }
            if let loans = loaded.value?.loans {
                Card { LoanTotals(loans: loans) }
                Segmented([("all", L.loans_all()), ("lent", L.loans_owed_to_you()), ("borrowed", L.loans_you_owe())],
                          selection: $direction, small: true)
                HStack(spacing: 8) {
                    ForEach([("open", L.loans_open()), ("paid", L.loans_paid()), ("all", L.loans_all())], id: \.0) { value, label in
                        Chip(label, on: status == value, small: true) { status = value }
                    }
                }
                if loans.count > 6 { KField(L.common_search(), text: $query, icon: "magnifying-glass") }
                let shown = LoanMath.sorted(visible(loans), today: today)
                Card(tight: true) {
                    if shown.isEmpty {
                        VStack(spacing: 16) {
                            PhIcon("hand-coins", size: 28, color: c.ink3)
                            Text(L.loans_empty()).kFont(.small).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                            KButton(L.loans_new(), size: .medium) { nav.push(.loanForm()) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 32)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, loan in
                        if i > 0 { Hairline() }
                        LoanRow(loan: loan, today: today) { nav.push(.loanDetail(id: loan.id)) }
                    }
                }
                Text(L.loans_currency_note()).kFont(.xs).foregroundStyle(c.ink3).padding(.horizontal, 2)
            } else if loaded.refreshing {
                Skeleton(height: 120)
                Skeleton(height: 200)
            } else {
                LoadingNote()
            }
        }
        .task(id: kosha.version) { await loadLoans(kosha) { loaded = $0 } }
    }

    private func visible(_ loans: [Loan]) -> [Loan] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return loans.filter { l in
            (direction == "all" || l.direction == direction)
                && (status == "all" || (l.remaining == 0) == (status == "paid"))
                && (q.isEmpty || "\(l.person) \(l.purpose)".lowercased().contains(q))
        }
    }
}

/// A person, how and when, the purpose, the state of repayment, the due date, and what is still owed.
private struct LoanRow: View {
    let loan: Loan
    let today: String
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 12) {
                PhIcon("hand-coins", size: 18)
                    .frame(width: 36, height: 36)
                    .background(c.soft, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loan.person).kFont(.head).lineLimit(1)
                    Text((loan.lent ? L.loans_lent() : L.loans_borrowed()) + " · " + loanDay(loan.day, theme.locale))
                        .kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                    if !loan.purpose.isEmpty { Text(loan.purpose).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1) }
                    LoanState(loan: loan)
                    LoanDueText(loan: loan, today: today)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MoneyText(loan.remaining, loan.currency)
                PhIcon("caret-right", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Paid back (in green), Partly paid back, or No repayments yet.
private struct LoanState: View {
    let loan: Loan
    @Environment(\.kosha) private var theme

    var body: some View {
        let text = switch loan.status {
        case .paid: L.loans_paid()
        case .partial: L.loans_partial()
        case .unpaid: L.loans_unpaid()
        }
        Text(text).kFont(.xs).foregroundStyle(loan.status == .paid ? theme.colors.pos : theme.colors.ink3)
    }
}

private enum LoanSheet: Identifiable {
    case delete(LoanPayment), unlink(LoanPayment), remove
    var id: String {
        switch self {
        case .delete(let p): "delete-\(p.id)"
        case .unlink(let p): "unlink-\(p.id)"
        case .remove: "remove"
        }
    }
}

/// One loan: Edit, the purpose under the person, a hero with what is still owed, a repaid bar and the facts, the main
/// action (Record repayment received or made), the bank history with Unlink and Delete, and why loans are neutral.
struct LoanDetailScreen: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = Loaded<LoanDetail>()
    @State private var sheet: LoanSheet?

    var body: some View {
        let c = theme.colors
        let loan = loaded.value?.loan
        Page(loan?.person ?? L.loans_title(),
             subtitle: loan.map { $0.purpose.isEmpty ? ($0.lent ? L.loans_lent() : L.loans_borrowed()) : $0.purpose },
             actions: {
                 if loan != nil { KButton(L.common_edit(), style: .secondary, size: .small) { nav.push(.loanForm(id: id)) } }
             }) {
            if loaded.offline { Text(L.common_offline_body()).kFont(.small).foregroundStyle(c.ink3) }
            if let error = loaded.error { Text(error).kFont(.small).foregroundStyle(c.bad) }
            if let detail = loaded.value {
                content(detail)
            } else if loaded.refreshing {
                Skeleton(height: 220)
            } else {
                LoadingNote()
            }
        }
        .task(id: "\(id)/\(kosha.version)") { await loadLoan(kosha, id) { loaded = $0 } }
        .kSheet(item: $sheet) { s in
            switch s {
            case .delete(let p): deleteSheet(p)
            case .unlink(let p): UnlinkSheet(payment: p) { sheet = nil } done: { if p.funding { dismiss() } }
            case .remove:
                ConfirmSheet(title: L.loans_remove(), text: L.loans_delete_warning(), confirm: L.common_delete(), onConfirm: {
                    sheet = nil
                    Task {
                        if await kosha.run(toasts, { try await $0.send("DELETE", "/api/v1/loans/\(id)") }) != nil { dismiss() }
                    }
                }, close: { sheet = nil })
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: LoanDetail) -> some View {
        let c = theme.colors
        let loan = detail.loan
        let today = kosha.today.text
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(loanSide(loan.lent)).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    LoanState(loan: loan)
                }
                HeroMoney(loan.remaining, loan.currency)
                RepaidBar(share: loan.repaidShare).padding(.top, 6)
                if loan.overdue(today) { LoanDueText(loan: loan, today: today) }
            }
            VStack(spacing: 0) {
                fact(loan.opening ? L.loans_starting() : L.loans_principal()) { MoneyText(loan.principal, loan.currency) }
                fact(L.loans_repaid()) { MoneyText(loan.repaid, loan.currency) }
                fact(L.tx_date()) { Text(loanDay(loan.day, theme.locale)).kFont(.body) }
                fact(loanFieldLabel(L.loans_due())) {
                    Text(loan.dueDay.map { loanDay($0, theme.locale) } ?? L.loans_no_due()).kFont(.body)
                        .foregroundStyle(loan.dueDay == nil ? c.ink3 : c.ink)
                }
            }
            if !loan.note.isEmpty { Text(loan.note).kFont(.small).foregroundStyle(c.ink2) }
            if loan.open {
                KButton(loan.lent ? L.loans_received() : L.loans_made()) {
                    nav.push(.loanForm(id: id, repayment: true))
                }
                .padding(.top, 4)
            }
        }
        Caption(L.loans_history())
        Card(tight: true) {
            if loan.opening {
                Text(L.loans_tracked_since(date: loanDay(loan.day, theme.locale))).kFont(.xs).foregroundStyle(c.ink3).padding(16)
            }
            let payments = detail.payments.sorted { $0.day < $1.day }
            ForEach(Array(payments.enumerated()), id: \.element.id) { i, p in
                if i > 0 || loan.opening { Hairline() }
                PaymentRow(payment: p, loan: loan, canUnlink: detail.canUnlink(p),
                           onUnlink: { sheet = .unlink(p) }, onDelete: { sheet = .delete(p) })
            }
        }
        if detail.canRemove {
            KButton(L.loans_remove(), style: .danger) { sheet = .remove }
        }
        HintLine(icon: "info", text: L.loans_neutral())
    }

    private func fact(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
            Spacer(minLength: 12)
            value()
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private func deleteSheet(_ p: LoanPayment) -> some View {
        let line = [loanDay(p.day, theme.locale), p.accountName, inText(p.amount, p.currency, theme)].joined(separator: " · ")
        return ConfirmSheet(title: L.common_delete(),
                            text: (p.reconciled ? L.tx_delete_reconciled() : L.tx_delete_transaction_title()) + "\n" + line,
                            confirm: L.common_delete(), onConfirm: {
                                sheet = nil
                                Task {
                                    await kosha.run(toasts) {
                                        try await $0.send("POST", "/api/v1/transactions/delete",
                                                          body: JSONValue.object(["ids": .array([.string(p.transactionId)])]))
                                    }
                                }
                            }, close: { sheet = nil })
    }
}

/// How much is paid back: a 6pt bar on soft, read by VoiceOver as a percentage.
private struct RepaidBar: View {
    let share: Double
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Capsule().fill(c.soft)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(c.bar).frame(width: g.size.width * share) }
            }
            .accessibilityElement()
            .accessibilityLabel(L.loans_repaid())
            .accessibilityValue(percent(share, theme.locale, signed: false))
    }
}

/// One bank movement in a loan's history: in (green) or out, when and where, and what it did to the principal, with
/// Unlink and Delete under it.
private struct PaymentRow: View {
    let payment: LoanPayment
    let loan: Loan
    let canUnlink: Bool
    let onUnlink: () -> Void
    let onDelete: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let incoming = payment.amount > 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                PhIcon(incoming ? "arrow-down-left" : "arrow-up-right", size: 18, color: incoming ? c.pos : c.ink3)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(payment.funding ? L.loans_original() : L.loans_repayment()).kFont(.body)
                    Text(loanDay(payment.day, theme.locale) + " · " + payment.accountName).kFont(.xs).foregroundStyle(c.ink3)
                    if !payment.note.isEmpty { Text(payment.note).kFont(.xs).foregroundStyle(c.ink3) }
                    if payment.currency != loan.currency {
                        Text(L.loans_applied() + " · " + inText(payment.principal, loan.currency, theme))
                            .kFont(.xs).foregroundStyle(c.ink3).money()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MoneyText(payment.amount, payment.currency, sign: .always, color: incoming ? c.pos : c.ink)
            }
            .accessibilityElement(children: .combine)
            if canUnlink || !payment.funding {
                HStack(spacing: 8) {
                    if canUnlink { KButton(L.loans_unlink(), style: .soft, size: .small, action: onUnlink) }
                    if !payment.funding { KButton(L.common_delete(), style: .danger, size: .small, action: onDelete) }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Unlink entry: why, a category for the entry to count in (income for money in, spending for money out), and Unlink.
private struct UnlinkSheet: View {
    let payment: LoanPayment
    let close: () -> Void
    let done: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var category: String?
    @State private var busy = false

    var body: some View {
        let c = theme.colors
        let categories = (kosha.meta?.categories ?? []).filter {
            !$0.isArchived && $0.parentId == nil && !Categories.isSystem($0.id) && $0.isIncome == (payment.amount > 0)
        }
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(L.loans_unlink(), onClose: close)
            Text(L.loans_unlink_warning()).kFont(.body).foregroundStyle(c.ink2)
            Card(tight: true) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { i, cat in
                    if i > 0 { Hairline() }
                    ListRow(action: { category = cat.id }) {
                        PhIcon(categoryIconName(cat.icon), size: 18)
                        Text(cat.name).frame(maxWidth: .infinity, alignment: .leading)
                        Radio(category == cat.id)
                    }
                    .accessibilityAddTraits(category == cat.id ? .isSelected : [])
                }
            }
            KButton(L.loans_unlink(), style: .danger) {
                guard let category else { return }
                busy = true
                Task {
                    let ok = await kosha.run(toasts) {
                        try await $0.send("POST", "/api/v1/loan-payments/\(payment.transactionId)/unlink",
                                          body: JSONValue.object(["transactionId": .string(payment.transactionId),
                                                                  "categoryId": .string(category)]))
                    }
                    busy = false
                    if ok != nil {
                        close()
                        done()
                    }
                }
            }
            .disabled(category == nil || busy || !kosha.canWrite)
        }
    }
}
