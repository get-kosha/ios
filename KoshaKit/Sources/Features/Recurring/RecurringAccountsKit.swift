import SwiftUI
import Model
import API
import Store
import Design

// Pieces Recurring and Accounts share: dates in a skeleton, writes, the form scaffold, detail rows, a signed keypad
// sheet, a confirm sheet and the share sheet. Ported from the Android app's recurring Kit.kt. Candidates for Shared/:
// fmtDay, KeypadSheet, ConfirmSheet, FormPage, DetailRow, SwitchRow and shareFile.

/// A day in the language's own order for a skeleton such as "dMMM" (20 Nov), "EEEdMMM" (Thu 20 Nov) or "dMMMy".
func fmtDay(_ day: String, _ template: String, _ locale: Locale) -> String {
    guard let d = Day(day) else { return day }
    return fmtDay(d, template, locale)
}

func fmtDay(_ d: Day, _ template: String, _ locale: Locale) -> String {
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = TimeZone(identifier: "UTC")
    f.setLocalizedDateFormatFromTemplate(template)
    return f.string(from: d.date)
}

/// The interval as a phrase: "every month", "every 3 weeks".
func everyText(_ every: Int, _ unit: String) -> String {
    switch unit {
    case "day": L.subs_every_day(count: every)
    case "week": L.subs_every_week(count: every)
    case "year": L.subs_every_year(count: every)
    default: L.subs_every_month(count: every)
    }
}

extension String {
    /// Upper-cases the first letter, for message phrases that start a line ("every month" → "Every month").
    func capitalisedFirst(_ locale: Locale) -> String { prefix(1).uppercased(with: locale) + dropFirst() }
}

/// Money inside a sentence. Hide amounts masks it.
@MainActor
func inText(_ minor: Int64, _ currency: String, _ theme: KTheme, sign: Sign = .natural) -> String {
    theme.hideAmounts ? "••••" : Money.format(minor, currency, theme.locale, sign: sign)
}

/// A JSON body from fields; nil values are left out, `.null` sends an explicit null.
func jsonBody(_ fields: [String: JSONValue?]) -> JSONValue {
    .object(fields.compactMapValues { $0 })
}

extension JSONValue {
    static func int(_ v: Int64) -> JSONValue { .number(Double(v)) }
    static func int(_ v: Int) -> JSONValue { .number(Double(v)) }
}

extension Kosha {
    /// Runs a write: the demo is told changes are off, the server's message shows when it refuses, and screens read
    /// again when it works. Returns the block's result, or nil when it didn't happen.
    func run<T: Sendable>(_ toasts: Toasts, _ block: (KoshaAPI) async throws -> T) async -> T? {
        if demo {
            toasts.show(L.common_demo_read_only(), warning: true)
            return nil
        }
        let api = api
        return await write(toasts) { try await block(api) }
    }
}

/// Keypad input that shows an amount: `10.99` for 1099, `1200` for ¥1,200 (stored as 120000). A negative amount (an
/// overdrawn balance, a loss) is typed as 0 − amount, since the keypad has no minus key.
func inputOf(_ minor: Int64, _ currency: String) -> String {
    if minor == 0 { return "" }
    if minor < 0 { return "0-" + inputOf(-minor, currency) }
    var s = AmountSheet.text(minor, currency)
    if s.hasSuffix(".00") { s.removeLast(3) }
    return s
}

/// The keypad input's value in minor units (×100 for every currency) with its sign; nil when it divides by zero.
func signedMinor(_ input: String, _ currency: String) -> Int64? {
    guard let v = Keypad.evaluate(input, decimals: Money.decimals(currency)) else { return nil }
    return NSDecimalNumber(decimal: (v * 100).rounded(0)).int64Value
}

/// A sheet to type one amount on the keypad. It starts showing the known amount; the first key replaces it, as a
/// selected field would. `positive` false allows zero and overdrawn balances (0 − amount).
struct KeypadSheet: View {
    let title: String
    let subtitle: String?
    let currency: String
    let note: String?
    let positive: Bool
    let clearLabel: String?
    let onClear: (() -> Void)?
    let onDone: (Int64) -> Void
    let close: () -> Void
    @State private var input: String
    @State private var fresh: Bool
    private let prefilled: String
    @Environment(\.kosha) private var theme

