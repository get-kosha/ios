import SwiftUI
import Model
import API
import Store
import Design

/// The sheets a detail opens.
enum DetailSheet: String, Identifiable {
    case amount, received, fee, payee, provider, note, category, account, from, to, date, tags, event, attach, delete,
        reconciled
    var id: String { rawValue }

    /// Long ones get the full height and a scroll view.
    var scrolls: Bool { [.category, .account, .from, .to, .tags, .event].contains(self) }
}

/// A transaction, saved as you edit (update_transactions): amount on the keypad, payee, category, account, date and
/// time, type, tags, note and event; its attachments; "At this payee"; Make this recurring…, Duplicate and Delete. A
/// reconciled entry asks before its amount, account or day changes. Read-only for the demo. Ported from TxDetail.kt.
struct TxDetailScreen: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: Loaded<Model.Transaction>?
    @State private var edited: Model.Transaction?
    @State private var sheet: DetailSheet?
    @State private var status: String?
    @State private var pending: [String: JSONValue]?

    private var t: Model.Transaction? { edited ?? loaded?.value }

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            DetailHeader(label: headerLabel, saved: status == "saved") { dismiss() }
            if let t {
                ScrollView {
                    Group { if let loan = t.loan { loanContent(t, loan) } else { content(t) } }
                        .padding(.horizontal, 16).padding(.bottom, 40)
                }
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
            await kosha.load("tx/\(id)", into: { (l: Loaded<Model.Transaction>) in
                loaded = l
                if !l.refreshing && l.value != nil { edited = nil }
            }) { api in
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

    private var kindLabel: String {
        guard let t else { return "" }
        if t.loan != nil { return L.loans_title() }
        if t.refundOf != nil { return L.tx_kind_refund() }
        if Categories.isNeutral(t.categoryId) { return L.tx_kind_correction() }
        return t.amount > 0 ? L.tx_kind_income() : L.tx_kind_expense()
    }

    private var headerLabel: String {
        switch status {
        case "saving": L.tx_header_saving(kind: kindLabel)
        case "saved": L.tx_header_saved(kind: kindLabel)
        default: kindLabel
        }
    }

    private func edit(_ s: DetailSheet) {
        if kosha.canWrite { sheet = s } else { toasts.show(L.common_demo_read_only(), warning: true) }
    }

    /// Saves one change. A reconciled entry asks first when the change touches its amount, account or day.
    private func save(_ change: [String: JSONValue], touchesReconciled: Bool) {
        guard let t else { return }
        guard kosha.canWrite else { return toasts.show(L.common_demo_read_only(), warning: true) }
        if t.reconciled && touchesReconciled {
            pending = change
            sheet = .reconciled
            return
        }
        pending = nil
        status = "saving"
        Task {
            let r = await kosha.write(toasts) { () -> Transactions in
                try await kosha.api.patch("/api/v1/transactions", patchBody(t.id, change))
            }
            if let fresh = r?.transactions.first {
                edited = fresh
                kosha.cache.write("tx/\(fresh.id)", fresh)
                status = "saved"
            } else {
                status = nil
            }
        }
    }

    /// A loan's funding or repayment is changed from the loan, as on the web.
    private func loanContent(_ t: Model.Transaction, _ loan: LoanLink) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MoneyText(t.amount, t.currency, sign: .always, font: .figure(40, .medium))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            Text(loan.person.isEmpty ? t.payee : loan.person).kFont(.head).frame(maxWidth: .infinity)
            HintLine(icon: "info", text: L.loans_edit_payment())
            KButton(L.loans_title(), style: .secondary, icon: "hand-coins") { nav.push(.loanDetail(id: loan.id)) }
        }
    }

    @ViewBuilder
    private func content(_ t: Model.Transaction) -> some View {
        let c = theme.colors
        let neutral = Categories.isNeutral(t.categoryId)
        let category = kosha.category(t.categoryId)
        VStack(spacing: 12) {
            Button { edit(.amount) } label: {
                MoneyText(t.amount, t.currency, sign: neutral ? .none : .always, font: .figure(40, .medium),
                          color: t.amount > 0 && !neutral ? c.pos : c.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint(L.tx_amount())
            Card(tight: true) {
                FieldRow(label: L.tx_payee(), action: { edit(.payee) }) { Text(t.payee.isEmpty ? "—" : t.payee).lineLimit(2) }
                Hairline()
                if t.refundOf != nil {
                    // A refund keeps its spending entry's category, which changes with that entry.
                    let name = category?.name ?? t.categoryName
                    Text(L.tx_refund_for(name: t.payee.isEmpty ? name : t.payee, category: name))
                        .kFont(.small).foregroundStyle(c.ink3)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FieldRow(label: L.tx_category(), action: { edit(.category) }) {
                        HStack(spacing: 8) {
                            PhIcon(categoryIconName(category?.icon), size: 18)
                            Text(category?.name ?? t.categoryName).lineLimit(1)
                        }
                    }
                }
                Hairline()
                FieldRow(label: L.tx_account(), action: { edit(.account) }) {
                    HStack(spacing: 8) {
                        AccountDot(c.account(kosha.colorIndex(t.accountId)))
                        Text(t.accountName).lineLimit(1)
                    }
                }
                Hairline()
                FieldRow(label: L.tx_date(), action: { edit(.date) }) {
                    Text((Day(t.day).map { dayText($0, theme.locale, weekday: true, year: true) } ?? t.day)
                         + " · " + DayFormat.time(t.hhmm, theme.locale))
                }
                if t.refundOf == nil { typeRow(t) }
            }
            tagsCard(t)
            if kosha.meta?.attachments == true { AttachmentsCard(t: t) { edit(.attach) } }
            if t.canRefund { RefundsCard(t: t) }
            if t.reconciled { ReconciledNote() }
            if !t.payee.trimmingCharacters(in: .whitespaces).isEmpty { AtPayee(payee: t.payee) }
            if kosha.canWrite {
                if t.refundOf == nil {
                    LinkCard(icon: "arrows-clockwise", label: L.add_make_recurring()) {
                        nav.push(.recurringForm(fromTransaction: t.id))
                    }
                }
                HStack(spacing: 8) {
                    if t.refundOf == nil {
                        KButton(L.tx_duplicate(), style: .secondary, size: .medium, icon: "copy") {
                            nav.openAdd(AddRequest(duplicateOf: t.id))
                        }
                    }
                    KButton(L.common_delete(), style: .danger, size: .medium, icon: "trash") { sheet = .delete }
                }
            }
        }
    }

    /// Expense · Income · Transfer. A refund has no type to change.
    @ViewBuilder
    private func typeRow(_ t: Model.Transaction) -> some View {
        let c = theme.colors
        Hairline()
        HStack(spacing: 12) {
            Text(L.tx_type()).kFont(.small).foregroundStyle(c.ink3).frame(width: 76, alignment: .leading)
            Segmented(
                [("expense", L.tx_kind_expense()), ("income", L.tx_kind_income()), ("transfer", L.tx_kind_transfer())],
                selection: Binding(get: { t.amount > 0 ? "income" : "expense" }, set: { kind in
                    if kind == "transfer" {
                        guard kosha.canWrite else { return toasts.show(L.common_demo_read_only(), warning: true) }
                        nav.openAdd(AddRequest(kind: .transfer, duplicateOf: t.id))
                    } else if (kind == "income") != (t.amount > 0) {
                        save(["amount": .number(Double(-t.amount))], touchesReconciled: true)
                    }
                }),
                small: true
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: theme.dims.settingsRow)
    }

    @ViewBuilder
    private func tagsCard(_ t: Model.Transaction) -> some View {
        let c = theme.colors
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L.tx_tags()).kFont(.small).foregroundStyle(c.ink3)
                FlowLayout(spacing: 6) {
                    ForEach(t.tags, id: \.self) { tag in
                        Chip("#\(tag)", small: true) { nav.push(.tagView(tag: tag, eventId: nil)) }
                            .accessibilityLabel(L.tx_tag_link(tag: tag))
                    }
                    Chip(L.tx_add_tags(), soft: true, small: true) { edit(.tags) } leading: { PhIcon("plus", size: 14) }
                }
                Hairline()
                Button { edit(.note) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.tx_note()).kFont(.small).foregroundStyle(c.ink3)
                        Text(t.note.isEmpty ? L.tx_note_placeholder() : t.note).foregroundStyle(t.note.isEmpty ? c.ink3 : c.ink)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                Hairline()
                let event = kosha.meta?.events.first { $0.id == t.eventId }
                HStack {
                    Text(L.tx_event()).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    Chip(event?.name ?? L.tx_add_to_event(), soft: true, small: true) {
                        if let event, !kosha.canWrite { nav.push(.tagView(tag: nil, eventId: event.id)) } else { edit(.event) }
                    } leading: { PhIcon("calendar-star", size: 14) }
                    if let event {
                        IconButton("arrow-right", label: L.app_act_event_all_dates()) {
                            nav.push(.tagView(tag: nil, eventId: event.id))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compact(_ s: DetailSheet) -> some View {
        if let t {
            let close = { sheet = nil }
            switch s {
            case .amount:
                AmountSheet(title: L.tx_amount(), currency: t.currency, initial: Int64(t.amount.magnitude),
                            kind: t.amount > 0 ? .income : .expense, button: L.common_save()) { minor in
                    close()
                    save(["amount": .number(Double(t.amount > 0 ? minor : -minor))], touchesReconciled: true)
                } close: { close() }
            case .payee:
                TextSheet(title: L.tx_payee(), start: t.payee, limit: 200, close: close) {
                    close()
                    save(["payee": .string($0.trimmingCharacters(in: .whitespaces))], touchesReconciled: false)
                }
            case .note:
                TextSheet(title: L.tx_note(), start: t.note, limit: 2000, close: close) {
                    close()
                    save(["note": .string($0.trimmingCharacters(in: .whitespacesAndNewlines))], touchesReconciled: false)
                }
            case .date:
                DateEditor(day: t.day, time: t.hhmm, withTime: true) { day, time in
                    close()
                    var change: [String: JSONValue] = ["time": .string(time)]
                    if day != t.day { change["day"] = .string(day) }
                    if day != t.day || time != t.hhmm { save(change, touchesReconciled: day != t.day) }
                }
            case .attach:
                AttachSheet(transactionId: t.id, close: close)
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
        if let t {
            let close = { sheet = nil }
            switch s {
            case .category:
                CategorySheet(title: L.tx_pick_category(), income: t.amount > 0, picked: t.subcategoryId ?? t.categoryId) { cat, sub in
                    close()
                    save(["categoryId": .string(cat), "subcategoryId": sub.map(JSONValue.string) ?? .null], touchesReconciled: false)
                } close: { close() }
            case .account:
                AccountSheet(title: L.tx_account(), selected: t.accountId) { id in
                    close()
                    if id != t.accountId { save(["accountId": .string(id)], touchesReconciled: true) }
                } close: { close() }
            case .tags:
                TagsSheet(start: t.tags, used: kosha.meta?.tags ?? [], close: close) { tags in
                    close()
                    save(["tags": .array(tags.map(JSONValue.string))], touchesReconciled: false)
                }
            case .event:
                ListPicker(
                    L.tx_event(),
                    choices: [Choice(id: "", title: L.tx_no_event())] + (kosha.meta?.events ?? []).map { Choice(id: $0.id, title: $0.name) },
                    selected: t.eventId ?? "",
                    onPick: { id in
                        close()
                        save(["eventId": id.isEmpty ? .null : .string(id)], touchesReconciled: false)
                    },
                    onClose: close
                )
            default:
                EmptyView()
            }
        }
    }
}

/// The top of a detail: back, the kind and whether it saved ("Expense · autosaved").
struct DetailHeader: View {
    let label: String
    let saved: Bool
    let back: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        HStack {
            IconButton("caret-left", label: L.common_back(), action: back)
            HStack(spacing: 6) {
                if saved { PhIcon("check", size: 14, color: c.pos) }
                Text(label).kFont(.small).foregroundStyle(c.ink3).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
    }
}

/// A label on the left, the value, and a caret: one editable field of a detail.
struct FieldRow<Value: View, End: View>: View {
    let label: String
    let action: (() -> Void)?
    let end: End
    let value: Value
    @Environment(\.kosha) private var theme

    init(label: String, action: (() -> Void)?, @ViewBuilder end: () -> End = { EmptyView() }, @ViewBuilder value: () -> Value) {
        self.label = label
        self.action = action
        self.end = end()
        self.value = value()
    }

    var body: some View {
        let c = theme.colors
        let row = HStack(spacing: 12) {
            Text(label).kFont(.small).foregroundStyle(c.ink3).frame(width: 76, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
            if End.self != EmptyView.self { end } else if action != nil { PhIcon("caret-right", size: 16, color: c.ink3) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: theme.dims.settingsRow)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(PressStyle()).accessibilityHint(label)
        } else {
            row
        }
    }
}

/// "Reconciled. Changing it means checking it again."
struct ReconciledNote: View {
    @Environment(\.kosha) private var theme
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PhIcon("check-circle", size: 18, color: theme.colors.pos)
            Text(L.tx_reconciled_note()).kFont(.small).foregroundStyle(theme.colors.ink2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Asked before a reconciled entry's amount, account or day changes.
struct ReconciledConfirm: View {
    let proceed: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            SheetHeader(L.tx_reconciled_note(), onClose: cancel)
            KButton(L.common_continue(), action: proceed)
            KButton(L.common_cancel(), style: .secondary, action: cancel)
        }
    }
}

/// Words in a sheet: payee, note or provider.
struct TextSheet: View {
    let title: String
    let limit: Int
    let close: () -> Void
    let onSave: (String) -> Void
    @State private var text: String

    init(title: String, start: String, limit: Int, close: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.title = title
        self.limit = limit
        self.close = close
        self.onSave = onSave
        _text = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 12) {
            SheetHeader(title, onClose: close)
            KField(title, text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }))
            KButton(L.common_save()) { onSave(text) }
        }
    }
}

/// The shared date sheet with the day and time kept here until it closes, then handed back as "YYYY-MM-DD" and "HH:mm".
struct DateEditor: View {
    let withTime: Bool
    let onDone: (String, String) -> Void
    @State private var day: Day
    @State private var time: String

    init(day: String, time: String, withTime: Bool, onDone: @escaping (String, String) -> Void) {
        self.withTime = withTime
        self.onDone = onDone
        _day = State(initialValue: Day(day) ?? Day(date: Date()))
        _time = State(initialValue: time)
    }

    var body: some View {
        DateSheet(title: L.tx_pick_date(), day: $day, time: withTime ? $time : nil) { onDone(day.text, time) }
    }
}

/// Tags: type them (a space or comma finishes one) or pick ones used before.
struct TagsSheet: View {
    let used: [String]
    let close: () -> Void
    let onSave: ([String]) -> Void
    @State private var tags: [String]
    @State private var typed = ""

    init(start: [String], used: [String], close: @escaping () -> Void, onSave: @escaping ([String]) -> Void) {
        self.used = used
        self.close = close
        self.onSave = onSave
        _tags = State(initialValue: start)
    }

    var body: some View {
        let prefix = cleanTag(typed)
        let suggestions = used.filter { !tags.contains($0) && $0.hasPrefix(prefix) }.prefix(12)
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(L.tx_tags(), onClose: close)
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Chip("#\(tag)", on: true, small: true) { tags.removeAll { $0 == tag } } leading: { PhIcon("x", size: 14) }
                        .accessibilityLabel(L.common_remove() + " #\(tag)")
                }
            }
            KField(L.tx_tags_placeholder(), text: Binding(get: { typed }, set: { new in
                if new.hasSuffix(" ") || new.hasSuffix(",") {
                    tags = unique(tags + parseTags(new))
                    typed = ""
                } else {
                    typed = new
                }
            }), icon: "hash")
            .keyboard(.text, capitalise: false)
            FlowLayout(spacing: 6) {
                ForEach(Array(suggestions), id: \.self) { tag in
                    Chip("#\(tag)", soft: true, small: true) {
                        tags.append(tag)
                        typed = ""
                    }
                }
            }
            KButton(L.common_save()) {
                onSave(unique(tags + parseTags(typed)))
            }
        }
    }
}

/// "At this payee: 14 payments · usually €27.60", opening Activity searched by the payee.
struct AtPayee: View {
    let payee: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var history: PayeeHistory?

    var body: some View {
        Group {
            if let h = history, h.count >= 2, let rates = kosha.meta?.rates {
                let shown = kosha.display
                // The amount entered most often, as the server counts it, in the shown currency.
                let usual = h.usual.map { abs(convert($0.amount, from: $0.currency, to: shown, perUsd: rates)) }
                LinkCard(
                    icon: "storefront", label: L.tx_at_payee(),
                    sub: usual.map { L.shell_search_payee_usually(count: String(h.count), amount: Money.format($0, shown, theme.locale)) }
                        ?? L.tx_count(count: h.count, n: String(h.count))
                ) {
                    nav.openActivity(ActivitySearch(query: String(payee.prefix(40))))
                }
            }
        }
        .task(id: payee) {
            await kosha.load("payee/\(payee)", into: { (l: Loaded<PayeeHistory>) in history = l.value }) { api in
                try await api.get("/api/app/payee-history", query: ["name": payee])
            }
        }
    }
}

/// The list without repeats, in order.
func unique(_ list: [String]) -> [String] { list.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
