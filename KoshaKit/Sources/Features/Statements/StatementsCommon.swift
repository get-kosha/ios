import SwiftUI
import UniformTypeIdentifiers
import Model
import Store
import Design

// What Reconcile and Import share: short days, money inside sentences, a page whose back steps within the flow, and
// the sheets for a day, an amount, a choice and words. Ported from the Android app's Common.kt and Columns.kt.

/// A day as statements write it: "31 Oct", with the year when it isn't this one.
@MainActor
func shortDay(_ day: String, _ kosha: Kosha, _ locale: Locale) -> String {
    guard let d = Day(day) else { return day }
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = TimeZone(identifier: "UTC")
    f.setLocalizedDateFormatFromTemplate(d.year == kosha.today.year ? "dMMM" : "dMMMy")
    return f.string(from: d.date)
}

/// An amount inside a sentence, with a true minus; masked while Hide amounts is on.
func moneyWords(_ theme: KTheme) -> (Int64, String) -> String {
    { minor, currency in theme.hideAmounts ? "••••" : Money.format(minor, currency, theme.locale) }
}

/// A count as the language writes it ("1,204").
func countText(_ n: Int, _ locale: Locale) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = locale
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// The statement screens' page: back (which may step within the flow), a title with a line under it, the banners,
/// scrolling content, and a footer on glass. `onBack` nil hides back (while saving).
// ponytail: Shell's Page always dismisses; give it an onBack and this can go.
struct StepPage<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let onBack: (() -> Void)?
    let footer: Footer
    let content: Content
    @Environment(\.kosha) private var theme

    init(_ title: String, subtitle: String? = nil, onBack: (() -> Void)?, @ViewBuilder footer: () -> Footer = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if let onBack { IconButton("caret-left", label: L.common_back(), action: onBack) } else { Color.clear.frame(width: 8) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).kFont(.title).lineLimit(2).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).kFont(.small).foregroundStyle(c.ink3) }
                }
                .padding(.horizontal, 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 52)
            TabBanners().padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { content }
                        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
                }
                .environment(\.scrollTo, ScrollTo { id in withAnimation(theme.animation()) { proxy.scrollTo(id, anchor: .center) } })
            }
            if Footer.self != EmptyView.self {
                VStack(spacing: 0) {
                    Hairline()
                    footer.padding(16)
                }
                .background(c.glass)
            }
        }
        .background(c.bg)
        .hideNavigationBar()
        .navigationBarBackButtonHidden(true)
    }
}

/// Scrolls the page to a row by id, for "Show" on a hint.
struct ScrollTo: Sendable {
    let action: @MainActor @Sendable (String) -> Void
    init(_ action: @escaping @MainActor @Sendable (String) -> Void) { self.action = action }
}

private struct ScrollToKey: EnvironmentKey { static let defaultValue: ScrollTo? = nil }
extension EnvironmentValues {
    var scrollTo: ScrollTo? {
        get { self[ScrollToKey.self] }
        set { self[ScrollToKey.self] = newValue }
    }
}

