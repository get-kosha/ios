import SwiftUI
import Model
import API
import Store
import Design

/// Overview: how this month compares with a usual one, what is due, and where the money stands. Every figure comes from
/// the dashboard read (GET /api/app/dashboard) and get_net_worth in the display currency; swiping sideways moves a
/// month. Ported from the Android app's OverviewScreen.kt.
struct OverviewScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var dash = Loaded<Dashboard>()
    @State private var worth: NetWorth?
    @State private var recap: RecapView?
    @State private var search = false

    var body: some View {
        VStack(spacing: 0) {
            MainHeader {
                IconButton("magnifying-glass", label: L.common_search()) { search = true }
            }
            ScrollView {
                VStack(spacing: 12) {
                    TabBanners()
                    VStack(spacing: 12) { LoansCard(); content }.padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }
            .monthSwipe()
        }
        .background(theme.colors.bg)
        .hideNavigationBar()
        .fullScreen(isPresented: $search) { SearchSheet { search = false } }
        .task(id: "\(kosha.month.text)/\(kosha.display)/\(kosha.version)") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let m = kosha.meta {
            if let d = dash.value {
                if !m.wallets.isEmpty && m.wallets.allSatisfy({ $0.entryCount == 0 }) {
                    FirstOverview(d: d, worth: worth)
                } else {
                    MonthView(d: d, worth: worth, recap: recap)
                }
            } else if dash.refreshing {
                OverviewLoading()
            } else {
                Text(dash.error ?? L.common_offline_body()).kFont(.small).foregroundStyle(theme.colors.ink3)
            }
        }
    }

    private func load() async {
        let month = kosha.month.text, shown = kosha.display
        async let a: Void = kosha.load("dashboard/\(month)/\(shown)", into: { (l: Loaded<Dashboard>) in dash = l }) { api in
            try await api.get("/api/app/dashboard", query: ["month": month, "currency": shown])
        }
        async let b: Void = kosha.load("networth/\(shown)", into: { (l: Loaded<NetWorth>) in worth = l.value }) { api in
            try await api.get("/api/v1/reports/net-worth", query: ["currency": shown])
        }
        if kosha.meta?.aiFlags.recap == true {
            await kosha.load("recap/\(month)", into: { (l: Loaded<RecapView?>) in recap = l.value ?? nil }) { api in
                try await api.get("/api/app/recap", query: ["month": month])
            }
        } else {
            recap = nil
        }
        _ = await (a, b)
    }
}

/// Grey blocks shaped like the first cards, with "Showing what this phone saved…".
private struct OverviewLoading: View {
    var body: some View {
        Card {
            HStack { Skeleton(height: 12).frame(width: 90); Spacer(); Skeleton(height: 12).frame(width: 70) }
            Skeleton(height: 38).frame(width: 170)
            Skeleton(height: 12).frame(width: 150)
            Skeleton(height: 110)
        }
        HStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                Card {
                    Skeleton(height: 12).frame(width: 80)
                    Skeleton(height: 22).frame(width: 110)
                }
            }
        }
        LoadingNote().frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The month's cards, in the design's order.
private struct MonthView: View {
    let d: Dashboard
    let worth: NetWorth?
    let recap: RecapView?
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let m = kosha.meta
        let rates = m?.rates ?? [:]
        let today = kosha.today
        let current = today.monthOf.text
        let saved = d.flows.income - d.flows.expense
        let bills = d.billsDue(current, rates)
        PaceCard(d: d, current: current)
        // Side by side, or one above the other at the accessibility text sizes.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            MiniStat(
                label: d.paceInfo.today != nil ? L.overview_saved_so_far() : L.overview_saved(), minor: saved,
                currency: d.primary, positive: saved > 0,
                sub: d.flows.income > 0
                    ? L.overview_pct_of_income(pct: percent(Double(saved) / Double(d.flows.income), theme.locale, signed: false)) : nil
            )
            MiniStat(
                label: L.overview_still_to_pay(), minor: d.stillToPay(current, rates), currency: d.primary,
                sub: bills > 0
                    ? L.overview_bills_before(count: bills, day: DayFormat.dayMonth(Day(d.monthEnd) ?? today, theme.locale))
                    : L.overview_nothing_left()
            )
        }
        if let recap { RecapCard(view: recap) }
        NeedsAttention(d: d, today: today)
        ComingUp(d: d, today: today)
        WhereItWent(d: d)
        NetWorthCard(d: d, worth: worth)
    }
}

