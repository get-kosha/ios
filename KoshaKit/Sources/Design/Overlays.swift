import SwiftUI
import Model

// MARK: Sheets

/// The title row of every sheet: the title and a 36pt close button.
public struct SheetHeader<Trailing: View>: View {
    let title: String
    let onClose: (() -> Void)?
    let trailing: Trailing
    @Environment(\.kosha) private var theme

    public init(_ title: String, onClose: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.onClose = onClose
        self.trailing = trailing()
    }

    /// Keeps a trailing view closure distinct from the close action.
    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, onClose: nil, trailing: trailing)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).kFont(.sheetTitle).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
            if let onClose {
                IconButton("x", label: L.common_close(), action: onClose)
            }
        }
        .frame(minHeight: 44)
        .padding(.bottom, 8)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A Kosha sheet: radius 24 on top, the grab handle, padding 8/16/34, sized to its content (up to the screen), drag
/// down to close, the scrim behind. The system sheet does the dragging; Kosha draws the rest.
private struct KoshaSheet<Body: View>: View {
    let content: Body
    @State private var height: CGFloat = 300
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            Capsule().fill(c.sel).frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 10)
                .accessibilityHidden(true)
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.bottom, 34)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { p in
                        Color.clear.preference(key: HeightKey.self, value: p.size.height + 23)
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onPreferenceChange(HeightKey.self) { h in if h > 0 { height = h } }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(24)
        .presentationBackground(c.surface)
    }
}

extension View {
    /// Shows `content` in a Kosha sheet. All sheets scroll when taller than the screen; `scrolls` remains for callers.
    public func kSheet<Content: View>(
        isPresented: Binding<Bool>, scrolls: Bool = false, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented) { KoshaSheet(content: content()) }
    }

    /// Shows a Kosha sheet for an item.
    public func kSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, scrolls: Bool = false, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item) { item in KoshaSheet(content: content(item)) }
    }
}

// MARK: Toast

/// A toast with an optional Undo, shown for five seconds at the top of the screen.
@MainActor @Observable
public final class Toasts {
    public struct Toast: Identifiable {
        public let id = UUID()
        public let message: String
        public let undo: (@MainActor () -> Void)?
        public let warning: Bool

        public init(message: String, undo: (@MainActor () -> Void)? = nil, warning: Bool = false) {
            self.message = message
            self.undo = undo
            self.warning = warning
        }
    }

    public private(set) var current: Toast?
    private var hide: Task<Void, Never>?

    public init() {}

    public func show(_ message: String, warning: Bool = false, undo: (@MainActor () -> Void)? = nil) {
        current = Toast(message: message, undo: undo, warning: warning)
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.current = nil }
        }
    }

    public func dismiss() {
        hide?.cancel()
        current = nil
    }
}

/// Where toasts appear: 16 from the edges, at least 52 high, radius 14, on ink, with Undo inside.
public struct ToastHost: ViewModifier {
    let toasts: Toasts
    @Environment(\.kosha) private var theme

    public func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = toasts.current {
                ToastView(toast: t) { toasts.dismiss() }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(theme.motion == .on ? .move(edge: .top).combined(with: .opacity) : .opacity)
                    .id(t.id)
            }
        }
        .animation(theme.animation(), value: toasts.current?.id)
        .sensoryFeedback(trigger: toasts.current?.id) { _, new in
            guard new != nil else { return nil }
            return toasts.current?.warning == true ? .warning : .success
        }
    }
}

public struct ToastView: View {
    let toast: Toasts.Toast
    let dismiss: () -> Void
    @Environment(\.kosha) private var theme

    public init(toast: Toasts.Toast, dismiss: @escaping () -> Void) {
        self.toast = toast
        self.dismiss = dismiss
    }

