import SwiftUI
import Model
import API
import Store
import Design

/// The header of the main tabs. Overview and Recurring show the selected month (tap for the month sheet), Activity its
/// own dates (`period`), and Accounts its title. Then the display currency pill (tap to step through the user's currencies, touch and hold
/// for the currency sheet), the Ask sparkle when Ask Kosha is on, an optional action, and the avatar, which opens the
/// account menu. Ported from MainHeader in Header.kt.
public struct MainHeader<Action: View>: View {
    let title: String?
    let subtitle: String?
    let showMonth: Bool
    let showCurrency: Bool
    let period: HeaderPeriod?
    let action: Action
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var sheet: HeaderSheet?

    enum HeaderSheet: String, Identifiable {
        case month, currency, menu
        var id: String { rawValue }
    }

    public init(
        title: String? = nil, subtitle: String? = nil, showMonth: Bool? = nil, showCurrency: Bool? = nil,
        period: HeaderPeriod? = nil, @ViewBuilder action: () -> Action = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showMonth = showMonth ?? (title == nil)
        self.showCurrency = showCurrency ?? (showMonth ?? (title == nil))
        self.period = period
        self.action = action()
    }

    public var body: some View {
        let c = theme.colors
        HStack(spacing: 4) {
            if showMonth || period != nil {
                let now = Dates.month(kosha.tz)
                let shown = period ?? HeaderPeriod(
                    label: DayFormat.monthName(kosha.month, theme.locale).capitalized(with: theme.locale)
                        + (kosha.month.year != now.year ? " \(kosha.month.year)" : ""),
                    spoken: DayFormat.month(kosha.month, theme.locale),
                    open: { sheet = .month },
                    previous: (L.shell_previous_month(), { kosha.month = kosha.month.adding(-1) }),
                    next: (L.shell_next_month(), { kosha.month = kosha.month.adding(1) })
                )
                Button(action: shown.open) {
                    HStack(spacing: 6) {
                        Text(shown.label).kFont(.page).lineLimit(1).minimumScaleFactor(0.7)
                        PhIcon("caret-down", size: 18, color: c.ink3)
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(shown.spoken)
                .accessibilityAddTraits(.isHeader)
                // The swipe that steps the dates, for VoiceOver.
                .accessibilityActions {
                    if let p = shown.previous { Button(p.name, action: p.go) }
                    if let n = shown.next { Button(n.name, action: n.go) }
                }
                Spacer(minLength: 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? "").kFont(.page).lineLimit(1).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).kFont(.small).foregroundStyle(c.ink3) }
                }
                Spacer(minLength: 4)
            }
            if showCurrency, let m = kosha.meta {
                let list = kosha.currencyOptions
                let shown = kosha.display
                if list.count > 1 {
                    let following = list[((list.firstIndex(of: shown) ?? 0) + 1) % list.count]
                    Text(shown.uppercased())
                        .kFont(.figure(13, .regular))
                        .foregroundStyle(c.ink2)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(c.surface, in: .capsule)
                        .overlay(Capsule().strokeBorder(c.line))
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                        .onTapGesture { kosha.currency = following == m.primaryCurrency ? nil : following }
                        .onLongPressGesture { sheet = .currency }
                        .accessibilityElement()
                        .accessibilityLabel(L.shell_currency_label(currency: shown.uppercased(), next: following.uppercased()))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { kosha.currency = following == m.primaryCurrency ? nil : following }
                        .accessibilityAction(named: L.app_ov_show_totals_in()) { sheet = .currency }
                }
            }
            if kosha.meta?.aiFlags.ask == true {
                IconButton("sparkle", label: L.shell_ask_kosha(), color: c.brand) { nav.push(.ask()) }
            }
            action
            Avatar(name: kosha.meta?.user?.name ?? "") { sheet = .menu }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        // A 34pt title grows only so far, so the month and the buttons still fit one row.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .kSheet(item: $sheet) { s in
            switch s {
            case .month: MonthSheet(month: kosha.month) { kosha.month = $0; sheet = nil } close: { sheet = nil }
            case .currency: CurrencySheet { sheet = nil }
            case .menu: AccountMenu { sheet = nil }
            }
        }
    }
}

