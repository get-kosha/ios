import SwiftUI
import Model
import API
import Store
import Design

/// A rate with sensible precision (core.ts fmtRate): 93.85, 1.1623, 0.008640.
func rateString(_ r: Double) -> String {
    if r >= 100 { return String(format: "%.2f", r) }
    if r >= 1 { return String(format: "%.4f", r) }
    if r <= 0 { return "0" }
    // Four significant digits.
    return String(format: "%.*f", max(0, 3 - Int(floor(log10(r)))), r)
}

/// Currency exchanges by year: the route, what was sent (fee included) and received, the rate against the market rate
/// that day, the fee, and the cost ("Negative means you beat it"). Ported from Exchanges.kt.
struct ExchangesScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var loaded = Loaded<Exchanges>()
    @State private var picked: String?

    var body: some View {
        let c = theme.colors
        let display = kosha.display
        let list = loaded.value?.exchanges ?? []
        let years = list.map { String($0.day.prefix(4)) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let year = picked ?? years.first
        let rows = list.filter { $0.day.hasPrefix(year ?? "") }
            .map { ($0, AccountsMath.exchange($0.sent, fee: $0.fee, received: $0.received, marketRate: $0.marketRate)) }
        let cost = rows.map { x, fx in convert(Int64(fx.totalCost.rounded()), from: x.fromCurrency, to: display, perUsd: kosha.meta?.rates ?? [:]) }
            .reduce(0, +)
        Page(L.accounts_fx_title(),
             subtitle: rows.isEmpty ? nil : L.app_acc_fx_count(count: rows.count) + " · " + L.accounts_fx_cost(cost: inText(cost, display, theme))) {
            if loaded.value == nil {
                if loaded.refreshing { Skeleton(height: 120) } else { LoadingNote() }
            } else {
                if years.count > 1 {
                    Segmented(years.map { ($0, $0) }, selection: Binding(get: { year ?? "" }, set: { picked = $0 }), small: true)
                }
                if rows.isEmpty { Text(L.app_acc_fx_empty()).kFont(.small).foregroundStyle(c.ink3) }
                ForEach(rows, id: \.0.id) { x, fx in row(x, fx) }
                Text(L.accounts_fx_footer()).kFont(.xs).foregroundStyle(c.ink3)
            }
        }
        .task(id: kosha.version) {
            await kosha.load("exchanges", into: { loaded = $0 }) { try await $0.get("/api/v1/exchanges", query: ["limit": "500"]) }
        }
    }

    private func row(_ x: Exchange, _ fx: FxCost) -> some View {
        let c = theme.colors
        let total = Int64(fx.totalCost.rounded())
        let counted = x.marketRate != nil || x.fee != 0
        let costText = inText(total, x.fromCurrency, theme)
        let rate = rateString(fx.rate)
        let market = x.marketRate.map(rateString)
        let feeText = inText(x.fee, x.fromCurrency, theme)
        return Card { VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fmtDay(x.day, "EEEdMMM", theme.locale)).kFont(.small).foregroundStyle(c.ink3)
                Spacer()
                if counted {
                    Text(figured(L.app_acc_fx_cost(amount: costText), [costText], size: 13, theme))
                        .foregroundStyle(total < 0 ? c.pos : c.ink)
                }
            }
            HStack(spacing: 6) {
                AccountDot(c.account(kosha.colorIndex(x.fromAccountId)))
                Text(kosha.wallet(x.fromAccountId)?.name ?? "").kFont(.head).lineLimit(1)
                PhIcon("arrow-right", size: 14, color: c.ink3)
                AccountDot(c.account(kosha.colorIndex(x.toAccountId)))
                Text(kosha.wallet(x.toAccountId)?.name ?? "").kFont(.head).lineLimit(1)
            }
            HStack {
                MoneyText(x.sent, x.fromCurrency, sign: .none)
                Spacer()
                PhIcon("arrow-right", size: 16, color: c.ink3)
                Spacer()
                MoneyText(x.received, x.toCurrency, sign: .none)
            }
            HStack(alignment: .top) {
                Text(figured([L.app_acc_fx_rate(rate: rate), market.map { L.app_acc_fx_market(rate: $0) },
                              x.provider.isEmpty ? nil : x.provider].compactMap { $0 }.joined(separator: " · "),
                             [rate, market ?? ""], size: 12, theme))
                Spacer()
                Text(figured(x.fee != 0 ? L.app_acc_fx_fee(amount: feeText) : L.app_acc_fx_no_fee(), [feeText], size: 12, theme))
            }
            .foregroundStyle(c.ink3)
        } }
        .accessibilityElement(children: .combine)
    }
}
