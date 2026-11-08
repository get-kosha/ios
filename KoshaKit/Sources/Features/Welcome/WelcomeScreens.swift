import SwiftUI
import Model
import API
import Store
import Design

/// Set when the person finishes or skips Welcome on this phone, so the root shows the tabs even with no accounts yet.
let welcomeDoneKey = "kosha.welcome.done"

/// The accounts Welcome suggests: the first three start the list, the rest are one tap away (welcome.tsx suggested).
private func suggestions() -> [(name: String, type: AccountType)] {
    [(L.welcome_suggest_current(), .bank), (L.welcome_type_credit_card(), .credit), (L.welcome_suggest_investments(), .investment),
     (L.welcome_suggest_savings(), .bank), (L.welcome_type_cash(), .cash), (L.welcome_suggest_pension(), .investment)]
}

/// First run, shown while the account has no accounts: (1) name, main currency and time zone; (2) the accounts, each
/// with the figures people know today, and a live net worth; (3) done, with Import statements next. Every step can be
/// skipped. The demo account can't save, so it goes straight to Overview.
struct WelcomeFlow: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(welcomeDoneKey) private var welcomeDone = false
    @State private var step = "you"
    @State private var name = ""
    @State private var currency = ""
    @State private var tz = ""
    @State private var rows: [NewAccount] = []
    @State private var added: [String] = []
    @State private var busy = false
    @State private var checked = false
    @State private var started = false

    var body: some View {
        Group {
            if let m = kosha.meta, !m.demo {
                switch step {
                case "you": you(m)
                case "accounts": accounts(m)
                default: WelcomeDone(added: added, onImport: { finish(then: .importStatements) }, onSkip: { finish(then: nil) })
                }
            } else {
                Color.clear.onAppear { finish(then: nil) }
            }
        }
        .background(theme.colors.bg)
        .hideNavigationBar()
        .onAppear(perform: start)
    }

    /// A new account still has the server's defaults, so start from the phone's zone and region instead (welcome.tsx).
    private func start() {
        guard !started, let m = kosha.meta else { return }
        started = true
        let fresh = m.wallets.isEmpty
        name = m.user?.name ?? ""
        let phoneCurrency = Locale.current.currency?.identifier.lowercased()
        currency = fresh ? (phoneCurrency.flatMap { m.rates[$0] != nil ? $0 : nil } ?? m.primaryCurrency) : m.primaryCurrency
        tz = fresh ? TimeZone.current.identifier : m.timeZone
    }

    private func finish(then route: Route?) {
        welcomeDone = true
        nav.tab = route == nil ? .overview : .accounts
        if let route { nav.paths[.accounts] = [route] }
        dismiss()
    }

    private func attempt(_ block: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            do {
                try await block()
            } catch let e as KoshaError {
                if case .api(_, let err) = e { toasts.show(err.message, warning: true) } else { toasts.show(L.common_offline_title(), warning: true) }
            } catch {}
            busy = false
        }
    }

    // MARK: Step 1

    private func you(_ m: Meta) -> some View {
        let c = theme.colors
        return WelcomeStep(at: 1, onSkip: { finish(then: nil) }, footer: {
            Text(L.welcome_change_later()).kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity)
            KButton(busy ? L.welcome_saving() : L.common_continue()) {
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    checked = true
                    return
                }
                saveYou(m)
            }
            .disabled(busy)
        }) {
            Text(L.welcome_title()).kFont(.sans(30, .semibold)).accessibilityAddTraits(.isHeader)
            Text(L.welcome_sub()).kFont(.small).foregroundStyle(c.ink2)
            YouStep(name: $name, checked: checked, currency: $currency, tz: $tz)
        }
    }

    private func saveYou(_ m: Meta) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        attempt {
            if trimmed != m.user?.name {
                try await kosha.api.send("PATCH", "/api/app/profile", body: JSONValue.object(["name": .string(trimmed)]))
            }
            let order = [currency] + m.order.filter { $0 != currency }
            try await kosha.api.send("PATCH", "/api/v1/settings", body: JSONValue.object([
                "primaryCurrency": .string(currency), "timeZone": .string(tz), "currencyOrder": .array(order.map(JSONValue.string)),
            ]))
            kosha.changed()
            // Rows still on the old main currency follow the new one.
            if rows.isEmpty {
                rows = suggestions().prefix(3).filter { s in !m.wallets.contains { $0.name.lowercased() == s.name.lowercased() } }
                    .map { NewAccount(name: $0.name, type: $0.type, currency: currency) }
            } else {
                rows = rows.map { var r = $0; if r.currency == m.primaryCurrency { r.currency = currency }; return r }
            }
            checked = false
            step = "accounts"
        }
    }

    // MARK: Step 2

    private func accounts(_ m: Meta) -> some View {
        let c = theme.colors
        let existing = m.wallets.filter { !$0.isArchived }.reduce(Int64(0)) { sum, w in
            sum + convert(accountWorth(w.kind, balance: w.balance, creditLimit: w.creditLimit, gain: w.gain), from: w.currency, to: currency, perUsd: m.rates)
        }
        let total = previewNetWorth(rows, to: currency, perUsd: m.rates) + existing
        return WelcomeStep(at: 2, onSkip: nil, onBack: { step = "you" }, footer: {
            HStack(spacing: 8) {
                KButton(L.welcome_skip(), style: .secondary) { finish(then: nil) }.frame(width: 120)
                KButton(busy ? L.welcome_adding() : rows.isEmpty ? L.welcome_add_an_account() : L.welcome_add_accounts(count: rows.count)) {
                    if rows.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        checked = true
                        return
                    }
                    saveAccounts()
                }
                .disabled(busy || rows.isEmpty)
            }
        }) {
            Text(L.welcome_accounts_title()).kFont(.title).accessibilityAddTraits(.isHeader)
            Text(L.welcome_accounts_sub()).kFont(.small).foregroundStyle(c.ink2)
            Card {
                HStack {
                    Text(L.welcome_net_worth()).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    MoneyText(total, currency, font: .figure(15, .medium))
                }
            }
            if rows.isEmpty {
                Text(L.welcome_rows_empty()).kFont(.small).foregroundStyle(c.ink3).frame(maxWidth: .infinity)
            }
            ForEach($rows) { $row in
                AccountCard(row: $row, index: m.wallets.count + (rows.firstIndex { $0.id == row.id } ?? 0), primary: currency,
                            checked: checked) { rows.removeAll { $0.id == row.id } }
            }
            let have = (rows.map(\.name) + m.wallets.map(\.name)).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let missing = suggestions().filter { !have.contains($0.name.lowercased()) }
            Flow(spacing: 8) {
                ForEach(missing.map(\.name) + [""], id: \.self) { label in
                    Chip(label.isEmpty ? L.welcome_another_account() : label, small: true, action: {
                        let s = missing.first { $0.name == label }
                        rows.append(NewAccount(name: s?.name ?? "", type: s?.type ?? .bank, currency: currency))
                    }) { PhIcon("plus", size: 14) }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    /// One at a time, dropping each row once saved, so a retry never adds one twice.
    private func saveAccounts() {
        let day = Dates.today(tz).text
        attempt {
            var gains: [JSONValue] = []
            for row in rows {
                let o = row.opening
                var body: [String: JSONValue] = ["name": .string(row.name.trimmingCharacters(in: .whitespaces)),
                                                 "type": .string(row.type.rawValue), "currency": .string(row.currency),
                                                 "balance": .number(Double(o.balance))]
                if let limit = o.creditLimit { body["creditLimit"] = .number(Double(limit)) }
                let account: Account
                do {
                    account = try await kosha.api.post("/api/v1/accounts", JSONValue.object(body))
                } catch {
                    if !added.isEmpty { kosha.changed() }
                    throw error
                }
                if let g = o.gain {
                    gains.append(.object(["accountId": .string(account.id), "day": .string(day), "gain": .number(Double(g))]))
                }
                added.append(row.currency)
                rows.removeAll { $0.id == row.id }
            }
            if !gains.isEmpty { try await kosha.api.send("POST", "/api/v1/gains", body: JSONValue.object(["gains": .array(gains)])) }
            step = "done"
        }
    }
}

/// The frame of a step: where you are (step N of 2), the content, and the actions at the bottom on glass.
private struct WelcomeStep<Content: View, Footer: View>: View {
    let at: Int
    let onSkip: (() -> Void)?
    var onBack: (() -> Void)?
    let footer: Footer
    let content: Content
    @Environment(\.kosha) private var theme

    init(at: Int, onSkip: (() -> Void)?, onBack: (() -> Void)? = nil, @ViewBuilder footer: () -> Footer, @ViewBuilder content: () -> Content) {
        self.at = at
        self.onSkip = onSkip
        self.onBack = onBack
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let onBack { IconButton("caret-left", label: L.common_back(), action: onBack) }
                Text(L.welcome_progress_step(at: "\(at)")).kFont(.xs).foregroundStyle(c.ink3)
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { n in Capsule().fill(n < at ? c.brand : c.sel).frame(height: 4) }
                }
                .accessibilityHidden(true)
                if let onSkip {
                    Button(L.welcome_skip(), action: onSkip).kFont(.small).foregroundStyle(c.ink3)
                        .padding(.horizontal, 12).frame(minHeight: 48).buttonStyle(PressStyle())
                }
            }
            .padding(.leading, onBack == nil ? 16 : 4).padding(.trailing, 4).padding(.top, 12).frame(minHeight: 48)
            .accessibilityElement(children: .contain)
            TabBanners()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16)
            }
            VStack(spacing: 8) { footer }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(c.glass)
        }
        .background(c.bg)
    }
}