    init(
        _ title: String, minor: Int64?, currency: String, subtitle: String? = nil, note: String? = nil, positive: Bool = true,
        clearLabel: String? = nil, onClear: (() -> Void)? = nil, onDone: @escaping (Int64) -> Void, close: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.currency = currency
        self.note = note
        self.positive = positive
        self.clearLabel = clearLabel
        self.onClear = onClear
        self.onDone = onDone
        self.close = close
        let text = minor.map { inputOf($0, currency) } ?? ""
        prefilled = text
        _input = State(initialValue: "")
        _fresh = State(initialValue: !text.isEmpty)
    }

    var body: some View {
        let shown = fresh ? prefilled : input
        let value = signedMinor(shown, currency)
        let valid = value.map { positive ? $0 > 0 : true } ?? false
        VStack(spacing: 12) {
            SheetHeader(title, onClose: close)
            if let subtitle { Text(subtitle).kFont(.body).foregroundStyle(theme.colors.ink2).frame(maxWidth: .infinity, alignment: .leading) }
            AmountDisplay(input: shown, currency: currency, kind: .transfer, note: note)
            AmountKeypad(input: Binding(get: { fresh ? "" : input }, set: { fresh = false; input = $0 }),
                         decimals: Money.decimals(currency))
            HStack(spacing: 8) {
                if let clearLabel, let onClear { KButton(clearLabel, style: .secondary, action: onClear) }
                KButton(L.common_done()) { if let value, valid { onDone(value) } }.disabled(!valid)
            }
        }
    }
}

/// Confirms a destructive action in a sheet with a danger button.
struct ConfirmSheet: View {
    let title: String
    let text: String
    let confirm: String
    let onConfirm: () -> Void
    let close: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title, onClose: close)
            Text(text).kFont(.body).foregroundStyle(theme.colors.ink2)
            HStack(spacing: 8) {
                KButton(L.common_cancel(), style: .secondary, action: close)
                KButton(confirm, style: .danger, action: onConfirm)
            }
        }
    }
}

/// A full-screen form: Cancel on the left, the title centred, scrolling fields with a 16pt gap, and a sticky footer for
/// the main button.
struct FormPage<Content: View, Footer: View>: View {
    let title: String
    let footer: Footer
    let content: Content
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, @ViewBuilder footer: () -> Footer, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            ZStack {
                Text(title).kFont(.sans(15, .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 80).accessibilityAddTraits(.isHeader)
                HStack {
                    Button(L.common_cancel()) { dismiss() }.foregroundStyle(c.ink2).frame(minWidth: 72, minHeight: 48)
                        .buttonStyle(PressStyle())
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 56)
            TabBanners()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
            footer.padding(16).background(c.glass)
        }
        .background(c.bg)
        .hideNavigationBar()
    }
}

/// A label and its value in a tight card: "Account   ● N26 Main  ›".
struct DetailRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    let trailing: String?
    let action: (() -> Void)?
    let content: Content
    @Environment(\.kosha) private var theme

    init(_ label: String, labelWidth: CGFloat = 92, trailing: String? = nil, action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.trailing = trailing ?? (action != nil ? "caret-right" : nil)
        self.action = action
        self.content = content()
    }

    var body: some View {
        let c = theme.colors
        let row = HStack(spacing: 12) {
            Text(label).kFont(.small).foregroundStyle(c.ink3).frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 8) { content }.frame(maxWidth: .infinity, alignment: .leading)
            if let trailing, !trailing.isEmpty { PhIcon(trailing, size: 16, color: c.ink3) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: theme.dims.settingsRow)
        .contentShape(Rectangle())
        if let action { Button(action: action) { row }.buttonStyle(PressStyle()) } else { row }
    }
}

/// A title and description with a switch, in a tight card.
struct SwitchRow: View {
    let title: String
    let text: String?
    @Binding var isOn: Bool
    @Environment(\.kosha) private var theme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(.head)
                if let text { Text(text).kFont(.small).foregroundStyle(theme.colors.ink3) }
            }
            Spacer(minLength: 8)
            KSwitch(title, isOn: $isOn)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: theme.dims.settingsRow)
    }
}

