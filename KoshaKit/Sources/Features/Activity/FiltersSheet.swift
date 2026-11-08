import SwiftUI
import Model
import API
import Store
import Design

/// Filters: Show, Account, Category, Amount (at least / at most, on the keypad, in each entry's own currency), Tag,
/// Event and balance corrections, with a live count on "Show N transactions". Category, tag, event and the amounts
/// open as pages inside the sheet.
struct FiltersSheet: View {
    let month: Month
    let onApply: (Filters) -> Void
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var draft: Filters
    @State private var page = ""
    @State private var count: Int?

    init(start: Filters, month: Month, onApply: @escaping (Filters) -> Void, close: @escaping () -> Void) {
        _draft = State(initialValue: start)
        self.month = month
        self.onApply = onApply
        self.close = close
    }

    var body: some View {
        Group {
            switch page {
            case "category": categoryPage
            case "tag": tagPage
            case "event": eventPage
            case "min", "max": amountPage
            default: mainPage
            }
        }
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let list: TransactionList? = try? await kosha.api.get(
                "/api/v1/transactions", query: draft.params(draft.period(month), limit: 1)
            )
            count = list?.total
        }
    }

    private var mainPage: some View {
        let c = theme.colors
        let m = kosha.meta
        let any = L.app_act_any()
        return VStack(alignment: .leading, spacing: 16) {
            SheetHeader(L.tx_filters()) {
                Button(L.tx_clear_all()) { draft = Filters(query: draft.query) }
                    .kFont(.sans(15, .regular)).foregroundStyle(c.ink2).frame(minHeight: 44).buttonStyle(PressStyle())
            }
            .padding(.bottom, -8)
            labeled(L.tx_show()) { TypeSegments(type: $draft.type) }
            labeled(L.tx_account()) {
                FlowLayout(spacing: 6) {
                    ForEach(kosha.activeWallets) { w in
                        Chip(w.name, on: draft.accountId == w.id, small: true) {
                            draft.accountId = draft.accountId == w.id ? nil : w.id
                        } leading: { AccountDot(c.account(kosha.colorIndex(w.id))) }
                    }
                }
            }
            labeled(L.tx_category()) {
                PickField(icon: "tag", value: kosha.category(draft.categoryId)?.name ?? L.tx_any_category(),
                          set: draft.categoryId != nil) { page = "category" }
            }
            labeled(L.tx_amount_note()) {
                HStack(spacing: 8) {
                    AmountField(label: L.app_act_at_least(), value: draft.minAmount, any: any) { page = "min" }
                    AmountField(label: L.tx_at_most(), value: draft.maxAmount, any: any) { page = "max" }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                labeled(L.tx_tag()) {
                    PickField(icon: "hash", value: draft.tag.map { "#\($0)" } ?? any, set: draft.tag != nil) { page = "tag" }
                }
                labeled(L.tx_event()) {
                    PickField(icon: "calendar-star", value: m?.events.first { $0.id == draft.eventId }?.name ?? any,
                              set: draft.eventId != nil) { page = "event" }
                }
            }
            Card(tight: true) {
                HStack {
                    Text(L.app_act_show_corrections()).frame(maxWidth: .infinity, alignment: .leading)
                    KSwitch(L.app_act_show_corrections(), isOn: $draft.corrections)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(minHeight: theme.dims.settingsRow)
            }
            KButton(count.map { L.tx_show_count(count: $0, n: String($0)) } ?? L.tx_show()) { onApply(draft) }
                .padding(.top, 8)
        }
    }

    private var categoryPage: some View {
        let cats = (kosha.meta?.categories ?? []).filter { !$0.isArchived && !Categories.isNeutral($0.id) }
        return ListPicker(
            L.tx_category(),
            choices: [Choice(id: "", title: L.tx_any_category())] + cats.map { Choice(id: $0.id, title: $0.name) },
            selected: draft.categoryId ?? "",
            onPick: { draft.categoryId = $0.isEmpty ? nil : $0; page = "" },
            onClose: { page = "" }
        )
    }

    private var tagPage: some View {
        ListPicker(
            L.tx_tag(),
            choices: [Choice(id: "", title: L.app_act_any())] + (kosha.meta?.tags ?? []).map { Choice(id: $0, title: "#\($0)") },
            selected: draft.tag ?? "",
            onPick: { draft.tag = $0.isEmpty ? nil : $0; page = "" },
            onClose: { page = "" }
        )
    }

    private var eventPage: some View {
        ListPicker(
            L.tx_event(),
            choices: [Choice(id: "", title: L.app_act_any())] + (kosha.meta?.events ?? []).map { Choice(id: $0.id, title: $0.name) },
            selected: draft.eventId ?? "",
            onPick: { draft.eventId = $0.isEmpty ? nil : $0; page = "" },
            onClose: { page = "" }
        )
    }

    private var amountPage: some View {
        let min = page == "min"
        return VStack(spacing: 8) {
            AmountSheet(
                title: min ? L.app_act_at_least() : L.tx_at_most(), currency: kosha.primary,
                initial: min ? draft.minAmount : draft.maxAmount, note: L.tx_amount_note()
            ) { v in
                if min { draft.minAmount = v } else { draft.maxAmount = v }
                page = ""
            } close: { page = "" }
            KButton(L.tx_clear(), style: .secondary) {
                if min { draft.minAmount = nil } else { draft.maxAmount = nil }
                page = ""
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A field that opens a picker: an icon, the value (ink3 when unset) and a caret.
struct PickField: View {
    let icon: String
    let value: String
    let set: Bool
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 10) {
                PhIcon(icon, size: 18, color: c.ink3)
                Text(value).foregroundStyle(set ? c.ink : c.ink3).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
    }
}

/// "At least 20.00": an amount bound in the Filters sheet, opening the keypad.
struct AmountField: View {
    let label: String
    let value: Int64?
    let any: String
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).kFont(.small).foregroundStyle(c.ink3)
                Text(value.map(plainAmount) ?? any).kFont(.num).foregroundStyle(value != nil ? c.ink : c.ink3)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
    }
}

/// Chips that wrap onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(i)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([i], size.width, size.height))
            }
        }
        return rows
    }
}

