#if DEBUG
import SwiftUI
import Model
import Design

// Debug only: every control in Design on one screen, to compare with
// ../kosha-android/design/screens/light/00-start-InputsKit.png. Its own words are English and not translated, as on
// Android (app/src/debug/res/values/kit.xml); the controls take their strings from the catalog. Sample data only.

private enum Kit {
    static let title = "Inputs kit"
    static let lead = "Kosha draws its own controls, so entry feels the same on iOS and Android and never waits for a system picker."
    static let keypad = "Amount keypad"
    static let keypadLead = "Used everywhere an amount is entered. Digits type straight into the amount, and a fourth column does the maths."
    static let keypadNotes = "• + − × ÷ work on the amount. Kosha keeps the sum and saves the result.\n• The decimal key follows the currency.\n• Backspace sits in the keypad; hold it to clear."
    static let tiles = "Tile row"
    static let tilesLead = "Category, date, repeat and note above the payee. Empty is dashed, a guess is grey, a sparkle marks an AI guess."
    static let date = "Date"
    static let dateLead = "Quick picks for the usual cases, a month grid for the rest."
    static let dateNotes = "Dots mark days that already have entries. Future days stay pickable for planned payments."
    static let time = "Time"
    static let timeLead = "A wheel for hours and minutes, drawn by Kosha in the style of iOS."
    static let timeNotes = "Flick or drag each wheel, or tap a row to jump to it. 24-hour or AM/PM follows your language."
    static let account = "Account"
    static let accountLead = "On Add, the account is a pill under the amount. Each carries its colour, balance and currency."
    static let accountNotes = "Recent first. Archived accounts are left out of quick entry."
    static let category = "Category"
    static let categoryLead = "Opens from the category tile, or from Next when Kosha can’t guess one. Five a row, most used first."
    static let categoryNotes = "Picked: accent outline. Guess: dashed, with a sparkle when AI made it. One tap accepts. After Next, picking a tile adds the entry straight away."
    static let controls = "Controls"
    static let controlsLead = "Segmented, switch, radio, tick, chip, stepper and buttons."
    static let fields = "Text fields"
    static let fieldsLead = "Rest, focused and with an error."
    static let fieldsNotes = "The system keyboard only ever opens for words: payee, note, names, search, server address and API keys."
    static let sheets = "Sheets, lists and toasts"
    static let sheetsLead = "One sheet pattern for every picker."
    static let sheetsNotes = "Sheets size to their content, drag down to close and keep the keypad under the thumb. Toasts carry Undo for five seconds. One list picker serves currencies, time zones, languages and “Move to…”."
    static let openAccount = "Open the account sheet"
    static let openList = "Open the list picker"
    static let openDate = "Open the date sheet"
    static let openTime = "Open the time sheet"
    static let openCategory = "Open the category sheet"
    static let showToast = "Show a toast"
    static let toast = "Added €4.20, Bonanza Coffee"
    static let serverError = "Enter a full URL, like https://kosha.example.com"
}

private struct SampleAccount {
    let id, name, currency: String
    let balance: Int64
    let colour: Int
}

private let accounts = [
    SampleAccount(id: "n26", name: "N26 Main", currency: "eur", balance: 241_830, colour: 0),
    SampleAccount(id: "visa", name: "Visa Card", currency: "eur", balance: -68_357, colour: 1),
    SampleAccount(id: "cash", name: "Cash", currency: "eur", balance: 8_500, colour: 4),
    SampleAccount(id: "hdfc", name: "HDFC Savings", currency: "inr", balance: 41_285_000, colour: 2),
]

private let categories = [
    CategoryTile(id: "groceries", icon: "shopping-cart", label: "Groceries"),
    CategoryTile(id: "dining", icon: "fork-knife", label: "Dining"),
    CategoryTile(id: "coffee", icon: "coffee", label: "Coffee"),
    CategoryTile(id: "transit", icon: "tram", label: "Transit"),
    CategoryTile(id: "shopping", icon: "shopping-bag", label: "Shopping"),
    CategoryTile(id: "home", icon: "house", label: "Home"),
    CategoryTile(id: "health", icon: "pill", label: "Health"),
    CategoryTile(id: "travel", icon: "airplane-tilt", label: "Travel"),
    CategoryTile(id: "gifts", icon: "gift", label: "Gifts"),
    CategoryTile(id: "bills", icon: "receipt", label: "Bills"),
]

/// The debug Inputs kit, with switches for theme, colour mode, accent and number font.
public struct InputsKit: View {
    @State private var dark = false
    @State private var settings = ThemeSettings()

    public init() {}

