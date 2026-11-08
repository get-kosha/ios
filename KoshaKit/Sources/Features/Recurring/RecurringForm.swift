import SwiftUI
import Model
import API
import Store
import Design

/// What the recurring form holds; filled once from the schedule, a suggestion or an entry.
private struct Form {
    var kind = FormKind.subscription
    var name = ""
    var amount: Int64?
    var variable = false
    var walletId = ""
    var toWalletId: String?
    var toAmount: Int64?
    var categoryId: String?
    var every = 1
    var unit = "month"
    var start: Day
    var end: Day?
    var autoPay: Bool
    var note = ""
    var link: [String] = []
    var filled = false

    mutating func fill(_ s: Sub) {
        kind = switch s.group {
        case .transfers: .transfer
        case .income: .income
        case .bills: .bill
        case .subscriptions: .subscription
        }
        name = s.name
        amount = Int64(s.amount.magnitude)
        variable = s.isVariable
        walletId = s.walletId
        toWalletId = s.toWalletId
        toAmount = s.toAmount
        categoryId = s.isTransfer ? nil : s.categoryId
        every = s.n
        unit = s.period
        start = Day(s.next?.dueDay ?? s.startDay) ?? start
        end = s.endDay.flatMap(Day.init)
        autoPay = s.auto
        note = s.note
        filled = true
    }

    /// A regular payment Kosha spotted: its past payments are filed under the new schedule.
    mutating func fill(_ g: Suggestion) {
        kind = g.amount > 0 ? .income : g.variable ? .bill : .subscription
        name = g.payee
        amount = Int64(g.amount.magnitude)
        walletId = g.accountId
        categoryId = g.categoryId
        every = g.every ?? 1
        unit = g.unit ?? "month"
        start = Day(g.nextDay) ?? start
        link = g.transactionIds
        filled = true
    }

    /// An entry made recurring: the schedule starts a month after it, and the entry is its first payment.
    mutating func fill(_ t: Model.Transaction) {
        kind = t.amount > 0 ? .income : .subscription
        name = t.payee
        amount = Int64(t.amount.magnitude)
        walletId = t.accountId
        categoryId = Categories.isSystem(t.categoryId) ? nil : t.categoryId
        start = (Day(t.day) ?? start).adding(months: 1)
        link = [t.id]
        filled = true
    }
}

private enum Picker: String, Identifiable {
    case amount, toAmount, account, toAccount, category, start, end
    var id: String { rawValue }
}

/// A new schedule or an edit: Bill · Subscription · Income · Transfer, its name, usual amount on the keypad, account (and
/// the account it moves to), category, how often, first payment and end, and whether payments are recorded on their
/// day. Started from a suggestion or an entry, it files the past payments under it. Ported from RecurringForm.kt.
struct RecurringFormScreen: View {
    let id: String?
    let fromPayee: String?
    let fromTransaction: String?
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var form: Form?
    @State private var original: Sub?
    @State private var picker: Picker?
    @State private var busy = false

    var body: some View {
        let today = kosha.today
        let base = form ?? Form(walletId: kosha.activeWallets.first?.id ?? "", start: today,
                                autoPay: kosha.meta?.pref("default_auto_pay", "1") == "1")
        content(base)
            .task { await fill(base) }
    }

    private func fill(_ base: Form) async {
        guard form == nil else { return }
        var f = base
        if let id {
            await loadSubscriptions(kosha) { l in
                if let s = l.value?.subscriptions.first(where: { $0.id == id }), !f.filled {
                    original = s
                    f.fill(s)
                }
            }
        } else if let tx = fromTransaction {
            await kosha.load("transaction/\(tx)", into: { (l: Loaded<Model.Transaction>) in
                if let t = l.value, !f.filled { f.fill(t) }
            }) { try await $0.get("/api/app/transactions/\(tx)") }
        } else if let payee = fromPayee {
            await kosha.load("recurring/suggestions", into: { (l: Loaded<RecurringList>) in
                if let g = l.value?.suggestions.first(where: { $0.payee == payee }), !f.filled { f.fill(g) }
            }) { try await $0.get("/api/v1/recurring", query: ["includeSuggestions": "true"]) }
            if !f.filled && f.name.isEmpty { f.name = payee }
        }
        form = f
    }