/// Step 1: name, main currency and time zone.
private struct YouStep: View {
    @Binding var name: String
    let checked: Bool
    @Binding var currency: String
    @Binding var tz: String
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var sheet: IdentifiedString?

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.welcome_name_title())
                KField("", text: $name, error: checked && name.trimmingCharacters(in: .whitespaces).isEmpty ? L.welcome_name_error() : nil)
                    .keyboard(.text)
                Hint(L.welcome_name_description())
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.welcome_currency_title())
                PickField(nil, "\(currency.uppercased())  \(currencyName(currency, theme.locale))") { sheet = IdentifiedString(id: "currency") }
                Hint(L.welcome_currency_description())
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.welcome_tz_title())
                PickField(nil, "\(zoneCity(tz))  ·  \(tz)") { sheet = IdentifiedString(id: "zone") }
                Hint(L.welcome_tz_description())
            }
        }
        .padding(.top, 4)
        .foregroundStyle(c.ink)
        .kSheet(item: $sheet, scrolls: true) { s in
            if s.id == "currency" {
                ListPicker(L.welcome_currency_label(), choices: currencyChoices(kosha.meta?.rates.keys ?? [:].keys, theme.locale),
                           selected: currency, onPick: { currency = $0; sheet = nil }, onClose: { sheet = nil })
            } else {
                ListPicker(L.welcome_tz_title(), choices: zoneChoices(), selected: tz, onPick: { tz = $0; sheet = nil },
                           onClose: { sheet = nil })
            }
        }
    }
}

