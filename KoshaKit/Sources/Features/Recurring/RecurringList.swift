import SwiftUI
import Model
import API
import Store
import Design

extension Sub {
    /// The name a schedule shows: its own, or the accounts it moves between.
    @MainActor func title(_ kosha: Kosha) -> String {
        guard let to = toWalletId else { return name }
        return "\(kosha.wallet(walletId)?.name ?? "") → \(kosha.wallet(to)?.name ?? "")"
    }
}

extension SubGroup {
    var title: String {
        switch self {
        case .bills: L.subs_group_bills()
        case .subscriptions: L.subs_group_subscriptions()
        case .income: L.subs_group_income()
        case .transfers: L.subs_group_transfers()
        }
    }
}

/// "1 Dec", or "Oct '27" when it is most of a year away (subscriptions.tsx nextLabel).
func nextLabel(_ day: String, today: Day, _ locale: Locale) -> String {
    guard let d = Day(day) else { return day }
    if d > today.adding(days: 300) { return "\(fmtDay(d, "MMM", locale)) '\(day.dropFirst(2).prefix(2))" }
    return fmtDay(d, "dMMM", locale)
}

/// The cached read of GET /api/app/subscriptions, shared by the list, detail and form.
@MainActor
func loadSubscriptions(_ kosha: Kosha, into update: @MainActor (Loaded<SubscriptionsData>) -> Void) async {
    await kosha.load("subscriptions", into: update) { try await $0.get("/api/app/subscriptions") }
}

/// The Recurring tab: what is committed each month, payments that look recurring, then bills, subscriptions, income and
/// transfers sorted by cost per month, and the ended ones folded away. The selected month (shared with Overview and
/// Activity; swipe sideways to move it) lists what falls due in it. Ported from RecurringList.kt.
struct RecurringScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var loaded = Loaded<SubscriptionsData>()
    @State private var spotted: [Suggestion] = []
    @State private var hidden: Set<String> = []
    @State private var showEnded = false
    @State private var monthSheet = false

    var body: some View {
        let c = theme.colors
        let display = kosha.display
        let rates = kosha.meta?.rates ?? [:]
        let today = kosha.today
        let thisMonth = today.monthOf
        let month = kosha.month
        let subs = loaded.value?.subscriptions ?? []
        let perMonth = { (s: Sub) in convert(s.perMonth, from: s.currency, to: display, perUsd: rates).magnitude }
        let active = subs.filter { !$0.ended }.sorted { perMonth($0) > perMonth($1) }
        let ended = subs.filter(\.ended).sorted { ($0.endDay ?? "") > ($1.endDay ?? "") }
        let transfers = active.filter(\.isTransfer).count
        VStack(spacing: 0) {
            MainHeader(
                title: L.subs_title(),
                subtitle: loaded.value == nil ? nil : [
                    L.subs_count_active(count: "\(active.count - transfers)"), L.subs_count_transfers(count: transfers),
                    L.subs_count_ended(count: "\(ended.count)"),
                ].joined(separator: " · "),
                showCurrency: true
            ) {
                IconButton("plus", label: L.subs_new_button(), solid: true, color: c.ink) { nav.push(.recurringForm()) }
            }
            TabBanners()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // The board has no month line; it shows only once a swipe has moved off this month, with the way back.
                    if month != thisMonth {
                        HStack(spacing: 8) {
                            Chip(fmtDay(month.first, "MMMMy", theme.locale), soft: true, small: true, action: { monthSheet = true }) {
                                PhIcon("calendar-blank", size: 16)
                            }
                            Chip(L.overview_this_month(), small: true) { kosha.month = thisMonth }
                        }
                    }
                    if let data = loaded.value {
                        if loaded.offline { LoadingNote() }
                        Committed(active: active, income: data.income, display: display, rates: rates)
                        let suggestions = spotted.filter { !hidden.contains($0.payee) }
                        if !suggestions.isEmpty {
                            Spotted(list: suggestions, today: today, onAdd: { nav.push(.recurringForm(fromPayee: $0.payee)) }) { g in
                                dismiss(g)
                            }
                        }
                        if active.isEmpty {
                            Card { Text(L.subs_empty()).kFont(.small).foregroundStyle(c.ink2) }
                        }
                        ForEach(SubGroup.allCases, id: \.self) { g in
                            let rows = active.filter { $0.group == g && (month == thisMonth || !Schedule.inMonth($0, month).isEmpty) }
                            if !rows.isEmpty {
                                Caption(g.title)
                                Card(tight: true) {
                                    ForEach(rows.indices, id: \.self) { i in
                                        if i > 0 { Hairline() }
                                        SubRow(s: rows[i], today: today, month: month, thisMonth: thisMonth) {
                                            nav.push(.recurringDetail(id: rows[i].id))
                                        }
                                    }
                                }
                            }
                        }
                        if month != thisMonth && !active.contains(where: { !Schedule.inMonth($0, month).isEmpty }) {
                            Text(L.app_rec_none_in_month(month: fmtDay(month.first, "MMMM", theme.locale)))
                                .kFont(.small).foregroundStyle(c.ink3)
                        }
                        if !ended.isEmpty {
                            Card(tight: true) {
                                FoldRow(title: L.subs_ended_count(count: "\(ended.count)"), detail: nil, open: $showEnded)
                                if showEnded {
                                    ForEach(ended) { s in
                                        Hairline()
                                        SubRow(s: s, today: today, month: thisMonth, thisMonth: thisMonth) { nav.push(.recurringDetail(id: s.id)) }
                                    }
                                }
                            }
                        }
                    } else if loaded.refreshing {
                        Skeleton(height: 160)
                    } else {
                        LoadingNote()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 112)
            }
            .monthSwipe()
        }
        .background(c.bg)
        .hideNavigationBar()
        .task(id: kosha.version) {
            await loadSubscriptions(kosha) { loaded = $0 }
            await kosha.load("recurring/suggestions", into: { (l: Loaded<RecurringList>) in spotted = l.value?.suggestions ?? [] }) {
                try await $0.get("/api/v1/recurring", query: ["includeSuggestions": "true"])
            }
        }
        .kSheet(isPresented: $monthSheet) {
            MonthSheet(month: kosha.month) { kosha.month = $0; monthSheet = false } close: { monthSheet = false }
        }
    }

    private func dismiss(_ g: Suggestion) {
        hidden.insert(g.payee)
        Task {
            let done: Void? = await kosha.run(toasts) { api in
                try await api.send("POST", "/api/v1/recurring/suggestions/dismiss", body: jsonBody(["payee": .string(g.payee)]))
            }
            if done == nil { hidden.remove(g.payee) }
        }
    }
}

