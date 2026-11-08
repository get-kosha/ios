import SwiftUI
import Model
import API
import Store
import Design

// Helpers every screen shares, ported from the Android app's core:ui (Shell.kt and Header.kt).

/// A money figure in the app's language, with a true minus. With Hide amounts on it is blurred and a touch and hold
/// peeks at it. VoiceOver reads the currency by name ("minus 29.57 euros"), or "Hide amounts" when hidden.
public struct MoneyText: View {
    let minor: Int64
    let currency: String
    let sign: Sign
    let font: KFont
    let color: Color?
    @Environment(\.kosha) private var theme

    public init(_ minor: Int64, _ currency: String, sign: Sign = .natural, font: KFont = .num, color: Color? = nil) {
        self.minor = minor
        self.currency = currency
        self.sign = sign
        self.font = font
        self.color = color
    }

    public var body: some View {
        let shown = sign == .none ? Int64(minor.magnitude) : minor
        Text(Money.format(minor, currency, theme.locale, sign: sign))
            .kFont(font)
            .foregroundStyle(color ?? theme.colors.ink)
            .lineLimit(1)
            .money()
            .accessibilityLabel(theme.hideAmounts ? L.shell_hide_amounts() : Money.spoken(shown, currency, theme.locale))
    }
}

/// The big figure: 40/600 with the cents in ink3 (`€1,312` + `.40`). `whole` drops the cents (Round amounts).
public struct HeroMoney: View {
    let minor: Int64
    let currency: String
    let size: CGFloat
    let color: Color?
    let sign: Sign
    let whole: Bool?
    @Environment(\.kosha) private var theme
    @Environment(Kosha.self) private var kosha

    public init(_ minor: Int64, _ currency: String, size: CGFloat = 40, color: Color? = nil, sign: Sign = .natural, whole: Bool? = nil) {
        self.minor = minor
        self.currency = currency
        self.size = size
        self.color = color
        self.sign = sign
        self.whole = whole
    }

    public var body: some View {
        let round = whole ?? (kosha.meta?.pref("round_hero", "0") == "1")
        let text = round ? wholeMoney(minor, currency, theme.locale, sign: sign) : Money.format(minor, currency, theme.locale, sign: sign)
        let decimals = Money.decimals(currency)
        let sep = Money.separators(theme.locale).decimal
        var styled = AttributedString(text)
        if !round, decimals > 0, let r = text.range(of: sep, options: .backwards) {
            let end = text.index(r.lowerBound, offsetBy: 1 + decimals, limitedBy: text.endIndex) ?? text.endIndex
            if let ar = Range(r.lowerBound..<end, in: styled) { styled[ar].foregroundColor = theme.colors.ink3 }
        }
        return Text(styled)
            .font(.custom("Geist-SemiBold", size: size, relativeTo: .largeTitle).monospacedDigit())
            .tracking(size * -0.035)
            .foregroundStyle(color ?? theme.colors.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .money()
            .accessibilityLabel(theme.hideAmounts ? L.shell_hide_amounts() : Money.spoken(minor, currency, theme.locale))
    }
}

/// Money in whole units, such as `€2,480` under a month or on a chart.
public func wholeMoney(_ minor: Int64, _ currency: String, _ locale: Locale, sign: Sign = .natural) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.locale = locale
    f.currencyCode = currency.uppercased()
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = 0
    f.roundingMode = .halfUp
    let text = f.string(from: (Decimal(minor.magnitude) / 100) as NSDecimalNumber) ?? ""
    if minor < 0 && sign != .none { return Money.minus + text }
    if minor > 0 && sign == .always { return "+" + text }
    return text
}

/// A share as a percentage in the language: "24%", with `signed` "+24%" or "−8%" (true minus).
public func percent(_ value: Double, _ locale: Locale, digits: Int = 0, signed: Bool = true) -> String {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.locale = locale
    f.minimumFractionDigits = digits
    f.maximumFractionDigits = digits
    let text = f.string(from: NSNumber(value: abs(value))) ?? ""
    if text == f.string(from: 0) { return text }
    if value < 0 { return Money.minus + text }
    return signed ? "+" + text : text
}