    public var body: some View {
        KitBody(dark: $dark, settings: $settings)
            .koshaTheme(settings)
            .environment(\.colorScheme, dark ? .dark : .light)
            .preferredColorScheme(dark ? .dark : .light)
    }
}

private struct KitBody: View {
    @Binding var dark: Bool
    @Binding var settings: ThemeSettings
    @Environment(\.kosha) private var theme
    @State private var toasts = Toasts()

    @State private var input = "12.50+4"
    @State private var kind = EntryKind.expense
    @State private var account = "n26"
    @State private var day = Day(2026, 11, 7)
    @State private var month = Month(2026, 11)
    @State private var time = "14:30"
    @State private var category: String? = "groceries"
    @State private var on = true
    @State private var off = false
    @State private var radio = true
    @State private var tick = true
    @State private var step = 1
    @State private var payee = ""
    @State private var focusedSample = "Bonanza Co"
    @State private var server = "kosha.home"
    @State private var currency = "eur"
    @State private var sheet: KitSheet?

    enum KitSheet: String, Identifiable {
        case account, list, date, time, category
        var id: String { rawValue }
    }

    var body: some View {
        let c = theme.colors
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Kit.title).kFont(.page)
                Text(Kit.lead).kFont(.body).foregroundStyle(c.ink2)
                switches
                section(Kit.keypad, Kit.keypadLead, Kit.keypadNotes) {
                    AmountDisplay(input: input, currency: "eur", kind: .transfer, note: "≈ ₹1,560.90 in HDFC Savings")
                    AmountKeypad(input: $input)
                }
                section(Kit.tiles, Kit.tilesLead) {
                    AccountPill("N26 Main", color: c.account(0)) { sheet = .account }
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 6) {
                        FieldTile(L.add_category(), icon: "tag", pick: .empty) { sheet = .category }
                        FieldTile(L.add_today(), icon: "calendar-blank") { sheet = .date }
                        FieldTile(L.app_add_repeat(), icon: "repeat", pick: .unset) {}
                        FieldTile(L.add_note(), icon: "note-pencil", pick: .unset) {}
                    }
                    HStack(spacing: 6) {
                        FieldTile("Dining", icon: "fork-knife", pick: .guess) {}
                        FieldTile("Coffee", icon: "coffee", pick: .guess, aiGuess: true) {}
                        FieldTile("Fri 6", icon: "calendar-blank") {}
                        FieldTile("Monthly", icon: "repeat") {}
                    }
                    TransferPills(
                        from: ("N26 Main", c.account(0)), to: ("HDFC Savings", c.account(2)), toPlaceholder: L.add_account(),
                        swapLabel: L.app_add_swap(), onFrom: {}, onTo: {}, onSwap: {}
                    )
                    .frame(maxWidth: .infinity)
                }
                section(Kit.date, Kit.dateLead, Kit.dateNotes) {
                    HStack(spacing: 8) {
                        Chip(L.add_today(), on: day == Day(2026, 11, 7)) { day = Day(2026, 11, 7) }
                        Chip(L.add_yesterday(), on: day == Day(2026, 11, 6)) { day = Day(2026, 11, 6) }
                        Chip(DayFormat.weekdayDay(Day(2026, 11, 6), theme.locale)) {}
                    }
                    MonthHeader(month: month) { month = month.adding($0) }
                    MonthGrid(month: month, selected: day, today: Day(2026, 11, 7),
                              dots: [Day(2026, 11, 1), Day(2026, 11, 4), Day(2026, 11, 5), Day(2026, 11, 6)]) { day = $0 }
                }
                section(Kit.time, Kit.timeLead, Kit.timeNotes) {
                    TimeWheel(time: $time)
                    KButton(L.app_time_now(), style: .soft, size: .medium) { time = "14:30" }
                }
                section(Kit.account, Kit.accountLead, Kit.accountNotes) {
                    AccountList(accountChoices(c), selected: account) { account = $0 }
                }
                section(Kit.category, Kit.categoryLead, Kit.categoryNotes) {
                    CategoryGrid(Array(categories.prefix(5)), picked: category, guess: "coffee", aiGuess: true) {
                        category = $0.id
                    }
                }
                section(Kit.controls, Kit.controlsLead) {
                    Segmented([(EntryKind.expense, L.add_kind_expense()), (.income, L.add_kind_income()),
                               (.transfer, L.add_kind_transfer())], selection: $kind)
                    HStack(spacing: 12) {
                        KSwitch("On", isOn: $on)
                        KSwitch("Off", isOn: $off)
                        Button { radio.toggle() } label: { Radio(radio) }.frame(width: 44, height: 44)
                        Radio(false)
                        Button { tick.toggle() } label: { Tick(tick) }.frame(width: 44, height: 44)
                        Tick(false)
                    }
                    HStack(spacing: 8) {
                        Chip("N26 Main") { AccountDot(c.account(0)) }
                        Chip(L.add_today(), on: true) { PhIcon("calendar-blank", size: 18) }
                    }
                    Chip("#lisbon", soft: true) { PhIcon("tag", size: 18) }
                    KStepper("Every", value: $step)
                    HStack(spacing: 8) {
                        KButton("Primary", size: .small) {}
                        KButton("Secondary", style: .secondary, size: .small) {}
                    }
                    KButton(L.common_delete(), style: .danger, size: .small) {}
                    HStack { Pill("fixed"); Pill("−8%", color: c.pos); Pill("+24%", color: c.warn) }
                }
                section(Kit.fields, Kit.fieldsLead, Kit.fieldsNotes) {
                    KField(L.add_payee(), text: $payee)
                    KField(L.add_payee(), text: $focusedSample)
                    KField(L.app_own_label(), text: $server, error: Kit.serverError)
                }
                section(Kit.sheets, Kit.sheetsLead, Kit.sheetsNotes) {
                    KButton(Kit.openAccount, style: .secondary, size: .medium) { sheet = .account }
                    KButton(Kit.openList, style: .secondary, size: .medium) { sheet = .list }
                    KButton(Kit.openDate, style: .secondary, size: .medium) { sheet = .date }
                    KButton(Kit.openTime, style: .secondary, size: .medium) { sheet = .time }
                    KButton(Kit.openCategory, style: .secondary, size: .medium) { sheet = .category }
                    KButton(Kit.showToast, style: .secondary, size: .medium) {
                        toasts.show(Kit.toast) { toasts.show(L.common_undo()) }
                    }
                }
            }
            .padding(16)
        }
        .background(c.bg)
        .toasts(toasts)
        .kSheet(item: $sheet, scrolls: false) { s in sheetContent(s) }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Segmented([(false, "Light"), (true, "Dark")], selection: $dark, small: true)
            Segmented([(false, "More colour"), (true, "Neutral")], selection: $settings.neutral, small: true)
            Segmented(Accent.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $settings.accent, small: true)
            Segmented([(Figures.mono, "Mono"), (.proportional, "Proportional")], selection: $settings.figures, small: true)
            Segmented(["en", "de", "hi", "ja"].map { ($0, $0) }, selection: $settings.language, small: true)
        }
        .onChange(of: settings.language) { _, l in L.use(language: l) }
    }

    private func accountChoices(_ c: KColors) -> [AccountChoice] {
        accounts.map { a in
            AccountChoice(
                id: a.id, name: a.name, color: c.account(a.colour), detail: a.currency.uppercased(),
                balance: Money.format(a.balance, a.currency, theme.locale), group: L.accounts_group_bank_cash()
            )
        }
    }

    @ViewBuilder
    private func sheetContent(_ s: KitSheet) -> some View {
        switch s {
        case .account:
            VStack(alignment: .leading) {
                SheetHeader(L.add_account()) { sheet = nil }
                AccountList(accountChoices(theme.colors), selected: account) {
                    account = $0
                    sheet = nil
                }
            }
        case .list:
            ListPicker(L.common_language(), choices: [
                Choice(id: "eur", title: "Euro", detail: "EUR"), Choice(id: "inr", title: "Indian rupee", detail: "INR"),
                Choice(id: "usd", title: "US dollar", detail: "USD"),
            ], selected: currency, onPick: { currency = $0; sheet = nil }, onClose: { sheet = nil })
        case .date:
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(L.add_date()) { sheet = nil }
                MonthHeader(month: month) { month = month.adding($0) }
                MonthGrid(month: month, selected: day, today: Day(2026, 11, 7)) { day = $0; sheet = nil }
            }
        case .time:
            VStack(spacing: 12) {
                SheetHeader(L.add_time()) { sheet = nil }
                TimeWheel(time: $time)
                KButton(L.common_done()) { sheet = nil }
            }
        case .category:
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(L.add_category()) { sheet = nil }
                Text(L.app_most_used()).kFont(.caption).foregroundStyle(theme.colors.ink3)
                CategoryGrid(categories, picked: category) { category = $0.id; sheet = nil }
            }
        }
    }

    private func section<Content: View>(
        _ title: String, _ lead: String, _ notes: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        Card {
            Text(title).kFont(.sans(17, .semibold))
            Text(lead).kFont(.small).foregroundStyle(theme.colors.ink2)
            content()
            if let notes { Text(notes).kFont(.small).foregroundStyle(theme.colors.ink2) }
        }
    }
}
#endif