/// "Spent so far": the hero, Day N of M, the pace sentence, the chart, and the usual and projected month.
private struct PaceCard: View {
    let d: Dashboard
    let current: String
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let live = d.paceInfo.today != nil
        let future = d.month > current
        let name = Month(d.month).map { DayFormat.monthName($0, theme.locale) } ?? d.month
        let money = { (v: Int64) in wholeMoney(v, d.primary, theme.locale) }
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SplitRow {
                    Text(live ? L.overview_pace_spent_so_far() : L.overview_pace_spent_in(month: name))
                        .kFont(.small).foregroundStyle(c.ink3).accessibilityAddTraits(.isHeader)
                } trailing: {
                    Text(live ? L.overview_pace_day(day: "\(d.dayN)", days: "\(d.paceInfo.days)")
                         : L.overview_pace_days(days: "\(d.paceInfo.days)"))
                        .kFont(.small).foregroundStyle(c.ink3)
                }
                HeroMoney(d.flows.expense, d.primary)
                Group {
                    if future {
                        Text(L.overview_pace_future()).kFont(.small).foregroundStyle(c.ink3)
                    } else if let diff = d.underUsual {
                        if diff >= 0 {
                            Text(live ? L.overview_pace_under_pace(amount: money(diff)) : L.overview_pace_under_month(amount: money(diff)))
                                .kFont(.sans(13, .medium)).foregroundStyle(c.pos).money()
                        } else {
                            Text(live ? L.overview_pace_over_pace(amount: money(-diff)) : L.overview_pace_over_month(amount: money(-diff)))
                                .kFont(.sans(13, .medium))
                                .foregroundStyle(Double(-diff) > 0.1 * Double(d.usualBy ?? 0) ? c.warn : c.ink2)
                                .money()
                        }
                    } else {
                        Text(L.overview_pace_no_history()).kFont(.small).foregroundStyle(c.ink3)
                    }
                }
                if !future && (d.paceInfo.usual != nil || !d.paceInfo.current.isEmpty) {
                    PaceChart(pace: d.paceInfo, projected: d.projected).padding(.top, 4)
                }
                if let usual = d.usualMonth {
                    SplitRow {
                        figured(L.overview_pace_usual_month(amount: money(usual)), [money(usual)], theme, size: 13)
                            .kFont(.small).foregroundStyle(c.ink3).money()
                    } trailing: {
                        if let p = d.projected {
                            figured(L.overview_pace_projected(amount: money(p)), [money(p)], theme, size: 13)
                                .kFont(.small).foregroundStyle(c.ink3).money()
                        }
                    }
                }
            }
        }
    }
}

/// The pace chart: the usual month dashed in ink3, this month to today as a 2pt ink line over a 6% fill, and a dot on
/// today. It draws in from the left unless Appearance › Animations is reduced or off.
private struct PaceChart: View {
    let pace: Dashboard.Pace
    let projected: Int64?
    @Environment(\.kosha) private var theme
    @State private var reveal: CGFloat = 0

