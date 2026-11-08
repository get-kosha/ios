import SwiftUI
import Model
import API
import Store
import Design

/// One tag or event across every date: its name and days, how many entries and what they cost, spending by category,
/// and the entries by day ("added to the event by hand" where the day is outside the event's dates). Ported from
/// TagView.kt.
struct TagViewScreen: View {
    let tag: String?
    let eventId: String?
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var loaded: Loaded<TransactionList>?

    private var event: Event? { eventId.flatMap { id in kosha.meta?.events.first { $0.id == id } } }

    var body: some View {
        let c = theme.colors
        Page(
            event?.name ?? tag.map { "#\($0)" } ?? "",
            subtitle: event != nil ? L.app_act_event_all_dates() : L.tx_tag_all_dates(tag: tag ?? "")
        ) {
            if let event {
                IconButton("pencil-simple", label: L.common_edit()) { nav.push(.settings(page: "events")) }
                    .accessibilityHint(event.name)
            }
        } content: {
            if let list = loaded?.value, let m = kosha.meta {
                summary(list, m)
                ForEach(byDay(list.transactions), id: \.day) { group in
                    DayHead(day: group.day, total: dayTotal(group.entries, to: kosha.display, rates: m.rates),
                            currency: kosha.display)
                        .padding(.leading, 2).padding(.top, 6)
                    Card(tight: true) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { Hairline() }
                            let byHand = event.map { t.outsideEvent($0.startDay, $0.endDay) } ?? false
                            TxRow(t: t, note: byHand ? L.app_act_by_hand() : nil) { openEntry(kosha, nav, t) }
                        }
                    }
                }
            } else if loaded?.refreshing != false {
                LoadingNote()
            } else {
                Text(loaded?.error ?? L.common_offline_body()).kFont(.small).foregroundStyle(c.ink3)
            }
        }
        .task(id: "\(tag ?? "")/\(eventId ?? "")/\(kosha.version)") {
            let filters = Filters(tag: tag, eventId: eventId)
            let current = kosha.today.monthOf
            await kosha.load(filters.key(current), into: { (l: Loaded<TransactionList>) in loaded = l }) { api in
                // ponytail: the entries by day stop at 2,000; a tag or event is rarely bigger. The totals come from the server.
                var all: TransactionList = try await api.get("/api/v1/transactions", query: filters.params(current, limit: 500))
                var next = all.nextOffset
                while let offset = next, all.transactions.count < 2000 {
                    let page: TransactionList = try await api.get("/api/v1/transactions", query: filters.params(current, offset: offset, limit: 500))
                    all.transactions += page.transactions
                    next = page.nextOffset
                }
                return all
            }
        }
    }

    @ViewBuilder
    private func summary(_ list: TransactionList, _ m: Meta) -> some View {
        let c = theme.colors
        let shown = kosha.display
        let spent = -list.totals.reduce(Int64(0)) { $0 + convert($1.spent, from: $1.currency, to: shown, perUsd: m.rates) }
        // Spending by category from the server's per-category, per-currency totals (net of refunds; transfers and
        // corrections left out), converted at the server's rates. Categories that came out as income aren't shown.
        let byCategory = Dictionary(grouping: list.byCategory, by: \.categoryId)
            .mapValues { -$0.reduce(Int64(0)) { $0 + convert($1.amount, from: $1.currency, to: shown, perUsd: m.rates) } }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let days = list.transactions.map(\.day)
        let first = event?.startDay ?? days.min()
        let last = event?.endDay ?? days.max()
        let max = byCategory.first.map { Swift.max($0.value, 1) } ?? 1
        Card {
            HStack {
                if let first, let f = Day(first) {
                    let range = last.flatMap(Day.init).flatMap { $0 == f ? nil : $0 }
                        .map { dayText(f, theme.locale) + " – " + dayText($0, theme.locale, year: true) }
                        ?? dayText(f, theme.locale, year: true)
                    Text(range).kFont(.small).foregroundStyle(c.ink3)
                }
                Spacer()
                Text(L.tx_count(count: list.total, n: String(list.total))).kFont(.small).foregroundStyle(c.ink3)
            }
            HeroMoney(spent, shown, size: 34)
            ForEach(byCategory, id: \.key) { id, total in
                let cat = kosha.category(id)
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        PhIcon(categoryIconName(cat?.icon), size: 18)
                        Text(cat?.name ?? L.overview_unknown_category()).kFont(.small).frame(maxWidth: .infinity, alignment: .leading)
                        MoneyText(total, shown, font: .figure(13, .regular))
                    }
                    GeometryReader { p in
                        ZStack(alignment: .leading) {
                            Capsule().fill(c.soft)
                            Capsule().fill(c.bar).frame(width: p.size.width * Swift.min(1, Swift.max(0.01, Double(total) / Double(max))))
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
