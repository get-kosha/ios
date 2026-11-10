import SwiftUI
import Charts
import Model
import API
import Store
import Design

extension Wallet {
    /// Where an account opens: investments have their own page.
    var route: Route { kind == .investment ? .investmentDetail(id: id) : .accountDetail(id: id) }
}

/// "today", "yesterday" or the date, for "last entry …".
func lastEntryText(_ day: String, today: Day, _ locale: Locale) -> String {
    guard let d = Day(day) else { return day }
    if d == today || d == today.adding(days: -1) { return DayFormat.label(d, today: today, locale).lowercased(with: locale) }
    return fmtDay(d, "dMMM", locale)
}

/// The cached accounts overview for the shared month and display currency.
@MainActor
func loadOverview(_ kosha: Kosha, into update: @MainActor (Loaded<AccountsOverview>) -> Void) async {
    let month = kosha.month.text
    let shown = kosha.currency
    await kosha.load("accounts-overview/\(month)/\(kosha.display)", into: update) {
        try await $0.get("/api/app/accounts-overview", query: ["month": month, "currency": shown])
    }
}

/// The Accounts tab: net worth with a stacked chart by account (1Y · 2Y · All), the rates other currencies are shown at,
/// bank and cash, credit cards, investments, archived accounts, and links to exchanges, reconcile and import. Ported
/// from AccountsScreen.kt.
struct AccountsScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var overview = Loaded<AccountsOverview>()
    @State private var fx: [Exchange] = []
    @State private var gainsFor: Wallet?
    @State private var showArchived = false

    var body: some View {
        let c = theme.colors
        let wallets = kosha.meta?.wallets ?? []
        let open = wallets.filter { !$0.isArchived }
        let archived = wallets.filter(\.isArchived)
        let currencies = Set(open.map(\.currency)).count
        let today = kosha.today
        let display = kosha.display
        VStack(spacing: 0) {
            MainHeader(
                title: L.accounts_title(),
                subtitle: open.isEmpty ? nil : L.accounts_count(count: open.count) + " · " + L.app_acc_currencies(count: currencies),
                showCurrency: true
            ) {
                IconButton("plus", label: L.accounts_new(), solid: true, color: c.ink) { nav.push(.accountForm()) }
            }
            HStack {
                Text(L.accounts_title()).kFont(.head)
                KButton(L.loans_title(), style: .secondary, size: .small) { nav.push(.loans) }
            }.padding(.horizontal, 16)
            TabBanners()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let o = overview.value {
                        Hero(o: o, wallets: wallets)
                        RatesNote(o: o, open: open, display: display)
                    } else if overview.refreshing {
                        Skeleton(height: 280)
                    } else {
                        LoadingNote()
                    }
                    ForEach(groups, id: \.0) { title, types in
                        let list = open.filter { types.contains($0.kind) }
                        if !list.isEmpty {
                            Caption(title)
                            Card(tight: true) {
                                ForEach(list.indices, id: \.self) { i in
                                    if i > 0 { Hairline() }
                                    row(list[i], today: today, display: display)
                                }
                            }
                        }
                    }
                    if !archived.isEmpty {
                        Card(tight: true) {
                            FoldRow(title: L.accounts_archived_count(count: "\(archived.count)"), detail: L.app_acc_still_counted(),
                                    open: $showArchived)
                            if showArchived {
                                ForEach(archived) { w in
                                    Hairline()
                                    BankRow(w: w, display: display, overview: overview.value, today: today) { nav.push(w.route) }
                                }
                            }
                        }
                    }
                    links(today: today, display: display)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 112)
            }
        }
        .background(c.bg)
        .hideNavigationBar()
        .task(id: "\(kosha.version)/\(kosha.month.text)/\(display)") {
            await loadOverview(kosha) { overview = $0 }
            await kosha.load("exchanges", into: { (l: Loaded<Exchanges>) in fx = l.value?.exchanges ?? [] }) {
                try await $0.get("/api/v1/exchanges", query: ["limit": "500"])
            }
        }
        .kSheet(item: $gainsFor) { w in GainsSheet(w: w) { gainsFor = nil } }
    }

    private var groups: [(String, [AccountType])] {
        [(L.accounts_group_bank_cash(), [.bank, .cash]), (L.accounts_group_credit(), [.credit]),
         (L.accounts_group_investment(), [.investment])]
    }

    @ViewBuilder
    private func row(_ w: Wallet, today: Day, display: String) -> some View {
        switch w.kind {
        case .credit: CardRow(w: w) { nav.push(w.route) }
        case .investment: InvestmentRow(w: w, today: today, onGains: { gainsFor = w }) { nav.push(w.route) }
        default: BankRow(w: w, display: display, overview: overview.value, today: today) { nav.push(w.route) }
        }
    }

    private func links(today: Day, display: String) -> some View {
        let year = String(today.year)
        let thisYear = fx.filter { $0.day.hasPrefix(year) }
        let rates = kosha.meta?.rates ?? [:]
        // ponytail: each exchange's cost from core.ts exchange(), converted at the server's rates, as the web shows it.
        let cost = thisYear.map {
            convert(Int64(AccountsMath.exchange($0.sent, fee: $0.fee, received: $0.received, marketRate: $0.marketRate).totalCost.rounded()),
                    from: $0.fromCurrency, to: display, perUsd: rates)
        }.reduce(0, +)
        let costText = inText(cost, display, theme)
        return Card(tight: true) {
            LinkRow(icon: "arrows-left-right", title: L.accounts_fx_title(), detail: thisYear.isEmpty ? nil
                : L.app_acc_fx_this_year(count: thisYear.count) + " · " + L.accounts_fx_cost(cost: costText), figures: [costText]) {
                nav.push(.exchanges)
            }
            Hairline()
            LinkRow(icon: "check-square", title: L.shell_page_reconcile(), detail: L.app_acc_reconcile_hint()) { nav.push(.reconcile()) }
            Hairline()
            LinkRow(icon: "file-arrow-up", title: L.shell_page_import(),
                    detail: kosha.meta?.aiFlags.statements == true ? L.app_acc_import_hint() : L.app_acc_import_hint_no_pdf()) {
                nav.push(.importStatements)
            }
        }
    }
}

