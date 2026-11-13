import SwiftUI
import Model
import API
import Store
import Design

// Pickers several screens share: accounts, categories, date and time, and an amount on the keypad. Ported from the
// Android app's Add sheets (feature/add Sheets.kt), made reusable for Recurring, Accounts, Activity and Reconcile.

extension Kosha {
    /// Accounts that aren't archived, in the user's order: what quick entry offers.
    public var activeWallets: [Wallet] { meta?.wallets.filter { !$0.isArchived } ?? [] }

    public func wallet(_ id: String?) -> Wallet? { id.flatMap { id in meta?.wallets.first { $0.id == id } } }

    public func category(_ id: String?) -> MetaCategory? { id.flatMap { id in meta?.categories.first { $0.id == id } } }

    /// The account's colour slot: its position in the user's account order (archived ones too, so colours stay put).
    public func colorIndex(_ accountId: String?) -> Int {
        meta?.wallets.firstIndex { $0.id == accountId } ?? 0
    }

    /// Categories a person can pick for an expense or an income: not archived, not Kosha's own.
    public func pickable(income: Bool) -> [MetaCategory] {
        (meta?.categories ?? []).filter { !$0.isArchived && $0.isIncome == income && !Categories.isSystem($0.id) }
    }
}

/// The account type's name: Bank, Cash, Credit card, Investment.
public func accountTypeName(_ type: AccountType) -> String {
    switch type {
    case .bank: L.accounts_type_bank()
    case .cash: L.accounts_type_cash()
    case .credit: L.accounts_type_credit()
    case .investment: L.accounts_type_investment()
    }
}

/// Accounts grouped as Bank & cash, Credit cards and Investments; archived ones left out (AccountSheet). Cards show the
/// credit left of their limit; foreign accounts add their currency code after the balance.
public struct AccountSheet: View {
    let title: String
    let selected: String?
    let exclude: String?
    let onPick: (String) -> Void
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    public init(title: String = L.add_account(), selected: String?, exclude: String? = nil,
                onPick: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.exclude = exclude
        self.onPick = onPick
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title, onClose: close)
            AccountList(choices, selected: selected) { onPick($0) }
        }
    }

    private var choices: [AccountChoice] {
        let groups: [(String, [AccountType])] = [
            (L.accounts_group_bank_cash(), [.bank, .cash]), (L.accounts_group_credit(), [.credit]),
            (L.accounts_group_investment(), [.investment]),
        ]
        let primary = kosha.primary
        return groups.flatMap { label, types in
            kosha.activeWallets.filter { types.contains($0.kind) && $0.id != exclude }.map { w in
                let color = theme.colors.account(kosha.colorIndex(w.id))
                let code = w.currency.uppercased()
                if w.kind == .credit, let limit = w.creditLimit {
                    // Cards show the credit left: the limit plus the (negative) balance.
                    let detail = L.app_add_available_of(
                        available: Money.format(limit + w.balance, w.currency, theme.locale),
                        limit: wholeMoney(limit, w.currency, theme.locale)
                    )
                    return AccountChoice(id: w.id, name: w.name, color: color, detail: detail, balance: "", group: label)
                }
                let balance = Money.format(w.balance, w.currency, theme.locale) + (w.currency != primary ? " \(code)" : "")
                return AccountChoice(id: w.id, name: w.name, color: color, detail: "\(accountTypeName(w.kind)) · \(code)",
                                     balance: balance, group: label)
            }
        }
    }
}

/// A category picker sheet: search, Most used (ten, five a row), All (each with its subcategories after it), and New.
/// `reason` replaces "Most used first." under the title (the Next flow). `onPick` gets the top category and the
/// subcategory, if one was picked.
public struct CategorySheet: View {
    let title: String
    let reason: String?
    let income: Bool
    let picked: String?
    let guess: String?
    let aiGuess: Bool
    let onPick: (_ category: String, _ subcategory: String?) -> Void
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var query = ""

    public init(
        title: String = L.add_category(), reason: String? = nil, income: Bool, picked: String?, guess: String? = nil,
        aiGuess: Bool = false, onPick: @escaping (String, String?) -> Void, close: @escaping () -> Void
    ) {
        self.title = title
        self.reason = reason
        self.income = income
        self.picked = picked
        self.guess = guess
        self.aiGuess = aiGuess
        self.onPick = onPick
        self.close = close
    }