/// A field that opens a picker: radius 14, a hairline, 48 high, an optional icon or label.
struct StatementPickField: View {
    let value: String
    var icon: String? = nil
    var label: String? = nil
    var muted = false
    var mono = false
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { PhIcon(icon, size: 18, color: c.ink2) }
                if let label { Text(label).kFont(.xs).foregroundStyle(c.ink3) }
                Text(value).kFont(mono ? .num : .body).foregroundStyle(muted ? c.ink3 : c.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel([label, value].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A note on a tinted ground: warn for things to check, ink2 for information.
struct Note: View {
    let text: String
    var icon = "warning"
    var tone: Color? = nil
    @Environment(\.kosha) private var theme

    var body: some View {
        let t = tone ?? theme.colors.warn
        HStack(alignment: .top, spacing: 8) {
            PhIcon(icon, size: 16, color: t)
            Text(text).kFont(.small).foregroundStyle(t).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(t.opacity(0.1), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A section heading above a card: an uppercase caption, with something on the right.
struct StatementSection<Content: View>: View {
    let title: String
    var aside: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.kosha) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).kFont(.caption).foregroundStyle(theme.colors.ink3).accessibilityAddTraits(.isHeader)
                Spacer()
                if let aside { Text(aside).kFont(.xs).foregroundStyle(theme.colors.ink3) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            content
        }
    }
}

/// A "Show N more" or group row inside a card: label, line under it, and a caret.
struct MoreRow: View {
    let text: String
    var sub: String? = nil
    var open = false
    var head = false
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).kFont(head ? .head : .small).foregroundStyle(head ? c.ink : c.ink2)
                    if let sub { Text(sub).kFont(.xs).foregroundStyle(c.ink3) }
                }
                Spacer()
                PhIcon(open ? "caret-up" : "caret-down", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// An amount on Kosha's keypad, never the system keyboard. `signed` adds a "below zero" chip for a balance that can be
/// overdrawn. Done with nothing typed clears it (nil).
struct SignedAmountSheet: View {
    let title: String
    let currency: String
    let signed: Bool
    let onDone: (Int64?) -> Void
    let close: () -> Void
    @State private var input: String
    @State private var negative: Bool

    init(title: String, start: Int64?, currency: String, signed: Bool, onDone: @escaping (Int64?) -> Void,
         close: @escaping () -> Void) {
        self.title = title
        self.currency = currency
        self.signed = signed
        self.onDone = onDone
        self.close = close
        _input = State(initialValue: start.map { AmountSheet.text($0, currency) } ?? "")
        _negative = State(initialValue: (start ?? 0) < 0)
    }

    var body: some View {
        let decimals = Money.decimals(currency)
        let value = Keypad.evaluate(input, decimals: decimals)
        VStack(spacing: 12) {
            SheetHeader(title, onClose: close)
            AmountDisplay(input: input, currency: currency, kind: negative ? .expense : .transfer)
            if signed {
                Chip(L.app_rcn_below_zero(), on: negative, small: true, action: { negative.toggle() }) {
                    PhIcon("plus-minus", size: 16)
                }
            }
            AmountKeypad(input: $input, decimals: decimals)
            KButton(L.common_done()) {
                if input.isEmpty {
                    onDone(nil)
                } else if let v = value {
                    let minor = NSDecimalNumber(decimal: (v * 100).rounded(0)).int64Value
                    onDone(negative ? -minor : minor)
                }
                close()
            }
            .disabled(!input.isEmpty && value == nil)
        }
    }
}

/// One choice from a short list, as radio rows in a sheet.
struct ChoiceSheet: View {
    let title: String
    let options: [(String, String)]
    let selected: String?
    let onPick: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title, onClose: close)
            ForEach(options, id: \.0) { value, label in
                Button {
                    onPick(value)
                    close()
                } label: {
                    HStack(spacing: 12) {
                        Text(label).frame(maxWidth: .infinity, alignment: .leading)
                        Radio(value == selected)
                    }
                    .padding(.vertical, 10)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(value == selected ? .isSelected : [])
            }
        }
    }
}

/// Words for one value: a field and Save.
struct StatementTextSheet: View {
    let title: String
    let onSave: (String) -> Void
    let close: () -> Void
    @State private var text: String

    init(title: String, start: String, onSave: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.title = title
        self.onSave = onSave
        self.close = close
        _text = State(initialValue: start)
    }

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 12) {
            SheetHeader(title, onClose: close)
            KField(title, text: $text)
            KButton(L.common_save()) {
                onSave(trimmed)
                close()
            }
            .disabled(trimmed.isEmpty)
        }
    }
}

/// A picked statement day on the month grid, as "YYYY-MM-DD".
struct DaySheet: View {
    let title: String
    @Binding var day: String
    let close: () -> Void
    @Environment(Kosha.self) private var kosha

    var body: some View {
        DateSheet(title: title, day: Binding(
            get: { Day(day) ?? kosha.today }, set: { day = $0.text }
        ), close: close)
    }
}

/// The file kind's icon.
func fileIcon(_ source: String) -> String {
    switch source {
    case "csv": "file-csv"
    case "pdf": "file-pdf"
    default: "file-text"
    }
}

/// The file types the picker offers. A PDF only when AI reads statements. Banks' CSV and OFX files come with all sorts of
/// types, so plain text and unknown data are allowed too.
func statementTypes(pdf: Bool) -> [UTType] {
    var out: [UTType] = [.commaSeparatedText, .plainText, .text, .data]
    for ext in ["ofx", "qfx"] { if let t = UTType(filenameExtension: ext) { out.append(t) } }
    if pdf { out.append(.pdf) }
    return out
}

// MARK: Columns

/// What a CSV's columns came from, for the Columns heading (statement-file.tsx columnsStatus).
func columnsStatus(remembered: Bool, byAi: Bool, confident: Bool) -> String {
    if remembered { return L.import_columns_remembered() }
    if byAi { return L.import_columns_by_ai() }
    return confident ? L.import_columns_confident() : L.import_columns_check()
}

/// A CSV's columns, each with a sample value and what it holds, to fix what Kosha guessed (statement-file.tsx Columns).
/// Open when Kosha wasn't sure. Every change re-reads the file on the server with the new layout.
struct Columns: View {
    let rows: [[String]]
    let layout: StatementLayout
    let count: Int
    let status: String
    let byAi: Bool
    let onChange: (StatementLayout) -> Void
    @State private var open: Bool
    @State private var roleFor: RoleFor?
    @State private var formats = false
    @Environment(\.kosha) private var theme

    struct RoleFor: Identifiable { let id: Int }

    init(rows: [[String]], layout: StatementLayout, count: Int, status: String, byAi: Bool, startOpen: Bool,
         onChange: @escaping (StatementLayout) -> Void) {
        self.rows = rows
        self.layout = layout
        self.count = count
        self.status = status
        self.byAi = byAi
        self.onChange = onChange
        _open = State(initialValue: startOpen)
    }

