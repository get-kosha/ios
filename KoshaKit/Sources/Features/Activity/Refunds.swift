import SwiftUI
import Model
import API
import Store
import Design

/// Money that came back for a spending entry (transaction-form.tsx Refunds): all of it or part, in one go or several,
/// into any account. Each refund is its own entry (create_transactions with refundOf), so balances and statements see
/// it, and totals count it as spending undone rather than income. Removing one deletes that entry. Shown only for
/// entries that can take refunds (Transaction.canRefund), which needs a server that knows them.
struct RefundsCard: View {
    let t: Model.Transaction
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var adding = false
    @State private var removing: Model.Transaction.Refund?

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 8) {
            if !t.refunds.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(L.tx_refunds()).kFont(.small).foregroundStyle(c.ink3)
                    Spacer(minLength: 8)
                    Text(t.refundState == .full ? L.tx_refunded_full()
                         : L.tx_refunded_part(refunded: Money.format(t.refunded ?? 0, t.currency, theme.locale),
                                              spent: Money.format(-t.amount, t.currency, theme.locale)))
                        .kFont(.small).foregroundStyle(t.refundState == .full ? c.pos : c.ink3).money()
                }
                Card(tight: true) {
                    ForEach(Array(t.refunds.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Hairline() }
                        row(r)
                    }
                }
            }
            if kosha.canWrite && t.refundState != .full {
                KButton(t.refunds.isEmpty ? L.tx_mark_refunded() : L.tx_add_refund(), style: .secondary, size: .medium,
                        icon: "arrow-u-up-left") { adding = true }
            }
        }
        .kSheet(isPresented: $adding) { RefundSheet(t: t) { adding = false } }
        .background { Color.clear.kSheet(item: $removing) { r in RemoveRefund(r: r) { removing = nil } } }
    }

    private func row(_ r: Model.Transaction.Refund) -> some View {
        let c = theme.colors
        let money = Money.format(r.amount, r.currency, theme.locale)
        let account = kosha.wallet(r.accountId)?.name ?? ""
        let day = Day(r.day).map { dayText($0, theme.locale) } ?? r.day
        return HStack(spacing: 10) {
            PhIcon("arrow-u-up-left", size: 16, color: c.ink3)
            MoneyText(r.amount, r.currency, sign: .always, color: c.pos)
            AccountDot(c.account(kosha.colorIndex(r.accountId)))
            Text(account + " · " + day).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if kosha.canWrite {
                IconButton("x", label: L.tx_remove_refund(amount: money)) { removing = r }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(minHeight: theme.dims.row)
    }
}

/// Mark as refunded: the amount back on Kosha's keypad (what's still to come back, in the chosen account's currency,
/// until typed), the account it came back to and the day.
struct RefundSheet: View {
    let t: Model.Transaction
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var accountId: String
    @State private var input: String?
    /// nil until picked: today in the user's zone.
    @State private var day: Day?
    @State private var pickingDay = false
    @State private var busy = false

    init(t: Model.Transaction, close: @escaping () -> Void) {
        self.t = t
        self.close = close
        _accountId = State(initialValue: t.accountId)
    }

    var body: some View {
        if pickingDay {
            DateSheet(day: Binding(get: { day ?? kosha.today }, set: { day = $0 })) { pickingDay = false }
        } else {
            form
        }
    }

    private var currency: String { kosha.wallet(accountId)?.currency ?? t.currency }

    /// What's still to come back, in the chosen account's currency.
    private var left: Int64 {
        convert(t.refundLeft, from: t.currency, to: currency, perUsd: kosha.meta?.rates ?? [:])
    }

    private var shown: String { input ?? (left > 0 ? AmountSheet.text(left, currency) : "") }

    private var form: some View {
        let c = theme.colors
        let decimals = Money.decimals(currency)
        let minor = Keypad.minorUnits(shown, decimals: decimals)
        let accounts = (kosha.meta?.wallets ?? []).filter { !$0.isArchived || $0.id == t.accountId }
        return VStack(alignment: .leading, spacing: 8) {
            SheetHeader(t.refunds.isEmpty ? L.tx_mark_refunded() : L.tx_add_refund(), onClose: close)
            Text(L.tx_refund_to()).kFont(.small).foregroundStyle(c.ink3)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(accounts) { w in
                        Chip(w.name, on: w.id == accountId, soft: w.id != accountId, small: true) {
                            if w.id != accountId { input = nil }
                            accountId = w.id
                        } leading: { AccountDot(c.account(kosha.colorIndex(w.id))) }
                        .accessibilityAddTraits(w.id == accountId ? .isSelected : [])
                    }
                }
            }
            Button { pickingDay = true } label: {
                HStack(spacing: 10) {
                    PhIcon("calendar-blank", size: 18, color: c.ink2)
                    Text(L.tx_date()).frame(maxWidth: .infinity, alignment: .leading)
                    Text(DayFormat.label(day ?? kosha.today, today: kosha.today, theme.locale)).foregroundStyle(c.ink2)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(PressStyle())
            AmountDisplay(input: shown, currency: currency, kind: .income, note: L.tx_refund_amount())
            AmountKeypad(input: Binding(get: { shown }, set: { input = $0 }), decimals: decimals)
            KButton(L.tx_save_refund()) { if let minor, minor > 0 { save(minor) } }
                .disabled(busy || (minor ?? 0) <= 0)
        }
    }

    /// One new entry with the spending entry's payee, tags and event; the server gives it the entry's category. It
    /// carries its own id, so a retry is saved once.
    private func save(_ minor: Int64) {
        let entry = NewTransaction(accountId: accountId, payee: t.payee, amount: minor, day: (day ?? kosha.today).text, tags: t.tags,
                                   eventId: t.eventId, refundOf: t.id)
        busy = true
        Task {
            let done = await kosha.write(toasts, offline: L.tx_refund_failed()) { () -> JSONValue in
                try await kosha.api.post("/api/v1/transactions", createTransactions(entry, noEvent: t.eventId == nil))
            }
            busy = false
            if done != nil {
                toasts.show(L.tx_refund_saved(amount: Money.format(minor, currency, theme.locale)))
                close()
            }
        }
    }
}

/// "Remove this refund?": deleting the refund's entry, so it counts as spending again.
struct RemoveRefund: View {
    let r: Model.Transaction.Refund
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var busy = false

    var body: some View {
        VStack(spacing: 10) {
            SheetHeader(L.tx_remove_refund_title(), onClose: close)
            Text(L.tx_remove_refund_body(amount: Money.format(r.amount, r.currency, theme.locale),
                                         account: kosha.wallet(r.accountId)?.name ?? ""))
                .kFont(.small).foregroundStyle(theme.colors.ink2).frame(maxWidth: .infinity, alignment: .leading).money()
            KButton(L.common_remove(), style: .danger) {
                busy = true
                Task {
                    let done = await kosha.write(toasts, offline: L.tx_delete_failed()) { () -> JSONValue in
                        try await kosha.api.post("/api/v1/transactions/delete", JSONValue.object(["ids": .array([.string(r.id)])]))
                    }
                    busy = false
                    if done != nil {
                        toasts.show(L.tx_refund_removed())
                        close()
                    }
                }
            }
            .disabled(busy)
            KButton(L.common_cancel(), style: .secondary, action: close)
        }
    }
}