    public var body: some View {
        let c = theme.colors
        let all = kosha.pickable(income: income)
        let tops = all.filter { $0.parentId == nil }
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(title, onClose: close)
                .padding(.bottom, -8)
            Text(reason ?? L.app_add_most_used_first()).kFont(.body).foregroundStyle(c.ink2)
            KField(L.add_find_category(), text: $query, icon: "magnifying-glass")
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty {
                let found = all.filter { cat in
                    let parent = all.first { $0.id == cat.parentId }
                    return [parent?.name, cat.name].compactMap { $0 }.joined(separator: " › ").lowercased().contains(q)
                }
                if found.isEmpty { Text(L.add_no_category_match()).foregroundStyle(c.ink3) }
                grid(found, all: all, tops: tops)
            } else {
                let most = Array(tops.sorted { $0.uses > $1.uses }.prefix(10))
                Text(L.app_most_used()).kFont(.caption).foregroundStyle(c.ink3)
                grid(most, all: all, tops: tops)
                // The rest, each with its subcategories after it (category-picker.tsx).
                let mostIds = Set(most.map(\.id))
                let rest = tops.filter { !mostIds.contains($0.id) }.flatMap { t in [t] + all.filter { $0.parentId == t.id } }
                    + most.flatMap { t in all.filter { $0.parentId == t.id } }
                if !rest.isEmpty {
                    Text(L.add_all()).kFont(.caption).foregroundStyle(c.ink3)
                    grid(rest, all: all, tops: tops)
                }
            }
            KButton(L.settings_cat_new(), style: .secondary, size: .medium, icon: "plus") {
                close()
                // From Add, the tab's stack sits behind the cover: close Add first so the new page shows.
                nav.add = nil
                nav.push(.settings(page: "category"))
            }
        }
    }

    private func grid(_ cats: [MetaCategory], all: [MetaCategory], tops: [MetaCategory]) -> some View {
        CategoryGrid(
            cats.map { CategoryTile(id: $0.id, icon: categoryIconName($0.icon), label: $0.name) },
            picked: picked, guess: guess, aiGuess: aiGuess
        ) { t in
            guard let cat = all.first(where: { $0.id == t.id }) else { return }
            let top = cat.parentId.flatMap { p in tops.contains { $0.id == p } ? p : nil } ?? cat.id
            onPick(top, cat.id == top ? nil : cat.id)
        }
    }
}

/// Days of a month with entries (GET /api/app/days), for the dots under the calendar.
@MainActor
func entryDays(_ kosha: Kosha, _ month: Month) async -> Set<Day> {
    var out: Set<Day> = []
    let m = month.text
    await kosha.load("days/\(m)", into: { (l: Loaded<Days>) in out = Set((l.value?.days ?? []).compactMap(Day.init)) }) { api in
        try await api.get("/api/app/days", query: ["month": m])
    }
    return out
}

/// Date and time (DateSheet, then TimeSheet in the same sheet): quick picks, the month grid with dots on days that have
/// entries, "Days with entries", the picked day spelled out, and a Time row that opens the wheel. `time` nil hides
/// the time row; `endOfMonth` adds End of month after Start of month; days before `earliest` can't be picked.
public struct DateSheet: View {
    let title: String
    @Binding var day: Day
    let time: Binding<String>?
    let endOfMonth: Bool
    let earliest: Day?
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var month: Month
    @State private var dots: Set<Day> = []
    @State private var wheel = false

    public init(title: String? = nil, day: Binding<Day>, time: Binding<String>? = nil, endOfMonth: Bool = false,
                earliest: Day? = nil, close: @escaping () -> Void) {
        self.title = title ?? (time == nil ? L.add_date() : L.add_date_and_time())
        _day = day
        self.time = time
        self.endOfMonth = endOfMonth
        self.earliest = earliest
        self.close = close
        _month = State(initialValue: day.wrappedValue.monthOf)
    }

    public var body: some View {
        if wheel, let time { timeBody(time) } else { dateBody }
    }