    var body: some View {
        let c = theme.colors
        Canvas { ctx, size in
            let days = max(pace.days, 1)
            let top = max(pace.current.last ?? 0, pace.usual?.last ?? 0, Double(projected ?? 0), 1)
            let pad = size.height / 12
            let x = { (day: Int) in size.width * CGFloat(day) / CGFloat(days) }
            let y = { (v: Double) in size.height - pad - CGFloat(v / top) * (size.height - 2 * pad) }
            if let usual = pace.usual {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y(0)))
                for (i, v) in usual.enumerated() { p.addLine(to: CGPoint(x: x(i + 1), y: y(v))) }
                ctx.stroke(p, with: .color(c.ink3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            if !pace.current.isEmpty {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(0)))
                for (i, v) in pace.current.enumerated() { line.addLine(to: CGPoint(x: x(i + 1), y: y(v))) }
                var area = line
                area.addLine(to: CGPoint(x: x(pace.current.count), y: y(0)))
                area.closeSubpath()
                ctx.fill(area, with: .color(c.ink.opacity(0.06)))
                ctx.stroke(line, with: .color(c.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if pace.today != nil, let last = pace.current.last {
                    let at = CGPoint(x: x(pace.current.count), y: y(last))
                    ctx.fill(Path(ellipseIn: CGRect(x: at.x - 3.5, y: at.y - 3.5, width: 7, height: 7)), with: .color(c.ink))
                }
            }
        }
        .frame(height: 120)
        // A Canvas doesn't animate its inputs, so the draw-in is a mask that grows from the left.
        .mask(alignment: .leading) { Rectangle().scaleEffect(x: reveal, y: 1, anchor: .leading) }
        .accessibilityHidden(true)
        .onAppear {
            if let a = theme.motion == .on ? Animation.easeOut(duration: 0.7) : nil {
                withAnimation(a) { reveal = 1 }
            } else {
                reveal = 1
            }
        }
    }
}

private struct MiniStat: View {
    let label: String
    let minor: Int64
    let currency: String
    var positive = false
    var sub: String?
    @Environment(\.kosha) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
                MoneyText(minor, currency, font: .figure(22, .regular), color: positive ? theme.colors.pos : theme.colors.ink)
                    .minimumScaleFactor(0.6)
                if let sub { Text(sub).kFont(.xs).foregroundStyle(theme.colors.ink3) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The month's recaps are written once per app run when Overview opens on them, as the web does on first visit.
@MainActor private var autoWritten: Set<String> = []

private struct RecapRequest: Encodable {
    let month: String
    let rewrite: Bool
}

/// Monthly recap (AI, only with meta.ai.recap). In a month's first week it shows last month's, written on the first
/// visit, until hidden (the `ai_recap_hidden` preference holds the hidden month). A past month offers to write one.
private struct RecapCard: View {
    let view: RecapView
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var recap: Recap?
    @State private var writing = false
    @State private var error: String?
    @State private var hidden = false

    var body: some View {
        let c = theme.colors
        let name = Month(view.month).map { DayFormat.monthName($0, theme.locale) } ?? view.month
        Group {
            if hidden || (recap == nil && !kosha.canWrite) {
                EmptyView()
            } else if recap == nil && !writing && error == nil && !view.auto {
                Card {
                    HStack(spacing: 10) {
                        Sparkle(size: 16)
                        Text(L.overview_recap_offer(month: name)).kFont(.small).foregroundStyle(c.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        KButton(L.overview_recap_write(), style: .secondary, size: .small) { write(false) }
                    }
                }
            } else {
                Card {
                    HStack(spacing: 6) {
                        Sparkle()
                        Text(L.overview_recap_title(month: name)).kFont(.head).accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if view.auto {
                            IconButton("x", label: L.overview_recap_hide(month: name)) {
                                hidden = true
                                kosha.setPreference("ai_recap_hidden", view.month)
                            }
                        }
                    }
                    if let error {
                        Text(L.overview_recap_error(error: error)).kFont(.small).foregroundStyle(c.ink3)
                        KButton(L.common_try_again(), style: .secondary, size: .small) { write(recap != nil) }
                    } else if writing && recap == nil {
                        Text(L.overview_recap_writing(month: name)).kFont(.xs).foregroundStyle(c.ink3)
                        Skeleton(height: 18).frame(maxWidth: 220, alignment: .leading)
                        Skeleton(height: 12)
                        Skeleton(height: 12).frame(maxWidth: 260, alignment: .leading)
                    } else if let r = recap {
                        if !r.headline.isEmpty { Text(r.headline).kFont(.sans(17, .medium)).money() }
                        if !r.summary.isEmpty { Text(r.summary).kFont(.small).foregroundStyle(c.ink2).lineSpacing(3).money() }
                        ForEach(r.points, id: \.self) { p in
                            HStack(spacing: 10) {
                                Circle().fill(p.tone == "good" ? c.pos : p.tone == "bad" ? c.warn : c.ink3).frame(width: 6, height: 6)
                                Text(p.text).kFont(.small).foregroundStyle(c.ink2).money()
                            }
                        }
                        HStack(spacing: 8) {
                            if let day = Day(r.writtenDay) {
                                Text(L.overview_recap_written(day: DayFormat.dayMonth(day, theme.locale)))
                                    .kFont(.xs).foregroundStyle(c.ink3)
                            }
                            Spacer()
                            if kosha.canWrite {
                                KButton(L.overview_recap_rewrite(), style: .secondary, size: .small) { write(true) }
                                    .disabled(writing)
                            }
                        }
                    }
                }
            }
        }
        .task(id: view.month) {
            recap = view.recap
            if view.auto && view.recap == nil && kosha.canWrite && !autoWritten.contains(view.month) {
                autoWritten.insert(view.month)
                write(false)
            }
        }
    }

    private func write(_ rewrite: Bool) {
        writing = true
        error = nil
        Task {
            do {
                let r: Recap = try await kosha.api.post("/api/v1/ai/recap", RecapRequest(month: view.month, rewrite: rewrite))
                recap = r
                var saved = view
                saved.recap = r
                kosha.cache.write("recap/\(kosha.month.text)", Optional(saved))
            } catch let e as KoshaError {
                if case .api(_, let err) = e { error = err.message } else { error = L.overview_recap_write_failed() }
            } catch {
                self.error = L.overview_recap_write_failed()
            }
            writing = false
        }
    }
}

private struct PayBody: Encodable { let status: String }

/// A card's header row: the title and something on the right.
private struct CardHead<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack {
            Text(title).kFont(.head).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// Needs attention: overdue bills (Mark paid), cards owed (Pay), categories above usual (Review), old values (Update).
private struct NeedsAttention: View {
    let d: Dashboard
    let today: Day
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var busy: String?

    var body: some View {
        let items = d.attention(today, kosha.meta?.wallets ?? [])
        if !items.isEmpty {
            Card(tight: true) {
                CardHead(title: L.overview_att_title()) { Pill("\(items.count)", color: theme.colors.warn) }
                ForEach(items) { item in
                    Hairline()
                    row(item)
                }
            }
        }
    }

    private func row(_ item: Attention) -> some View {
        let c = theme.colors
        let loc = theme.locale
        let (title, sub): (String, String?) = switch item {
        case .overdue(let p):
            (L.overview_att_due(name: p.name, day: Day(p.day).map { DayFormat.dayMonth($0, loc) } ?? p.day),
             L.overview_att_not_paid(amount: Money.format(p.toWalletId != nil ? abs(p.amount) : p.amount, p.currency, loc)))
        case .cardOwed(let card, let owed):
            (L.overview_att_card_owed(name: card.name, amount: Money.format(owed, card.currency, loc)), L.overview_att_card_hint())
        case .aboveUsual(let cat, let usual):
            (L.overview_att_category_above(
                name: kosha.category(cat.id)?.name ?? L.overview_att_a_category(),
                pct: percent(Double(cat.total) / Double(usual) - 1, loc, signed: false)),
             L.overview_att_category_sub(count: cat.count, spent: Money.format(cat.total, d.primary, loc),
                                         usual: Money.format(usual, d.primary, loc)))
        case .stale(let w, let age):
            (age.map { L.overview_att_value_age(count: $0, name: w.name) } ?? L.overview_att_no_value(name: w.name),
             L.overview_att_understated())
        }
        // Amounts in the sub line are set as figures, as the design does.
        let figures: [String] = switch item {
        case .overdue(let p): [Money.format(p.toWalletId != nil ? abs(p.amount) : p.amount, p.currency, loc)]
        case .aboveUsual(let cat, let usual): [Money.format(cat.total, d.primary, loc), Money.format(usual, d.primary, loc)]
        default: []
        }
        return HStack(spacing: 12) {
            switch item {
            case .overdue(let p): IconTile(categoryIconName(kosha.category(p.categoryId)?.icon))
            case .cardOwed(let w, _), .stale(let w, _): DotTile(accountId: w.id)
            case .aboveUsual(let cat, _): IconTile(categoryIconName(kosha.category(cat.id)?.icon))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(.body).money()
                if let sub { figured(sub, figures, theme, size: 12).kFont(.xs).foregroundStyle(c.ink3).money() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action(item)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: theme.dims.row)
    }

    @ViewBuilder
    private func action(_ item: Attention) -> some View {
        switch item {
        case .overdue(let p):
            KButton(L.overview_att_mark_paid(), style: .secondary, size: .small) {
                guard let sub = p.subscriptionId else { return }
                busy = item.id
                Task {
                    let done: Empty? = await kosha.write(toasts, offline: L.overview_att_mark_failed()) {
                        try await kosha.api.patch("/api/v1/recurring/\(sub)/payments/\(p.dueDay)", PayBody(status: "paid"))
                    }
                    if done != nil { toasts.show(L.overview_att_marked_paid(name: p.name)) }
                    busy = nil
                }
            }
            .disabled(!kosha.canWrite || busy == item.id)
        case .cardOwed(let card, let owed):
            KButton(L.overview_att_pay(), style: .secondary, size: .small) {
                // Pay opens Add as a transfer to the card, with what it owes filled in.
                nav.openAdd(AddRequest(kind: .transfer, toAccount: card.id, amount: owed))
            }
            .disabled(!kosha.canWrite)
        case .aboveUsual(let cat, _):
            KButton(L.overview_att_review(), style: .secondary, size: .small) {
                nav.openActivity(ActivitySearch(categoryId: cat.id, month: Month(d.month)))
            }
        case .stale(let w, _):
            KButton(L.overview_att_update(), style: .secondary, size: .small) { nav.push(.investmentDetail(id: w.id)) }
        }
    }
}

/// An account's colour square on an icon tile (a wallet icon in neutral mode).
private struct DotTile: View {
    let accountId: String
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    var body: some View {
        if theme.colors.accountColours {
            AccountDot(theme.colors.account(kosha.colorIndex(accountId)), size: 10)
                .frame(width: 36, height: 36)
                .background(theme.colors.soft, in: .rect(cornerRadius: 10))
        } else {
            IconTile("wallet")
        }
    }
}

/// Coming up: payments before month end (or the next 30 days), transfers greyed, and a way to Recurring.
private struct ComingUp: View {
    let d: Dashboard
    let today: Day
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let m = kosha.meta
        let (end, soon) = d.comingUp(today, thirtyDays: m?.pref("upcoming_horizon", "month") == "30d")
        // The web's cutoff for a past month is "YYYY-MM-31", which isn't a day in every month.
        let endDay = DayFormat.dayMonth(Day(end) ?? Month(String(end.prefix(7)))?.last ?? today, theme.locale)
        let total = soon.reduce(Int64(0)) { $0 + $1.outflow(d.primary, m?.rates ?? [:]) }
        if !d.upcoming.isEmpty {
            Card(tight: true) {
                CardHead(title: L.overview_coming_title()) {
                    Text(L.overview_coming_total(amount: Money.format(total, d.primary, theme.locale), day: endDay))
                        .kFont(.small).foregroundStyle(c.ink3).money()
                }
                if soon.isEmpty {
                    Hairline()
                    Text(L.overview_coming_empty(day: endDay)).kFont(.small).foregroundStyle(c.ink3).padding(16)
                }
                ForEach(soon.prefix(6), id: \.key) { u in
                    Hairline()
                    HStack(spacing: 12) {
                        Text(Day(u.day).map { DayFormat.dayMonth($0, theme.locale) } ?? u.day)
                            .kFont(.figure(13, .regular)).foregroundStyle(u.day < today.text ? c.warn : c.ink3)
                            .lineLimit(1).frame(width: 52, alignment: .leading)
                        if let to = kosha.wallet(u.toWalletId) {
                            HStack(spacing: 6) {
                                Text(L.tx_to())
                                AccountDot(c.account(kosha.colorIndex(to.id)))
                                Text(to.name).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            MoneyText(abs(u.amount), u.currency, sign: .none, color: c.ink3)
                        } else {
                            Text(u.name.isEmpty ? kosha.category(u.categoryId)?.name ?? L.overview_untitled() : u.name)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            MoneyText(u.amount, u.currency)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: theme.dims.row)
                    .accessibilityElement(children: .combine)
                }
                Hairline()
                OverviewLinkRow(L.app_ov_all_recurring()) { nav.open(.recurring) }
            }
        }
    }
}

/// A centred link at the foot of a card, like "All in Recurring →".
private struct OverviewLinkRow: View {
    let label: String
    let action: () -> Void
    @Environment(\.kosha) private var theme
    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink2).frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Where it went: the top categories with a bar and a pill against the usual by the same day.
private struct WhereItWent: View {
    let d: Dashboard
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let top = Array(d.categories.prefix(5))
        let rest = Array(d.categories.dropFirst(5))
        let max = Swift.max(d.categories.first?.total ?? 1, 1)
        Card {
            HStack {
                Text(L.overview_where_title()).kFont(.head).accessibilityAddTraits(.isHeader)
                Spacer()
                if !top.isEmpty { Text(L.overview_where_vs_usual(day: "\(d.dayN)")).kFont(.xs).foregroundStyle(c.ink3) }
            }
            if top.isEmpty { Text(L.overview_where_empty()).kFont(.small).foregroundStyle(c.ink3) }
            ForEach(top, id: \.id) { cat in
                let info = kosha.category(cat.id)
                Button {
                    nav.openActivity(ActivitySearch(categoryId: cat.id, month: Month(d.month)))
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            PhIcon(categoryIconName(info?.icon))
                            Text(info?.name ?? L.overview_unknown_category()).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            MoneyText(cat.total, d.primary)
                            UsualPill(v: vsUsual(cat.total, cat.usualToDate, fixed: cat.fixed))
                        }
                        .frame(minHeight: 32)
                        Track(share: CGFloat(cat.total) / CGFloat(max))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityElement(children: .combine)
            }
            if !rest.isEmpty {
                HStack {
                    Text(L.overview_others(count: rest.count)).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    MoneyText(rest.reduce(0) { $0 + $1.total }, d.primary, font: .figure(13, .regular), color: c.ink2)
                }
            }
            OverviewLinkRow(L.overview_all_activity()) { nav.openActivity(ActivitySearch(month: Month(d.month))) }
        }
    }
}

private struct UsualPill: View {
    let v: VsUsual
    @Environment(\.kosha) private var theme
    var body: some View {
        let c = theme.colors
        let (text, color): (String, Color) = switch v {
        case .fixed: (L.overview_chip_fixed(), c.ink2)
        case .new: (L.overview_chip_new(), c.ink2)
        case .change(let r): (percent(r, theme.locale), v.warn ? c.warn : v.good ? c.pos : c.ink2)
        }
        Pill(text, color: color).frame(width: 56)
    }
}

private struct Track: View {
    let share: CGFloat
    @Environment(\.kosha) private var theme
    var body: some View {
        GeometryReader { g in
            Capsule().fill(theme.colors.soft)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.colors.bar).frame(width: g.size.width * min(max(share, 0.01), 1))
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Net worth: today's total, the change this month and over 12 months, and a way to Accounts.
private struct NetWorthCard: View {
    let d: Dashboard
    let worth: NetWorth?
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let change = d.worthChange
        Card {
            HStack {
                Text(L.overview_net_worth()).kFont(.small).foregroundStyle(c.ink3).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L.overview_accounts_link()) { nav.open(.accounts) }
                    .kFont(.small).foregroundStyle(c.ink2).frame(minHeight: 44).buttonStyle(PressStyle())
            }
            if let w = worth {
                HeroMoney(w.total, w.currency.isEmpty ? d.primary : w.currency, size: 32)
            } else {
                Skeleton(height: 32).frame(width: 170)
            }
            HStack(spacing: 12) {
                if let m = change.thisMonth {
                    Text(L.overview_worth_this_month(amount: Money.format(m, d.primary, theme.locale, sign: .always)))
                        .kFont(.small).foregroundStyle(m >= 0 ? c.pos : c.bad).money()
                }
                if let g = change.growth {
                    Text(L.overview_worth_growth(pct: percent(g, theme.locale, digits: 1))).kFont(.small).foregroundStyle(c.ink3)
                }
            }
        }
    }
}

/// Overview on day one: nothing spent yet, a way to fill in the history, and the new accounts.
private struct FirstOverview: View {
    let d: Dashboard
    let worth: NetWorth?
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @AppStorage("kosha.overview.history_hidden") private var historyHidden = false

    var body: some View {
        let c = theme.colors
        let accounts = kosha.activeWallets
        Card {
            HStack {
                Text(L.overview_pace_spent_so_far()).kFont(.small).foregroundStyle(c.ink3)
                Spacer()
                if d.paceInfo.today != nil {
                    Text(L.overview_pace_day(day: "\(d.dayN)", days: "\(d.paceInfo.days)")).kFont(.small).foregroundStyle(c.ink3)
                }
            }
            HeroMoney(0, d.primary, color: c.ink3)
            Text(L.app_ov_first_entry()).kFont(.small).foregroundStyle(c.ink3)
        }
        if !historyHidden {
            Card {
                HStack(spacing: 10) {
                    PhIcon("clock-counter-clockwise", size: 18, color: c.brand)
                        .frame(width: 36, height: 36)
                        .background(c.brand.opacity(0.12), in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.welcome_history_title()).kFont(.head)
                        Text(L.app_ov_from_statements()).kFont(.xs).foregroundStyle(c.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    KButton(L.app_ov_import(), style: .secondary, size: .small) { nav.push(.importStatements) }
                    IconButton("x", label: L.app_ov_hide_card()) { historyHidden = true }
                }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L.overview_net_worth()).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    Text(L.app_ov_accounts(count: accounts.count)).kFont(.xs).foregroundStyle(c.ink3)
                }
                if let w = worth { HeroMoney(w.total, w.currency.isEmpty ? d.primary : w.currency, size: 30) }
                Text(L.app_ov_chart_later()).kFont(.xs).foregroundStyle(c.ink3).padding(.bottom, 4)
                ForEach(accounts) { a in
                    Hairline()
                    HStack(spacing: 12) {
                        AccountDot(c.account(kosha.colorIndex(a.id)), size: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                            Text(accountTypeName(a.kind) + detail(a)).kFont(.xs).foregroundStyle(c.ink3).money()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        MoneyText(a.worth, a.currency)
                    }
                    .padding(.vertical, 8)
                    .frame(minHeight: theme.dims.row)
                }
            }
        }
    }

    private func detail(_ a: Wallet) -> String {
        switch a.kind {
        case .credit: " · " + L.accounts_available(amount: Money.format(a.balance, a.currency, theme.locale))
        case .investment: a.gain.map { " · " + L.welcome_gain(amount: Money.format($0, a.currency, theme.locale)) } ?? ""
        default: ""
        }
    }
}

/// A sentence with its amounts in the figure font (Geist Mono unless Number font is proportional), as the design sets
/// "Usual month €2,480" and "€86.20 against €69.50 by day 7". The rest takes the view's font.
func figured(_ text: String, _ amounts: [String], _ theme: KTheme, size: CGFloat) -> Text {
    let figure = KFont.figure(size, .regular)
    var out = Text("")
    var rest = Substring(text)
    for a in amounts {
        guard !a.isEmpty, let r = rest.range(of: a) else { continue }
        out = out + Text(rest[..<r.lowerBound]) + Text(a).font(figure.font(theme)).tracking(figure.tracking(theme))
        rest = rest[r.upperBound...]
    }
    return out + Text(rest)
}