/// One account to add: its colour, name (typed in place), type, currency and remove; then its figures, each on the
/// keypad; and a line on what a card has left, what an investment has made, or its value in the main currency.
private struct AccountCard: View {
    @Binding var row: NewAccount
    let index: Int
    let primary: String
    let checked: Bool
    let onRemove: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var sheet: IdentifiedString?

    var body: some View {
        let c = theme.colors
        let o = row.opening
        let named = row.name.trimmingCharacters(in: .whitespaces)
        let (first, second): (String, String?) = switch row.type {
        case .credit: (L.welcome_field_owed(), L.welcome_field_credit_limit())
        case .investment: (L.welcome_field_put_in(), L.welcome_field_value_today())
        default: (L.welcome_field_balance(), nil)
        }
        Card {
            HStack(spacing: 8) {
                AccountDot(c.account(index), size: 10)
                TextField("", text: $row.name, prompt: Text(L.welcome_account_name_placeholder()).foregroundStyle(c.ink3))
                    .kFont(.head).keyboard(.text).frame(minHeight: 40)
                    .accessibilityLabel(L.welcome_account_name_label())
                Chip(typeLabel(row.type), soft: true, small: true, action: { sheet = IdentifiedString(id: "type") }) {
                    PhIcon("caret-down", size: 14)
                }
                Chip(row.currency.uppercased(), soft: true, small: true, action: { sheet = IdentifiedString(id: "currency") })
                IconButton("x", label: named.isEmpty ? L.welcome_remove_this_account() : L.welcome_remove(name: named), action: onRemove)
            }
            HStack(spacing: 8) {
                FigureField(label: first, minor: row.amount, currency: row.currency) { sheet = IdentifiedString(id: "amount") }
                if let second {
                    FigureField(label: second, minor: row.extra, currency: row.currency) { sheet = IdentifiedString(id: "extra") }
                }
            }
            if checked && named.isEmpty {
                Text(L.welcome_error_name()).kFont(.xs).foregroundStyle(c.bad)
            } else {
                notes(o)
            }
        }
        .kSheet(item: $sheet) { s in sheetBody(s.id, first: first, second: second) }
    }