    private var dateBody: some View {
        let c = theme.colors
        let today = kosha.today
        var quick: [(String, Day)] = [
            (L.add_today(), today), (L.add_yesterday(), today.adding(days: -1)), (L.add_start_of_month(), today.monthOf.first),
        ]
        if endOfMonth { quick.append((L.add_end_of_month(), today.monthOf.last)) }
        if let earliest { quick.removeAll { $0.1 < earliest } }
        return VStack(alignment: .leading, spacing: 8) {
            SheetHeader(title, onClose: close)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quick, id: \.0) { label, d in
                        Chip(label, on: day == d, soft: day != d, small: true) {
                            day = d
                            month = d.monthOf
                        }
                    }
                }
            }
            MonthHeader(month: month) { month = month.adding($0) }
            MonthGrid(month: month, selected: day, today: today, dots: dots, earliest: earliest) { day = $0 }
            HStack(spacing: 6) {
                Circle().fill(c.ink3).frame(width: 4, height: 4)
                Text(L.app_add_days_with_entries()).kFont(.small).foregroundStyle(c.ink3)
                Spacer()
                Text(DayFormat.long(day, theme.locale)).kFont(.small).foregroundStyle(c.ink3)
            }
            .padding(.vertical, 8)
            HStack(spacing: 8) {
                if let time {
                    let shown = DayFormat.time(time.wrappedValue, theme.locale)
                    Button { wheel = true } label: {
                        HStack(spacing: 10) {
                            PhIcon("clock", size: 18, color: c.ink2)
                            Text(L.add_time()).frame(maxWidth: .infinity, alignment: .leading)
                            Text(shown).kFont(.num)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                        .contentShape(.rect(cornerRadius: 14))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(L.app_add_time_row(time: shown))
                    KButton(L.common_done(), action: close).frame(width: 120)
                } else {
                    KButton(L.common_done(), action: close)
                }
            }
        }
        .task(id: "\(month.text)/\(kosha.version)") { dots = await entryDays(kosha, month) }
    }

    private func timeBody(_ time: Binding<String>) -> some View {
        let c = theme.colors
        let twelve = DayFormat.uses12Hour(theme.locale)
        return VStack(alignment: .leading, spacing: 8) {
            SheetHeader(L.add_time(), onClose: close)
            Button { wheel = false } label: {
                HStack(spacing: 6) {
                    PhIcon("caret-left", size: 18, color: c.ink2)
                    Text(DayFormat.label(day, today: kosha.today, theme.locale)).foregroundStyle(c.ink2)
                }
                .frame(minHeight: 48)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(L.app_add_back_to_date())
            TimeWheel(time: time)
            KButton(L.app_time_now(), style: .soft, size: .medium) { time.wrappedValue = Dates.time(kosha.tz) }
            Text(twelve ? L.app_add_time_help_12() : L.app_add_time_help_24())
                .kFont(.small).foregroundStyle(c.ink3).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .padding(.vertical, 12)
            KButton(L.common_done(), action: close)
        }
    }
}

/// An amount on Kosha's keypad in a sheet: the title, the amount with its expression, an optional note and the keypad,
/// then the primary button. For Fix balance, Update gains, Enter this payment, a recurring amount, editing an entry and
/// the filters' amounts. `onDone` gets positive minor units (×100); the caller gives the sign.
public struct AmountSheet: View {
    let title: String
    let currency: String
    let kind: EntryKind
    let note: String?
    let button: String
    let onDone: (Int64) -> Void
    let close: () -> Void
    @State private var input: String

    public init(
        title: String, currency: String, initial: Int64? = nil, kind: EntryKind = .transfer, note: String? = nil,
        button: String = L.common_done(), onDone: @escaping (Int64) -> Void, close: @escaping () -> Void
    ) {
        self.title = title
        self.currency = currency
        self.kind = kind
        self.note = note
        self.button = button
        self.onDone = onDone
        self.close = close
        _input = State(initialValue: initial.map { AmountSheet.text($0, currency) } ?? "")
    }

    /// Minor units as keypad input: 1250 is "12.5", 120000 yen "1200".
    nonisolated public static func text(_ minor: Int64, _ currency: String) -> String {
        let value = Decimal(minor.magnitude) / 100
        let d = Money.decimals(currency)
        var s = NSDecimalNumber(decimal: value.rounded(d)).stringValue
        if d == 0, let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        return s
    }

    public var body: some View {
        let decimals = Money.decimals(currency)
        let minor = Keypad.minorUnits(input, decimals: decimals)
        VStack(spacing: 8) {
            SheetHeader(title, onClose: close)
            AmountDisplay(input: input, currency: currency, kind: kind, note: note)
            AmountKeypad(input: $input, decimals: decimals)
            KButton(button) {
                if let minor { onDone(minor) }
            }
            .disabled(minor == nil)
        }
    }
}