/// Committed per month: bills and subscriptions, per year with the share of a year's income, and savings moved.
private struct Committed: View {
    let active: [Sub]
    let income: [SubscriptionsData.Income]
    let display: String
    let rates: [String: Double]
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        // ponytail: the schedules' monthly costs, converted at the server's rates and summed, as the web's Recurring does.
        let per = { (s: Sub) in Int64(convert(s.perMonth, from: s.currency, to: display, perUsd: rates).magnitude) }
        let costs = active.filter(\.isCost)
        let bills = costs.filter { $0.group == .bills }.map(per).reduce(0, +)
        let subs = costs.filter { $0.group == .subscriptions }.map(per).reduce(0, +)
        let committed = bills + subs
        let moved = active.filter(\.isTransfer).map(per).reduce(0, +)
        let yearIncome = income.map { convert($0.total, from: $0.currency, to: display, perUsd: rates) }.reduce(0, +)
        Card {
            Text(L.subs_committed()).kFont(.small).foregroundStyle(c.ink3)
            HeroMoney(committed, display, size: 34)
            let b = inText(bills, display, theme), sub = inText(subs, display, theme)
            Text(figured(L.subs_committed_hint(bills: b, subscriptions: sub), [b, sub], size: 13, theme)).foregroundStyle(c.ink3)
            Hairline()
            line(L.subs_per_year()) {
                MoneyText(committed * 12, display, font: .figure(13, .regular))
                Text(" · " + (yearIncome > 0
                    ? L.subs_share_of_income(percent: percent(Double(committed * 12) / Double(yearIncome), theme.locale, signed: false))
                    : L.subs_no_income())).kFont(.small).foregroundStyle(c.ink3)
            }
            if moved > 0 {
                line(L.subs_moved_to_savings()) {
                    MoneyText(moved, display, font: .figure(13, .regular))
                    Text(" " + L.subs_moved_hint()).kFont(.small).foregroundStyle(c.ink3)
                }
            }
        }
    }

    private func line<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 0) {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
            Spacer(minLength: 8)
            value()
        }
    }
}