private let ranges: [Int?] = [13, 25, nil]

/// Net worth now, how it moved this month and over 12 months, and the stacked chart by account.
private struct Hero: View {
    let o: AccountsOverview
    let wallets: [Wallet]
    @State private var range: Int? = 13
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let all = o.series
        let now = Int64((all.last?.netWorth ?? 0).rounded())
        let prev = all.count > 1 ? Int64(all[all.count - 2].netWorth.rounded()) : nil
        let yearAgo = all.count > 1 ? Int64(all[max(0, all.count - 13)].netWorth.rounded()) : nil
        let points = AccountsMath.range(all, range)
        Card {
            HStack {
                Text(L.accounts_net_worth()).kFont(.small).foregroundStyle(c.ink3)
                Spacer()
                Segmented([(13, L.accounts_range_1y()), (25, L.accounts_range_2y()), (Int?.none, L.accounts_range_all())]
                    .map { ($0.0 as Int?, $0.1) }, selection: $range, small: true)
                    .frame(width: 160)
            }
            HeroMoney(now, o.currency, size: 34)
            if let prev {
                let month = now - prev
                HStack(spacing: 0) {
                    let amount = inText(month, o.currency, theme, sign: .always)
                    Text(figured(L.overview_worth_this_month(amount: amount), [amount], size: 13, theme))
                        .foregroundStyle(month >= 0 ? c.pos : c.bad)
                    if let yearAgo, yearAgo != 0 {
                        let n = min(12, all.count - 1)
                        Text(" · " + percent(Double(now - yearAgo) / Double(yearAgo.magnitude), theme.locale, digits: 1) + " "
                             + L.accounts_change_period(count: n)).kFont(.small).foregroundStyle(c.ink3)
                    }
                }
            }
            if points.count > 1 {
                WorthChart(points: points, wallets: wallets, currency: o.currency)
            } else {
                Text(L.accounts_worth_empty()).kFont(.small).foregroundStyle(c.ink3).padding(.vertical, 24)
            }
        }
    }
}

/// A layer's colour: the account's own, or shades of ink in neutral mode; gains are a light ink band.
private func layerColor(_ c: KColors, _ id: String?, _ index: Int, _ k: Int) -> Color {
    if id == nil { return c.ink3.opacity(0.35) }
    if c.neutral { return c.ink.opacity([0.85, 0.6, 0.42, 0.28, 0.18, 0.1][k % 6]) }
    return c.account(index).opacity(0.85)
}

