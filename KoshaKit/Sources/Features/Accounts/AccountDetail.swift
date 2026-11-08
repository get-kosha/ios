import SwiftUI
import Model
import API
import Store
import Design

/// "Bank account · EUR", plus "Archived".
private func subtitle(_ w: Wallet) -> String {
    (w.kind == .bank ? L.accounts_type_bank_account() : accountTypeName(w.kind)) + " · " + w.currency.uppercased()
        + (w.isArchived ? " · " + L.accounts_archived() : "")
}

/// Fix balance opened by route (from Reconcile): the account with the sheet up; closing it goes back.
struct FixBalanceScreen: View {
    let id: String
    var body: some View { AccountDetailScreen(id: id, fix: true) }
}

/// A bank, cash or card account: its balance, this month's in, out and moved, whether it matches the bank (Reconcile,
/// Fix balance), recent entries, Edit, Archive and Delete. `fix` opens Fix balance at once. Ported from
/// AccountDetail.kt.
struct AccountDetailScreen: View {
    let id: String
    var fix = false
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var overview = Loaded<AccountsOverview>()
    @State private var recent: [Model.Transaction] = []
    @State private var fixing = false

    var body: some View {
        let c = theme.colors
        let today = kosha.today
        if let w = kosha.wallet(id) {
            let flow = overview.value?.accounts[id]
            Page(w.name, subtitle: subtitle(w), leading: AnyView(AccountDot(theme.colors.account(kosha.colorIndex(w.id)), size: 12))) {
                KButton(L.common_edit(), style: .secondary, size: .small) { nav.push(.accountForm(id: id)) }
            } content: {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(w.kind == .credit ? L.accounts_currently_owed() : L.accounts_balance()).kFont(.small).foregroundStyle(c.ink3)
                        HeroMoney(AccountsMath.shownWorth(w), w.currency)
                        if w.kind == .credit && w.creditLimit != nil {
                            let available = inText(w.balance, w.currency, theme)
                            Text(figured(L.accounts_available(amount: available), [available], size: 13, theme)).foregroundStyle(c.ink3)
                        } else if let last = flow?.lastEntry {
                            Text(L.accounts_last_entry(date: lastEntryText(last, today: today, theme.locale))).kFont(.small).foregroundStyle(c.ink3)
                        }
                    }
                }
                if let flow {
                    let m = fmtDay(kosha.month.first, "MMM", theme.locale)
                    HStack(spacing: 8) {
                        flowCard(L.accounts_in_month(month: m), Int64(flow.inflow.rounded()), w.currency, .always, c.pos)
                        flowCard(L.accounts_out_month(month: m), Int64(flow.out.rounded()), w.currency, .natural, c.ink)
                        flowCard(L.accounts_moved(), Int64(flow.moved.rounded()), w.currency, .none, c.ink2)
                    }
                }
                Card {
                    HStack(spacing: 8) {
                        if w.reconciledDay != nil { PhIcon("seal-check", size: 18, color: c.pos) }
                        Text(w.reconciledDay.map { L.accounts_reconciled_to(date: fmtDay($0, "dMMM", theme.locale)) } ?? L.accounts_match_bank())
                            .kFont(.head)
                    }
                    Text(w.reconciledDay != nil ? L.accounts_match_bank() : L.accounts_reconcile_hint()).kFont(.small).foregroundStyle(c.ink2)
                    HStack(spacing: 8) {
                        KButton(L.accounts_reconcile(), size: .medium) { nav.push(.reconcile(accountId: id)) }
                        KButton(L.accounts_fix_balance(), style: .secondary, size: .medium) { fixing = true }.disabled(!kosha.canWrite)
                    }
                }
                RecentCard(w: w, recent: recent, today: today)
                ArchiveRow(w: w)
            }
            .kSheet(isPresented: $fixing) {
                FixBalanceSheet(w: w) {
                    fixing = false
                    if fix { dismiss() }
                }
            }
            .onAppear { if fix { fixing = true } }
            .task(id: "\(kosha.version)/\(kosha.month.text)") {
                await loadOverview(kosha) { overview = $0 }
                let id = id
                await kosha.load("account/\(id)/recent", into: { (l: Loaded<TransactionList>) in recent = l.value?.transactions ?? [] }) {
                    // Without a range the search covers this month only; recent entries go back as far as needed.
                    try await $0.get("/api/v1/transactions", query: ["accountId": id, "from": "2000-01-01", "limit": "5", "includeCorrections": "true"])
                }
            }
        } else {
            Page(L.accounts_title()) { EmptyView() }
        }
    }

    private func flowCard(_ label: String, _ minor: Int64, _ currency: String, _ sign: Sign, _ color: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).kFont(.small).foregroundStyle(theme.colors.ink3).lineLimit(1)
                MoneyText(minor, currency, sign: sign, color: minor == 0 ? theme.colors.ink3 : color)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