/// What the header's title shows when a screen picks its own dates, as Activity does: `label`, read as `spoken`,
/// opening the screen's picker, and the steps back and on (a name for VoiceOver and the action), when there are any.
public struct HeaderPeriod {
    public var label: String
    public var spoken: String
    public var open: () -> Void
    public var previous: (name: String, go: () -> Void)?
    public var next: (name: String, go: () -> Void)?

    public init(label: String, spoken: String, open: @escaping () -> Void,
                previous: (name: String, go: () -> Void)? = nil, next: (name: String, go: () -> Void)? = nil) {
        self.label = label
        self.spoken = spoken
        self.open = open
        self.previous = previous
        self.next = next
    }
}

/// Profile pictures already fetched, by their URL (user.image changes with each upload).
@MainActor private var photos: [String: Image] = [:]

/// The avatar: the account's photo, or its initial on the selection ground. 48pt to tap.
public struct Avatar: View {
    let name: String
    let size: CGFloat
    let action: (() -> Void)?
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var photo: Image?

    public init(name: String, size: CGFloat = 36, action: (() -> Void)? = nil) {
        self.name = name
        self.size = size
        self.action = action
    }

    public var body: some View {
        let face = ZStack {
            Circle().fill(theme.colors.sel)
            if let photo {
                photo.resizable().scaledToFill()
            } else {
                Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased().ifEmpty("K"))
                    .font(.custom("Geist-SemiBold", size: size * 0.39, relativeTo: .body))
                    .foregroundStyle(theme.colors.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: kosha.meta?.user?.image) { await load() }
        if let action {
            Button(action: action) { face.frame(width: 48, height: 48).contentShape(.circle) }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L.shell_account_menu())
        } else {
            face.accessibilityHidden(true)
        }
    }

    private func load() async {
        guard let image = kosha.meta?.user?.image else { photo = nil; return }
        if let p = photos[image] { photo = p; return }
        guard let data = try? await kosha.api.bytes("/api/app/avatar"), let p = platformImage(data) else { return }
        photos[image] = p
        photo = p
    }
}

