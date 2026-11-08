import SwiftUI
import UniformTypeIdentifiers
import Model
import API
import Store
import Design

/// A paid payment or a skipped one, for the Payments list.
private struct PaymentLine {
    let due: String
    let day: String
    let paid: Paid?
    let skipped: Instance?
}

private enum Open: Identifiable {
    case payment(Instance, pay: Bool)
    case end
    case delete
    var id: String {
        switch self {
        case .payment(let i, let pay): "p\(i.dueDay)\(pay)"
        case .end: "end"
        case .delete: "delete"
        }
    }
}

/// One schedule: its next payment (pay, enter the amount, change or skip it), what was paid so far and per month, the
/// payments with their bills, documents by month, its details, and ending or deleting it. Ported from
/// RecurringDetail.kt.
struct RecurringDetailScreen: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = Loaded<SubscriptionsData>()
    @State private var files: [ScheduleFile] = []
    @State private var open: Open?
    @State private var docs = false
    @State private var all = false

    var body: some View {
        Group {
            if let s = loaded.value?.subscriptions.first(where: { $0.id == id }) {
                detail(s)
                    .navigationDestination(isPresented: $docs) { DocumentsPage(s: s, files: files) }
                    .kSheet(item: $open) { o in sheet(o, s) }
            } else {
                Page(L.subs_title()) { if loaded.refreshing { Skeleton(height: 160) } else { LoadingNote() } }
            }
        }
        .task(id: kosha.version) {
            await loadSubscriptions(kosha) { loaded = $0 }
            guard kosha.meta?.attachments == true else { return }
            let id = id
            await kosha.load("recurring/\(id)/files", into: { (l: Loaded<[ScheduleFile]>) in files = l.value ?? [] }) {
                try await $0.get("/api/app/recurring/\(id)/attachments")
            }
        }
    }

    private func detail(_ s: Sub) -> some View {
        let c = theme.colors
        let loc = theme.locale
        let cat = kosha.category(s.categoryId)
        let kind = switch s.group {
        case .bills: L.subs_kind_bill()
        case .subscriptions: L.subs_kind_subscription()
        case .income: L.subs_kind_income()
        case .transfers: L.subs_kind_transfer()
        }
        let since = s.history.last?.day ?? s.startDay
        let every = everyText(s.n, s.period)
        let sign: Sign = s.isTransfer ? .none : .always
        let docsOn = kosha.meta?.attachments == true && !s.isTransfer
        return Page(s.title(kosha), subtitle: L.subs_detail_meta(kind: kind, every: every, date: fmtDay(since, "MMMy", loc))) {
            KButton(L.common_edit(), style: .secondary, size: .small) { nav.push(.recurringForm(id: s.id)) }
        } content: {
            nextCard(s, cat: cat, sign: sign)

            let paidTotal = s.history.map(\.amount).reduce(0, +)
            let recent = s.history.prefix(12)
            let (perMonth, hint): (Int64, String) = if s.isVariable && !recent.isEmpty {
                (Int64((abs(Double(recent.map(\.amount).reduce(0, +)) / Double(recent.count)) * perMonthFactor(s.period) / Double(s.n)).rounded()),
                 L.app_rec_average_last(count: recent.count))
            } else {
                (Int64(s.perMonth.magnitude), inText(Int64(s.amount.magnitude), s.currency, theme) + " " + every)
            }
            HStack(spacing: 12) {
                stat(s.isTransfer ? L.subs_moved_so_far() : L.subs_paid_so_far(), Int64(paidTotal.magnitude), s.currency,
                     L.app_rec_payments_count(count: s.history.count))
                stat(L.subs_column_per_month(), perMonth, s.currency, hint)
            }

            let lines = (s.history.map { PaymentLine(due: $0.dueDay ?? $0.day, day: $0.day, paid: $0, skipped: nil) }
                + s.instances.filter { $0.status == "skipped" }.map { PaymentLine(due: $0.dueDay, day: $0.day, paid: nil, skipped: $0) })
                .sorted { $0.due > $1.due }
            Card(tight: true) {
                HStack {
                    Text(L.subs_payments()).kFont(.head).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if lines.count > 5 && !all {
                        Button { all = true } label: {
                            Text(L.subs_all_payments(count: "\(lines.count)")).kFont(.small).foregroundStyle(c.ink2)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                if lines.isEmpty {
                    Text(L.subs_no_payments()).kFont(.small).foregroundStyle(c.ink3).padding(16)
                }
                ForEach(Array((all ? lines : Array(lines.prefix(5))).enumerated()), id: \.offset) { _, line in
                    Hairline()
                    PaymentRow(s: s, line: line, files: files.filter { f in line.paid.map { f.transactionId == $0.id } ?? false }) {
                        if let skipped = line.skipped {
                            open = .payment(skipped, pay: false)
                        } else if let p = line.paid {
                            nav.push(p.transferId.map { .transferDetail(id: $0) } ?? .txDetail(id: p.id))
                        }
                    }
                }
                if docsOn && !files.isEmpty {
                    Hairline()
                    LinkRow(icon: "file-zip", title: L.app_rec_documents_by_month(), detail: nil, count: "\(files.count)", tile: false) {
                        docs = true
                    }
                }
            }

            Card(tight: true) {
                DetailRow(s.isTransfer ? L.subs_from() : L.subs_account()) {
                    AccountDot(c.account(kosha.colorIndex(s.walletId)))
                    Text(kosha.wallet(s.walletId)?.name ?? "")
                }
                Hairline()
                if s.isTransfer {
                    DetailRow(L.subs_to()) {
                        AccountDot(c.account(kosha.colorIndex(s.toWalletId)))
                        Text(kosha.wallet(s.toWalletId)?.name ?? "")
                    }
                } else {
                    DetailRow(L.subs_category()) {
                        PhIcon(categoryIconName(cat?.icon), size: 18)
                        Text(cat?.name ?? "")
                    }
                }
                Hairline()
                DetailRow(L.subs_amount()) {
                    if s.isVariable { Text(L.subs_variable()) } else {
                        MoneyText(s.isTransfer ? Int64(s.amount.magnitude) : s.amount, s.currency, sign: sign)
                    }
                }
                Hairline()
                DetailRow(L.subs_ends()) { Text(s.endDay.map { fmtDay($0, "dMMMy", loc) } ?? L.subs_never()) }
            }

            HStack(spacing: 8) {
                if s.ended {
                    KButton(L.subs_resume(), style: .secondary, size: .medium) { resume(s) }
                } else {
                    KButton(endThis(s.group), style: .secondary, size: .medium) { open = .end }
                }
                KButton(L.common_delete(), style: .danger, size: .medium) { open = .delete }
            }
            .disabled(!kosha.canWrite)
            if !s.ended {
                Text(L.subs_end_description()).kFont(.xs).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func nextCard(_ s: Sub, cat: MetaCategory?, sign: Sign) -> some View {
        let c = theme.colors
        let loc = theme.locale
        Card {
            if s.ended {
                Text(L.subs_ended_on(date: fmtDay(s.endDay ?? s.startDay, "dMMMy", loc))).kFont(.head)
                Text(L.subs_ended_hint()).kFont(.small).foregroundStyle(c.ink3)
            } else if let next = s.next {
                // One payment can come from another account, in that account's currency.
                let moved = next.walletId.flatMap { $0 != s.walletId ? kosha.wallet($0) : nil }
                HStack {
                    Text(L.subs_next_payment()).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    if s.isVariable { Pill(L.subs_varies()) }
                }
                HStack(spacing: 12) {
                    IconTile(s.isTransfer ? "arrows-left-right" : categoryIconName(cat?.icon))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fmtDay(next.day, "EEEdMMM", loc)).kFont(.head).foregroundStyle(next.status == "overdue" ? c.warn : c.ink)
                        Text([
                            s.isVariable ? L.app_rec_asks_that_day() : s.auto ? L.subs_auto_recorded() : L.subs_mark_when_out(),
                            next.edited ? L.subs_changed_once() : nil,
                            moved?.name,
                            s.endDay.map { L.subs_ends_on(date: fmtDay($0, "dMMMy", loc)) },
                        ].compactMap { $0 }.joined(separator: " · ")).kFont(.xs).foregroundStyle(c.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !s.isVariable {
                        MoneyText(s.isTransfer ? Int64(next.amount.magnitude) : next.amount, moved?.currency ?? s.currency, sign: sign)
                    }
                }
                HStack(spacing: 8) {
                    if s.isVariable {
                        KButton(L.subs_enter_amount_button(), size: .medium) { open = .payment(next, pay: true) }
                    } else {
                        KButton(s.isTransfer ? L.subs_mark_done_now() : L.subs_mark_paid_now(), size: .medium) {
                            act(s, next, "paid", L.subs_marked_paid())
                        }
                    }
                    KButton(L.subs_skip_this(), style: .secondary, size: .medium) { act(s, next, "skipped", L.subs_skipped()) }
                }
                .disabled(!kosha.canWrite)
                if !s.isVariable {
                    KButton(L.subs_change_amount(), style: .soft, size: .medium) { open = .payment(next, pay: false) }
                        .disabled(!kosha.canWrite)
                }
            } else {
                Text(L.subs_no_more_scheduled()).kFont(.small).foregroundStyle(c.ink3)
            }
        }
    }

    private func stat(_ label: String, _ minor: Int64, _ currency: String, _ hint: String) -> some View {
        Card {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
            MoneyText(minor, currency, sign: .none, font: .figure(20, .regular))
            Text(hint).kFont(.xs).foregroundStyle(theme.colors.ink3)
        }
    }

    private func act(_ s: Sub, _ instance: Instance, _ status: String, _ done: String) {
        Task {
            let ok = await kosha.run(toasts) { api in
                try await api.send("PATCH", "/api/v1/recurring/\(s.id)/payments/\(instance.dueDay)", body: jsonBody(["status": .string(status)]))
            }
            if ok != nil { toasts.show(done) }
        }
    }

    /// Resuming keeps the old schedule from today on and doesn't back-fill the gap (subscriptions.tsx setEnd).
    private func resume(_ s: Sub) {
        let today = kosha.today
        let start = Day(s.startDay) ?? today
        let next = start >= today ? start : Schedule.next(start, every: s.n, unit: s.period, end: nil, from: today) ?? today
        Task {
            let ok = await kosha.run(toasts) { api in
                try await api.send("PATCH", "/api/v1/recurring/\(s.id)", body: jsonBody(["endDay": .null, "startDay": .string(next.text)]))
            }
            if ok != nil { toasts.show(L.subs_resumed_toast(name: s.name)) }
        }
    }

    @ViewBuilder
    private func sheet(_ o: Open, _ s: Sub) -> some View {
        switch o {
        case .payment(let instance, let pay):
            PaymentSheet(s: s, instance: instance, pay: pay) { open = nil }
        case .end:
            ConfirmSheet(title: L.subs_end_title(name: s.name), text: L.subs_end_description(), confirm: endShort(s.group), onConfirm: {
                let today = kosha.today.text
                Task {
                    let ok = await kosha.run(toasts) { api in
                        try await api.send("PATCH", "/api/v1/recurring/\(s.id)", body: jsonBody(["endDay": .string(today)]))
                    }
                    open = nil
                    if ok != nil { toasts.show(L.subs_ended_toast(name: s.name)) }
                }
            }, close: { open = nil })
        case .delete:
            ConfirmSheet(title: L.subs_delete_title(name: s.name), text: L.subs_delete_description(), confirm: L.common_delete(), onConfirm: {
                Task {
                    let ok = await kosha.run(toasts) { api in try await api.send("DELETE", "/api/v1/recurring/\(s.id)") }
                    open = nil
                    if ok != nil {
                        toasts.show(L.subs_deleted())
                        dismiss()
                    }
                }
            }, close: { open = nil })
        }
    }

    private func endThis(_ g: SubGroup) -> String {
        switch g {
        case .bills: L.subs_end_this_bill()
        case .subscriptions: L.subs_end_this_subscription()
        case .income: L.subs_end_this_income()
        case .transfers: L.subs_end_this_transfer()
        }
    }

    private func endShort(_ g: SubGroup) -> String {
        switch g {
        case .bills: L.subs_end_bill()
        case .subscriptions: L.subs_end_subscription()
        case .income: L.subs_end_income()
        case .transfers: L.subs_end_transfer()
        }
    }
}

private struct PaymentRow: View {
    let s: Sub
    let line: PaymentLine
    let files: [ScheduleFile]
    let action: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        ListRow(action: action) {
            Text(fmtDay(line.day, "dMMM", theme.locale)).kFont(.figure(13, .regular)).foregroundStyle(c.ink3).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let paid = line.paid {
                    Text(s.isTransfer ? L.subs_moved() : L.subs_paid()).kFont(.small)
                    let changed = !s.isVariable && paid.amount.magnitude != s.amount.magnitude
                    let elsewhere = !paid.walletId.isEmpty && paid.walletId != s.walletId
                    if !files.isEmpty {
                        HStack(spacing: 4) {
                            PhIcon("paperclip", size: 14, color: c.ink3)
                            Text(files.map(\.name).joined(separator: ", ")).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                        }
                    } else if elsewhere {
                        Text(kosha.wallet(paid.walletId)?.name ?? "").kFont(.xs).foregroundStyle(c.ink3)
                    } else if changed {
                        Text(L.subs_changed_once()).kFont(.xs).foregroundStyle(c.ink3)
                    }
                } else {
                    Text(L.subs_skipped()).kFont(.small).foregroundStyle(c.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let paid = line.paid {
                MoneyText(s.isTransfer ? Int64(paid.amount.magnitude) : paid.amount, s.currency, sign: s.isTransfer ? .none : .always,
                          color: s.isTransfer ? c.ink2 : c.ink)
            } else {
                Text("—").kFont(.num).foregroundStyle(c.ink3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Enter one payment, or change it before it is due: the amount on the keypad with the account pill ("Usually about
/// €84.00"), its day, a bill to attach, Reset to regular, and Record payment. Only this payment changes; it can be paid
/// from another account. Ported from Payment.kt.
struct PaymentSheet: View {
    let s: Sub
    let instance: Instance
    let pay: Bool
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var from: String = ""
    @State private var input = ""
    @State private var fresh = false
    @State private var prefilled = ""
    @State private var day = Day(2000, 1, 1)
    @State private var panel: Panel = .keypad
    @State private var file: (name: String, type: String, data: Data)?
    @State private var picking = false
    @State private var busy = false
    @State private var started = false

    enum Panel { case keypad, calendar, accounts }

    /// The account it's paid from: this payment's own, else the schedule's. For a transfer, the one it leaves.
    private var usual: String { instance.walletId ?? s.walletId }

    private func setUp() {
        guard !started else { return }
        started = true
        from = usual
        day = Day(instance.day) ?? kosha.today
        reset(for: from)
    }

    /// A variable amount starts empty so it can't be saved as the estimate by accident; so does one from an account in
    /// another currency, which must be given in that currency.
    private func reset(for account: String) {
        let currency = kosha.wallet(account)?.currency ?? s.currency
        let start: Int64? = (pay && s.isVariable && !instance.edited) || currency != s.currency ? nil : Int64(instance.amount.magnitude)
        prefilled = start.map { inputOf($0, currency) } ?? ""
        fresh = !prefilled.isEmpty
        input = ""
    }

    var body: some View {
        let c = theme.colors
        let currency = kosha.wallet(from)?.currency ?? s.currency
        let shown = fresh ? prefilled : input
        let minor = signedMinor(shown, currency)
        VStack(spacing: 12) {
            SheetHeader("\(s.title(kosha)) · \(fmtDay(instance.dueDay, "dMMM", theme.locale))") { close() }
                .padding(.bottom, -8)
            Text(!pay ? L.subs_edit_once_description() : s.isTransfer ? L.subs_pay_transfer_description() : L.subs_pay_description())
                .kFont(.body).foregroundStyle(c.ink2).frame(maxWidth: .infinity, alignment: .leading)
            AmountDisplay(input: shown, currency: currency, kind: s.isTransfer ? .transfer : s.amount < 0 ? .expense : .income)
            AccountPill(kosha.wallet(from)?.name ?? "", color: c.account(kosha.colorIndex(from)), open: panel == .accounts) {
                panel = panel == .accounts ? .keypad : .accounts
            }
            let usual = inText(Int64(s.amount.magnitude), s.currency, theme)
            Text(figured(L.app_rec_usually(amount: usual), [usual], size: 13, theme)).foregroundStyle(c.ink2)
            HStack(spacing: 8) {
                Chip(fmtDay(day, "EEEdMMM", theme.locale), on: panel == .calendar, action: {
                    panel = panel == .calendar ? .keypad : .calendar
                }) { PhIcon("calendar-blank", size: 18) }
                if pay && kosha.meta?.attachments == true && !s.isTransfer {
                    Chip(file?.name ?? L.app_rec_attach_bill(), action: { picking = true }) { PhIcon("paperclip", size: 18) }
                }
            }
            switch panel {
            case .keypad:
                AmountKeypad(input: Binding(get: { fresh ? "" : input }, set: { fresh = false; input = $0 }),
                             decimals: Money.decimals(currency))
            case .calendar:
                MonthGrid(month: day.monthOf, selected: day, today: kosha.today) { day = $0; panel = .keypad }
            case .accounts:
                AccountList(accountChoices(kosha, theme, except: s.toWalletId), selected: from) { id in
                    from = id
                    reset(for: id)
                    panel = .keypad
                }
            }
            HStack(spacing: 8) {
                if instance.edited || instance.status == "skipped" {
                    KButton(L.subs_reset_regular(), style: .secondary) { resetRegular() }
                }
                KButton(pay ? L.app_rec_record_payment() : L.subs_save_this_payment()) { save(minor) }
                    .disabled(busy || (minor ?? 0) <= 0)
            }
        }
        .onAppear(perform: setUp)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .pdf]) { result in
            if case .success(let url) = result { file = readPicked(url) }
        }
    }

    private func save(_ minor: Int64?) {
        guard let value = minor else { return }
        busy = true
        let amount = Int64(value.magnitude) * (s.amount < 0 ? -1 : 1)
        let fields: [String: JSONValue?] = [
            "status": .string(pay ? "paid" : "scheduled"), "amount": .int(amount), "day": .string(day.text),
            "accountId": from != usual ? .string(from) : nil,
        ]
        let path = "/api/v1/recurring/\(s.id)/payments/\(instance.dueDay)"
        let bill = file
        let sid = s.id, due = instance.dueDay
        Task {
            let result: PaymentResult? = await kosha.run(toasts) { api in try await api.patch(path, jsonBody(fields)) }
            if result != nil, let bill {
                // A payment in the past comes back as null once paid, so find its row in the history.
                let ok = await kosha.run(toasts) { api -> Bool in
                    var tx = result?.payment?.transactionId
                    if tx == nil {
                        let data: SubscriptionsData = try await api.get("/api/app/subscriptions")
                        tx = data.subscriptions.first { $0.id == sid }?.history.first { $0.dueDay == due }?.id
                    }
                    guard let tx else { return false }
                    try await api.upload("/api/app/transactions/\(tx)/attachments", name: bill.name, type: bill.type, data: bill.data)
                    return true
                }
                if ok != true { toasts.show(L.tx_attach_failed(), warning: true) }
            }
            busy = false
            if result != nil {
                if bill == nil { toasts.show(pay ? L.subs_recorded() : L.subs_payment_updated()) }
                close()
            }
        }
    }

    private func resetRegular() {
        let path = "/api/v1/recurring/\(s.id)/payments/\(instance.dueDay)"
        Task {
            let ok = await kosha.run(toasts) { api in try await api.send("PATCH", path, body: jsonBody(["status": .string("scheduled")])) }
            if ok != nil { close() }
        }
    }
}

/// The account picker's rows: open accounts with their colour (by position in the account order) and balance.
@MainActor
func accountChoices(_ kosha: Kosha, _ theme: KTheme, except: String? = nil) -> [AccountChoice] {
    kosha.activeWallets.filter { $0.id != except }.map { w in
        AccountChoice(id: w.id, name: w.name, color: theme.colors.account(kosha.colorIndex(w.id)),
                      detail: "\(accountTypeName(w.kind)) · \(w.currency.uppercased())",
                      balance: Money.format(w.balance, w.currency, theme.locale), group: "")
    }
}

/// Documents by month for a schedule's payments: tick months and share them as one zip through the share sheet. Kosha
/// downloads each file, stores them uncompressed in a zip in the temporary folder and hands it to other apps.
struct DocumentsPage: View {
    let s: Sub
    let files: [ScheduleFile]
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var picked: Set<String> = []
    @State private var busy = false

    var body: some View {
        let c = theme.colors
        let all = picked.count == files.count
        let sorted = files.sorted { ($0.dueDay ?? $0.day) > ($1.dueDay ?? $1.day) }
        Page(L.tx_documents(), subtitle: "\(s.name) · \(files.count)") {
            Button { picked = all ? [] : Set(files.map(\.id)) } label: {
                Text(all ? L.tx_select_none() : L.tx_select_all()).kFont(.small).foregroundStyle(c.ink2)
                    .padding(.horizontal, 8).frame(minHeight: 48)
            }
            .buttonStyle(PressStyle())
        } footer: {
            KButton(L.app_rec_share_zip(count: picked.count), icon: "export") { share(sorted) }
                .disabled(picked.isEmpty || busy)
        } content: {
            Card(tight: true) {
                ForEach(sorted.indices, id: \.self) { i in
                    let f = sorted[i]
                    let on = picked.contains(f.id)
                    if i > 0 { Hairline() }
                    ListRow(action: { if on { picked.remove(f.id) } else { picked.insert(f.id) } }) {
                        Tick(on)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fmtDay(f.dueDay ?? f.day, "MMMMy", theme.locale))
                            Text("\(f.name) · \(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))")
                                .kFont(.small).foregroundStyle(c.ink3).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let p = s.history.first(where: { $0.id == f.transactionId }) {
                            MoneyText(p.amount, s.currency, sign: .always, font: .figure(13, .regular), color: c.ink2)
                        }
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(L.app_rec_zip_hint()).kFont(.xs).foregroundStyle(c.ink3)
        }
    }

    private func share(_ sorted: [ScheduleFile]) {
        let chosen = sorted.filter { picked.contains($0.id) }
        let zipName = L.tx_docs_zip_name(name: s.name)
        busy = true
        Task {
            do {
                let names = Schedule.archiveNames(chosen.map { ($0.dueDay ?? $0.day, $0.name) })
                var entries: [(name: String, data: Data)] = []
                for (name, f) in zip(names, chosen) { entries.append((name, try await kosha.api.bytes("/api/app/attachments/\(f.id)"))) }
                let safe = String(zipName.map { "\\/:*?\"<>|".contains($0) ? "-" : $0 })
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).zip")
                try StoredZip.make(entries).write(to: url, options: .atomic)
                shareFile(url)
            } catch KoshaError.offline {
                toasts.show(L.common_offline_title(), warning: true)
            } catch {
                toasts.show(L.tx_zip_failed(), warning: true)
            }
            busy = false
        }
    }
}
