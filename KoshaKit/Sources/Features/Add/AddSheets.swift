import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Model
import Store
import Design

/// The sheet Add has open. Account, date and category use the shared pickers; the rest are Add's own.
struct AddSheets: View {
    @Bindable var model: AddModel
    let sheet: AddSheet
    @Environment(\.kosha) private var theme

    var body: some View {
        let close = { model.sheet = nil }
        switch sheet {
        case .account:
            AccountSheet(title: model.transfer ? L.add_from() : L.add_account(), selected: model.account?.id,
                         onPick: { model.pickAccount($0, to: false) }, close: close)
        case .to:
            AccountSheet(title: L.add_to(), selected: model.toAccount?.id, exclude: model.account?.id,
                         onPick: { model.pickAccount($0, to: true) }, close: close)
        case .date:
            DateSheet(day: $model.day, time: Binding(
                get: { model.time ?? Dates.time(model.kosha.tz) },
                // The wheels report where they rest when they open; only a real change sets the time.
                set: { if $0 != (model.time ?? Dates.time(model.kosha.tz)) { model.time = $0 } }
            ), close: close)
        case .category:
            CategorySheet(
                title: model.viaNext ? L.tx_pick_category() : L.add_category(), reason: model.viaNext ? reason : nil,
                income: model.kind == .income,
                picked: model.categoryId != nil ? model.subcategoryId ?? model.categoryId : nil,
                guess: model.categoryId == nil ? model.chosen : nil, aiGuess: model.chosenIsAi,
                onPick: { top, sub in
                    if model.viaNext { model.save(again: false, top: top, sub: sub) } else { model.pickCategory(top, sub) }
                },
                close: close
            )
        case .note: NoteSheet(model: model, close: close)
        case .fee: FeeSheet(model: model, close: close)
        case .describe: DescribeSheet(model: model, close: close)
        case .repeating: RepeatSheet(model: model, close: close)
        }
    }

    private var reason: String {
        let payee = model.payee.trimmingCharacters(in: .whitespaces)
        let income = model.kind == .income
        if !payee.isEmpty { return income ? L.app_add_why_income_new(payee: payee) : L.app_add_why_expense_new(payee: payee) }
        return income ? L.app_add_why_income() : L.app_add_why_expense()
    }
}

// MARK: Repeat

/// Repeat (RepeatSheet): Never · Weekly · Monthly · Yearly with the rule read back from the entry's day and a Custom
/// link (every N days, weeks, months or years); List it as Bill or Subscription for an expense; Ends; Record payments
/// automatically (default from Settings › Recurring); what will happen. Nothing is saved until the primary button.
struct RepeatSheet: View {
    let model: AddModel
    let close: () -> Void
    @Environment(\.kosha) private var theme
    @State private var draft: Repeat
    @State private var on: Bool
    @State private var custom: Bool
    @State private var pickingEnd = false
    @State private var endMonth: Month

    init(model: AddModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let auto = model.meta?.pref("default_auto_pay", "1") == "1"
        _draft = State(initialValue: model.repeating ?? Repeat(autoPay: auto))
        _on = State(initialValue: model.repeating != nil)
        _custom = State(initialValue: model.repeating.map { !$0.preset } ?? false)
        _endMonth = State(initialValue: (model.repeating?.endDay ?? model.day).monthOf)
    }

    private var preset: String {
        guard on else { return "never" }
        return custom ? "custom" : draft.unit
    }

