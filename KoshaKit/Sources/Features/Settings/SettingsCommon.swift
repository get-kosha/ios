import SwiftUI
import Model
import API
import Store
import Design

// What every settings page shares: the answers it reads, the pure rules behind it (ported from the web, tested), reads
// through the cache, writes with the demo lock, and the rows. Ported from the Android app's feature/settings
// (Data.kt, Logic.kt, Common.kt).

// MARK: Answers

/// GET /api/app/account (accountOverview): sign-in methods and what Delete & reset would remove.
struct AccountSummary: Codable, Sendable {
    @D var transactions: Int
    @D var accounts: Int
    @D var recurring: Int
    @D var categories: Int
    @D var rules: Int
    @D var hasPassword: Bool
    /// Nil when the server has no Google sign-in; `accountId` is the connected login, if any.
    var google: Google?
    @D var twoFactor: Bool
    @D var passkeys: Int

    struct Google: Codable, Sendable { var accountId: String? }
}

/// One AI provider from GET /api/app/ai/providers. The key never comes back, only its last four characters.
struct AiProvider: Codable, Sendable, Identifiable {
    var id: String
    @D var connected: Bool
    @D var model: String
    var keyHint: String?
    var baseUrl: String?
    @D var isDefault: Bool

    init(id: String) { self.id = id }
}

/// POST /api/app/ai/providers/{id}/test: the provider's models, or why it couldn't be reached.
struct AiTest: Codable, Sendable {
    @D var ok: Bool
    @D var ms: Int64
    @D var models: [String]
    var error: String?
}

/// GET /api/app/ai/log: this month's usage and the last 30 days of requests.
struct AiUsage: Codable, Sendable {
    @D var requests: Int
    @D var tokens: Int64
    @D var log: [Entry]

    struct Entry: Codable, Sendable, Identifiable {
        var id: String
        var at: Int64
        var provider: String
        var model: String
        var feature: String
        @D var request: String
        @D var response: String
        @D var tokens_in: Int64
        @D var tokens_out: Int64
    }
}

/// GET /api/app/api-access: API keys, apps connected through OAuth, and where MCP and the API docs live.
struct ApiAccess: Codable, Sendable {
    @D var keys: [Key]
    @D var apps: [App]
    @D var mcpUrl: String
    @D var docsUrl: String

    struct Key: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        @D var hint: String
        var scope: String?
        /// Unix seconds.
        @D var created_at: Int64
        var last_used_at: Int64?
    }

    struct App: Codable, Sendable, Identifiable {
        var clientId: String
        var name: String
        @D var host: String
        @D var write: Bool
        /// Milliseconds.
        @D var connectedAt: Int64
        var lastUsedAt: Int64?
        var id: String { clientId }
    }
}

/// POST /api/app/api-keys: the new key, shown this once.
struct NewKey: Codable, Sendable {
    var id: String
    var key: String
}

/// GET /api/v1/categories?includeArchived=true, with the count of balance corrections (system category 0).
struct CategoryList: Codable, Sendable {
    var categories: [Model.Category]
    @D var correctionCount: Int
}

struct EventList: Codable, Sendable { var events: [KoshaEvent] }

struct PayeeRules: Codable, Sendable {
    var rules: [PayeeRule]
    @D var total: Int
    var nextOffset: Int?
}

// MARK: Rules

/// The four sign-in steps and whether each is done (security.tsx securitySteps). The Settings badge counts the open
/// ones. Backup codes count only once two-factor is on.
func securitySteps(_ a: AccountSummary, backupCodesSaved: Bool) -> [(key: String, done: Bool)] {
    [("password", a.hasPassword), ("passkey", a.passkeys > 0), ("two-factor", a.twoFactor),
     ("codes", a.twoFactor && backupCodesSaved)]
}

/// Settings words typed into search: every word must appear in one of the texts (registry.tsx searchSettings).
func matchesAll(_ query: String, _ texts: String...) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    if words.isEmpty { return false }
    let hay = texts.joined(separator: " ").lowercased()
    return words.allSatisfy { hay.contains($0) }
}