    private var roles: [(String, String)] {
        [("", L.import_role_ignore()), ("date", L.import_role_date()), ("description", L.import_role_description()),
         ("amount", L.import_role_amount()), ("debit", L.import_role_debit()), ("credit", L.import_role_credit()),
         ("balance", L.import_role_balance())]
    }

    private var dateFormats: [(String, String)] {
        [(DateFormatKind.dmy.rawValue, L.import_date_dmy()), (DateFormatKind.mdy.rawValue, L.import_date_mdy()),
         (DateFormatKind.ymd.rawValue, L.import_date_ymd()), (DateFormatKind.text.rawValue, L.import_date_text())]
    }

    private func roleOf(_ i: Int) -> String {
        if i == layout.date { return "date" }
        if layout.description.contains(i) { return "description" }
        if i == layout.amount { return "amount" }
        if i == layout.debit { return "debit" }
        if i == layout.credit { return "credit" }
        if i == layout.balance { return "balance" }
        return ""
    }

    private func set(_ i: Int, _ role: String) {
        var next = layout
        next.description.removeAll { $0 == i }
        if next.amount == i { next.amount = nil }
        if next.debit == i { next.debit = nil }
        if next.credit == i { next.credit = nil }
        if next.balance == i { next.balance = nil }
        switch role {
        case "date":
            next.date = i
            let values = rows.dropFirst(layout.header + 1).map { $0.indices.contains(i) ? $0[i] : "" }
            next.dateFormat = guessDateFormat(Array(values)) ?? next.dateFormat
        case "description": next.description = Array((next.description + [i]).suffix(2))
        case "amount": next.amount = i; next.debit = nil; next.credit = nil
        case "debit": next.debit = i; next.amount = nil
        case "credit": next.credit = i; next.amount = nil
        case "balance": next.balance = i
        default: break
        }
        onChange(next)
    }

    var body: some View {
        let c = theme.colors
        let head = layout.header >= 0 && rows.indices.contains(layout.header) ? rows[layout.header] : []
        let sample = rows.indices.contains(layout.header + 1) ? rows[layout.header + 1] : []
        let width = max(head.count, sample.count)
        VStack(alignment: .leading, spacing: 10) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Text(L.import_columns()).kFont(.small).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        if byAi { Sparkle(size: 11) }
                        Pill(status, color: !open && status == L.import_columns_check() || byAi ? c.warn : c.ink2)
                    }
                    PhIcon(open ? "caret-up" : "caret-down", size: 16, color: c.ink3)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if open {
                VStack(spacing: 0) {
                    ForEach(0..<width, id: \.self) { i in
                        if i > 0 { Hairline() }
                        Button { roleFor = RoleFor(id: i) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if head.indices.contains(i), !head[i].trimmingCharacters(in: .whitespaces).isEmpty {
                                        Text(head[i]).kFont(.xs).foregroundStyle(c.ink3).lineLimit(1)
                                    }
                                    Text(sample.indices.contains(i) ? sample[i] : "").kFont(.figure(12, .regular))
                                        .foregroundStyle(c.ink2).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Chip(roles.first { $0.0 == roleOf(i) }?.1 ?? "", soft: true, small: true) {
                                    EmptyView()
                                }
                                PhIcon("caret-down", size: 14, color: c.ink3)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.line))
                Button { formats = true } label: {
                    HStack(spacing: 4) {
                        Text(L.import_columns_dates()).kFont(.small).foregroundStyle(c.ink3).frame(maxWidth: .infinity, alignment: .leading)
                        Text(dateFormats.first { $0.0 == layout.dateFormat.rawValue }?.1 ?? "").kFont(.small)
                        PhIcon("caret-down", size: 14, color: c.ink3)
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                if layout.amount != nil {
                    HStack {
                        Text(L.import_columns_invert()).kFont(.small).frame(maxWidth: .infinity, alignment: .leading)
                        KSwitch(L.import_columns_invert(), isOn: Binding(get: { layout.invert }, set: {
                            var next = layout
                            next.invert = $0
                            onChange(next)
                        }))
                    }
                }
                Text(L.import_columns_lines_read(count: count, n: countText(count, theme.locale))).kFont(.xs).foregroundStyle(c.ink3)
            }
        }
        .kSheet(item: $roleFor) { r in
            let name = head.indices.contains(r.id) && !head[r.id].trimmingCharacters(in: .whitespaces).isEmpty
                ? head[r.id] : L.import_columns_column(n: "\(r.id + 1)")
            ChoiceSheet(title: name, options: roles, selected: roleOf(r.id), onPick: { set(r.id, $0) }) { roleFor = nil }
        }
        .kSheet(isPresented: $formats) {
            ChoiceSheet(title: L.import_columns_dates(), options: dateFormats, selected: layout.dateFormat.rawValue,
                        onPick: { v in
                            var next = layout
                            next.dateFormat = DateFormatKind(rawValue: v) ?? next.dateFormat
                            onChange(next)
                        }) { formats = false }
        }
    }
}