    var body: some View {
        let c = theme.colors
        let locale = theme.locale
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(L.app_add_repeat(), onClose: close)
            Segmented([("never", L.subs_never()), ("week", L.app_ios_add_weekly()), ("month", L.app_ios_add_monthly()),
                       ("year", L.app_ios_add_yearly())],
                      selection: Binding(get: { preset }, set: { v in
                          if v == "never" { on = false } else {
                              on = true
                              custom = false
                              draft.every = 1
                              draft.unit = v
                          }
                      }))
            HStack {
                Text(on ? ruleText(draft, day: model.day, locale) : L.app_add_repeat_once())
                    .foregroundStyle(c.ink2)
                Spacer()
                Button {
                    on = true
                    custom.toggle()
                } label: {
                    Text(L.app_add_repeat_custom()).underline().foregroundStyle(c.ink)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(custom ? .isSelected : [])
            }
            .padding(.horizontal, 4)
            if on && custom {
                HStack(spacing: 12) {
                    Text(L.subs_repeats_every()).foregroundStyle(c.ink2)
                    KStepper(L.subs_repeats_every(), value: $draft.every, in: 1...365)
                    Spacer()
                }
                Segmented([("day", L.subs_interval_day(count: draft.every)), ("week", L.subs_interval_week(count: draft.every)),
                           ("month", L.subs_interval_month(count: draft.every)), ("year", L.subs_interval_year(count: draft.every))],
                          selection: $draft.unit, small: true)
            }
            if on {
                if model.kind == .expense {
                    Text(L.app_ios_add_list_as()).kFont(.small).foregroundStyle(c.ink3).padding(.horizontal, 4).padding(.top, 4)
                    Segmented([("repetitive", L.subs_kind_bill()), ("subscription", L.subs_kind_subscription())],
                              selection: $draft.kind)
                }
                Card(tight: true) {
                    ListRow(action: { pickingEnd.toggle() }) {
                        Text(L.subs_ends()).kFont(.head).frame(maxWidth: .infinity, alignment: .leading)
                        Text(draft.endDay.map { DayFormat.short($0, locale) } ?? L.subs_never()).foregroundStyle(c.ink2)
                        PhIcon(pickingEnd ? "caret-down" : "caret-right", size: 16, color: c.ink3)
                    }
                    if pickingEnd {
                        VStack(alignment: .leading, spacing: 8) {
                            Chip(L.subs_never(), on: draft.endDay == nil, small: true) { draft.endDay = nil }
                            MonthHeader(month: endMonth) { endMonth = endMonth.adding($0) }
                            MonthGrid(month: endMonth, selected: draft.endDay, today: model.today) { d in
                                if d >= model.day { draft.endDay = d }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    Hairline()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.subs_auto_pay()).kFont(.head)
                            Text(L.app_ios_add_auto_hint()).kFont(.small).foregroundStyle(c.ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        KSwitch(L.subs_auto_pay(), isOn: $draft.autoPay)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: theme.dims.settingsRow)
                }
                Text(outcome).kFont(.small).foregroundStyle(c.ink3).padding(.horizontal, 4)
            }
            KButton(L.common_done()) {
                model.repeating = on ? draft : nil
                close()
            }
            .padding(.top, 8)
        }
    }

    /// What will happen: today's payment is added now and where the next shows; or when the first is due.
    private var outcome: String {
        let list = switch model.kind {
        case .income: L.subs_group_income()
        case .transfer: L.subs_group_transfers()
        case .expense: draft.kind == "subscription" ? L.subs_group_subscriptions() : L.subs_group_bills()
        }
        let locale = theme.locale
        if model.day > model.today { return L.app_ios_add_repeat_future(date: DayFormat.short(model.day, locale), list: list) }
        let next = DayFormat.short(draft.next(after: model.day), locale)
        return model.day == model.today ? L.app_ios_add_repeat_today(date: next, list: list)
            : L.app_ios_add_repeat_past(date: next, list: list)
    }
}

// MARK: Fee and rate

private enum FeeField { case fee, received, rate }

/// Fee and rate for a transfer (FeeSheet): the fee in From's currency, what arrived in To's, the provider, and the rate,
/// with what it cost against the market rate. Typing the rate works out what arrived, and the other way round.
struct FeeSheet: View {
    @Bindable var model: AddModel
    let close: () -> Void
    @Environment(\.kosha) private var theme
    @State private var field: FeeField = .fee
    @FocusState private var viaFocused: Bool

    var body: some View {
        let c = theme.colors
        let locale = theme.locale
        let s = model.sides
        let f = model.fee
        let (grouping, decimal) = Money.separators(locale)
        let show = { (t: String) in t.isEmpty ? "" : Keypad.group(t, grouping: grouping, decimal: decimal) }
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(s.cross ? L.add_fee_and_rate() : L.add_fee(), onClose: close)
            if let from = model.account {
                HStack(spacing: 6) {
                    AccountDot(c.account(model.kosha.colorIndex(from.id)), size: 10)
                    Text(from.name).lineLimit(1)
                    if let to = model.toAccount {
                        PhIcon("arrow-right", size: 16, color: c.ink3)
                        AccountDot(c.account(model.kosha.colorIndex(to.id)), size: 10)
                        Text(to.name).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Money.format(model.minor ?? 0, from.currency, locale)).kFont(.num).foregroundStyle(c.ink2).money()
                }
                HStack(alignment: .top, spacing: 12) {
                    KeyField(label: L.tx_fee_currency(currency: from.currency.uppercased()), text: show(f.fee), on: field == .fee,
                             onDelete: { model.fee.fee = Keypad.press(f.fee, .delete) }, onClear: { model.fee.fee = "" }) {
                        viaFocused = false
                        field = .fee
                    }
                    if s.cross, let to = model.toAccount {
                        let typed = f.typed == .received
                        let toDecimals = Money.decimals(to.currency)
                        KeyField(label: L.tx_received_currency(currency: to.currency.uppercased()),
                                 text: typed ? show(f.received) : show(keypadInput(s.received, decimals: toDecimals)),
                                 on: field == .received,
                                 onDelete: {
                                     model.fee.received = Keypad.press(typed ? f.received : "", .delete)
                                     model.fee.typed = .received
                                 },
                                 onClear: { model.fee.received = ""; model.fee.typed = .received }) {
                            viaFocused = false
                            field = .received
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.tx_via()).kFont(.small).foregroundStyle(c.ink3)
                        TextField("", text: Binding(get: { f.provider }, set: { model.fee.provider = String($0.prefix(60)) }))
                            .kFont(.sans(16, .regular))
                            .focused($viaFocused)
                            .keyboard(.text)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(c.surface, in: .rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(viaFocused ? c.ink : c.line,
                                                                                    lineWidth: viaFocused ? 2 : 1))
                            .accessibilityLabel(L.tx_via())
                    }
                    if s.cross {
                        let typed = f.typed == .rate
                        KeyField(label: L.tx_rate_label(currency: from.currency.uppercased()),
                                 text: typed ? show(f.rate) : rateString(s.rate),
                                 on: field == .rate,
                                 onDelete: {
                                     model.fee.rate = Keypad.press(typed ? f.rate : "", .delete)
                                     model.fee.typed = .rate
                                 },
                                 onClear: { model.fee.rate = ""; model.fee.typed = .rate }) {
                            viaFocused = false
                            field = .rate
                        }
                    }
                }
                if let sentence = sentence(s, from: from) {
                    Text(sentence).kFont(.small).foregroundStyle(c.ink2).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(c.soft, in: .rect(cornerRadius: 14))
                        .money()
                }
                if !viaFocused {
                    switch field {
                    case .fee:
                        AmountKeypad(input: $model.fee.fee, decimals: Money.decimals(from.currency))
                    case .received:
                        AmountKeypad(input: Binding(get: { f.typed == .received ? model.fee.received : "" },
                                                    set: { model.fee.received = $0; model.fee.typed = .received }),
                                     decimals: Money.decimals(model.toAccount?.currency ?? from.currency))
                    case .rate:
                        AmountKeypad(input: Binding(get: { f.typed == .rate ? model.fee.rate : "" },
                                                    set: { model.fee.rate = $0; model.fee.typed = .rate }),
                                     decimals: rateDecimals)
                    }
                }
            }
            KButton(L.common_done(), action: close)
        }
    }

    private func rateString(_ r: Double) -> String {
        let (value, digits) = fmtRate(r)
        let nf = NumberFormatter()
        nf.locale = theme.locale
        nf.minimumFractionDigits = digits
        nf.maximumFractionDigits = digits
        return nf.string(from: NSNumber(value: value)) ?? ""
    }

    private func sentence(_ s: TransferSides, from: Wallet) -> String? {
        let locale = theme.locale
        guard s.converted > 0, s.fee > 0 || s.cross else { return nil }
        var parts: [String] = []
        if s.cross, let to = model.toAccount {
            parts.append(L.tx_fx_becomes(sent: Money.format(s.converted, from.currency, locale),
                                         received: Money.format(s.received, to.currency, locale), rate: rateString(s.market)))
        } else {
            parts.append(L.tx_fx_arrives(amount: Money.format(s.converted, from.currency, locale)))
        }
        let cost = s.cost
        if cost.totalCost > 0.5 {
            let pct = NumberFormatter()
            pct.locale = locale
            pct.minimumFractionDigits = 2
            pct.maximumFractionDigits = 2
            parts.append(L.add_fx_cost(cost: Money.format(Int64(cost.totalCost.rounded()), from.currency, locale),
                                       pct: pct.string(from: NSNumber(value: cost.costPct)) ?? ""))
        }
        return parts.joined(separator: " ")
    }
}

/// A number typed on Kosha's keypad, never the system keyboard: tap to make it the one the keypad fills.
private struct KeyField: View {
    let label: String
    let text: String
    let on: Bool
    let onDelete: () -> Void
    let onClear: () -> Void
    let onTap: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 6) {
            Text(label).kFont(.small).foregroundStyle(c.ink3).lineLimit(1)
            HStack(spacing: 0) {
                Text(text).kFont(.figure(16, .regular)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).money()
                if on && !text.isEmpty {
                    PhIcon("backspace", size: 20, color: c.ink3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onDelete)
                        .onLongPressGesture(perform: onClear)
                        .accessibilityElement()
                        .accessibilityLabel(L.app_key_delete())
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onDelete() }
                }
            }
            .padding(.leading, 14)
            .frame(minHeight: 52)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? c.ink : c.line, lineWidth: on ? 2 : 1))
            .contentShape(.rect(cornerRadius: 14))
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) \(text)")
            .accessibilityAddTraits(on ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
            .accessibilityAction { onTap() }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Note, tags, event and files

/// Note, tags (type a tag then space; "Used before" chips), event (picked by date, or chosen, or New event) and files
/// with Attach (NoteSheet). A transfer takes a note only.
struct NoteSheet: View {
    @Bindable var model: AddModel
    let close: () -> Void
    @Environment(\.kosha) private var theme
    @State private var tagText = ""
    @State private var naming: String?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var picking = false

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(model.transfer ? L.add_note() : L.add_note_tags_event(), onClose: close)
            VStack(alignment: .leading, spacing: 6) {
                Text(L.add_note()).kFont(.small).foregroundStyle(c.ink3)
                TextField("", text: Binding(get: { model.note }, set: { model.note = String($0.prefix(2000)) }), axis: .vertical)
                    .kFont(.sans(16, .regular))
                    .lineLimit(1...6)
                    .keyboard(.text)
                    .padding(14)
                    .frame(minHeight: 48)
                    .background(c.surface, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                    .accessibilityLabel(L.add_note())
            }
            if !model.transfer {
                tags
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.add_event()).kFont(.small).foregroundStyle(c.ink3)
                    events
                }
                if model.meta?.attachments == true { files }
            }
            KButton(L.common_done()) {
                if !tagText.trimmingCharacters(in: .whitespaces).isEmpty { addTags(tagText) }
                close()
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { stage("photo.jpg", "image/jpeg", data) }
                photo = nil
            }
        }
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return model.toasts.show(L.tx_attach_failed(), warning: true) }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            stage(url.lastPathComponent, type, data)
        }
    }

    private func stage(_ name: String, _ type: String, _ data: Data) {
        if data.count > attachmentLimit { return model.toasts.show(L.tx_file_too_big(files: name), warning: true) }
        model.files.append(Staged(name: name, type: type, data: data))
    }

    private func addTags(_ text: String) {
        var all = model.tags
        for t in parseTags(text) where !all.contains(t) { all.append(t) }
        model.tags = Array(all.prefix(maxTags))
        tagText = ""
    }

    private var tags: some View {
        let c = theme.colors
        let before = (model.meta?.tags ?? []).filter { !model.tags.contains($0) }.prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L.add_tags()).kFont(.small).foregroundStyle(c.ink3)
            VStack(alignment: .leading, spacing: 8) {
                if !model.tags.isEmpty {
                    Flow(spacing: 8) {
                        ForEach(model.tags, id: \.self) { t in
                            Button { model.tags.removeAll { $0 == t } } label: {
                                HStack(spacing: 8) {
                                    Text("#\(t)")
                                    PhIcon("x", size: 16, color: c.ink2)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 40)
                                .background(c.soft, in: .capsule)
                            }
                            .buttonStyle(PressStyle())
                            .accessibilityLabel(L.tx_remove_file(name: "#\(t)"))
                        }
                    }
                }
                TextField("", text: Binding(get: { tagText }, set: { v in
                    // A space or comma ends a tag, as on the web's tag input.
                    if v.contains(where: { $0 == " " || $0 == "," }) { addTags(v) } else { tagText = v }
                }), prompt: Text(L.tx_type_a_tag()).foregroundStyle(c.ink3))
                .kFont(.sans(16, .regular))
                .keyboard(.text, capitalise: false)
                .onSubmit { addTags(tagText) }
                .accessibilityLabel(L.add_tags())
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            if !before.isEmpty {
                Flow(spacing: 8) {
                    Text(L.app_add_used_before()).kFont(.small).foregroundStyle(c.ink3).frame(minHeight: 32)
                    ForEach(Array(before), id: \.self) { t in
                        Chip("#\(t)", small: true) { addTags(t) }
                    }
                }
            }
        }
    }

    /// No event, the event the day falls in plus recent ones, and New event (named inline).
    private var events: some View {
        let c = theme.colors
        let all = model.meta?.events ?? []
        let auto = eventFor(model.day.text, all)
        let current = model.eventId
        let shown = ([model.event].compactMap { $0 } + all.prefix(4)).reduce(into: [Event]()) { out, e in
            if !out.contains(where: { $0.id == e.id }) { out.append(e) }
        }
        return Card(tight: true) {
            eventRow("prohibit", L.tx_no_event(), nil, current == nil) { model.pickEvent(nil) }
            ForEach(shown) { e in
                Hairline()
                let dates = eventDates(e)
                let detail = e.id == auto && !model.eventPicked ? L.app_add_picked_by_date(dates: dates) : (dates.isEmpty ? nil : dates)
                eventRow("calendar-star", e.name, detail, current == e.id) { model.pickEvent(e.id) }
            }
            Hairline()
            if let name = naming {
                VStack(alignment: .leading, spacing: 8) {
                    KField(L.tx_event_placeholder(), text: Binding(get: { name }, set: { naming = String($0.prefix(80)) }))
                    Text(L.tx_event_from(day: DayFormat.dayMonth(model.day, theme.locale))).kFont(.small).foregroundStyle(c.ink3)
                    HStack(spacing: 8) {
                        KButton(L.common_cancel(), style: .secondary, size: .medium) { naming = nil }
                        KButton(L.tx_create_event(), size: .medium) { model.createEvent(name) { naming = nil } }
                    }
                }
                .padding(12)
            } else {
                eventRow("plus", L.tx_new_event(), nil, false) { naming = "" }
            }
        }
    }

    private func eventRow(_ icon: String, _ name: String, _ detail: String?, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        let c = theme.colors
        return ListRow(selected: on, action: action) {
            PhIcon(icon, size: 20, color: c.ink2)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let detail { Text(detail).kFont(.small).foregroundStyle(c.ink3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if on { PhIcon("check", size: 20, color: c.selection) }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "4 – 9 Nov", "From 20 Dec", "Until 3 Jan", or "" for an undated event (tags-events.tsx eventDates).
    private func eventDates(_ e: Event) -> String {
        let locale = theme.locale
        let start = e.startDay.flatMap(Day.init)
        let end = e.endDay.flatMap(Day.init)
        switch (start, end) {
        case (nil, nil): return ""
        case (nil, let end?): return L.tx_event_until(day: DayFormat.dayMonth(end, locale))
        case (let start?, nil): return L.tx_event_from(day: DayFormat.dayMonth(start, locale))
        case (let start?, let end?):
            let f = DateIntervalFormatter()
            f.locale = locale
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateTemplate = "dMMM"
            return f.string(from: start.date, to: end.date)
        }
    }

    private var files: some View {
        let c = theme.colors
        return VStack(alignment: .leading, spacing: 8) {
            Text(L.app_add_files()).kFont(.small).foregroundStyle(c.ink3)
            Flow(spacing: 8) {
                ForEach(model.files) { f in
                    Chip("\(f.name)  \(ByteCountFormatter.string(fromByteCount: Int64(f.data.count), countStyle: .file))",
                         action: { model.files.removeAll { $0.id == f.id } }) {
                        PhIcon(f.type.hasPrefix("image/") ? "image" : "file-pdf", size: 18)
                    }
                    .accessibilityLabel(L.tx_remove_file(name: f.name))
                }
                Chip(L.app_add_choose_photo(), action: { picking = true }) { PhIcon("image", size: 18) }
                .buttonStyle(PressStyle())
                Chip(L.app_add_attach(), action: { importing = true }) { PhIcon("paperclip", size: 18) }
            }
        }
    }
}

/// Rows of views that wrap to the next line, for chips.
struct Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > maxWidth && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width += rows[last].items.isEmpty ? size.width : size.width + spacing
            rows[last].height = max(rows[last].height, size.height)
            rows[last].items.append(i)
        }
        return rows
    }
}