/// The currencies in the order the person keeps them: the default first, then the saved order, then any account currency
/// missing from it (shell.tsx currencyOptions, plus currencies added here).
func currencyOrder(primary: String, order: [String], used: [String]) -> [String] {
    ([primary] + order + used).map { $0.lowercased() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
}

extension Array {
    /// The list with the item at `from` moved to `to`.
    func moved(from: Int, to: Int) -> [Element] {
        guard from != to, indices.contains(from), indices.contains(to) else { return self }
        var out = self
        out.insert(out.remove(at: from), at: to)
        return out
    }
}

/// Units of `to` for one unit of `from`, at rates held per 1 USD. Nil when either rate is missing.
func rate(from: String, to: String, perUsd: [String: Double]) -> Double? {
    guard let f = perUsd[from], let t = perUsd[to], f != 0 else { return nil }
    return t / f
}

/// A zone's city as people say it: "Europe/Kolkata" reads "Kolkata", "America/New_York" reads "New York".
func zoneCity(_ id: String) -> String {
    (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
}

/// "UTC+1", "UTC+5:30", "UTC−5" for a zone right now, with a true minus.
func zoneOffset(_ id: String, now: Date = Date()) -> String {
    guard let zone = TimeZone(identifier: id) else { return "UTC" }
    let seconds = zone.secondsFromGMT(for: now)
    if seconds == 0 { return "UTC+0" }
    let sign = seconds < 0 ? Money.minus : "+"
    let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
    return "UTC\(sign)\(h)" + (m != 0 ? String(format: ":%02d", m) : "")
}

/// The zones a person can pick: region/city ones, without the legacy aliases, the phone's first.
func zoneChoices() -> [Choice<String>] {
    let phone = TimeZone.current.identifier
    let all = TimeZone.knownTimeZoneIdentifiers.filter {
        $0.contains("/") && !$0.hasPrefix("Etc/") && !$0.hasPrefix("SystemV/") && !$0.hasPrefix("US/")
            && $0.first?.isUppercase == true && $0 != phone
    }
    return ([phone] + all.sorted { zoneCity($0) < zoneCity($1) }).map {
        Choice(id: $0, title: zoneCity($0), detail: "\($0) · \(zoneOffset($0))")
    }
}

/// A language named in its own language: "Deutsch", "日本語".
func languageName(_ code: String) -> String {
    let l = Locale(identifier: code)
    return l.localizedString(forLanguageCode: code).map { $0.prefix(1).uppercased(with: l) + $0.dropFirst() } ?? code
}

/// The currencies a person can pick: those the server has a rate for that the phone can name, by name.
func currencyChoices(_ codes: some Sequence<String>, _ locale: Locale, except: [String] = []) -> [Choice<String>] {
    codes.filter { $0.count == 3 && !except.contains($0) && locale.localizedString(forCurrencyCode: $0.uppercased()) != nil }
        .map { Choice(id: $0, title: currencyName($0, locale), detail: $0.uppercased()) }
        .sorted { $0.title < $1.title }
}

/// The AI features with the preference that turns each on and what it can't work without (core.ts AI_FEATURES).
enum AiFeature: String, CaseIterable {
    case categorise, quick_add, receipts, recap, ask, statements

    var pref: String { "ai_\(rawValue)" }
    var needs: [String] {
        switch self {
        case .categorise: ["ai_share_payee", "suggest_category"]
        case .recap: ["ai_share_amount"]
        default: []
        }
    }
}

/// Every preference's default (core.ts PREFS), for the keys Settings reads before the server has sent them.
let prefDefaults: [String: String] = [
    "theme": "system", "motion": "on", "accent": "teal", "density": "comfortable", "figures": "mono",
    "hide_amounts": "0", "account_colours": "1", "round_hero": "0", "default_wallet": "last", "add_kind": "expense",
    "suggest_category": "1", "default_auto_pay": "1", "upcoming_horizon": "month", "learn_rules": "1",
    "ai_enabled": "0", "ai_share_amount": "1", "ai_share_payee": "1", "ai_share_date": "1", "ai_share_note": "0",
    "ai_share_account": "0", "ai_log_enabled": "1", "ai_categorise": "1", "ai_quick_add": "1", "ai_receipts": "1",
    "ai_recap": "1", "ai_ask": "1", "ai_statements": "1",
]

extension Optional where Wrapped == Meta {
    /// A preference as text, with Kosha's default when the server hasn't sent it.
    func prefOf(_ key: String) -> String { self?.pref(key, prefDefaults[key] ?? "") ?? prefDefaults[key] ?? "" }
}

/// The stable code that stands in for a payee name when payee names aren't shared (core.ts payeeCode, FNV-1a).
func payeeCode(uid: String, payee: String) -> String {
    var h: UInt32 = 0x811c9dc5
    for unit in "\(uid)\u{0}\(payee.trimmingCharacters(in: .whitespaces).lowercased())".utf16 {
        h = (h ^ UInt32(unit)) &* 0x01000193
    }
    return "payee_" + String(h, radix: 36)
}

/// How one field of the example shows: sent as is, sent in a masked form, or left out.
enum Shown { case on, masked, off }

/// One sample transaction for What AI can see, as core.ts redactForAi would send it (ai.tsx Payload).
struct SampleTx {
    var payee: String
    var amount: Int64
    var currency: String
    var day: String
    var note: String
    var account: String
}

/// The example's lines: field, its JSON value, and how it shows.
func samplePayload(_ tx: SampleTx, shares: [String: Bool], uid: String) -> [(field: String, value: String, shown: Shown)] {
    func json(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    let payee = shares["payee"] == true, amount = shares["amount"] == true, date = shares["date"] == true
    let note = shares["note"] == true, account = shares["account"] == true
    let value = NSDecimalNumber(decimal: Decimal(tx.amount) / 100).stringValue
    return [
        ("payee", json(payee ? tx.payee : payeeCode(uid: uid, payee: tx.payee)), payee ? .on : .masked),
        ("amount", amount ? value : "null", amount ? .on : .masked),
        ("currency", json(tx.currency.uppercased()), .on),
        date ? ("date", json(tx.day), .on) : ("month", json(String(tx.day.prefix(7))), .masked),
        ("note", json(tx.note), note ? .on : .off),
        ("account", json(tx.account), account ? .on : .off),
    ]
}

/// The server's host, as the footer and the hand-off notes name it: "getkosha.app".
func serverHost(_ server: String?) -> String { server.flatMap { URL(string: $0)?.host } ?? "getkosha.app" }

/// "3 Aug", or "3 Aug 2025" in another year, from unix seconds in the user's time zone.
func shortDate(_ seconds: Int64, tz: String, locale: Locale) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(seconds))
    let day = Dates.today(tz, now: date)
    return day.year == Dates.today(tz).year ? DayFormat.dayMonth(day, locale) : DayFormat.long(day, locale)
}

// MARK: Reads and writes

private struct Load<T: Codable & Sendable>: ViewModifier {
    let key: String
    @Binding var value: T?
    let fetch: @Sendable (KoshaAPI) async throws -> T
    @Environment(Kosha.self) private var kosha

    func body(content: Content) -> some View {
        content.task(id: "\(key)/\(kosha.version)") {
            await kosha.load(key, into: { (l: Loaded<T>) in if let v = l.value { value = v } }, fetch: fetch)
        }
    }
}

extension View {
    /// Reads through the cache (the saved copy first, then the server's) into `value`, again after every change.
    func load<T: Codable & Sendable>(_ key: String, into value: Binding<T?>, fetch: @escaping @Sendable (KoshaAPI) async throws -> T) -> some View {
        modifier(Load(key: key, value: value, fetch: fetch))
    }
}

/// Runs a page's writes. The demo account is read-only, so every write there shows its message instead. Failures show
/// the server's message (or the offline one) and success refreshes what every screen reads.
@MainActor
struct Writer {
    let kosha: Kosha
    let toasts: Toasts

    func refused() -> Bool {
        if kosha.demo { toasts.show(L.common_demo_read_only(), warning: true) }
        return kosha.demo
    }

    /// A write; `done` runs with its result when it worked, `always` once it has finished either way.
    func run<T: Sendable>(_ block: @escaping @MainActor () async throws -> T, always: @escaping @MainActor () -> Void = {},
                          done: @escaping @MainActor (T) -> Void = { _ in }) {
        if refused() { return always() }
        Task {
            let r = await kosha.write(toasts) { try await block() }
            always()
            if let r { done(r) }
        }
    }

    /// Sends a request whose answer isn't read.
    func send(_ method: String, _ path: String, _ body: JSONValue? = nil, done: @escaping @MainActor () -> Void = {}) {
        run({ try await kosha.api.send(method, path, body: body) }, done: { _ in done() })
    }

    /// Saves a synced preference, applied at once.
    func pref(_ key: String, _ value: String?) { if !refused() { kosha.setPreference(key, value) } }

    func toast(_ message: String) { toasts.show(message) }
}

extension View {
    /// The `on`/`off` of a "0"/"1" preference as a binding that saves itself.
    @MainActor func prefBinding(_ kosha: Kosha, _ w: Writer, _ key: String) -> Binding<Bool> {
        Binding(get: { kosha.meta.prefOf(key) == "1" }, set: { w.pref(key, $0 ? "1" : "0") })
    }
}

/// Copies text to the clipboard.
@MainActor func copyText(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

// MARK: Rows

/// A section caption above a card.
struct GroupCaption<Trailing: View>: View {
    let text: String
    let trailing: Trailing
    @Environment(\.kosha) private var theme

    init(_ text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(text).kFont(.caption).foregroundStyle(theme.colors.ink3).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }
}

/// A tight card of rows; callers put a `Hairline()` between rows.
struct Rows<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { Card(tight: true) { content } }
}

/// A settings row: an optional icon tile, a title with a description under it, and whatever sits on the right. At
/// least 56 high (48 compact).
struct SRow<Trailing: View, Extra: View>: View {
    let title: String
    let description: String?
    let icon: String?
    let descriptionColor: Color?
    let action: (() -> Void)?
    let titleExtra: Extra
    let trailing: Trailing
    @Environment(\.kosha) private var theme

    init(
        _ title: String, description: String? = nil, icon: String? = nil, descriptionColor: Color? = nil,
        action: (() -> Void)? = nil, @ViewBuilder titleExtra: () -> Extra = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.descriptionColor = descriptionColor
        self.action = action
        self.titleExtra = titleExtra()
        self.trailing = trailing()
    }

    var body: some View {
        let row = HStack(spacing: 12) {
            if let icon { IconTile(icon) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).kFont(.head)
                    titleExtra
                }
                if let description {
                    Text(description).kFont(.small).foregroundStyle(descriptionColor ?? theme.colors.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: theme.dims.settingsRow)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(PressStyle())
        } else {
            row
        }
    }
}

/// A row that opens another page: a caret (or the external-link icon) on the right.
struct NavRow<Extra: View>: View {
    let title: String
    let description: String?
    let icon: String?
    let value: String?
    let external: Bool
    let badge: Int
    let titleExtra: Extra
    let action: () -> Void
    @Environment(\.kosha) private var theme

    init(
        _ title: String, description: String? = nil, icon: String? = nil, value: String? = nil, external: Bool = false,
        badge: Int = 0, @ViewBuilder titleExtra: () -> Extra = { EmptyView() }, action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.value = value
        self.external = external
        self.badge = badge
        self.titleExtra = titleExtra()
        self.action = action
    }

    var body: some View {
        SRow(title, description: description, icon: icon, action: action, titleExtra: { titleExtra }) {
            if let value { Text(value).kFont(.small).foregroundStyle(theme.colors.ink2).lineLimit(1) }
            if badge > 0 { CountBadge(badge) }
            PhIcon(external ? "arrow-square-out" : "caret-right", size: 16, color: theme.colors.ink3)
        }
    }
}

/// A row whose switch is the whole row: one tap anywhere toggles it, and VoiceOver reads it as a switch.
struct SettingsSwitchRow<Extra: View>: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool
    let enabled: Bool
    let extra: Extra
    @Environment(\.kosha) private var theme

    init(_ title: String, description: String?, isOn: Binding<Bool>, enabled: Bool = true,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.title = title
        self.description = description
        _isOn = isOn
        self.enabled = enabled
        self.extra = extra()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(.head)
                if let description { Text(description).kFont(.small).foregroundStyle(theme.colors.ink3) }
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            KSwitch(title, isOn: $isOn).allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: theme.dims.settingsRow)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { isOn.toggle() } }
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(description ?? "")
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAction { if enabled { isOn.toggle() } }
    }
}