/// Recent entries of one account; a transfer reads "To Cash" or "From N26 Main".
private struct RecentCard: View {
    let w: Wallet
    let recent: [Model.Transaction]
    let today: Day
    var transfersOnly = false
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        if recent.isEmpty {
            Card {
                Text(L.accounts_recent()).kFont(.head)
                Text(L.accounts_no_transactions()).kFont(.small).foregroundStyle(c.ink3)
            }
        } else {
            Card(tight: true) {
                HStack {
                    Text(L.accounts_recent()).kFont(.head).accessibilityAddTraits(.isHeader)
                    Spacer()
                    // Every entry of this account, in Activity.
                    if w.txCount > recent.count {
                        Button { nav.openActivity(ActivitySearch(accountId: w.id, type: transfersOnly ? "transfer" : nil)) } label: {
                            Text(L.accounts_all_count(n: "\(w.txCount)")).kFont(.small).foregroundStyle(c.ink2).frame(minHeight: 44)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6)
                ForEach(recent) { t in
                    Hairline()
                    row(t)
                }
            }
        }
    }

    private func row(_ t: Model.Transaction) -> some View {
        let c = theme.colors
        let transfer = t.transfer
        let counter = kosha.wallet(transfer?.counterAccountId)?.name ?? L.accounts_another_account()
        let cat = kosha.category(t.categoryId)
        let title = transfer == nil ? (t.payee.isEmpty ? L.accounts_untitled() : t.payee)
            : t.amount < 0 ? L.app_rec_to_account(account: counter) : L.app_acc_from_account(account: counter)
        let day = Day(t.day).map { DayFormat.label($0, today: today, theme.locale) } ?? t.day
        return ListRow(action: { nav.push(transfer.map { .transferDetail(id: $0.id) } ?? .txDetail(id: t.id)) }) {
            IconTile(transfer != nil ? "arrows-left-right" : categoryIconName(cat?.icon))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(day + " · " + (transfer != nil ? L.subs_kind_transfer() : (t.categoryName.isEmpty ? cat?.name ?? "" : t.categoryName)))
                    .kFont(.xs).foregroundStyle(c.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if transfer != nil && !transfersOnly {
                MoneyText(t.amount, t.currency, color: c.ink2)
            } else {
                MoneyText(t.amount, t.currency, sign: .always, color: t.amount > 0 ? c.pos : c.ink)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Archive or unarchive; Delete while the account has no transactions.
private struct ArchiveRow: View {
    let w: Wallet
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 8) {
            KButton(w.isArchived ? L.accounts_unarchive() : L.accounts_archive(), style: .secondary, size: .medium, icon: "archive") {
                let archived = !w.isArchived
                let id = w.id
                let toast = archived ? L.accounts_archived_toast(name: w.name) : L.accounts_restored_toast(name: w.name)
                Task {
                    let ok = await kosha.run(toasts) { api in
                        try await api.send("PATCH", "/api/v1/accounts/\(id)", body: jsonBody(["archived": .bool(archived)]))
                    }
                    if ok != nil { toasts.show(toast) }
                }
            }
            if w.txCount == 0 {
                KButton(L.common_delete(), style: .danger, size: .medium) { confirm = true }
            }
        }
        .disabled(!kosha.canWrite)
        .kSheet(isPresented: $confirm) {
            ConfirmSheet(title: L.accounts_delete_title(name: w.name), text: L.accounts_delete_description(),
                         confirm: L.accounts_delete_account(), onConfirm: {
                let id = w.id
                Task {
                    let ok = await kosha.run(toasts) { api in try await api.send("DELETE", "/api/v1/accounts/\(id)") }
                    confirm = false
                    if ok != nil { dismiss() }
                }
            }, close: { confirm = false })
        }
    }
}

/// An investment: its value, money put in, unrealized gains with the return, Update gains, the gains history (each entry
/// deletable), and recent transfers in.
struct InvestmentDetailScreen: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var history: [Gain] = []
    @State private var transfers: [Model.Transaction] = []
    @State private var gains = false

    var body: some View {
        let c = theme.colors
        let today = kosha.today
        if let w = kosha.wallet(id) {
            let (age, stale) = valueAge(w, today: today, theme.locale)
            let gain = w.gain ?? 0
            Page(w.name, subtitle: subtitle(w), leading: AnyView(AccountDot(theme.colors.account(kosha.colorIndex(w.id)), size: 12))) {
                KButton(L.common_edit(), style: .secondary, size: .small) { nav.push(.accountForm(id: id)) }
            } content: {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.app_acc_value()).kFont(.small).foregroundStyle(c.ink3)
                        HeroMoney(AccountsMath.worth(w), w.currency)
                        HStack(spacing: 6) {
                            PhIcon("clock", size: 14, color: stale ? c.warn : c.ink2)
                            Text(age).kFont(.small).foregroundStyle(stale ? c.warn : c.ink2)
                        }
                        .padding(.horizontal, 10).frame(minHeight: 26)
                        .background(c.soft, in: .capsule)
                        .accessibilityElement(children: .combine)
                    }
                    Hairline()
                    HStack {
                        Text(L.accounts_invested_so_far()).kFont(.small).foregroundStyle(c.ink3)
                        Spacer()
                        MoneyText(w.balance, w.currency, font: .figure(13, .regular))
                    }
                    HStack(spacing: 0) {
                        Text(L.accounts_chart_gains()).kFont(.small).foregroundStyle(c.ink3)
                        Spacer()
                        MoneyText(gain, w.currency, sign: .always, font: .figure(13, .regular), color: gain >= 0 ? c.pos : c.bad)
                        if w.balance != 0 {
                            Text(" · " + percent(Double(gain) / Double(w.balance), theme.locale, digits: 1, signed: false))
                                .kFont(.figure(13, .regular)).foregroundStyle(gain >= 0 ? c.pos : c.bad)
                        }
                    }
                    KButton(L.accounts_update_gains(), size: .medium, icon: "trend-up") { gains = true }.disabled(!kosha.canWrite)
                }
                if !history.isEmpty {
                    Card(tight: true) {
                        HStack {
                            Text(L.accounts_gains_history()).kFont(.head)
                            Spacer()
                            Text(L.app_acc_gain_over_in()).kFont(.xs).foregroundStyle(c.ink3)
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                        ForEach(history) { g in
                            Hairline()
                            HStack(spacing: 8) {
                                Text(fmtDay(g.day, "dMMM", theme.locale)).kFont(.figure(13, .regular)).foregroundStyle(c.ink3)
                                    .frame(width: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    MoneyText(g.invested + g.gain, w.currency)
                                    if !g.note.isEmpty { Text(g.note).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                MoneyText(g.gain, w.currency, sign: .always, font: .figure(13, .regular), color: g.gain >= 0 ? c.pos : c.bad)
                                if kosha.canWrite {
                                    IconButton("trash", label: L.accounts_delete_valuation(date: fmtDay(g.day, "dMMMy", theme.locale))) {
                                        let gid = g.id
                                        Task { await kosha.run(toasts) { api in try await api.send("DELETE", "/api/v1/gains/\(gid)") } }
                                    }
                                }
                            }
                            .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: theme.dims.row)
                        }
                    }
                }
                RecentCard(w: w, recent: transfers, today: today, transfersOnly: true)
                ArchiveRow(w: w)
            }
            .kSheet(isPresented: $gains) { GainsSheet(w: w) { gains = false } }
            .task(id: kosha.version) {
                let id = id
                await kosha.load("gains/\(id)", into: { (l: Loaded<Gains>) in history = l.value?.gains ?? [] }) {
                    try await $0.get("/api/v1/gains", query: ["accountId": id])
                }
                await kosha.load("account/\(id)/transfers", into: { (l: Loaded<TransactionList>) in transfers = l.value?.transactions ?? [] }) {
                    try await $0.get("/api/v1/transactions", query: ["accountId": id, "type": "transfer", "from": "2000-01-01", "limit": "5"])
                }
            }
        } else {
            Page(L.accounts_title()) { EmptyView() }
        }
    }
}

/// Fix balance: type the balance the bank shows (for a card, what it says is owed), and Kosha books the difference as a
/// balance correction through update_account { balance } (PLAN.md Conflicts rule 3).
struct FixBalanceSheet: View {
    let w: Wallet
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var input = ""
    @State private var fresh = true

    var body: some View {
        let c = theme.colors
        let credit = w.kind == .credit
        let limit = w.creditLimit ?? 0
        let shown = credit ? limit - w.balance : w.balance
        let prefilled = inputOf(shown, w.currency)
        let text = fresh ? prefilled : input
        let entered = signedMinor(text, w.currency)
        // A card keeps the credit left, so what is owed becomes the limit minus it.
        let target = entered.map { credit ? limit - Int64($0.magnitude) : $0 }
        let correction = (target ?? w.balance) - w.balance
        VStack(spacing: 12) {
            SheetHeader(L.accounts_fix_title(name: w.name), onClose: close).padding(.bottom, -8)
            Text(credit ? L.accounts_fix_credit_description() : L.accounts_fix_description())
                .kFont(.body).foregroundStyle(c.ink2).frame(maxWidth: .infinity, alignment: .leading)
            AmountDisplay(input: text, currency: w.currency, kind: .transfer)
            let showsText = inText(shown, w.currency, theme)
            Text(figured(L.app_acc_kosha_shows(amount: showsText), [showsText], size: 13, theme)).foregroundStyle(c.ink3)
                .padding(.top, -8)
            HStack(spacing: 8) {
                PhIcon("scales", size: 16)
                let corr = inText(correction, w.currency, theme, sign: .always)
                Text(figured(correction != 0 ? L.accounts_fix_adds_correction(amount: corr) : L.accounts_no_correction(), [corr], size: 13, theme))
                    .foregroundStyle(c.ink2)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(c.soft, in: .rect(cornerRadius: 12))
            AmountKeypad(input: Binding(get: { fresh ? "" : input }, set: { fresh = false; input = $0 }), decimals: Money.decimals(w.currency))
            KButton(L.common_save()) {
                guard let target else { return }
                let id = w.id
                let done = correction != 0 ? L.accounts_corrected_by(amount: inText(correction, w.currency, theme, sign: .always))
                    : L.accounts_balance_matches()
                Task {
                    let ok = await kosha.run(toasts) { api in
                        try await api.send("PATCH", "/api/v1/accounts/\(id)", body: jsonBody(["balance": .int(target)]))
                    }
                    if ok != nil {
                        toasts.show(done)
                        close()
                    }
                }
            }
            .disabled(target == nil)
        }
    }
}

/// Update an investment: today's value from the broker, or the gain directly (the other follows from the money put
/// in), as of a day, with a note. Shows the gain and the return, and saves with record_gains.
struct GainsSheet: View {
    let w: Wallet
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var gainMode = false
    @State private var panel = Panel.keypad
    @State private var day: Day?
    @State private var note = ""
    @State private var prefilled: String?
    @State private var input = ""
    @State private var fresh = true

    enum Panel { case keypad, date, note }

    var body: some View {
        let c = theme.colors
        let today = kosha.today
        let seed = prefilled ?? inputOf(w.balance + (w.gain ?? 0), w.currency)
        let text = fresh ? seed : input
        let entered = signedMinor(text, w.currency)
        let gain = entered.map { gainMode ? $0 : $0 - w.balance }
        let on = day ?? today
        VStack(spacing: 12) {
            SheetHeader(L.overview_gain_title(name: w.name), onClose: close).padding(.bottom, -8)
            Text(L.overview_gain_description(amount: inText(w.balance, w.currency, theme)))
                .kFont(.body).foregroundStyle(c.ink2).frame(maxWidth: .infinity, alignment: .leading)
            Segmented([(false, L.overview_gain_value()), (true, L.overview_gain_gain())], selection: Binding(get: { gainMode }, set: { next in
                guard next != gainMode else { return }
                // Switching between value and gain carries the figure over, so nothing typed is lost.
                let g = gain ?? (w.gain ?? 0)
                prefilled = inputOf(next ? g : w.balance + g, w.currency)
                fresh = true
                input = ""
                gainMode = next
            }))
            AmountDisplay(input: text, currency: w.currency, kind: .transfer)
            if let gain {
                HStack(spacing: 0) {
                    Text(L.overview_gain_gain() + " " + inText(gain, w.currency, theme, sign: .always)).foregroundStyle(gain >= 0 ? c.pos : c.bad)
                    Text(" · " + L.overview_gain_return(pct: w.balance != 0 ? percent(Double(gain) / Double(w.balance), theme.locale, digits: 1) : "—"))
                        .foregroundStyle(c.ink3)
                }
                .kFont(.small)
            }
            HStack(spacing: 8) {
                Chip(L.overview_gain_as_of() + " " + DayFormat.label(on, today: today, theme.locale), on: panel == .date, action: {
                    panel = panel == .date ? .keypad : .date
                }) { PhIcon("calendar-blank", size: 18) }
                Chip(note.isEmpty ? L.overview_gain_note() + " " + L.accounts_optional() : note, on: panel == .note, action: {
                    panel = panel == .note ? .keypad : .note
                }) { PhIcon("note-pencil", size: 18) }
            }
            switch panel {
            case .keypad:
                AmountKeypad(input: Binding(get: { fresh ? "" : input }, set: { fresh = false; input = $0 }), decimals: Money.decimals(w.currency))
            case .date:
                MonthGrid(month: on.monthOf, selected: on, today: today) { day = $0; panel = .keypad }
            case .note:
                KField(L.overview_gain_note(), text: Binding(get: { note }, set: { note = String($0.prefix(500)) }))
            }
            KButton(L.common_save()) {
                guard let gain else { return toasts.show(L.overview_gain_missing(), warning: true) }
                let fields: JSONValue = .object(["gains": .array([jsonBody([
                    "accountId": .string(w.id), "day": .string(on.text), "gain": .int(gain),
                    "note": .string(note.trimmingCharacters(in: .whitespaces)),
                ])])])
                Task {
                    let ok = await kosha.run(toasts) { api in try await api.send("POST", "/api/v1/gains", body: fields) }
                    if ok != nil {
                        toasts.show(L.overview_gain_updated())
                        close()
                    }
                }
            }
            .disabled(gain == nil)
        }
    }
}