/// A rate the way the web writes one (core.ts fmtRate): 94.60, 1.1623, 0.01057.
public func rateText(_ to: Double?, _ from: Double?) -> String {
    guard let to, let from, from != 0 else { return "…" }
    let r = to / from
    if r >= 100 { return String(format: "%.2f", r) }
    if r >= 1 { return String(format: "%.4f", r) }
    return String(format: "%.4g", r)
}

/// The currency's name in the app's language: "Euro", "Indian rupee".
public func currencyName(_ code: String, _ locale: Locale) -> String {
    locale.localizedString(forCurrencyCode: code.uppercased()).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code.uppercased()
}

/// A soft banner: an icon, a title and a line under it, and an optional action.
public struct Banner<Action: View>: View {
    let icon: String
    let title: String
    let text: String
    let action: Action
    @Environment(\.kosha) private var theme

    public init(icon: String, title: String, text: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.text = text
        self.action = action()
    }

    public var body: some View {
        let c = theme.colors
        HStack(alignment: .top, spacing: 10) {
            PhIcon(icon, size: 18, color: c.ink2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(.sans(13, .medium))
                Text(text).kFont(.small).foregroundStyle(c.ink2)
                action
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(c.soft, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// The banners on the main tabs: offline (with the waiting count), and the demo account's, which offers "Create your
/// own account" on the server's sign-up page.
public struct TabBanners: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    public init() {}

    public var body: some View {
        let c = theme.colors
        VStack(spacing: 8) {
            if !kosha.online {
                Banner(
                    icon: "cloud-slash", title: L.common_offline_title(),
                    text: kosha.waiting.isEmpty ? L.app_offline_none() : L.app_offline_waiting(count: kosha.waiting.count)
                )
            }
            if kosha.demo {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        PhIcon("flask", size: 18, color: c.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.shell_demo_title()).kFont(.head)
                            Text(L.shell_demo_body()).kFont(.small).foregroundStyle(c.ink2)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    KButton(L.shell_demo_create(), size: .medium, icon: "arrow-square-out") {
                        if let server = kosha.server, let url = URL(string: "\(server)/login?mode=up") { nav.openWeb?(url) }
                    }
                }
                .padding(16)
                .background(c.brand.opacity(0.09), in: .rect(cornerRadius: 16))
                .background(c.surface, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.brand.opacity(0.3)))
            }
        }
        .padding(.horizontal, 16)
    }
}

/// "Showing what this phone saved…", for a screen whose saved copy is all it has while the server answers.
public struct LoadingNote: View {
    @Environment(\.kosha) private var theme
    public init() {}
    public var body: some View {
        Text(L.app_loading()).kFont(.small).foregroundStyle(theme.colors.ink3).accessibilityHidden(true)
    }
}

/// Grey blocks where content will be, while there is nothing saved to show.
public struct Skeleton: View {
    let height: CGFloat
    @Environment(\.kosha) private var theme
    public init(height: CGFloat = 16) { self.height = height }
    public var body: some View {
        RoundedRectangle(cornerRadius: 8).fill(theme.colors.soft).frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .accessibilityHidden(true)
    }
}

/// A page below the tabs: back, a title (22/600) with an optional line under it, and actions on the right. Content
/// scrolls under a 16pt gutter, above an optional footer on glass.
public struct Page<Content: View, Actions: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let scroll: Bool
    let actions: Actions
    let footer: Footer
    let content: Content
    /// Drawn before the title, such as an account's colour square.
    let leading: AnyView?
    /// Drawn right after the title, such as the AI page's Beta pill.
    let badge: AnyView?
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss

    public init(
        _ title: String, subtitle: String? = nil, scroll: Bool = true, leading: AnyView? = nil, badge: AnyView? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() }, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.badge = badge
        self.subtitle = subtitle
        self.scroll = scroll
        self.actions = actions()
        self.footer = footer()
        self.content = content()
    }

