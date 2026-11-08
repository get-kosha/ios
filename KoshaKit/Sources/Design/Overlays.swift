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
    let scrolls: Bool
    @State private var height: CGFloat = 300
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            Capsule().fill(c.sel).frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 10)
                .accessibilityHidden(true)
            if scrolls {
                ScrollView { content.padding(.horizontal, 16).padding(.bottom, 34) }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                content.padding(.horizontal, 16).padding(.bottom, 34)
            }
        }
        .background(GeometryReader { p in Color.clear.preference(key: HeightKey.self, value: p.size.height) })
        .onPreferenceChange(HeightKey.self) { h in if h > 0 && !scrolls { height = h } }
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .presentationDetents(scrolls ? [.large] : [.height(height)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(24)
        .presentationBackground(c.surface)
    }
}

extension View {
    /// Shows `content` in a Kosha sheet. `scrolls` gives tall content (lists, pickers) the full height and a scroll view.
    public func kSheet<Content: View>(
        isPresented: Binding<Bool>, scrolls: Bool = false, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented) { KoshaSheetHost(scrolls: scrolls, content: content) }
    }

    /// Shows a Kosha sheet for an item.
    public func kSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, scrolls: Bool = false, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item) { item in KoshaSheetHost(scrolls: scrolls) { content(item) } }
    }
}

/// Carries the theme into the sheet, which the system presents outside the screen's environment on some paths.
private struct KoshaSheetHost<Content: View>: View {
    let scrolls: Bool
    let content: () -> Content
    var body: some View { KoshaSheet(content: content(), scrolls: scrolls) }
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
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                    undo()
                    dismiss()
                } label: {
                    Text(L.common_undo()).kFont(.sans(14, .medium)).foregroundStyle(c.onInk)
                        .padding(.horizontal, 12).frame(minHeight: 36)
                        .background(c.onInk.opacity(0.14), in: .rect(cornerRadius: 9))
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
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
                .onLongPressGesture(minimumDuration: 0.2, perform: {}, onPressingChanged: { peek = $0 })
        } else {
            content
        }
    }
}

extension View {
    /// Blurs a money figure when Hide amounts is on; touch and hold to peek.
    public func money() -> some View { modifier(MoneyBlur()) }
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
        }
        VStack(alignment: .leading, spacing: 8) {
            SheetHeader(title, onClose: onClose)
            KField(L.common_search(), text: $query, icon: "magnifying-glass")
            LazyVStack(spacing: 0) {
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
/// under its caption. The picked one sits on the selection ground with a check (AccountSheet).
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
                        ListRow(selected: on, action: { onPick(a.id) }) {
                            AccountDot(a.color, size: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).kFont(.body)
                                Text(a.detail).kFont(.small).foregroundStyle(c.ink3).money()
                            }
                            Spacer(minLength: 8)
                            if !a.balance.isEmpty { Text(a.balance).kFont(.num).foregroundStyle(c.ink2).money() }
                            if on { PhIcon("check", size: 20, color: c.selection) }
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }
}
