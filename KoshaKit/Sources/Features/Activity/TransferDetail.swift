import SwiftUI
import Model
import API
import Store
import Design

/// A transfer: from, to, what was sent and received, the fee, the rate and its cost against the market, the provider,
/// the day and the note. Edits go through update_transfer, so both halves stay in step; deleting removes it from both
/// accounts. Ported from TransferDetail.kt.
struct TransferDetailScreen: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: Loaded<Model.Transaction>?
    @State private var sheet: DetailSheet?
    @State private var saved = false
    @State private var pending: [String: JSONValue]?

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            DetailHeader(label: saved ? L.tx_header_saved(kind: L.tx_kind_transfer()) : L.tx_kind_transfer(), saved: false) {
                dismiss()
            }
            if let t = loaded?.value, let link = t.transfer {
                ScrollView { content(t, link).padding(.horizontal, 16).padding(.bottom, 40) }
            } else {
                Group {
                    if loaded?.refreshing != false { LoadingNote() } else {
                        Text(loaded?.error ?? L.common_offline_body()).kFont(.small).foregroundStyle(c.ink3)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(c.bg)
        .hideNavigationBar()
        .task(id: "\(id)/\(kosha.version)") {
            await kosha.load("tx/\(id)", into: { (l: Loaded<Model.Transaction>) in loaded = l }) { api in
                try await api.get("/api/app/transactions/\(id)")
            }
        }
        .kSheet(item: Binding(get: { sheet?.scrolls == false ? sheet : nil }, set: { sheet = $0 })) { s in compact(s) }
        .background {
            Color.clear.kSheet(item: Binding(get: { sheet?.scrolls == true ? sheet : nil }, set: { sheet = $0 }), scrolls: true) { s in
                long(s)
            }
        }
    }

    /// The transfer the way it went, from → to, whichever half opened it.
    private struct Legs {
        var from: Wallet?, to: Wallet?
        var fromCurrency: String, toCurrency: String
        var sent: Int64, received: Int64
    }

    private func legs(_ t: Model.Transaction, _ link: Model.Transaction.TransferLink) -> Legs {
        let outgoing = t.amount < 0
        let from = kosha.wallet(outgoing ? t.accountId : link.counterAccountId)
        let to = kosha.wallet(outgoing ? link.counterAccountId : t.accountId)
        let counter = Int64((link.counterAmount ?? 0).magnitude)
        return Legs(
            from: from, to: to, fromCurrency: from?.currency ?? t.currency, toCurrency: to?.currency ?? t.currency,
            sent: (outgoing ? Int64(t.amount.magnitude) : counter) + link.fee,
            received: outgoing ? counter : t.amount
        )
    }

    private func edit(_ s: DetailSheet) {
        if kosha.canWrite { sheet = s } else { toasts.show(L.common_demo_read_only(), warning: true) }
    }

    private func save(_ change: [String: JSONValue], touchesReconciled: Bool) {
        guard let t = loaded?.value, let link = t.transfer else { return }
        guard kosha.canWrite else { return toasts.show(L.common_demo_read_only(), warning: true) }
        if t.reconciled && touchesReconciled {
            pending = change
            sheet = .reconciled
            return
        }
        pending = nil
        Task {
            let r = await kosha.write(toasts) { () -> JSONValue in
                try await kosha.api.patch("/api/v1/transfers/\(link.id)", JSONValue.object(change))
            }
            if r != nil { saved = true }
        }
    }

    @ViewBuilder
    private func content(_ t: Model.Transaction, _ link: Model.Transaction.TransferLink) -> some View {
        let c = theme.colors
        let l = legs(t, link)
        VStack(spacing: 12) {
            Button { edit(.amount) } label: {
                VStack(spacing: 4) {
                    MoneyText(l.sent, l.fromCurrency, sign: .none, font: .figure(40, .medium))
                    Text(L.app_act_not_counted()).kFont(.small).foregroundStyle(c.ink3)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint(L.tx_amount())
            Card(tight: true) {
                FieldRow(label: L.tx_from(), action: { edit(.from) }) {
                    MoneyText(l.sent, l.fromCurrency, sign: .none, color: c.ink2)
                } value: { account(l.from) }
                Hairline()
                FieldRow(label: L.tx_to(), action: { edit(.to) }) {
                    Button { edit(.received) } label: {
                        HStack(spacing: 4) {
                            MoneyText(l.received, l.toCurrency, sign: .none, color: c.ink2)
                            if l.toCurrency != l.fromCurrency {
                                Text(l.toCurrency.uppercased()).kFont(.num).foregroundStyle(c.ink3)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityHint(L.tx_amount_received())
                } value: { account(l.to) }
                Hairline()
                let feeCategory = kosha.category(Categories.transferFee)?.name ?? L.defaults_transfer_fees()
                FieldRow(label: L.tx_fee(), action: { edit(.fee) }) {
                    if link.fee > 0 {
                        Text(L.app_act_fee_counted(category: feeCategory)).kFont(.xs).foregroundStyle(c.ink3)
                            .multilineTextAlignment(.trailing)
                    }
                } value: { MoneyText(link.fee, l.fromCurrency, sign: .none) }
                Hairline()
                FieldRow(label: L.tx_via(), action: { edit(.provider) }) {
                    Text(link.provider.isEmpty ? "—" : link.provider).lineLimit(1)
                }
                Hairline()
                FieldRow(label: L.tx_date(), action: { edit(.date) }) {
                    Text((Day(t.day).map { dayText($0, theme.locale, weekday: true, year: true) } ?? t.day)
                         + " · " + DayFormat.time(t.hhmm, theme.locale))
                }
            }
            if l.fromCurrency != l.toCurrency, let rate = link.marketRate {
                let cost = exchange(total: l.sent, fee: link.fee, received: l.received, marketRate: rate)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.tx_fx_becomes(sent: Money.format(cost.converted, l.fromCurrency, theme.locale),
                                         received: Money.format(l.received, l.toCurrency, theme.locale),
                                         rate: rateText(rate, 1)))
                        .kFont(.small).foregroundStyle(c.ink2)
                    Text(L.tx_fx_cost(cost: Money.format(Int64(cost.totalCost.rounded()), l.fromCurrency, theme.locale),
                                      pct: cost.costPct.formatted(.number.precision(.fractionLength(2)).locale(theme.locale))))
                        .kFont(.small).foregroundStyle(c.ink)
                }
                .money()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(c.soft, in: .rect(cornerRadius: 12))
            }
            if !t.note.isEmpty || kosha.canWrite {
                LinkCard(icon: "note", label: t.note.isEmpty ? L.tx_add_note() : t.note) { edit(.note) }
            }
            if t.reconciled { ReconciledNote() }
            if kosha.canWrite {
                KButton(L.tx_delete_transfer(), style: .danger, size: .medium, icon: "trash") { sheet = .delete }
                    .padding(.top, 6)
                Text(L.tx_delete_transfer_both()).kFont(.xs).foregroundStyle(c.ink3).multilineTextAlignment(.center)
            }
        }
    }

    private func account(_ w: Wallet?) -> some View {
        HStack(spacing: 8) {
            if let w { AccountDot(theme.colors.account(kosha.colorIndex(w.id))) }
            Text(w?.name ?? "—").lineLimit(2)
        }
    }

    @ViewBuilder
    private func compact(_ s: DetailSheet) -> some View {
        if let t = loaded?.value, let link = t.transfer {
            let l = legs(t, link)
            let close = { sheet = nil }
            switch s {
            case .amount:
                AmountSheet(title: L.tx_amount(), currency: l.fromCurrency, initial: l.sent, button: L.common_save()) {
                    close()
                    save(["sent": .number(Double($0))], touchesReconciled: true)
                } close: { close() }
            case .received:
                AmountSheet(title: L.tx_received_currency(currency: l.toCurrency.uppercased()), currency: l.toCurrency,
                            initial: l.received, button: L.common_save()) {
                    close()
                    save(["received": .number(Double($0))], touchesReconciled: true)
                } close: { close() }
            case .fee:
                FeeSheet(fee: link.fee, currency: l.fromCurrency, close: close) {
                    close()
                    save(["fee": .number(Double($0))], touchesReconciled: true)
                }
            case .provider:
                TextSheet(title: L.tx_provider(), start: link.provider, limit: 60, close: close) {
                    close()
                    save(["provider": .string($0.trimmingCharacters(in: .whitespaces))], touchesReconciled: false)
                }
            case .note:
                TextSheet(title: L.tx_note(), start: t.note, limit: 2000, close: close) {
                    close()
                    save(["note": .string($0.trimmingCharacters(in: .whitespacesAndNewlines))], touchesReconciled: false)
                }
            case .date:
                DateEditor(day: t.day, time: t.hhmm, withTime: false) { day, _ in
                    close()
                    if day != t.day { save(["day": .string(day)], touchesReconciled: true) }
                }
            case .delete:
                DeleteConfirm(t: t) { deleted in
                    close()
                    if deleted { dismiss() }
                }
            case .reconciled:
                ReconciledConfirm {
                    let change = pending
                    close()
                    if let change { save(change, touchesReconciled: false) }
                } cancel: {
                    pending = nil
                    close()
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func long(_ s: DetailSheet) -> some View {
        if let t = loaded?.value, let link = t.transfer {
            let l = legs(t, link)
            let from = s == .from
            AccountSheet(title: from ? L.tx_from() : L.tx_to(), selected: from ? l.from?.id : l.to?.id) { id in
                sheet = nil
                save([from ? "fromAccountId" : "toAccountId": .string(id)], touchesReconciled: true)
            } close: { sheet = nil }
        }
    }
}

/// The fee on the keypad; zero is allowed, so it can be cleared.
private struct FeeSheet: View {
    let currency: String
    let close: () -> Void
    let onSave: (Int64) -> Void
    @State private var input: String

    init(fee: Int64, currency: String, close: @escaping () -> Void, onSave: @escaping (Int64) -> Void) {
        self.currency = currency
        self.close = close
        self.onSave = onSave
        _input = State(initialValue: fee == 0 ? "" : AmountSheet.text(fee, currency))
    }

    var body: some View {
        let decimals = Money.decimals(currency)
        let value = input.isEmpty ? 0 : Keypad.minorUnits(input, decimals: decimals)
        VStack(spacing: 8) {
            SheetHeader(L.tx_fee_currency(currency: currency.uppercased()), onClose: close)
            AmountDisplay(input: input, currency: currency, kind: .transfer)
            AmountKeypad(input: $input, decimals: decimals)
            KButton(L.common_save()) { if let value { onSave(value) } }.disabled(value == nil)
        }
    }
}