/// "Looks recurring": regular payments Kosha spotted, to make recurring or dismiss.
private struct Spotted: View {
    let list: [Suggestion]
    let today: Day
    let onAdd: (Suggestion) -> Void
    let onDismiss: (Suggestion) -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Card {
            Text(L.subs_spotted_title()).kFont(.head)
            ForEach(list.indices, id: \.self) { i in
                let g = list[i]
                if i > 0 { Hairline() }
                let cat = kosha.category(g.categoryId)
                let currency = kosha.wallet(g.accountId)?.currency ?? kosha.primary
                let amount = inText(g.amount.magnitude.asInt, currency, theme)
                HStack(spacing: 12) {
                    IconTile(categoryIconName(cat?.icon))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.payee)
                        Text(figured([
                            (g.variable ? L.subs_about_amount(amount: amount) : amount) + " " + everyText(g.every ?? 1, g.unit ?? "month"),
                            L.subs_spotted_paid(count: g.count, day: fmtDay(g.lastDay, "dMMM", theme.locale)),
                            L.subs_spotted_next(day: nextLabel(g.nextDay, today: today, theme.locale)),
                        ].joined(separator: " · "), [amount], size: 12, theme)).foregroundStyle(c.ink3)
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 8) {
                    WideSmallButton(title: L.subs_make_recurring()) { onAdd(g) }
                    WideSmallButton(title: L.subs_not_recurring(), style: .secondary) { onDismiss(g) }
                }
                .disabled(!kosha.canWrite)
            }
        }
    }
}

extension UInt64 { var asInt: Int64 { Int64(self) } }

/// One schedule: its icon, name, how often and when next (or when it falls in the selected month), and its amount.
struct SubRow: View {
    let s: Sub
    let today: Day
    let month: Month
    let thisMonth: Month
    let action: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let loc = theme.locale
        let cat = kosha.category(s.categoryId)
        let overdue = s.next?.status == "overdue"
        let every = everyText(s.n, s.period).capitalisedFirst(loc)
        let inMonth = month != thisMonth && !s.ended ? Schedule.inMonth(s, month).first : nil
        let line: String = {
            if s.ended { return L.subs_ended_on_short(date: fmtDay(s.endDay ?? s.startDay, "dMMM", loc)) }
            if let inMonth {
                let paid = s.history.first { ($0.dueDay ?? $0.day) == inMonth.text }
                return every + " · " + (paid.map { L.app_rec_paid_on(day: fmtDay($0.day, "dMMM", loc)) }
                    ?? L.app_rec_due_on(day: fmtDay(inMonth, "dMMM", loc)))
            }
            if overdue, let next = s.next { return L.app_rec_overdue(day: fmtDay(next.day, "dMMM", loc)) }
            var parts = [every]
            if let next = s.next { parts.append(L.app_rec_next(day: nextLabel(next.day, today: today, loc))) }
            if s.isVariable { parts.append(L.subs_varies_asks()) }
            if s.isTransfer { parts.append(L.subs_not_counted()) }
            if s.attachmentCount > 0 && !s.isTransfer && kosha.meta?.attachments == true {
                parts.append(s.amount > 0 ? L.app_rec_payslips(count: s.attachmentCount) : L.add_files(count: s.attachmentCount))
            }
            return parts.joined(separator: " · ")
        }()
        let income = s.amount > 0 && !s.isTransfer
        ListRow(action: action) {
            IconTile(s.isTransfer ? "arrows-left-right" : categoryIconName(cat?.icon))
            VStack(alignment: .leading, spacing: 2) {
                if s.isTransfer {
                    HStack(spacing: 4) {
                        AccountDot(c.account(kosha.colorIndex(s.toWalletId)))
                        Text(L.app_rec_to_account(account: kosha.wallet(s.toWalletId)?.name ?? "")).lineLimit(1)
                    }
                } else {
                    Text(s.name).lineLimit(1)
                }
                Text(line).kFont(.xs).foregroundStyle(overdue && inMonth == nil && !s.ended ? c.warn : c.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(income ? s.amount : Int64(s.amount.magnitude), s.currency, sign: income ? .always : .none,
                          color: income ? c.pos : (s.isTransfer || s.ended) ? c.ink3 : c.ink)
                if !(s.period == "month" && s.n == 1) && !s.ended {
                    Text(L.app_rec_per_month_short(amount: inText(Int64(s.perMonth.magnitude), s.currency, theme)))
                        .kFont(.figure(12, .regular)).foregroundStyle(c.ink3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
