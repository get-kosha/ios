import SwiftUI
import Model
import API
import Store
import Design

/// Activity: the entries in its own dates (this month by default) from search_transactions, with a search field, All · Out · In · Transfers, the
/// Filters sheet, a summary of the server's totals in the display currency, entries grouped by day, entries waiting in
/// the outbox first in their day, swipe left to delete and right to duplicate, and paging. Ported from
/// ActivityScreen.kt.
struct ActivityScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var filters = Filters()
    @State private var typed = ""
    @State private var loaded: Loaded<TransactionList>?
    @State private var more: [Model.Transaction] = []
    @State private var next: Int?
    @State private var loadingMore = false
    @State private var showFilters = false
    @State private var picking = false
    @State private var deleting: Model.Transaction?
    /// A row is being swiped, so the step swipe leaves it alone.
    @State private var rowDragging = false

    var body: some View {
        let c = theme.colors
        // Activity picks its own dates; the shared month is Overview's, Accounts' and Recurring's.
        let current = kosha.today.monthOf
        let period = filters.shown(current)
        let header = periodHeader(period, current: current, locale: theme.locale, open: { picking = true }, pick: pick)
        VStack(spacing: 0) {
            MainHeader(period: header)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TabBanners().padding(.bottom, 8)
                    searchRow.padding(.horizontal, 16).padding(.top, 4)
                    TypeSegments(type: $filters.type).padding(.horizontal, 16).padding(.top, 10)
                    if let m = kosha.meta {
                        SummaryCard(
                            summary: Summary(loaded?.value?.totals ?? [], to: kosha.display, rates: m.rates),
                            currency: kosha.display, empty: rows.isEmpty
                        )
                        .padding(.horizontal, 16).padding(.top, 12)
                    }
                    // A tag or event with dates picked narrows to them; its own view covers every date.
                    if (filters.tag != nil || filters.eventId != nil) && filters.period != nil {
                        tagLink.padding(.horizontal, 16).padding(.top, 12)
                    }
                    list(period: period, current: current)
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(c.bg)
        .hideNavigationBar()
        .simultaneousGesture(stepSwipe(header))
        .task(id: "\(filters.key(current))/\(kosha.version)") {
            more = []
            next = nil
            let f = filters
            await kosha.load(f.key(current), into: { (l: Loaded<TransactionList>) in
                loaded = l
                next = l.value?.nextOffset
            }) { api in try await api.get("/api/v1/transactions", query: f.params(current)) }
        }
        .task(id: typed) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled && typed != filters.query { filters.query = typed }
        }
        .onAppear(perform: applySearch)
        .onChange(of: nav.activitySearch) { _, _ in applySearch() }
        .kSheet(isPresented: $showFilters, scrolls: true) {
            FiltersSheet(start: filters, month: current) { f in
                filters = f
                typed = f.query
                showFilters = false
            } close: { showFilters = false }
        }
        .background { Color.clear.kSheet(item: $deleting) { t in DeleteConfirm(t: t) { _ in deleting = nil } } }
        .background {
            Color.clear.kSheet(isPresented: $picking) {
                PeriodSheet(shown: period, current: current, onPick: { p in pick(p); picking = false }) { picking = false }
            }
        }
    }

    /// Picking this month while not finding stores no period, as on the web.
    private func pick(_ p: Period) {
        filters.period = !filters.finding && p == .month(kosha.today.monthOf) ? nil : p
    }

    private var rows: [Model.Transaction] { (loaded?.value?.transactions ?? []) + more }

    /// A search handed over from Overview, Search, Ask or a transaction.
    private func applySearch() {
        guard let s = nav.activitySearch else { return }
        filters = Filters.of(s)
        typed = filters.query
        nav.activitySearch = nil
    }

    /// Sideways steps the month or year: right back, left on, unless a row is being swiped (Shell's monthSwipe can't
    /// tell). Chosen days and every date have no steps.
    private func stepSwipe(_ header: HeaderPeriod) -> some Gesture {
        DragGesture(minimumDistance: 30).onEnded { g in
            guard !rowDragging, abs(g.translation.width) > 72, abs(g.translation.width) > abs(g.translation.height) * 2
            else { return }
            (g.translation.width < 0 ? header.next : header.previous)?.go()
        }
    }

    private var searchRow: some View {
        let c = theme.colors
        return HStack(spacing: 8) {
            KField(L.tx_search_placeholder(), text: Binding(get: { typed }, set: { typed = String($0.prefix(40)) }),
                   icon: "magnifying-glass")
                .keyboard(.search)
            // A rounded square beside the field (Activity.dc.html: .ibtn.solid with radius 12), as tall as the field.
            Button { showFilters = true } label: {
                PhIcon("funnel", size: 22, color: c.ink2)
                    .frame(width: 48, height: 48)
                    .background(c.surface, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.line))
                    .overlay(alignment: .topTrailing) {
                        if filters.count > 0 { Circle().fill(c.selection).frame(width: 8, height: 8).padding(7) }
                    }
                    .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(filters.count > 0 ? L.tx_filters_on(count: String(filters.count)) : L.tx_filters())
        }
    }

    @ViewBuilder
    private var tagLink: some View {
        if let id = filters.eventId, let event = kosha.meta?.events.first(where: { $0.id == id }) {
            LinkCard(icon: "calendar-star", label: event.name, sub: L.app_act_event_all_dates()) {
                nav.push(.tagView(tag: nil, eventId: event.id))
            }
        } else if let tag = filters.tag {
            LinkCard(icon: "hash", label: L.tx_tag_all_dates(tag: tag)) { nav.push(.tagView(tag: tag, eventId: nil)) }
        }
    }

    @ViewBuilder
    private func list(period: Period, current: Month) -> some View {
        let c = theme.colors
        let pending = waitingRows(period)
        let waitingIds = Set(pending.map(\.id))
        let groups = byDay((pending + rows).sorted { $0.day > $1.day })
        if loaded?.value == nil && loaded?.refreshing != false {
            LoadingRows().padding(16)
        } else if groups.isEmpty && filters.searching {
            VStack(spacing: 12) {
                Text(L.tx_no_match()).kFont(.small).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                KButton(L.tx_clear_filters(), style: .secondary, size: .small) {
                    filters = Filters()
                    typed = ""
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.horizontal, 16)
        } else if groups.isEmpty {
            if loaded?.value == nil {
                Text(loaded?.error ?? L.common_offline_body()).kFont(.small).foregroundStyle(c.ink3).padding(16)
            } else if filters.period != nil {
                Text(L.tx_empty_period()).kFont(.small).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .padding(.horizontal, 16)
            } else {
                EmptyMonth()
            }
        } else if let m = kosha.meta {
            ForEach(groups, id: \.day) { group in
                DayHead(day: group.day, total: dayTotal(group.entries, to: kosha.display, rates: m.rates), currency: kosha.display)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
                Card(tight: true) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Hairline() }
                        let isWaiting = waitingIds.contains(t.id)
                        // A copy of a refund would be ordinary income, so a refund has no Duplicate.
                        SwipeRow(enabled: !isWaiting && t.loan == nil && t.categoryId != Categories.loanPrincipal, dragging: $rowDragging, onDelete: {
                            guard kosha.canWrite else { return toasts.show(L.common_demo_read_only(), warning: true) }
                            deleting = t
                        }, onDuplicate: t.refundOf != nil ? nil : {
                            guard kosha.canWrite else { return toasts.show(L.common_demo_read_only(), warning: true) }
                            nav.openAdd(AddRequest(duplicateOf: t.id))
                        }) {
                            TxRow(t: t, waiting: isWaiting, onTap: isWaiting ? nil : { openEntry(kosha, nav, t) })
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            if next != nil {
                KButton(L.tx_load_earlier(), style: .secondary, size: .small) { Task { await loadMore(current) } }
                    .disabled(loadingMore)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .onAppear { Task { await loadMore(current) } }
            }
        }
    }

    /// Entries waiting for a connection, shown first in their day with a "waiting" mark.
    /// Only those whose day is inside the dates listed.
    private func waitingRows(_ period: Period) -> [Model.Transaction] {
        guard !filters.searching else { return [] }
        let today = kosha.today
        return kosha.waiting.compactMap { q in
            let day = q.entry.day.flatMap { Day($0) } ?? today
            if let days = period.days, !days.contains(day) { return nil }
            return Model.Transaction.waiting(q, day: day.text)
        }
    }

    private func loadMore(_ current: Month) async {
        guard let offset = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page: TransactionList = try? await kosha.api.get("/api/v1/transactions", query: filters.params(current, offset: offset)) {
            more += page.transactions
            next = page.nextOffset
        }
    }
}

/// Opens an entry's detail, keeping its row on this phone so the detail opens at once, offline too.
@MainActor
func openEntry(_ kosha: Kosha, _ nav: Navigator, _ t: Model.Transaction) {
    kosha.cache.write("tx/\(t.id)", t)
    if let loan = t.loan { nav.push(.loanDetail(id: loan.id)); return }
    nav.push(t.transfer != nil ? .transferDetail(id: t.id) : .txDetail(id: t.id))
}

/// All · Out · In · Transfers.
struct TypeSegments: View {
    @Binding var type: String?

    var body: some View {
        Segmented(
            [("", L.tx_type_all()), ("expense", L.tx_out()), ("income", L.tx_in()), ("transfer", L.tx_type_transfers())],
            selection: Binding(get: { type ?? "" }, set: { type = $0.isEmpty ? nil : $0 }),
            small: true
        )
    }
}

/// Out, In and Net, and what moved between accounts, not counted.
struct SummaryCard: View {
    let summary: Summary
    let currency: String
    let empty: Bool
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Card {
            HStack(alignment: .top, spacing: 8) {
                column(L.tx_out(), summary.out, empty ? c.ink3 : c.ink)
                column(L.tx_in(), summary.inn, empty ? c.ink3 : summary.inn > 0 ? c.pos : c.ink)
                column(L.tx_net(), summary.net, empty ? c.ink3 : c.ink)
            }
            if summary.moved > 0 {
                Text(L.tx_moved_not_counted(amount: Money.format(summary.moved, currency, theme.locale)))
                    .kFont(.xs).foregroundStyle(c.ink3).money()
            }
        }
    }

    private func column(_ label: String, _ value: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).kFont(.xs).foregroundStyle(theme.colors.ink3)
            MoneyText(value, currency, sign: value == 0 ? .natural : .always, color: color)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "Today · Sat 7 Nov" and the day's total.
struct DayHead: View {
    let day: String
    let total: Int64
    let currency: String
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let today = kosha.today
        let label: String = {
            guard let d = Day(day) else { return day }
            let text = dayText(d, theme.locale, weekday: true, year: d.year != today.year)
            if d == today { return L.add_today() + " · " + text }
            if d == today.adding(days: -1) { return L.add_yesterday() + " · " + text }
            return text
        }()
        HStack {
            Text(label).kFont(.sans(13, .medium)).foregroundStyle(c.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if total != 0 {
                MoneyText(total, currency, sign: .always, font: .figure(13, .regular), color: total > 0 ? c.pos : c.ink3)
            }
        }
    }
}

/// One entry: its category tile, payee, "category · account · #tags", and the amount. Income shows + in the positive
/// colour; transfers and neutral entries show in ink2 without a sign. A foreign amount shows ≈ in the display currency
/// under it.
struct TxRow: View {
    let t: Model.Transaction
    var waiting = false
    var note: String?
    let onTap: (() -> Void)?
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        if let onTap {
            Button(action: onTap) { row.contentShape(Rectangle()) }.buttonStyle(PressStyle())
        } else {
            row
        }
    }

    private var row: some View {
        let c = theme.colors
        let category = kosha.category(t.categoryId)
        let neutral = Categories.isNeutral(t.categoryId)
        let display = kosha.display
        return HStack(spacing: 12) {
            IconTile(t.transfer != nil ? "arrows-left-right" : categoryIconName(category?.icon))
            VStack(alignment: .leading, spacing: 2) {
                if let link = t.transfer {
                    let to = kosha.wallet(link.counterAccountId)
                    HStack(spacing: 4) {
                        AccountDot(c.account(kosha.colorIndex(t.accountId)))
                        Text(t.accountName).foregroundStyle(c.ink2).lineLimit(1)
                        PhIcon("arrow-right", size: 14, color: c.ink3)
                        if let to { AccountDot(c.account(kosha.colorIndex(to.id))) }
                        Text(to?.name ?? "").foregroundStyle(c.ink2).lineLimit(1)
                    }
                    Text(L.tx_kind_transfer() + " · " + L.subs_not_counted()).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(t.payee.isEmpty ? category?.name ?? L.tx_untitled() : t.payee).lineLimit(1)
                        if let badge {
                            Text(badge).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                                .padding(.horizontal, 6)
                                .background(c.soft, in: .rect(cornerRadius: 4))
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 4) {
                        Text((t.loan.map { L.loans_title() + " · " + $0.person } ?? category?.name ?? t.categoryName) + " ·").kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                            .layoutPriority(1)
                        AccountDot(c.account(kosha.colorIndex(t.accountId)))
                        Text(([t.accountName] + rest).joined(separator: " · ")).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                        if t.recurringId != nil { PhIcon("arrows-clockwise", size: 14, color: c.ink3) }
                        if t.attachmentCount > 0 { PhIcon("paperclip", size: 14, color: c.ink3) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if waiting {
                HStack(spacing: 4) {
                    PhIcon("cloud-arrow-up", size: 14)
                    Text(L.app_waiting()).kFont(.xs).foregroundStyle(c.ink2)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .background(c.soft, in: .capsule)
            }
            VStack(alignment: .trailing, spacing: 2) {
                if t.transfer != nil {
                    MoneyText(t.sent, t.currency, sign: .none, color: c.ink2)
                } else if neutral {
                    MoneyText(t.amount, t.currency, sign: .none, color: c.ink2)
                } else if t.amount > 0 {
                    MoneyText(t.amount, t.currency, sign: .always, color: c.pos)
                } else if t.refundState == .full {
                    // Refunded in full: it happened, but costs nothing now.
                    MoneyText(t.amount, t.currency, color: c.ink3).strikethrough(color: c.ink3)
                } else {
                    MoneyText(t.amount, t.currency)
                }
                if t.currency != display, let rates = kosha.meta?.rates {
                    let amount = t.transfer != nil ? t.sent : Int64(t.amount.magnitude)
                    Text("≈ " + Money.format(convert(amount, from: t.currency, to: display, perUsd: rates), display, theme.locale))
                        .kFont(.xs).foregroundStyle(c.ink3).money()
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: theme.dims.row, alignment: .leading)
        .background(c.surface)
    }

    /// refund, refunded or part refunded (transactions.tsx Row).
    private var badge: String? {
        if t.refundOf != nil { return L.tx_refund_badge() }
        switch t.refundState {
        case .full: return L.tx_refunded_badge()
        case .part: return L.tx_part_refunded_badge()
        case .none: return nil
        }
    }

    private var rest: [String] {
        var out: [String] = []
        if t.isUpcoming { out.append(L.tx_kind_upcoming()) }
        out += t.tags.map { "#\($0)" }
        if let note { out.append(note) }
        return out
    }
}

/// A row that swipes: left reveals Delete, right reveals Duplicate (when it has one). Letting go past the reveal does it; VoiceOver gets
/// both as actions.
struct SwipeRow<Content: View>: View {
    let enabled: Bool
    @Binding var dragging: Bool
    let onDelete: () -> Void
    /// nil: no Duplicate, so the row doesn't swipe right.
    let onDuplicate: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    @Environment(\.kosha) private var theme

    private let reveal: CGFloat = 88

    var body: some View {
        if enabled {
            swiping
        } else {
            content
        }
    }

    private var swiping: some View {
        let c = theme.colors
        return content
            .offset(x: offset)
            .background {
                HStack(spacing: 0) {
                    if offset > 0 {
                        action("copy", L.tx_duplicate(), ink: c.ink2).background(c.soft)
                    }
                    Spacer(minLength: 0)
                    if offset < 0 {
                        action("trash", L.common_delete(), ink: .white).background(c.bad)
                    }
                }
            }
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { g in
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        dragging = true
                        offset = max(-reveal * 1.4, min(onDuplicate == nil ? 0 : reveal * 1.4, g.translation.width))
                    }
                    .onEnded { _ in
                        let v = offset
                        withAnimation(theme.animation(.easeOut(duration: 0.2))) { offset = 0 }
                        if v <= -reveal { onDelete() }
                        if v >= reveal { onDuplicate?() }
                        // The month swipe reads this on the same release, so it clears a moment later.
                        Task {
                            try? await Task.sleep(for: .milliseconds(100))
                            dragging = false
                        }
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: abs(offset) >= reveal)
            .accessibilityActions {
                Button(L.common_delete(), action: onDelete)
                if let onDuplicate { Button(L.tx_duplicate(), action: onDuplicate) }
            }
    }

    private func action(_ icon: String, _ label: String, ink: Color) -> some View {
        VStack(spacing: 2) {
            PhIcon(icon, size: 22, color: ink)
            Text(label).kFont(.xs).foregroundStyle(ink)
        }
        .frame(width: reveal)
        .frame(maxHeight: .infinity)
    }
}

/// Grey rows while nothing is saved yet, with "Showing what this phone saved…".
struct LoadingRows: View {
    var body: some View {
        VStack(spacing: 12) {
            Card(tight: true) {
                ForEach(0..<4, id: \.self) { i in
                    if i > 0 { Hairline() }
                    HStack(spacing: 12) {
                        Skeleton(height: 36).frame(width: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Skeleton(height: 12).frame(maxWidth: 160)
                            Skeleton(height: 10).frame(maxWidth: 100)
                        }
                        Spacer()
                        Skeleton(height: 14).frame(width: 64)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            LoadingNote()
        }
    }
}

/// No entries this month: what Activity is for, Add a transaction, or import a statement.
struct EmptyMonth: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        VStack(spacing: 10) {
            PhIcon("receipt", size: 28)
                .frame(width: 56, height: 56)
                .background(c.soft, in: .rect(cornerRadius: 18))
            Text(L.app_act_empty_title()).kFont(.head).multilineTextAlignment(.center)
            Text(L.app_act_empty_body()).kFont(.small).foregroundStyle(c.ink3).multilineTextAlignment(.center)
            if kosha.canWrite {
                KButton(L.add_heading(), size: .small, icon: "plus") { nav.openAdd() }
                    .padding(.top, 6)
                Button(L.app_act_or_import()) { nav.push(.importStatements) }
                    .kFont(.small).foregroundStyle(c.ink2).frame(minHeight: 48).buttonStyle(PressStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 72)
    }
}

/// A card that opens something: an icon (on a tile when there is a line under it), a label and a caret.
struct LinkCard: View {
    let icon: String
    let label: String
    var sub: String?
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Card(tight: true) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if sub != nil { IconTile(icon) } else { PhIcon(icon) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).kFont(sub != nil ? .head : .body).multilineTextAlignment(.leading)
                        if let sub { Text(sub).kFont(.xs).foregroundStyle(c.ink3).money() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PhIcon("caret-right", size: 16, color: c.ink3)
                }
                .padding(16)
                .frame(minHeight: theme.dims.settingsRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        }
    }
}