/// The warning-coloured count of open steps.
struct CountBadge: View {
    let count: Int
    @Environment(\.kosha) private var theme
    init(_ count: Int) { self.count = count }
    var body: some View {
        Text("\(count)").font(.custom("Geist-SemiBold", size: 11, relativeTo: .caption2))
            .foregroundStyle(theme.colors.dark ? theme.colors.onInk : .white)
            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
            .background(theme.colors.warn, in: .capsule)
    }
}

/// A quiet note on soft: an icon and a line of text.
struct SoftNote: View {
    let icon: String
    let text: String
    @Environment(\.kosha) private var theme
    init(_ icon: String, _ text: String) {
        self.icon = icon
        self.text = text
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PhIcon(icon, size: 16, color: theme.colors.ink2)
            Text(text).kFont(.small).foregroundStyle(theme.colors.ink2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.colors.soft, in: .rect(cornerRadius: 12))
    }
}

/// A line of small text under a card.
struct SettingsHint: View {
    let text: String
    @Environment(\.kosha) private var theme
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).kFont(.xs).foregroundStyle(theme.colors.ink3).padding(.horizontal, 2) }
}

/// A label above a field.
struct FieldLabel: View {
    let text: String
    @Environment(\.kosha) private var theme
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).kFont(.small).foregroundStyle(theme.colors.ink3) }
}