    @ViewBuilder private func notes(_ o: Opening) -> some View {
        let c = theme.colors
        let worth = accountWorth(row.type, balance: o.balance, creditLimit: o.creditLimit, gain: o.gain)
        HStack(spacing: 12) {
            if row.type == .credit {
                Text(o.creditLimit == nil ? L.welcome_credit_left_hint()
                     : L.welcome_credit_left(amount: Money.format(max(0, o.balance), row.currency, theme.locale)))
                    .foregroundStyle(c.ink3)
            }
            if row.type == .investment {
                if let g = o.gain {
                    Text(g >= 0 ? L.welcome_gain(amount: Money.format(g, row.currency, theme.locale))
                         : L.welcome_loss(amount: Money.format(-g, row.currency, theme.locale)))
                        .foregroundStyle(g >= 0 ? c.pos : c.bad)
                } else {
                    Text(L.welcome_gain_hint()).foregroundStyle(c.ink3)
                }
            }
            if row.currency != primary && worth != 0 {
                Text("≈ " + Money.format(convert(worth, from: row.currency, to: primary, perUsd: kosha.meta?.rates ?? [:]), primary, theme.locale))
                    .foregroundStyle(c.ink3)
            }
        }
        .kFont(.xs)
        .money()
    }

    @ViewBuilder private func sheetBody(_ which: String, first: String, second: String?) -> some View {
        switch which {
        case "type":
            let named = row.name.trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(named.isEmpty ? L.welcome_type_of_account() : L.welcome_type_of(name: named)) { sheet = nil }
                ForEach([(AccountType.bank, L.welcome_type_bank_account()), (.cash, L.welcome_type_cash()),
                         (.credit, L.welcome_type_credit_card()), (.investment, L.welcome_type_investment_long())], id: \.0) { type, label in
                    ListRow(action: {
                        // The second figure means something else for another type, so it starts over.
                        if type != row.type { row.extra = nil }
                        row.type = type
                        sheet = nil
                    }) {
                        Text(label).frame(maxWidth: .infinity, alignment: .leading)
                        Radio(row.type == type)
                    }
                    .accessibilityAddTraits(row.type == type ? .isSelected : [])
                }
            }
        case "currency":
            ListPicker(L.welcome_currency_label(), choices: currencyChoices(kosha.meta?.rates.keys ?? [:].keys, theme.locale),
                       selected: row.currency, onPick: { row.currency = $0; sheet = nil }, onClose: { sheet = nil })
        default:
            let isAmount = which == "amount"
            // A sum like 1200+300 is kept as its result.
            AmountSheet(title: isAmount ? first : (second ?? ""), currency: row.currency, initial: isAmount ? row.amount : row.extra,
                        onDone: { minor in
                            if isAmount { row.amount = minor } else { row.extra = minor }
                            sheet = nil
                        }, close: { sheet = nil })
        }
    }

    private func typeLabel(_ t: AccountType) -> String {
        switch t {
        case .bank: L.welcome_type_bank()
        case .cash: L.welcome_type_cash()
        case .credit: L.welcome_type_card()
        case .investment: L.welcome_type_investment()
        }
    }
}