/// Net worth over time stacked by account in each account's colour, card debt below zero, gains on top, and the net
/// worth itself as a 2pt line. Drawn with Swift Charts.
private struct WorthChart: View {
    let points: [AccountsOverview.Point]
    let wallets: [Wallet]
    let currency: String
    @Environment(\.kosha) private var theme

    struct Band: Identifiable {
        let id: String
        let k: Int
        let i: Int
        let low: Double
        let high: Double
    }

    var body: some View {
        let c = theme.colors
        let loc = theme.locale
        let layers = AccountsMath.layers(points, order: wallets.map(\.id))
        let stacked = AccountsMath.stack(layers)
        let lows: [Double] = stacked.flatMap { $0.map { $0.0 } } + [0]
        let highs: [Double] = stacked.flatMap { $0.map { $0.1 } } + points.map(\.netWorth)
        let below = lows.min() ?? 0
        let above = highs.max() ?? 1
        // Card debt that is only a sliver starts the axis at zero rather than mirroring the scale below it.
        let lo: Double = -below < above * 0.05 ? 0 : below
        let hi = max(above, lo + 1)
        let index = { (id: String?) in wallets.firstIndex { $0.id == id } ?? 0 }
        let bands = layers.indices.flatMap { k in
            stacked[k].indices.map { i in Band(id: "\(k)-\(i)", k: k, i: i, low: max(stacked[k][i].0, lo), high: max(stacked[k][i].1, lo)) }
        }
        let first = Month(points.first?.month ?? "") ?? Month(2026, 1)
        let last = Month(points.last?.month ?? "") ?? Month(2026, 1)
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(bands) { b in
                    AreaMark(x: .value("m", b.i), yStart: .value("lo", b.low), yEnd: .value("hi", b.high), series: .value("layer", b.k))
                        .foregroundStyle(layerColor(c, layers[b.k].id, index(layers[b.k].id), b.k))
                        .interpolationMethod(.linear)
                }
                ForEach(points.indices, id: \.self) { i in
                    LineMark(x: .value("m", i), y: .value("worth", max(points[i].netWorth, lo)), series: .value("layer", -1))
                        .foregroundStyle(c.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if lo < 0 { RuleMark(y: .value("zero", 0)).foregroundStyle(c.line).lineStyle(StrokeStyle(lineWidth: 1)) }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXScale(domain: 0...max(1, points.count - 1))
            .chartYScale(domain: lo...hi)
            .frame(height: 140)
            .money()
            .accessibilityElement()
            .accessibilityLabel([
                L.accounts_net_worth(), fmtDay(first.first, "MMMy", loc), Money.format(Int64((points.first?.netWorth ?? 0).rounded()), currency, loc),
                fmtDay(last.first, "MMMy", loc), Money.format(Int64((points.last?.netWorth ?? 0).rounded()), currency, loc),
            ].joined(separator: ", "))
            HStack {
                Text(fmtDay(first.first, "MMMy", loc))
                Spacer()
                Text(fmtDay(last.first, "MMMy", loc))
            }
            .kFont(.xs).foregroundStyle(c.ink3)
            // The key, two columns.
            let keys = layers.enumerated().map { k, l -> (String, Color) in
                let w = wallets.first { $0.id == l.id }
                let name = l.id == Categories.loanPrincipal ? L.loans_title() : l.id == nil ? L.accounts_chart_gains() : w == nil ? L.accounts_chart_other()
                    : l.values.allSatisfy { $0 <= 0 } ? L.app_acc_owed(account: w!.name) : w!.name
                return (name, layerColor(c, l.id, index(l.id), k))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(keys.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle().fill(keys[i].1).frame(width: 8, height: 8)
                        Text(keys[i].0).kFont(.xs).foregroundStyle(c.ink2).lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// "INR shown at ₹94.60 = €1 · updated today", for each other currency the accounts hold.
private struct RatesNote: View {
    let o: AccountsOverview
    let open: [Wallet]
    let display: String
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let loc = theme.locale
        let rates = kosha.meta?.rates ?? [:]
        let others = open.map(\.currency).reduce(into: [String]()) { if $1 != display && !$0.contains($1) { $0.append($1) } }
        if !others.isEmpty {
            let one = wholeMoney(100, display, loc)
            let parts = others.map { cur in
                L.accounts_rate_shown(currency: cur.uppercased(), rate: Money.format(convert(100, from: display, to: cur, perUsd: rates), cur, loc), base: one)
            }
            let updated: String? = {
                guard o.ratesUpdated > 0, let today = Day(o.today) else { return nil }
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: kosha.tz) ?? .gmt
                let p = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(o.ratesUpdated)))
                let day = Day(p.year!, p.month!, p.day!)
                switch day.days(to: today) {
                case 0: return L.accounts_rates_updated_today()
                case 1: return L.accounts_rates_updated_yesterday()
                default: return L.accounts_rates_updated_on(date: fmtDay(day, "dMMMy", loc))
                }
            }()
            // In figures, as the web's `num` line.
            Text((parts + [updated].compactMap { $0 }).joined(separator: " · "))
                .kFont(.figure(12, .regular)).foregroundStyle(theme.colors.ink3).padding(.horizontal, 2)
        }
    }
}

struct BankRow: View {
    let w: Wallet
    let display: String
    let overview: AccountsOverview?
    let today: Day
    let action: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let foreign = w.currency != display
        let worth = AccountsMath.shownWorth(w)
        let last = overview?.accounts[w.id]?.lastEntry
        let approx = inText(convert(AccountsMath.worth(w), from: w.currency, to: display, perUsd: kosha.meta?.rates ?? [:]), display, theme)
        let second: String? = foreign ? "≈ " + approx : last.map { L.accounts_last_entry(date: lastEntryText($0, today: today, theme.locale)) }
        ListRow(action: action) {
            AccountDot(c.account(kosha.colorIndex(w.id)), size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name).foregroundStyle(w.isArchived ? c.ink2 : c.ink)
                Text(figured([accountTypeName(w.kind), second].compactMap { $0 }.joined(separator: " · "), foreign ? [approx] : [], size: 12, theme))
                    .foregroundStyle(c.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                MoneyText(worth, w.currency, color: worth < 0 ? c.bad : c.ink)
                if foreign { Text(" " + w.currency.uppercased()).kFont(.num).foregroundStyle(c.ink3) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CardRow: View {
    let w: Wallet
    let action: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let limit = w.creditLimit ?? 0
        let owed = max(0, limit - w.balance)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AccountDot(c.account(kosha.colorIndex(w.id)), size: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.name)
                        if limit > 0 {
                            let available = inText(w.balance, w.currency, theme)
                            Text(figured(L.accounts_available(amount: available), [available], size: 12, theme)).foregroundStyle(c.ink3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MoneyText(-owed, w.currency)
                }
                if limit > 0 {
                    let used = Double(owed) / Double(limit)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(c.soft)
                            Capsule().fill(c.bar).frame(width: g.size.width * min(1, max(0, used)))
                        }
                    }
                    .frame(height: 6)
                    let limitText = inText(limit, w.currency, theme)
                    Text(figured(L.app_acc_credit_used(percent: percent(used, theme.locale, signed: false), limit: limitText), [limitText], size: 12, theme))
                        .foregroundStyle(c.ink3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
    }
}

/// How fresh an investment's value is: "Value is 41 days old" in the warning colour once it is stale.
func valueAge(_ w: Wallet, today: Day, _ locale: Locale) -> (String, Bool) {
    guard let gd = w.gainDay, let day = Day(gd) else { return (L.accounts_no_value(), true) }
    let age = day.days(to: today)
    return age > staleDays ? (L.accounts_value_age(days: "\(age)"), true) : (L.accounts_value_as_of(date: fmtDay(day, "dMMM", locale)), false)
}

private struct InvestmentRow: View {
    let w: Wallet
    let today: Day
    let onGains: () -> Void
    let action: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let (age, stale) = valueAge(w, today: today, theme.locale)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 12) {
                    AccountDot(c.account(kosha.colorIndex(w.id)), size: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.name)
                        Text(age).kFont(.xs).foregroundStyle(stale ? c.warn : c.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        MoneyText(AccountsMath.worth(w), w.currency)
                        if let gain = w.gain, w.gainDay != nil {
                            MoneyText(gain, w.currency, sign: .always, font: .figure(12, .regular), color: gain >= 0 ? c.pos : c.bad)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityElement(children: .combine)
            KButton(L.accounts_update_gains(), style: .secondary, size: .small, action: onGains)
                .padding(.leading, 22)
                .disabled(!kosha.canWrite)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
