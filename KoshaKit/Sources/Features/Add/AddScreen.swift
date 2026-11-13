import SwiftUI
import Model
import API
import Store
import Design

/// Add (02-add-*): the amount first with the keypad under the thumb, the kind, the account pill (From → To for a
/// transfer), the tile row (Category, Date, Repeat, Note), the payee with its suggestions or the transfer's fee and
/// rate, then Add another and the primary button. Presented full screen over the tabs.
struct AddScreen: View {
    let request: AddRequest
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(Navigator.self) private var nav
    @State private var model: AddModel?

    var body: some View {
        Group {
            if let model {
                AddForm(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model == nil { model = AddModel(request: request, kosha: kosha, toasts: toasts, nav: nav) }
        }
    }
}

private struct AddForm: View {
    @Bindable var model: AddModel
    @Environment(\.kosha) private var theme
    @Environment(Toasts.self) private var toasts
    @FocusState private var payeeFocused: Bool

    var body: some View {
        let c = theme.colors
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    // The amount block is 262pt on the board; the room left over sits above the keypad, so the
                    // keypad stays under the thumb. Short screens and big text shrink it, then scroll.
                    amount
                        .padding(.horizontal, 16)
                        .frame(height: payeeFocused ? nil : amountHeight(proxy.size.height))
                    VStack(spacing: 12) {
                        tiles
                        if model.transfer {
                            feeRow
                        } else {
                            payeeField
                            if payeeFocused && !model.payee.trimmingCharacters(in: .whitespaces).isEmpty { suggestions }
                        }
                    }
                    .padding(.horizontal, 16)
                    if !payeeFocused {
                        Spacer(minLength: 12)
                        VStack(spacing: 12) {
                            AmountKeypad(input: $model.input, decimals: model.decimals)
                            buttons
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 8)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(c.bg)
        .overlay(alignment: .top) {
            // The app's toast host sits under this cover, so Add shows the same toast itself (Add another, errors).
            if let t = toasts.current {
                ToastView(toast: t) { toasts.dismiss() }.padding(.horizontal, 16).padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(theme.animation(), value: toasts.current?.id)
        .animation(theme.animation(), value: payeeFocused)
        .kSheet(item: shortSheet) { s in AddSheets(model: model, sheet: s) }
        .background(Color.clear.kSheet(item: tallSheet, scrolls: true) { s in AddSheets(model: model, sheet: s) })
        .fullScreen(isPresented: $model.camera) { ReceiptCamera(model: model) }
    }

    /// Sheets that size to their content; the tall ones (lists) take the full height and scroll.
    private static let tall: Set<AddSheet> = [.account, .to, .category, .note, .repeating]

    private var shortSheet: Binding<AddSheet?> {
        Binding(get: { model.sheet.flatMap { Self.tall.contains($0) ? nil : $0 } }, set: { if $0 == nil { model.sheet = nil } })
    }

    private var tallSheet: Binding<AddSheet?> {
        Binding(get: { model.sheet.flatMap { Self.tall.contains($0) ? $0 : nil } }, set: { if $0 == nil { model.sheet = nil } })
    }

    // MARK: Header

    private var header: some View {
        let ai = model.meta?.aiFlags ?? AiFlags()
        return HStack(spacing: 4) {
            IconButton("x", label: L.common_close()) { model.nav.add = nil }
            Segmented([(EntryKind.expense, L.add_kind_expense()), (.income, L.add_kind_income()), (.transfer, L.add_kind_transfer())],
                      selection: Binding(get: { model.kind }, set: { model.pickKind($0) }))
            if ai.quickAdd || ai.receipts {
                // With only receipts on, the sparkle goes straight to the camera.
                Button {
                    if ai.quickAdd { model.sheet = .describe } else { model.camera = true }
                } label: {
                    Sparkle(size: 24).frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(model.reading != nil)
                .accessibilityLabel(ai.quickAdd ? L.add_describe_or_scan() : L.add_scan_receipt())
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
    }

    // MARK: Amount

    @ViewBuilder
    private var amount: some View {
        let c = theme.colors
        if let reading = model.reading {
            HStack(spacing: 8) {
                ProgressView().tint(c.brand)
                Text(reading == .receipt ? L.add_hint_reading_receipt() : L.add_reading_text()).foregroundStyle(c.ink2)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 8) {
                if let filled = model.filled, !payeeFocused { FilledNote(model: model, filled: filled) }
                amountLine
                if !payeeFocused {
                    pills
                    if let note = amountNote {
                        Text(note).kFont(.xs).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                            .frame(minHeight: 15).money()
                    }
                }
            }
        }
    }

    /// The amount block's height: 262 as on the board, less on short screens (52 header, 58 tiles, 12 + 48 payee,
    /// 12 + 248 keypad, 12 + 52 buttons and the bottom gap).
    private func amountHeight(_ total: CGFloat) -> CGFloat { min(262, max(150, total - 502)) }

    /// The expression when it has an operator, then the amount at 60 (46 when long), with the caret while it's empty.
    private var amountLine: some View {
        let c = theme.colors
        let input = model.input
        let text = amountText(input, currency: model.currency, kind: model.kind, locale: theme.locale)
        let (grouping, decimal) = Money.separators(theme.locale)
        // Smaller while the payee is typed, as on AddPayee.
        let long = text.count > 8 || payeeFocused
        return VStack(spacing: 8) {
            if Keypad.hasOperator(input) {
                Text(Keypad.pretty(input, grouping: grouping, decimal: decimal)).kFont(.expr).foregroundStyle(c.ink3)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            HStack(alignment: .center, spacing: 4) {
                Text(text)
                    .kFont(long ? .amountLong : .amount)
                    .foregroundStyle(input.isEmpty ? c.ink3 : model.kind == .income ? c.pos : c.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    // The board sets the amount's line height to its size.
                    .padding(.vertical, long ? -5 : -6)
                if input.isEmpty {
                    RoundedRectangle(cornerRadius: 1).fill(c.selection).frame(width: 2, height: 50).accessibilityHidden(true)
                }
            }
            .money()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(input.isEmpty ? L.add_amount() : text)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var amountNote: String? {
        if model.transfer { return L.app_add_transfer_note() }
        if model.input.isEmpty { return model.savedOnce ? L.app_add_ready_next() : L.app_add_start() }
        if let conv = model.converted { return L.app_add_converted(amount: Money.format(conv, model.primary, theme.locale)) }
        if model.kind == .income { return L.app_add_income_note() }
        return nil
    }

    /// The account as a pill under the amount; a transfer's From → To pills, the arrow swapping them.
    @ViewBuilder
    private var pills: some View {
        let c = theme.colors
        let kosha = model.kosha
        if model.transfer {
            TransferPills(
                from: (model.account?.name ?? L.add_no_account(), c.account(kosha.colorIndex(model.account?.id))),
                to: model.toAccount.map { ($0.name, c.account(kosha.colorIndex($0.id))) },
                toPlaceholder: L.add_to(), swapLabel: L.app_add_swap(),
                onFrom: { model.sheet = .account }, onTo: { model.sheet = .to }, onSwap: { model.swap() }
            )
        } else if let account = model.account {
            AccountPill(account.name, color: c.account(kosha.colorIndex(account.id)), guess: model.accountGuessed,
                        open: model.sheet == .account) { model.sheet = .account }
                .accessibilityLabel(model.accountGuessed ? L.app_add_account_guessed(name: account.name)
                                    : L.add_chip_account(name: account.name))
        } else {
            AccountPill(L.add_no_account(), color: .clear, guess: true) { model.sheet = .account }
                .accessibilityLabel(L.add_chip_account_none())
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let locale = theme.locale
        let dayText = DayFormat.label(model.day, today: model.today, locale)
        let timeText = DayFormat.time(model.time ?? Dates.time(model.kosha.tz), locale)
        return HStack(spacing: 6) {
            if !model.transfer {
                let cat = model.chosenCategory
                let pick: Pick = model.categoryId != nil ? .picked : model.chosen != nil ? .guess : .empty
                FieldTile(
                    cat?.name ?? L.add_category(), icon: cat.map { categoryIconName($0.icon) } ?? "squares-four", pick: pick,
                    aiGuess: pick == .guess && model.chosenIsAi,
                    description: cat == nil ? L.app_add_category_none()
                        : pick == .picked ? L.app_add_category_picked(name: cat!.name)
                        : model.chosenIsAi ? L.app_add_category_ai(name: cat!.name) : L.app_add_category_usual(name: cat!.name)
                ) {
                    model.viaNext = false
                    model.sheet = .category
                }
            }
            FieldTile(dayText, icon: "calendar-blank", description: L.add_chip_date(day: dayText, time: timeText)) {
                model.sheet = .date
            }
            let r = model.repeating
            let repeatText = r.map { repeatLabel($0, locale) }
            FieldTile(repeatText ?? L.app_add_repeat(), icon: "arrows-clockwise", pick: r == nil ? .unset : .picked,
                      description: L.app_add_repeat_label(frequency: repeatText ?? L.app_add_repeat_once())) {
                model.sheet = .repeating
            }
            noteTile
        }
    }

    /// The note tile names what is set: the note, else the event, else the first tag, else the files ("1 file").
    private var noteTile: some View {
        var details: [String] = []
        if let line = model.note.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first {
            details.append(String(line))
        }
        if !model.transfer {
            if let e = model.event?.name { details.append(e) }
            if let t = model.tags.first { details.append("#\(t)") }
            if !model.files.isEmpty { details.append(L.add_files(count: model.files.count)) }
        }
        let onlyFiles = details.count == 1 && !model.files.isEmpty && model.note.trimmingCharacters(in: .whitespaces).isEmpty
            && model.event == nil && model.tags.isEmpty
        let label = details.first.map { details.count > 1 ? "\($0) +\(details.count - 1)" : $0 } ?? L.add_note()
        return FieldTile(label, icon: onlyFiles ? "paperclip" : "note-pencil", pick: details.isEmpty ? .unset : .picked,
                         description: details.first.map { "\(L.add_note()), \($0)" }
                             ?? (model.transfer ? L.add_note() : L.add_note_tags_event())) {
            model.sheet = .note
        }
    }

    // MARK: Payee

    /// The payee: the only text field on Add. "usually €28" or AI's sparkle sit on the right, a clear button while typing.
    private var payeeField: some View {
        let c = theme.colors
        let usual = model.match?.usualAmount.flatMap { $0 == 0 ? nil : $0 }
        return HStack(spacing: 8) {
            TextField("", text: Binding(get: { model.payee }, set: { model.typePayee($0) }),
                      prompt: Text(L.add_payee()).foregroundStyle(c.ink3))
                .kFont(.sans(16, .regular))
                .tint(c.selection)
                .focused($payeeFocused)
                .submitLabel(.done)
                .keyboard(.text)
                .accessibilityLabel(L.add_payee())
            if payeeFocused && !model.payee.isEmpty {
                IconButton("x-circle", label: L.app_add_clear_payee(), color: c.ink3) { model.typePayee("") }
            } else if model.payeeByAi {
                Sparkle(size: 16).padding(.trailing, 10)
            } else if let usual, let cur = model.match?.currency {
                Text(L.add_usually(amount: wholeMoney(abs(usual), cur, theme.locale))).kFont(.small).foregroundStyle(c.ink3)
                    .lineLimit(1).padding(.trailing, 10).money()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 48)
        .background(c.surface, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(payeeFocused ? c.ink : c.line, lineWidth: payeeFocused ? 2 : 1)
        }
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture { payeeFocused = true }
    }

    /// Payees matching what's typed, then a way to search Activity for it (AddPayee).
    private var suggestions: some View {
        let c = theme.colors
        let typed = model.payee.trimmingCharacters(in: .whitespaces)
        return Card(tight: true) {
            if !model.suggestions.isEmpty {
                Text(L.add_section_payees()).kFont(.caption).foregroundStyle(c.ink3).padding(.leading, 16).padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(model.suggestions, id: \.payee) { p in suggestionRow(p, typed: typed) }
                Hairline().padding(.horizontal, 16)
            }
            Text(L.add_section_go_to()).kFont(.caption).foregroundStyle(c.ink3).padding(.leading, 16).padding(.top, 14)
                .padding(.bottom, 6)
            ListRow(action: {
                model.nav.add = nil
                model.nav.openActivity(ActivitySearch(query: typed))
            }) {
                IconTile("magnifying-glass")
                Text(L.add_search_activity(term: typed)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 6)
        }
    }

    private func suggestionRow(_ p: Payee, typed: String) -> some View {
        let c = theme.colors
        let kosha = model.kosha
        let cat = kosha.category(p.categoryId)
        let detail = [cat?.name, kosha.wallet(p.accountId)?.name, p.count > 0 ? L.app_add_times(count: p.count) : nil]
            .compactMap { $0 }.joined(separator: " · ")
        // The typed part in bold, as the design does.
        var name = AttributedString(p.payee)
        if !typed.isEmpty, let r = name.range(of: typed, options: .caseInsensitive) {
            name[r].font = KFont.sans(15, .semibold).font(theme)
        }
        return ListRow(action: {
            model.pickPayee(p)
            payeeFocused = false
        }) {
            IconTile(categoryIconName(cat?.icon))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).kFont(.body)
                if !detail.isEmpty { Text(detail).kFont(.small).foregroundStyle(c.ink3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let usual = p.usualAmount, usual != 0, let cur = p.currency {
                Text(L.add_usually(amount: Money.format(abs(usual), cur, theme.locale))).kFont(.small).foregroundStyle(c.ink3)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 96, alignment: .trailing).money()
            }
        }
    }

    // MARK: Transfer

    /// "Fee and rate" with what was charged and what arrives (AddTransfer): the fee in ink2, what arrives in ink with
    /// "arrives" in ink3, figures in the number font.
    private var feeRow: some View {
        let c = theme.colors
        let s = model.sides
        let locale = theme.locale
        var value = AttributedString()
        func add(_ text: String, _ color: Color, figure: Bool) {
            var part = AttributedString(text)
            part.foregroundColor = color
            part.font = (figure ? KFont.num : KFont.body).font(theme)
            value += part
        }
        if s.fee > 0 || (s.cross && model.toAccount != nil) {
            if s.fee > 0 { add(L.app_add_fee_amount(amount: Money.format(s.fee, model.currency, locale)), c.ink2, figure: true) }
            if s.cross, let to = model.toAccount {
                if s.fee > 0 { add(" · ", c.ink3, figure: false) }
                // "{amount} arrives": the amount in ink, the word in ink3.
                let marker = "\u{1}"
                let parts = L.add_arrives(amount: marker).components(separatedBy: marker)
                add(parts.first ?? "", c.ink3, figure: false)
                add(Money.format(s.received, to.currency, locale), c.ink, figure: true)
                add(parts.count > 1 ? parts[1] : "", c.ink3, figure: false)
            }
        } else {
            add(L.add_fee_none(), c.ink3, figure: false)
        }
        let title = s.cross ? L.add_fee_and_rate() : L.add_fee()
        return Button { model.sheet = .fee } label: {
            HStack(spacing: 10) {
                Text(title).kFont(.sans(16, .regular)).foregroundStyle(c.ink2).lineLimit(1)
                Text(value).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).money()
                PhIcon("caret-right", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(title), \(String(value.characters))")
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            // Sized to its label, so it never cuts off at large text sizes; the primary button takes the rest.
            KButton(L.add_another(), style: .secondary) { model.save(again: true) }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 132)
                .disabled(!model.ready || model.saving)
            KButton(model.primaryLabel) { model.tapPrimary() }
                .disabled(model.minor == nil || model.saving)
        }
    }
}

/// "Read from your receipt · Check it before adding." with the photo, after AI filled the form (AddFilledAI).
private struct FilledNote: View {
    let model: AddModel
    let filled: Filled
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        HStack(spacing: 10) {
            if let data = model.receipt, let image = platformImage(data) {
                image.resizable().scaledToFill().frame(width: 36, height: 44).clipShape(.rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c.line))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Sparkle(size: 14)
                    Text(filled == .receipt ? L.app_add_filled_receipt() : L.app_add_filled_ai()).kFont(.sans(13, .medium))
                }
                let photo = filled == .receipt && model.files.contains { $0.name == "receipt.jpg" }
                Text(photo ? L.app_add_check_photo() : L.app_add_check_it()).kFont(.small).foregroundStyle(c.ink2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(c.soft, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