/// A figure's field: its label on the left, the number on the right; tapping opens the keypad.
private struct FigureField: View {
    let label: String
    let minor: Int64?
    let currency: String
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).kFont(.xs).foregroundStyle(c.ink3)
                Spacer(minLength: 4)
                if let minor {
                    Text(plain(minor)).kFont(.figure(18, .regular)).lineLimit(1).minimumScaleFactor(0.6).money()
                } else {
                    Text(L.welcome_amount_placeholder()).kFont(.figure(18, .regular)).foregroundStyle(c.ink3)
                }
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(minor.map { Money.spoken($0, currency, theme.locale) } ?? "")
    }

    /// A number as the field shows it: grouped, with the currency's decimals, no symbol.
    private func plain(_ minor: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = theme.locale
        let d = Money.decimals(currency)
        f.minimumFractionDigits = d
        f.maximumFractionDigits = d
        return f.string(from: (Decimal(minor) / 100) as NSDecimalNumber) ?? ""
    }
}

/// Step 3: what was added, net worth from the server's report, and Import statements or Skip for now.
private struct WelcomeDone: View {
    let added: [String]
    let onImport: () -> Void
    let onSkip: () -> Void
    @Environment(\.kosha) private var theme
    @State private var worth: WelcomeNetWorth?

    var body: some View {
        let c = theme.colors
        let currencies = Set(added).count
        let line = currencies > 1 ? L.welcome_done_added_currencies(count: added.count, currencies: "\(currencies)")
            : L.welcome_done_added(count: added.count)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    PhIcon("check-circle", size: 32, fill: true, color: c.pos)
                        .frame(width: 72, height: 72)
                        .background(c.pos.opacity(0.12), in: .rect(cornerRadius: 24))
                    Text(L.welcome_done_title()).kFont(.title).accessibilityAddTraits(.isHeader)
                    Text(line + (worth.map { theme.hideAmounts ? "" : " " + L.app_wel_net_worth_starts(amount: Money.format($0.total, $0.currency, theme.locale)) } ?? ""))
                        .kFont(.small).foregroundStyle(c.ink2).multilineTextAlignment(.center)
                    Card {
                        HStack(spacing: 12) {
                            IconTile("clock-counter-clockwise")
                            Text(L.welcome_history_title()).kFont(.head)
                        }
                        Text(L.welcome_history_body()).kFont(.small).foregroundStyle(c.ink2)
                        Text(L.app_wel_formats()).kFont(.xs).foregroundStyle(c.ink3)
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 16).padding(.top, 96)
            }
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    PhIcon("info", size: 14, color: c.ink3)
                    Text(L.app_wel_import_later()).kFont(.xs).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                KButton(L.welcome_import(), icon: "file-arrow-up", action: onImport)
                KButton(L.welcome_skip(), style: .secondary, action: onSkip)
            }
            .padding(16)
        }
        .background(c.bg)
        .load("net-worth", into: $worth) { try await $0.get("/api/v1/reports/net-worth") }
    }
}

private struct WelcomeNetWorth: Codable, Sendable {
    var currency: String
    @Rounded var total: Int64
}

/// Lays children out in rows, wrapping when the next one doesn't fit (the suggestion chips).
struct Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
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
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let next = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if next > width && !current.items.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.items + [i], next, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