    public var body: some View {
        let c = theme.colors
        HStack(spacing: 10) {
            Text(toast.message).kFont(.sans(14, .regular)).foregroundStyle(c.onInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo = toast.undo {
                Button {
                    dismiss()
                    undo()
                } label: {
                    Text(L.common_undo()).kFont(.sans(14, .medium)).foregroundStyle(c.onInk)
                        .padding(.horizontal, 12).frame(minHeight: 36)
                        .background(c.onInk.opacity(0.14), in: .rect(cornerRadius: 9))
                        .frame(minHeight: 44)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background(c.ink, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(toast.message).post() }
    }
}

extension View {
    public func toasts(_ toasts: Toasts) -> some View { modifier(ToastHost(toasts: toasts)) }
}

// MARK: Hide amounts

private struct MoneyBlur: ViewModifier {
    @Environment(\.kosha) private var theme
    @State private var peek = false

    func body(content: Content) -> some View {
        if theme.hideAmounts {
            content
                .blur(radius: peek ? 0 : 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L.shell_hide_amounts())
                .onLongPressGesture(minimumDuration: 0.2, perform: {}, onPressingChanged: { peek = $0 })
        } else {
            content
        }
    }
}

extension View {
    /// Blurs a money figure when Hide amounts is on; touch and hold to peek.
    public func money() -> some View { minimumScaleFactor(0.1).modifier(MoneyBlur()) }
}

// MARK: Pickers

/// One row of a list picker: an id, a title, and optional detail and trailing text.
public struct Choice<ID: Hashable & Sendable>: Identifiable, Sendable {
    public let id: ID
    public let title: String
    public let detail: String?
    public let trailing: String?

    public init(id: ID, title: String, detail: String? = nil, trailing: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }
}

/// One searchable radio list for time zones, currencies, languages and "Move to…".
public struct ListPicker<ID: Hashable & Sendable>: View {
    let title: String
    let choices: [Choice<ID>]
    let selected: ID?
    let onPick: (ID) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @Environment(\.kosha) private var theme

    public init(
        _ title: String, choices: [Choice<ID>], selected: ID?, onPick: @escaping (ID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.choices = choices
        self.selected = selected
        self.onPick = onPick
        self.onClose = onClose
    }

    public var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? choices : choices.filter {
            $0.title.lowercased().contains(q) || ($0.detail?.lowercased().contains(q) ?? false)
                || String(describing: $0.id).lowercased().contains(q)
        }
        VStack(alignment: .leading, spacing: 8) {
            SheetHeader(title, onClose: onClose)
            KField(L.common_search(), text: $query, icon: "magnifying-glass")
            VStack(spacing: 0) {
                ForEach(shown) { choice in
                    ListRow(selected: false, action: { onPick(choice.id) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title).kFont(.body)
                            if let d = choice.detail { Text(d).kFont(.small).foregroundStyle(theme.colors.ink3) }
                        }
                        Spacer(minLength: 8)
                        if let t = choice.trailing { Text(t).kFont(.num).foregroundStyle(theme.colors.ink2) }
                        Radio(choice.id == selected)
                    }
                    .accessibilityAddTraits(choice.id == selected ? .isSelected : [])
                }
            }
        }
    }
}

/// An account in the account picker: its colour, name, type and currency, and balance (cards: available of limit).
public struct AccountChoice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let color: Color
    public let detail: String
    public let balance: String
    public let group: String

    public init(id: String, name: String, color: Color, detail: String, balance: String, group: String) {
        self.id = id
        self.name = name
        self.color = color
        self.detail = detail
        self.balance = balance
        self.group = group
    }
}

/// The account picker's list, grouped by type (Bank & cash, Credit cards, Investments) in the order given, each group
/// under its caption. A radio marks the picked account, as on Android.
public struct AccountList: View {
    let accounts: [AccountChoice]
    let selected: String?
    let onPick: (String) -> Void
    @Environment(\.kosha) private var theme

    public init(_ accounts: [AccountChoice], selected: String?, onPick: @escaping (String) -> Void) {
        self.accounts = accounts
        self.selected = selected
        self.onPick = onPick
    }

    public var body: some View {
        let c = theme.colors
        let groups = accounts.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.self) { group in
                if !group.isEmpty { Text(group).kFont(.caption).foregroundStyle(c.ink3).padding(.top, 6) }
                Card(tight: true) {
                    let rows = accounts.filter { $0.group == group }
                    ForEach(rows.indices, id: \.self) { i in
                        let a = rows[i]
                        let on = a.id == selected
                        if i > 0 { Hairline() }
                        ListRow(action: { onPick(a.id) }) {
                            AccountDot(a.color, size: 12)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    accountName(a)
                                    Spacer(minLength: 0)
                                    balance(a).fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    accountName(a)
                                    balance(a).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(minHeight: theme.dims.row - 4)
                            Radio(on)
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func accountName(_ account: AccountChoice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.name).kFont(.body).fixedSize(horizontal: false, vertical: true)
            if !account.detail.isEmpty {
                Text(account.detail).kFont(.small).foregroundStyle(theme.colors.ink3).money()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func balance(_ account: AccountChoice) -> some View {
        if !account.balance.isEmpty {
            Text(account.balance).kFont(.num).foregroundStyle(theme.colors.ink2).money()
        }
    }
}