/// An image from bytes, on iOS or the Mac.
public func platformImage(_ data: Data) -> Image? {
    #if canImport(UIKit)
    UIImage(data: data).map(Image.init(uiImage:))
    #else
    NSImage(data: data).map(Image.init(nsImage:))
    #endif
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// One month of get_month_overview's history: what MonthSheet shows under each month.
struct MonthHistory: Codable, Sendable {
    @D var history: [Item]
    struct Item: Codable, Sendable {
        var month: String
        @Rounded var spending: Int64
    }
}

/// A year of months to jump to, each with what was spent in it (one get_month_overview for December gives the year's
/// twelve). "Swipe Overview, Activity or Recurring sideways to move one month."
public struct MonthSheet: View {
    let month: Month
    let onPick: (Month) -> Void
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var year: Int
    @State private var spent: [String: Int64] = [:]

    public init(month: Month, onPick: @escaping (Month) -> Void, close: @escaping () -> Void) {
        self.month = month
        self.onPick = onPick
        self.close = close
        _year = State(initialValue: month.year)
    }

    public var body: some View {
        let c = theme.colors
        let now = Dates.month(kosha.tz)
        let currency = kosha.display
        VStack(spacing: 8) {
            SheetHeader(L.app_ov_pick_month(), onClose: nil, trailing: {
                Chip(L.overview_this_month(), soft: true, small: true) { onPick(now) }
            })
            HStack {
                IconButton("caret-left", label: L.app_previous_year()) { year -= 1 }
                Text(String(year)).kFont(.figure(17, .medium)).frame(maxWidth: .infinity)
                IconButton("caret-right", label: L.app_next_year()) { year += 1 }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<4, id: \.self) { r in
                    GridRow {
                        ForEach(1...3, id: \.self) { col in
                            let ym = Month(year, r * 3 + col)
                            tile(ym, now: now, currency: currency)
                        }
                    }
                }
            }
            Text(L.app_month_swipe()).kFont(.xs).foregroundStyle(c.ink3).multilineTextAlignment(.center).padding(.top, 8)
        }
        .task(id: "\(year)/\(currency)/\(kosha.version)") {
            guard year <= now.year else { spent = [:]; return }
            let y = year
            await kosha.load("monthsheet/\(y)/\(currency)", into: { (l: Loaded<MonthHistory>) in
                spent = Dictionary((l.value?.history ?? []).map { ($0.month, $0.spending) }, uniquingKeysWith: { a, _ in a })
            }) { api in
                try await api.get("/api/v1/reports/month", query: ["month": "\(y)-12", "currency": currency])
            }
        }
    }

    private func tile(_ ym: Month, now: Month, currency: String) -> some View {
        let c = theme.colors
        let on = ym == month
        let future = ym > now
        let tint = on ? c.onSelection : c.ink3
        return Button { onPick(ym) } label: {
            VStack(spacing: 2) {
                Text(DayFormat.monthName(ym, theme.locale).capitalized(with: theme.locale))
                    .kFont(on ? .head : .body).foregroundStyle(on ? c.onSelection : c.ink).lineLimit(1).minimumScaleFactor(0.7)
                Group {
                    if future {
                        Text(L.app_ov_not_started())
                    } else if let s = spent[ym.text] {
                        let amount = wholeMoney(s, currency, theme.locale, sign: .none)
                        Text(ym == now ? L.app_ov_month_so_far(amount: amount) : amount)
                    } else {
                        Text(" ")
                    }
                }
                .kFont(.figure(12, .regular)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7).money()
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(on ? c.selection : c.soft, in: .rect(cornerRadius: 12))
            .opacity(future && !on ? 0.55 : 1)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct NetWorthTotal: Codable, Sendable {
    @D var currency: String
    @Rounded var total: Int64
}

/// "Show totals in": the user's currencies in their order, each with today's rate and net worth converted at it, then a
/// way to Settings › Currencies. Picking one sets the display currency for Overview, Activity and Recurring.
public struct CurrencySheet: View {
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var worth: NetWorthTotal?

    public init(close: @escaping () -> Void) { self.close = close }

    public var body: some View {
        let c = theme.colors
        if let m = kosha.meta {
            let list = kosha.currencyOptions
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(L.app_ov_show_totals_in(), onClose: close)
                Card(tight: true) {
                    ForEach(list.indices, id: \.self) { i in
                        let code = list[i]
                        let on = code == kosha.display
                        if i > 0 { Hairline() }
                        ListRow(action: {
                            kosha.currency = code == m.primaryCurrency ? nil : code
                            close()
                        }) {
                            Radio(on)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(currencyName(code, theme.locale)).kFont(on ? .head : .body)
                                    Text(code.uppercased()).kFont(.body).foregroundStyle(c.ink3)
                                }
                                Text(code == m.primaryCurrency ? L.app_ov_main_currency()
                                     : "1 \(m.primaryCurrency.uppercased()) = \(rateText(m.rates[code], m.rates[m.primaryCurrency])) \(code.uppercased())")
                                    .kFont(.xs).foregroundStyle(c.ink3)
                            }
                            Spacer(minLength: 8)
                            if let w = worth {
                                MoneyText(convert(w.total, from: m.primaryCurrency, to: code, perUsd: m.rates), code, color: c.ink2)
                            }
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Text(L.app_ov_converted_today()).kFont(.xs).foregroundStyle(c.ink3).padding(.horizontal, 4).padding(.top, 12)
                KButton(L.app_ov_your_currencies(), style: .secondary, size: .medium) {
                    close()
                    nav.push(.settings(page: "currencies"))
                }
                .padding(.top, 16)
            }
            .task(id: kosha.version) {
                await kosha.load("networth/\(m.primaryCurrency)", into: { (l: Loaded<NetWorthTotal>) in worth = l.value }) { api in
                    try await api.get("/api/v1/reports/net-worth")
                }
            }
        }
    }
}

/// Sign-in methods, for the badge on Sign-in & security (GET /api/app/account).
struct SignIns: Codable, Sendable {
    var hasPassword: Bool?
    @D var passkeys: Int
    @D var twoFactor: Bool
}

/// The account menu from the avatar: who is signed in, theme, Hide amounts, Settings, Sign-in & security (with a badge
/// for missing steps), Categories, AI, Language, and Sign out ("Signing out clears what this device saved.").
public struct AccountMenu: View {
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var signIns: SignIns?

    public init(close: @escaping () -> Void) { self.close = close }

    private func go(_ page: String) {
        close()
        nav.push(.settings(page: page))
    }

    public var body: some View {
        let c = theme.colors
        let m = kosha.meta
        // Password, a passkey, and backup codes once two-factor is on: the steps Security's progress counts.
        let missing = signIns.map { s in
            [s.hasPassword == false, s.passkeys == 0, s.twoFactor && (m?.pref("backup_codes_saved_at", "") ?? "").isEmpty]
                .filter { $0 }.count
        } ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(name: m?.user?.name ?? "", size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m?.user?.name ?? "").kFont(.sans(17, .semibold))
                    Text(m?.user?.email ?? "").kFont(.body).foregroundStyle(c.ink3)
                }
                Spacer()
                IconButton("x", label: L.common_close(), action: close)
            }
            Card {
                Text(L.shell_theme()).kFont(.small).foregroundStyle(c.ink3)
                Segmented(
                    [("light", L.shell_theme_light()), ("dark", L.shell_theme_dark()), ("system", L.shell_theme_system())],
                    selection: Binding(get: { m?.pref("theme", "system") ?? "system" }, set: { kosha.setPreference("theme", $0) }),
                    small: true, icons: ["sun", "moon", "circle-half"]
                )
            }
            Card(tight: true) {
                menuRow("eye-slash", L.shell_hide_amounts(), action: nil) {
                    KSwitch(L.shell_hide_amounts(), isOn: Binding(
                        get: { m?.pref("hide_amounts", "0") == "1" },
                        set: { kosha.setPreference("hide_amounts", $0 ? "1" : "0") }
                    ))
                }
            }
            Card(tight: true) {
                menuRow("gear", L.shell_settings()) { go("") }
                Hairline()
                menuRow("shield-check", L.shell_security(), action: { go("security") }) {
                    if missing > 0 {
                        Text("\(missing)").font(.custom("Geist-SemiBold", size: 11, relativeTo: .caption2))
                            .foregroundStyle(c.dark ? Color.black : .white)
                            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20).background(c.warn, in: .capsule)
                    }
                    chevron
                }
                Hairline()
                menuRow("tag", L.shell_categories()) { go("categories") }
                if m?.aiFlags.any == true || m?.pref("ai_enabled", "0") == "1" {
                    Hairline()
                    menuRow("sparkle", L.shell_ai(), action: { go("ai") }) {
                        Pill(L.shell_beta(), color: c.brand)
                        chevron
                    }
                }
                Hairline()
                menuRow("translate", L.common_language(), action: { go("general") }) {
                    let lang = Locale(identifier: L.language)
                    Text(lang.localizedString(forLanguageCode: L.language)?.capitalized(with: lang) ?? L.language)
                        .kFont(.small).foregroundStyle(c.ink3)
                    chevron
                }
            }
            if !kosha.waiting.isEmpty {
                Text(L.app_signout_waiting(count: kosha.waiting.count)).kFont(.small).foregroundStyle(c.warn)
            }
            Card(tight: true) {
                ListRow(action: {
                    close()
                    Task { await kosha.signOut() }
                }) {
                    PhIcon("sign-out", color: c.bad)
                    Text(L.shell_sign_out()).foregroundStyle(c.bad)
                    Spacer()
                }
            }
            Text(L.app_signout_clears()).kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity)
        }
        .task {
            await kosha.load("account", into: { (l: Loaded<SignIns>) in signIns = l.value }) { api in
                try await api.get("/api/app/account")
            }
        }
    }

    private var chevron: some View { PhIcon("caret-right", size: 16, color: theme.colors.ink3) }

    private func menuRow(_ icon: String, _ label: String, action: (() -> Void)?) -> some View {
        menuRow(icon, label, action: action) { chevron }
    }

    private func menuRow<End: View>(_ icon: String, _ label: String, action: (() -> Void)?, @ViewBuilder end: () -> End) -> some View {
        let row = HStack(spacing: 12) {
            PhIcon(icon)
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            end()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: theme.dims.settingsRow)
        .contentShape(Rectangle())
        return Group {
            if let action { Button(action: action) { row }.buttonStyle(PressStyle()) } else { row }
        }
    }
}