// MARK: Describe it

/// Describe it (AI): one sentence, Fill in, or Scan a receipt. The system keyboard is right here: these are words.
struct DescribeSheet: View {
    @Bindable var model: AddModel
    let close: () -> Void
    @Environment(\.kosha) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(L.add_describe(), onClose: close)
                .overlay(alignment: .leading) { EmptyView() }
            Text(L.add_describe_label()).kFont(.small).foregroundStyle(c.ink2)
            TextField("", text: Binding(get: { model.described }, set: { model.described = String($0.prefix(500)) }),
                      prompt: Text(L.add_describe_placeholder()).foregroundStyle(c.ink3), axis: .vertical)
                .kFont(.sans(16, .regular))
                .lineLimit(2...5)
                .focused($focused)
                .keyboard(.text)
                .submitLabel(.done)
                .onSubmit { model.describe() }
                .padding(14)
                .background(c.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? c.ink : c.line, lineWidth: focused ? 2 : 1))
                .accessibilityLabel(L.add_describe_label())
            Text(L.add_describe_help()).kFont(.small).foregroundStyle(c.ink3)
            PrivacyLine(model: model)
            HStack(spacing: 8) {
                if model.meta?.aiFlags.receipts == true {
                    KButton(L.add_scan_receipt(), style: .secondary, icon: "camera") {
                        close()
                        model.camera = true
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                KButton(L.add_fill_in()) { model.describe() }
                    .disabled(model.described.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

/// "Kosha sends only what you share with Anthropic", with "what you share" opening Settings › AI › What AI can see.
struct PrivacyLine: View {
    let model: AddModel
    @Environment(\.kosha) private var theme

    var body: some View {
        if let ai = model.meta?.aiModel {
            let provider = switch ai.provider {
            case "anthropic": "Anthropic"
            case "openai": "OpenAI"
            case "gemini": "Gemini"
            case "openrouter": "OpenRouter"
            case "ollama": "Ollama"
            case "compatible": L.ask_your_endpoint()
            default: ai.provider
            }
            var text = AttributedString()
            for s in Msg.segments(key: "app_add_privacy", ["provider": provider]) {
                var part = AttributedString(s.text)
                if s.tag == "link" { part.underlineStyle = .single }
                text += part
            }
            return AnyView(
                Button {
                    model.sheet = nil
                    model.nav.add = nil
                    model.nav.push(.settings(page: "ai-privacy"))
                } label: {
                    Text(text).kFont(.small).foregroundStyle(theme.colors.ink3).multilineTextAlignment(.leading)
                }
                .buttonStyle(PressStyle())
            )
        }
        return AnyView(EmptyView())
    }
}