/// A field-like button that opens a picker.
struct SettingsPickField: View {
    let icon: String?
    let text: String
    let placeholder: Bool
    let action: () -> Void
    @Environment(\.kosha) private var theme

    init(_ icon: String?, _ text: String, placeholder: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.text = text
        self.placeholder = placeholder
        self.action = action
    }

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { PhIcon(icon, size: 18, color: c.ink3) }
                Text(text).foregroundStyle(placeholder ? c.ink3 : c.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
    }
}

/// The profile picture, or the name's initial on the accent. The picture comes from GET /api/app/avatar with the
/// session's token, read again whenever meta's image changes.
/// ponytail: held in memory only, so offline it shows the initial until the next launch online.
struct ProfileAvatar: View {
    let size: CGFloat
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var photo: Image?

    var body: some View {
        ZStack {
            Circle().fill(theme.colors.brand)
            if let photo {
                photo.resizable().scaledToFill()
            } else {
                let name = (kosha.meta?.user?.name ?? "").trimmingCharacters(in: .whitespaces)
                Text(name.isEmpty ? "K" : name.prefix(1).uppercased())
                    .font(.custom("Geist-SemiBold", size: size * 0.38, relativeTo: .title))
                    .foregroundStyle(theme.colors.onBrand)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: kosha.meta?.user?.image) {
            guard kosha.meta?.user?.image != nil else { photo = nil; return }
            if let data = try? await kosha.api.bytes("/api/app/avatar") { photo = platformImage(data) }
        }
    }
}

/// A choice in a card: a title, a segmented control and a line under it.
struct ChoiceRow<T: Hashable>: View {
    let title: String
    let description: String?
    let options: [(T, String)]
    @Binding var selection: T
    @Environment(\.kosha) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).kFont(.head)
            Segmented(options, selection: $selection, small: true)
            if let description { Text(description).kFont(.xs).foregroundStyle(theme.colors.ink3) }
        }
    }
}

/// A switch with its title and description, inside a card.
struct InlineSwitch: View {
    let title: String
    let description: String
    @Binding var isOn: Bool
    @Environment(\.kosha) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(.head)
                Text(description).kFont(.xs).foregroundStyle(theme.colors.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            KSwitch(title, isOn: $isOn)
        }
    }
}

/// A confirmation in a sheet: what will happen and the danger button.
struct SettingsConfirmSheet: View {
    let title: String
    let text: String
    let button: String
    let action: () -> Void
    let close: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title, onClose: close)
            Text(text).foregroundStyle(theme.colors.ink2)
            KButton(button, style: .danger) {
                close()
                action()
            }
        }
    }
}