/// "Delete this transaction?" with its payee, amount and day; "Its receipt is deleted with it." when it has files. A
/// transfer is deleted from both accounts. `onDone` says whether it was deleted.
struct DeleteConfirm: View {
    let t: Model.Transaction
    let onDone: (Bool) -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var busy = false

    var body: some View {
        let c = theme.colors
        let transfer = t.transfer != nil
        let amount = transfer ? Money.format(t.sent, t.currency, theme.locale, sign: .none)
            : Money.format(t.amount, t.currency, theme.locale)
        VStack(spacing: 10) {
            PhIcon("trash", size: 24, color: c.bad)
                .frame(width: 52, height: 52)
                .background(c.bad.opacity(0.1), in: .circle)
                .padding(.top, 8)
            Text(transfer ? L.tx_delete_transfer_title() : L.tx_delete_transaction_title())
                .kFont(.sans(20, .semibold)).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            Text(L.tx_delete_summary(name: t.payee.isEmpty ? t.categoryName : t.payee, amount: amount,
                                     day: Day(t.day).map { dayText($0, theme.locale) } ?? t.day))
                .kFont(.small).foregroundStyle(c.ink2).multilineTextAlignment(.center).money()
            if transfer {
                Text(L.tx_delete_transfer_both()).kFont(.small).foregroundStyle(c.ink2).multilineTextAlignment(.center)
            }
            if t.attachmentCount > 0 {
                Text(L.app_act_receipt_deleted(count: t.attachmentCount)).kFont(.small).foregroundStyle(c.ink2)
                    .multilineTextAlignment(.center)
            }
            if t.reconciled {
                Text(L.tx_delete_reconciled()).kFont(.small).foregroundStyle(c.warn).multilineTextAlignment(.center)
            }
            KButton(transfer ? L.tx_delete_transfer() : L.tx_delete_transaction(), style: .danger) {
                busy = true
                Task {
                    let done = await kosha.write(toasts, offline: L.tx_delete_failed()) { () -> JSONValue in
                        try await kosha.api.post("/api/v1/transactions/delete",
                                                 JSONValue.object(["ids": .array([.string(t.id)])]))
                    }
                    busy = false
                    if done != nil { toasts.show(L.tx_deleted()) }
                    onDone(done != nil)
                }
            }
            .disabled(busy)
            .padding(.top, 4)
            KButton(L.common_cancel(), style: .secondary) { onDone(false) }
        }
        .frame(maxWidth: .infinity)
    }
}