    public var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IconButton("caret-left", label: L.common_back()) { dismiss() }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        if let leading { leading }
                        Text(title).kFont(.title).lineLimit(2).accessibilityAddTraits(.isHeader)
                        if let badge { badge }
                    }
                    if let subtitle { Text(subtitle).kFont(.xs).foregroundStyle(c.ink3) }
                }
                .padding(.horizontal, 4)
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 52)
            TabBanners().padding(.bottom, 4)
            Group {
                if scroll {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { content }
                            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) { content }.padding(.horizontal, 16).padding(.top, 8)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if Footer.self != EmptyView.self {
                footer.padding(16).background(c.glass)
            }
        }
        .background(c.bg)
        .hideNavigationBar()
    }
}

/// Swiping sideways moves the shared month by one: left for the next, right for the previous. For Overview, Activity
/// and Recurring.
public struct MonthSwipe: ViewModifier {
    @Environment(Kosha.self) private var kosha
    public func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { g in
                guard abs(g.translation.width) > 72, abs(g.translation.width) > abs(g.translation.height) * 2 else { return }
                kosha.month = kosha.month.adding(g.translation.width < 0 ? 1 : -1)
            }
        )
    }
}

extension View {
    public func monthSwipe() -> some View { modifier(MonthSwipe()) }
}

extension Kosha {
    /// Currencies the header switch cycles through: the main one plus active accounts' currencies, in the saved order
    /// (shell.tsx currencyOptions). Single-currency users get one, and the switch hides.
    public var currencyOptions: [String] {
        guard let m = meta else { return [] }
        var used = [m.primaryCurrency]
        for w in m.wallets where !w.isArchived && !used.contains(w.currency) { used.append(w.currency) }
        return m.order.filter(used.contains) + used.filter { !m.order.contains($0) }
    }

    /// Whether this account can change anything: false for the demo.
    public var canWrite: Bool { !demo }

    /// Runs a write, then refreshes. Offline it shows `offline`; refused, the server's message (the demo's read-only
    /// one included). Returns nil when it didn't work.
    @discardableResult
    public func write<T: Sendable>(_ toasts: Toasts, offline: String = L.common_offline_title(), _ block: () async throws -> T) async -> T? {
        do {
            let out = try await block()
            changed()
            return out
        } catch let e as KoshaError {
            switch e {
            case .api(_, let err): toasts.show(err.message, warning: true)
            case .offline, .retryLater: toasts.show(offline, warning: true)
            default: break
            }
            return nil
        } catch {
            return nil
        }
    }
}

/// The current theme settings from the account's preferences: accent, account colours, density, figures, language,
/// motion and Hide amounts. The colour scheme comes from `theme` (Light, Dark, System).
@MainActor
public func themeSettings(_ kosha: Kosha) -> ThemeSettings {
    let m = kosha.meta
    return ThemeSettings(
        accent: Accent(rawValue: m?.pref("accent", "teal") ?? "teal") ?? .teal,
        neutral: m?.pref("account_colours", "1") == "0",
        density: m?.pref("density", "comfortable") == "compact" ? .compact : .comfortable,
        figures: m?.pref("figures", "mono") == "proportional" ? .proportional : .mono,
        language: L.resolve(m?.prefs["language"]?.string),
        motion: Motion(rawValue: m?.pref("motion", "on") ?? "on") ?? .on,
        hideAmounts: m?.pref("hide_amounts", "0") == "1"
    )
}

/// Light, dark, or nil for the system's, from the `theme` preference.
@MainActor
public func preferredScheme(_ kosha: Kosha) -> ColorScheme? {
    switch kosha.meta?.pref("theme", "system") {
    case "light": .light
    case "dark": .dark
    default: nil
    }
}
