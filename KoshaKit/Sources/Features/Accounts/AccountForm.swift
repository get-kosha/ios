import SwiftUI
import Model
import API
import Store
import Design

private enum Picker: String, Identifiable {
    case currency, limit, balance
    var id: String { rawValue }
}

private let types: [(AccountType, String)] = [(.bank, "bank"), (.cash, "money"), (.credit, "credit-card"), (.investment, "chart-line-up")]

/// A new account or an edit: name, type, currency, and for a card its credit limit and what it owes, otherwise its
/// opening (or current) balance. A changed balance on an existing account is booked as a correction. Ported from
/// AccountForm.kt.
struct AccountFormScreen: View {
    let id: String?
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = AccountType.bank
    @State private var currency = ""
    @State private var limit: Int64?
    /// For a card people know what they owe; the account keeps what's left (limit minus owed).
    @State private var balance: Int64?
    @State private var picker: Picker?
    @State private var busy = false
    @State private var started = false

    private var initial: Wallet? { kosha.wallet(id) }

    var body: some View {
        let c = theme.colors
        let credit = type == .credit
        let locked = (initial?.txCount ?? 0) > 0
        let target = balance.map { credit ? (limit ?? 0) - Int64($0.magnitude) : $0 }
        let shownBefore = initial.map { $0.kind == .credit ? ($0.creditLimit ?? 0) - $0.balance : $0.balance }
        let changedBalance = initial == nil || balance != shownBefore || (credit && limit != initial?.creditLimit && balance != nil)
        let correction = initial.flatMap { i in target.map { $0 - i.balance } } ?? 0
        let balanceLabel = switch type {
        case .credit: L.accounts_currently_owed()
        case .investment: L.accounts_invested_so_far()
        default: L.accounts_current_balance()
        }
        FormPage(initial.map { L.accounts_edit_title(name: $0.name) } ?? L.accounts_new()) {
            KButton(initial != nil ? L.common_save() : L.accounts_add_account()) { save(target: target, changedBalance: changedBalance) }
                .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || !kosha.canWrite)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.accounts_name()).kFont(.small).foregroundStyle(c.ink3)
                KField(L.accounts_name(), text: $name)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.accounts_type()).kFont(.small).foregroundStyle(c.ink3)
                HStack(spacing: 6) {
                    ForEach(types, id: \.0) { t, icon in
                        let on = t == type
                        Button { type = t } label: {
                            // The board's type tiles: soft, the picked one filled in the selection colour.
                            VStack(spacing: 6) {
                                PhIcon(icon, size: 22, color: on ? c.onSelection : c.ink)
                                Text(accountTypeName(t)).kFont(on ? .head : .body).foregroundStyle(on ? c.onSelection : c.ink)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(on ? c.selection : c.soft, in: .rect(cornerRadius: 14))
                            .contentShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            Card(tight: true) {
                DetailRow(L.accounts_currency(), labelWidth: 100, action: locked ? nil : { picker = .currency }) {
                    Text(currency.uppercased()).kFont(.num)
                    Text(currencyName(currency, theme.locale)).foregroundStyle(c.ink3).lineLimit(1)
                }
                if credit {
                    Hairline()
                    DetailRow(L.accounts_credit_limit(), labelWidth: 100, trailing: "pencil-simple", action: { picker = .limit }) {
                        if let limit { MoneyText(limit, currency, sign: .none) } else { Text("—").foregroundStyle(c.ink3) }
                    }
                }
                Hairline()
                // An optional opening balance says so instead of showing the pencil, as on the board.
                DetailRow(balanceLabel, labelWidth: 100, trailing: initial == nil ? "" : "pencil-simple", action: { picker = .balance }) {
                    if let balance { MoneyText(balance, currency) } else { Text("—").foregroundStyle(c.ink3) }
                    Spacer()
                    if initial == nil { Text(L.accounts_optional()).kFont(.small).foregroundStyle(c.ink3) }
                }
            }
            if initial != nil && correction != 0 && changedBalance {
                HintLine(icon: "scales", text: L.accounts_save_adds_correction(amount: inText(correction, currency, theme, sign: .always)))
            } else if credit {
                HintLine(icon: "info", text: L.app_acc_debt_hint())
            } else if type == .investment {
                HintLine(icon: "info", text: L.accounts_investment_hint())
            }
        }
        .onAppear(perform: setUp)
        .kSheet(item: $picker, scrolls: picker == .currency) { p in sheet(p, balanceLabel: balanceLabel) }
    }

    private func setUp() {
        guard !started else { return }
        started = true
        currency = kosha.primary
        if let i = initial {
            name = i.name
            type = i.kind
            currency = i.currency
            limit = i.creditLimit
            balance = i.kind == .credit ? (i.creditLimit ?? 0) - i.balance : i.balance
        }
    }

    @ViewBuilder
    private func sheet(_ p: Picker, balanceLabel: String) -> some View {
        switch p {
        case .currency:
            let m = kosha.meta
            let codes = ([kosha.primary] + (m?.order ?? []) + (m?.wallets.map(\.currency) ?? []) + (m?.rates.keys.sorted() ?? []))
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ListPicker(L.accounts_currency(), choices: codes.map { Choice(id: $0, title: $0.uppercased(), detail: currencyName($0, theme.locale)) },
                       selected: currency, onPick: { currency = $0; picker = nil }, onClose: { picker = nil })
        case .limit:
            KeypadSheet(L.accounts_credit_limit(), minor: limit, currency: currency,
                        onDone: { limit = $0; picker = nil }, close: { picker = nil })
        case .balance:
            KeypadSheet(balanceLabel, minor: balance, currency: currency, positive: type == .credit || type == .investment,
                        clearLabel: initial == nil ? L.tx_clear() : nil, onClear: { balance = nil; picker = nil },
                        onDone: { balance = $0; picker = nil }, close: { picker = nil })
        }
    }

    private func save(target: Int64?, changedBalance: Bool) {
        let credit = type == .credit
        if credit && (limit ?? 0) <= 0 { return toasts.show(L.accounts_enter_credit_limit(), warning: true) }
        let initial = initial
        let fields: [String: JSONValue?] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "type": .string(type.rawValue),
            "currency": .string(currency),
            "creditLimit": credit ? limit.map { .int($0) } : initial != nil ? .null : nil,
            "balance": changedBalance ? target.map { .int($0) } : nil,
        ]
        let payload = jsonBody(fields)
        let kind = type
        busy = true
        Task {
            let saved = await kosha.run(toasts) { api -> String in
                if let initial {
                    try await api.send("PATCH", "/api/v1/accounts/\(initial.id)", body: payload)
                    return initial.id
                }
                let created: CreatedAccount = try await api.post("/api/v1/accounts", payload)
                return created.id
            }
            busy = false
            if let saved {
                toasts.show(initial != nil ? L.accounts_updated() : L.accounts_added())
                dismiss()
                if initial == nil { nav.push(kind == .investment ? .investmentDetail(id: saved) : .accountDetail(id: saved)) }
            }
        }
    }
}