    private func content(_ f: Form) -> some View {
        let c = theme.colors
        let loc = theme.locale
        let binding = Binding<Form>(get: { form ?? f }, set: { form = $0 })
        let transfer = f.kind == .transfer
        let income = f.kind == .income
        let wallet = kosha.wallet(f.walletId)
        let toWallet = kosha.wallet(f.toWalletId)
        let currency = wallet?.currency ?? kosha.primary
        let cross = transfer && toWallet != nil && toWallet?.currency != wallet?.currency
        let category = kosha.category(f.categoryId)
        let backfill = id == nil && f.autoPay && !f.variable
            ? Schedule.backfill(f.start, every: f.every, unit: f.unit, end: f.end, today: kosha.today) : 0
        return FormPage(id != nil ? L.subs_edit_title(name: f.name) : L.subs_new_title()) {
            KButton(primaryLabel(f)) { save(f) }.disabled(busy || !kosha.canWrite)
        } content: {
            Segmented([(FormKind.bill, L.subs_kind_bill()), (.subscription, L.subs_kind_subscription()),
                       (.income, L.subs_kind_income()), (.transfer, L.subs_kind_transfer())],
                      selection: Binding(get: { f.kind }, set: { k in
                          if (k == .income) != income { binding.wrappedValue.categoryId = nil }
                          binding.wrappedValue.kind = k
                      }), small: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L.subs_name()).kFont(.small).foregroundStyle(c.ink3)
                KField(L.subs_name(), text: binding.name)
            }
            Button { picker = .amount } label: {
                VStack(spacing: 4) {
                    Text(f.variable ? L.subs_usual_amount() : L.subs_amount()).kFont(.small).foregroundStyle(c.ink3)
                    if let a = f.amount {
                        MoneyText(a, currency, sign: income ? .always : .none, font: .figure(40, .medium), color: income ? c.pos : c.ink)
                    } else {
                        Text(Money.format(0, currency, loc)).kFont(.figure(40, .medium)).foregroundStyle(c.ink3)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(c.surface, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.line))
                .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(PressStyle())
            Card(tight: true) {
                SwitchRow(title: L.subs_variable(), text: L.app_rec_asks_each_time(), isOn: binding.variable)
                Hairline()
                DetailRow(transfer ? L.subs_from() : L.subs_account(), labelWidth: 80, action: { picker = .account }) {
                    AccountDot(c.account(kosha.colorIndex(f.walletId)))
                    Text(wallet?.name ?? "")
                }
                Hairline()
                if transfer {
                    DetailRow(L.subs_to(), labelWidth: 80, action: { picker = .toAccount }) {
                        if toWallet != nil { AccountDot(c.account(kosha.colorIndex(f.toWalletId))) }
                        Text(toWallet?.name ?? L.subs_account()).foregroundStyle(toWallet == nil ? c.ink3 : c.ink)
                    }
                    if cross && !f.variable, let toWallet {
                        Hairline()
                        DetailRow(L.subs_amount_received(), labelWidth: 80, action: { picker = .toAmount }) {
                            if let to = f.toAmount { MoneyText(to, toWallet.currency, sign: .none) } else {
                                Text(L.subs_leave_empty_rate()).kFont(.small).foregroundStyle(c.ink3)
                            }
                        }
                    }
                } else {
                    DetailRow(L.subs_category(), labelWidth: 80, action: { picker = .category }) {
                        if let category { PhIcon(categoryIconName(category.icon), size: 18) }
                        Text(category?.name ?? L.subs_pick_category()).foregroundStyle(category == nil ? c.ink3 : c.ink)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.subs_repeats_every()).kFont(.small).foregroundStyle(c.ink3)
                HStack(spacing: 8) {
                    KStepper(L.subs_repeats_every(), value: binding.every, in: 1...365)
                    Segmented([("day", L.app_rec_unit_day()), ("week", L.app_rec_unit_week()), ("month", L.app_rec_unit_month()),
                               ("year", L.app_rec_unit_year())], selection: binding.unit, small: true)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                dateField(id != nil ? L.subs_next_payment() : L.subs_first_payment(), "calendar-blank", fmtDay(f.start, "dMMMy", loc)) {
                    picker = .start
                }
                dateField(L.subs_ends(), "calendar-x", f.end.map { fmtDay($0, "dMMMy", loc) } ?? L.subs_never()) { picker = .end }
            }
            if backfill > 0 {
                HintLine(icon: "clock-counter-clockwise", text: L.app_rec_backfill(count: backfill, date: fmtDay(f.start, "dMMM", loc)))
            }
            if !f.variable {
                Card(tight: true) { SwitchRow(title: L.subs_auto_pay(), text: L.app_rec_on_due_date(), isOn: binding.autoPay) }
            }
            if id != nil { Text(L.subs_changes_hint()).kFont(.xs).foregroundStyle(c.ink3) }
        }
        .kSheet(item: $picker, scrolls: picker == .category) { p in sheet(p, f, binding, currency: currency, toCurrency: toWallet?.currency) }
    }

    @ViewBuilder
    private func sheet(_ p: Picker, _ f: Form, _ form: Binding<Form>, currency: String, toCurrency: String?) -> some View {
        switch p {
        case .amount:
            KeypadSheet(f.variable ? L.subs_usual_amount() : L.subs_amount(), minor: f.amount, currency: currency,
                        onDone: { form.wrappedValue.amount = $0; picker = nil }, close: { picker = nil })
        case .toAmount:
            KeypadSheet(L.subs_amount_received(), minor: f.toAmount, currency: toCurrency ?? currency,
                        subtitle: L.subs_leave_empty_rate(), clearLabel: L.tx_clear(),
                        onClear: { form.wrappedValue.toAmount = nil; picker = nil },
                        onDone: { form.wrappedValue.toAmount = $0; picker = nil }, close: { picker = nil })
        case .account, .toAccount:
            let to = p == .toAccount
            AccountSheet(title: L.subs_account(), selected: to ? f.toWalletId : f.walletId, exclude: to ? f.walletId : nil,
                         onPick: { id in
                             if to { form.wrappedValue.toWalletId = id } else { form.wrappedValue.walletId = id }
                             if form.wrappedValue.toWalletId == form.wrappedValue.walletId { form.wrappedValue.toWalletId = nil }
                             picker = nil
                         }, close: { picker = nil })
        case .category:
            CategorySheet(title: L.subs_category(), income: f.kind == .income, picked: f.categoryId,
                          onPick: { top, sub in form.wrappedValue.categoryId = sub ?? top; picker = nil }, close: { picker = nil })
        case .start:
            DateSheet(title: L.subs_first_payment(), day: form.start, close: { picker = nil })
        case .end:
            VStack(spacing: 8) {
                DateSheet(title: L.subs_ends(), day: Binding(get: { f.end ?? f.start }, set: { d in
                    form.wrappedValue.end = max(d, form.wrappedValue.start)
                }), close: { picker = nil })
                KButton(L.subs_never(), style: .secondary) { form.wrappedValue.end = nil; picker = nil }
            }
        }
    }

    private func dateField(_ label: String, _ icon: String, _ value: String, action: @escaping () -> Void) -> some View {
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).kFont(.small).foregroundStyle(c.ink3)
            Button(action: action) {
                HStack(spacing: 8) {
                    PhIcon(icon, size: 18)
                    Text(value).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(c.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("\(label), \(value)")
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryLabel(_ f: Form) -> String {
        if id != nil { return L.subs_save_changes() }
        return switch f.kind {
        case .transfer: L.subs_add_transfer()
        case .income: L.subs_add_income()
        case .bill: L.subs_add_bill()
        case .subscription: L.subs_add_subscription()
        }
    }

    private func save(_ f: Form) {
        let transfer = f.kind == .transfer
        let income = f.kind == .income
        guard let amount = f.amount, amount > 0 else {
            return toasts.show(f.variable ? L.subs_enter_usual_amount() : L.subs_enter_amount(), warning: true)
        }
        if transfer && (f.toWalletId == nil || f.toWalletId == f.walletId) { return toasts.show(L.subs_pick_to_account(), warning: true) }
        let categories = kosha.pickable(income: income)
        // An edit may keep a category that has since been archived; anything else must be pickable.
        let keptArchived = f.categoryId != nil && f.categoryId == original?.categoryId
        if !transfer && (f.categoryId == nil || !(categories.contains { $0.id == f.categoryId } || keptArchived)) {
            return toasts.show(L.subs_pick_category(), warning: true)
        }
        let wallet = kosha.wallet(f.walletId)
        let toWallet = kosha.wallet(f.toWalletId)
        let cross = transfer && toWallet != nil && toWallet?.currency != wallet?.currency
        let o = original
        let name = f.name.trimmingCharacters(in: .whitespaces)
        // Changing every, unit or the start starts a new schedule and drops one-off edits, so send them only when changed.
        var fields: [String: JSONValue?] = [
            "name": .string(name.isEmpty && transfer ? "\(wallet?.name ?? "") → \(toWallet?.name ?? "")" : name),
            "accountId": .string(f.walletId),
            "amount": .int(amount * (income ? 1 : -1)),
            "categoryId": transfer ? nil : f.categoryId.map(JSONValue.string),
            "every": o == nil || o?.n != f.every ? .int(f.every) : nil,
            "unit": o == nil || o?.period != f.unit ? .string(f.unit) : nil,
            "startDay": o == nil || Day(o?.next?.dueDay ?? o?.startDay ?? "") != f.start ? .string(f.start.text) : nil,
            "endDay": f.end.map { .string($0.text) } ?? .null,
            "autoPay": .bool(f.autoPay && !f.variable),
            "kind": .string(f.kind == .subscription ? "subscription" : "repetitive"),
            "note": .string(f.note),
            "variable": .bool(f.variable),
        ]
        if transfer {
            fields["toAccountId"] = f.toWalletId.map(JSONValue.string)
            // create_recurring takes no null here; update_recurring clears it with null.
            if let to = f.toAmount, cross && !f.variable { fields["toAmount"] = .int(to) } else if o != nil { fields["toAmount"] = .null }
        } else if o != nil {
            fields["toAccountId"] = .null
        }
        if o == nil && !f.link.isEmpty { fields["linkTransactionIds"] = .array(f.link.map(JSONValue.string)) }
        let payload = jsonBody(fields)
        let done = id != nil ? L.common_saved() : transfer ? L.subs_transfer_added() : income ? L.subs_income_added()
            : f.kind == .bill ? L.subs_bill_added() : L.subs_subscription_added()
        busy = true
        Task {
            let editing = id
            let saved = await kosha.run(toasts) { api -> String in
                if let editing {
                    try await api.send("PATCH", "/api/v1/recurring/\(editing)", body: payload)
                    return editing
                }
                let created: Created = try await api.post("/api/v1/recurring", payload)
                return created.id
            }
            busy = false
            if let saved {
                toasts.show(done)
                dismiss()
                if id == nil { nav.push(.recurringDetail(id: saved)) }
            }
        }
    }
}