/// A soft hint line with an icon, as under the recurring form's dates.
struct HintLine: View {
    let icon: String
    let text: String
    @Environment(\.kosha) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PhIcon(icon, size: 18, color: theme.colors.ink3)
            Text(text).kFont(.small).foregroundStyle(theme.colors.ink2)
        }
    }
}

/// An icon, title, optional detail and chevron, in a tight card.
struct LinkRow: View {
    let icon: String
    let title: String
    let detail: String?
    var count: String? = nil
    var tile = true
    /// Amounts in `detail` to set in the figure font.
    var figures: [String] = []
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        ListRow(action: action) {
            if tile { IconTile(icon) } else { PhIcon(icon, size: 16) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(tile ? .body : .small).foregroundStyle(tile ? c.ink : c.ink2)
                if let detail { Text(figured(detail, figures, size: 13, theme)).foregroundStyle(c.ink3).money() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let count { Text(count).kFont(.num).foregroundStyle(c.ink3) }
            PhIcon("caret-right", size: 16, color: c.ink3)
        }
    }
}

/// A small caption above a group of cards.
struct Caption: View {
    let text: String
    @Environment(\.kosha) private var theme
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).kFont(.caption).foregroundStyle(theme.colors.ink3).padding(.leading, 2).padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A collapsible "Ended (3)" or "Archived (1)" row.
struct FoldRow: View {
    let title: String
    let detail: String?
    @Binding var open: Bool
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                PhIcon("archive", color: c.ink3)
                Text(title).foregroundStyle(c.ink2)
                if let detail { Text("· " + detail).kFont(.xs).foregroundStyle(c.ink3) }
                Spacer()
                PhIcon(open ? "caret-up" : "caret-down", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Hands a file to other apps through the share sheet.
@MainActor
func shareFile(_ url: URL) {
    #if os(iOS)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    guard var top = scene?.keyWindow?.rootViewController else { return }
    while let next = top.presentedViewController { top = next }
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.popoverPresentationController?.sourceView = top.view
    share.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
    top.present(share, animated: true)
    #endif
}

/// Reads a file the person picked (fileImporter), with its name and type.
func readPicked(_ url: URL) -> (name: String, type: String, data: Data)? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else { return nil }
    let ext = url.pathExtension.lowercased()
    let type = switch ext {
    case "pdf": "application/pdf"
    case "png": "image/png"
    case "heic": "image/heic"
    case "heif": "image/heif"
    case "jpg", "jpeg": "image/jpeg"
    default: "application/octet-stream"
    }
    return (url.lastPathComponent, type, data)
}

/// A sentence with its amounts and numbers (each of `figures`) set in the figure font, as the boards write "Bills
/// €1,156.50 · subscriptions €46.97" or "Rate 93.85 · market 94.60".
@MainActor
func figured(_ text: String, _ figures: [String], size: CGFloat, _ theme: KTheme) -> AttributedString {
    var out = AttributedString(text)
    out.font = KFont.sans(size, .regular).font(theme)
    for f in figures where !f.isEmpty {
        var search = out.startIndex..<out.endIndex
        while let r = out[search].range(of: f) {
            out[r].font = KFont.figure(size, .regular).font(theme)
            search = r.upperBound..<out.endIndex
        }
    }
    return out
}

/// A small (36pt, radius 8) button that fills its width, as the boards' paired card actions.
struct WideSmallButton: View {
    let title: String
    var style: KButtonStyle = .primary
    let action: () -> Void
    @Environment(\.kosha) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let c = theme.colors
        let (ground, ink): (Color, Color) = style == .primary ? (c.ink, c.onInk) : (c.surface, c.ink)
        Button(action: action) {
            Text(title).kFont(.sans(14, .medium)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(ground, in: .rect(cornerRadius: 8))
                .overlay { if style != .primary { RoundedRectangle(cornerRadius: 8).strokeBorder(c.line) } }
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(PressStyle())
        .opacity(enabled ? 1 : 0.4)
    }
}
