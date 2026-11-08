import SwiftUI
import Model
import API
import Store
import Design

// Currencies, Categories (and one category), Events and Payee rules.

// MARK: Currencies

/// "3 hours ago" in the app's language, or "just now".
func ago(_ unixSeconds: Int64, _ locale: Locale) -> String {
    let s = Int64(Date().timeIntervalSince1970) - unixSeconds
    if s < 90 { return L.settings_currencies_just_now() }
    let f = RelativeDateTimeFormatter()
    f.locale = locale
    f.unitsStyle = .full
    let comps: DateComponents = s < 3600 ? DateComponents(minute: -Int((Double(s) / 60).rounded()))
        : Double(s) < 86400 * 1.5 ? DateComponents(hour: -Int((Double(s) / 3600).rounded()))
        : DateComponents(day: -Int((Double(s) / 86400).rounded()))
    return f.localizedString(from: comps)
}

/// Currencies: the person's currencies in order, held and dragged to reorder (the one on top is the default, so net worth
/// and totals add up in it), add and remove, and the exchange rates with Refresh.
struct CurrenciesPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var items: [String] = []
    @State private var adding = false
    @State private var refreshing = false

    var body: some View {
        if let m = kosha.meta { content(m) }
    }

    private func content(_ m: Meta) -> some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let used = m.wallets.filter { !$0.isArchived }.map { $0.currency.lowercased() }
        let saved = currencyOrder(primary: m.primaryCurrency, order: m.order, used: used)
        let list = items.isEmpty ? saved : items
        let (prefix, suffix) = Money.affixes(m.primaryCurrency, theme.locale)
        let save = { (next: [String]) in
            items = next
            w.send("PATCH", "/api/v1/settings", .object([
                "primaryCurrency": .string(next[0]), "currencyOrder": .array(next.map(JSONValue.string)),
            ]))
        }
        return Page(L.settings_section_currencies()) {
            GroupCaption(L.settings_row_currencies())
            Rows {
                ForEach(Array(list.enumerated()), id: \.element) { i, code in
                    if i > 0 { Hairline() }
                    let accounts = used.filter { $0 == code }.count
                    let r = i == 0 ? nil : rate(from: m.primaryCurrency, to: code, perUsd: m.rates)
                    HStack(spacing: 12) {
                        if list.count > 1 {
                            PhIcon("dots-six-vertical", size: 18, color: c.ink3, label: L.settings_currencies_reorder(code: code.uppercased()))
                        }
                        Text(code.uppercased()).kFont(.figure(15, .medium)).frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currencyName(code, theme.locale)).kFont(.head)
                            let detail = [accounts > 0 ? L.accounts_count(count: accounts) : nil,
                                          r.map { "\(rateText($0, 1)) = \(prefix)1\(suffix)" }].compactMap { $0 }.joined(separator: " · ")
                            if !detail.isEmpty { Text(detail).kFont(.small).foregroundStyle(c.ink3) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if i == 0 {
                            Pill(L.settings_currencies_default(), color: c.brand)
                        } else if accounts == 0 {
                            IconButton("x", label: L.common_remove() + " " + code.uppercased()) { save(list.filter { $0 != code }) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(minHeight: theme.dims.settingsRow)
                    .background(c.surface)
                    .draggable(code)
                    .dropDestination(for: String.self) { dropped, _ in
                        guard let from = dropped.first.flatMap({ list.firstIndex(of: $0) }), from != i else { return false }
                        save(list.moved(from: from, to: i))
                        return true
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: L.app_set_move_up()) { if i > 0 { save(list.moved(from: i, to: i - 1)) } }
                    .accessibilityAction(named: L.app_set_move_down()) { if i < list.count - 1 { save(list.moved(from: i, to: i + 1)) } }
                }
                Hairline()
                Button { if !w.refused() { adding = true } } label: {
                    HStack(spacing: 12) {
                        PhIcon("plus", size: 18, color: c.ink2)
                        Text(L.app_set_add_currency()).foregroundStyle(c.ink2)
                        Spacer()
                    }
                    .padding(.horizontal, 16).frame(minHeight: theme.dims.settingsRow).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            Hint(L.app_set_currencies_note())

            GroupCaption(L.settings_currencies_rates())
            Card {
                let fresh = m.ratesUpdated > 0 && Double(Int64(Date().timeIntervalSince1970) - m.ratesUpdated) < 86400 * 1.5
                HStack(spacing: 10) {
                    PhIcon(fresh ? "check-circle" : "warning-circle", size: 18, color: fresh ? c.pos : c.warn)
                    Text(fresh ? L.settings_currencies_up_to_date() : L.settings_row_rates_source()).kFont(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KButton(refreshing ? L.settings_currencies_refreshing() : L.settings_currencies_refresh(), style: .secondary,
                            size: .small, icon: "arrow-clockwise") {
                        refreshing = true
                        w.run({ try await kosha.api.send("POST", "/api/v1/exchange-rates/refresh", body: JSONValue.object([:])) },
                              always: { refreshing = false })
                    }
                    .disabled(refreshing)
                }
                Text(m.ratesUpdated > 0 ? L.settings_currencies_updated(ago: ago(m.ratesUpdated, theme.locale))
                     : L.settings_currencies_never_updated())
                    .kFont(.small).foregroundStyle(c.ink2)
                let others = list.dropFirst().filter { m.rates[$0] != nil }
                if !others.isEmpty {
                    Hairline()
                    ForEach(Array(others), id: \.self) { code in
                        HStack {
                            Text(L.app_set_rate_in(from: m.primaryCurrency.uppercased(), to: code.uppercased()))
                                .kFont(.small).foregroundStyle(c.ink3)
                            Spacer()
                            Text(rate(from: m.primaryCurrency, to: code, perUsd: m.rates).map { rateText($0, 1) } ?? "")
                                .kFont(.figure(13, .regular))
                        }
                    }
                }
            }
        }
        .onChange(of: saved) { _, s in items = s }
        .kSheet(isPresented: $adding, scrolls: true) {
            ListPicker(L.app_set_add_currency(), choices: currencyChoices(m.rates.keys, theme.locale, except: list), selected: nil,
                       onPick: { code in
                           adding = false
                           save(list + [code])
                       }, onClose: { adding = false })
        }
    }
}

// MARK: Categories

/// "124 transactions · 1 recurring · 3 rules", or "Not used yet".
func usage(_ cat: Model.Category) -> String {
    [cat.transactionCount > 0 ? L.settings_cat_count_tx(count: cat.transactionCount) : nil,
     cat.recurringCount > 0 ? L.settings_cat_count_recurring(count: cat.recurringCount) : nil,
     cat.ruleCount > 0 ? L.settings_cat_count_rules(count: cat.ruleCount) : nil]
        .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? L.settings_cat_unused()
}

/// Top-level categories, each followed by its subcategories (categories.tsx tree).
func tree(_ cats: [Model.Category]) -> [Model.Category] {
    let tops = cats.filter { c in c.parentId == nil || !cats.contains { $0.id == c.parentId } }
    return tops.flatMap { t in [t] + cats.filter { $0.parentId == t.id } }
}

private let shownCategories = 10

extension View {
    /// Every category, archived ones too, with the balance-correction count.
    func loadCategories(into value: Binding<CategoryList?>) -> some View {
        load("categories-all", into: value) { try await $0.get("/api/v1/categories", query: ["includeArchived": "true"]) }
    }
}

/// Categories: Spending and Income, with subcategories under their parent, Kosha's own categories, and Archived.
struct CategoriesPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var list: CategoryList?
    @State private var tab = "expense"
    @State private var showAll = false
    @State private var archivedOpen = false

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let all = list?.categories ?? []
        let active = all.filter { !$0.archived && !Categories.isSystem($0.id) }
        let spending = active.filter { !$0.income }
        let income = active.filter { $0.income }
        let rows = tree(tab == "income" ? income : spending)
        let visible = showAll || rows.count <= shownCategories + 1 ? rows : Array(rows.prefix(shownCategories))
        Page(L.settings_section_categories(), actions: {
            IconButton("plus", label: L.settings_cat_new(), solid: true) {
                nav.push(.settings(page: "category", id: tab == "income" ? "new-income" : "new"))
            }
        }) {
            Segmented([("expense", L.settings_cat_spending() + " · \(spending.count)"), ("income", L.settings_cat_income() + " · \(income.count)")],
                      selection: Binding(get: { tab }, set: { tab = $0; showAll = false }), small: true)
            if list == nil { LoadingNote() }
            if list != nil && rows.isEmpty {
                Text(tab == "income" ? L.settings_cat_empty_income() : L.settings_cat_empty_spending()).foregroundStyle(c.ink3)
            }
            if !visible.isEmpty {
                Rows {
                    ForEach(visible.indices, id: \.self) { i in
                        let cat = visible[i]
                        if i > 0 { Hairline() }
                        CategoryRow(cat: cat, sub: cat.parentId != nil && rows.contains { $0.id == cat.parentId }) {
                            nav.push(.settings(page: "category", id: cat.id))
                        }
                    }
                    if visible.count < rows.count {
                        Hairline()
                        Button { showAll = true } label: {
                            HStack {
                                Text(L.settings_cat_show_all(count: "\(rows.count)")).kFont(.small).foregroundStyle(c.ink2)
                                Spacer()
                                PhIcon("caret-down", size: 16, color: c.ink3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            // Kosha's own categories: transfer fees count as spending; balance corrections are neutral.
            if tab == "expense", list != nil {
                let fees = all.filter { $0.id == Categories.transferFee }
                let correction = kosha.meta?.categories.first { $0.id == Categories.correction }
                Rows {
                    ForEach(fees) { cat in
                        CategoryRow(cat: cat, sub: false, system: true) { nav.push(.settings(page: "category", id: cat.id)) }
                    }
                    if let correction {
                        if !fees.isEmpty { Hairline() }
                        let used = list?.correctionCount ?? 0
                        HStack(spacing: 12) {
                            IconTile(categoryIconName(correction.icon ?? "⚖"))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(correction.name)
                                    Pill(L.settings_cat_system())
                                }
                                Text(used > 0 ? L.settings_cat_count_tx(count: used) : L.settings_cat_unused()).kFont(.xs).foregroundStyle(c.ink3)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: theme.dims.row)
                    }
                }
            }
            let archived = all.filter(\.archived)
            if !archived.isEmpty {
                Card(tight: true) {
                    Button { archivedOpen.toggle() } label: {
                        HStack(spacing: 10) {
                            PhIcon("archive", color: c.ink3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.settings_cat_archived_count(count: "\(archived.count)")).foregroundStyle(c.ink2)
                                Text(L.settings_cat_archived_hint()).kFont(.xs).foregroundStyle(c.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            PhIcon(archivedOpen ? "caret-up" : "caret-down", size: 16, color: c.ink3)
                        }
                        .padding(16).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    if archivedOpen {
                        ForEach(tree(archived)) { cat in
                            Hairline()
                            SRow(cat.name, description: usage(cat), icon: categoryIconName(cat.icon)) {
                                KButton(L.settings_cat_restore(), style: .secondary, size: .small) {
                                    w.send("PATCH", "/api/v1/categories/\(cat.id)", .object(["archived": .bool(false)])) {
                                        w.toast(L.settings_cat_restored(name: cat.name))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .loadCategories(into: $list)
    }
}

private struct CategoryRow: View {
    let cat: Model.Category
    let sub: Bool
    var system = false
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Button(action: action) {
            HStack(spacing: 12) {
                PhIcon(categoryIconName(cat.icon), size: sub ? 16 : 18)
                    .frame(width: sub ? 30 : 36, height: sub ? 30 : 36)
                    .background(c.soft, in: .rect(cornerRadius: sub ? 8 : 10))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cat.name)
                        if system { Pill(L.settings_cat_system()) }
                    }
                    Text(usage(cat)).kFont(.xs).foregroundStyle(c.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 16, color: c.ink3)
            }
            .padding(.leading, sub ? 44 : 16).padding(.trailing, 16).padding(.vertical, 10)
            .frame(minHeight: theme.dims.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// One category: name, the category it sits inside, type, icon (with search), its subcategories, and Merge into… (or
/// Delete when nothing uses it) and Archive. Every change saves as it's made; a new one saves once it has a name.
/// `routeId` is a category id, "new" for a new spending category or "new-income" for income.
struct CategoryEditPage: View {
    let routeId: String
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var list: CategoryList?
    @State private var id: String?
    @State private var name = ""
    @State private var icon = "ph:tag"
    @State private var income = false
    @State private var parentId: String?
    @State private var filled = false
    @State private var iconQuery = ""
    @State private var sheet: EditSheet?

    enum EditSheet: String, Identifiable {
        case parent, merge, delete
        var id: String { rawValue }
    }

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let all = list?.categories ?? []
        let cat = all.first { $0.id == id }
        let system = id.map(Categories.isSystem) ?? false
        let children = cat.map { cat in all.filter { $0.parentId == cat.id } } ?? []
        Page(name.isEmpty ? L.settings_cat_new() : name, subtitle: cat.map(usage)) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.settings_cat_name())
                KField(L.settings_cat_name_placeholder(), text: $name).keyboard(.text)
            }
            if !system {
                Rows {
                    Button { sheet = .parent } label: {
                        HStack(spacing: 12) {
                            Text(L.settings_cat_inside()).kFont(.small).foregroundStyle(c.ink3).frame(width: 72, alignment: .leading)
                            Text(parents(all).first { $0.id == parentId }?.name ?? L.settings_cat_top_level())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            PhIcon("caret-right", size: 16, color: c.ink3)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: theme.dims.settingsRow)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    if parentId == nil {
                        Hairline()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Text(L.settings_cat_type()).kFont(.small).foregroundStyle(c.ink3).frame(width: 72, alignment: .leading)
                                Segmented([("expense", L.settings_cat_spending()), ("income", L.settings_cat_income())], selection: Binding(
                                    get: { income ? "income" : "expense" },
                                    set: { v in
                                        income = v == "income"
                                        commit(w, cat, ["type": .string(v), "parentId": .null])
                                    }
                                ), small: true)
                            }
                            if let cat, cat.income != income, cat.transactionCount > 0 {
                                Text(income ? L.settings_cat_now_income(count: cat.transactionCount) : L.settings_cat_now_spending(count: cat.transactionCount))
                                    .kFont(.xs).foregroundStyle(c.warn)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                FieldLabel(L.settings_cat_icon())
                KField(L.settings_cat_find_icon(), text: $iconQuery, icon: "magnifying-glass").keyboard(.search, capitalise: false)
                let q = iconQuery.trimmingCharacters(in: .whitespaces).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
                let icons = categoryIcons.filter { q.isEmpty || $0.contains(q) }
                let picked = categoryIconName(icon)
                if icons.isEmpty { Text(L.settings_cat_no_icon(query: iconQuery)).kFont(.small).foregroundStyle(c.ink3) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(icons, id: \.self) { n in
                        let on = n == picked
                        Button {
                            icon = "ph:\(n)"
                            commit(w, cat, ["icon": .string("ph:\(n)")])
                        } label: {
                            PhIcon(n, size: 22, color: on ? c.selection : c.ink2)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(on ? c.surface : c.soft, in: .rect(cornerRadius: 12))
                                .overlay { if on { RoundedRectangle(cornerRadius: 12).strokeBorder(c.selection, lineWidth: 1.5) } }
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel(n.replacingOccurrences(of: "-", with: " "))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            if !children.isEmpty {
                GroupCaption(L.app_set_subcategories())
                Rows {
                    ForEach(children.indices, id: \.self) { i in
                        if i > 0 { Hairline() }
                        SRow(children[i].name, icon: categoryIconName(children[i].icon), action: {
                            nav.push(.settings(page: "category", id: children[i].id))
                        }) {
                            Text("\(children[i].transactionCount)").kFont(.xs).foregroundStyle(c.ink3)
                        }
                    }
                }
            }
            if let cat, !system {
                let used = cat.transactionCount > 0 || cat.recurringCount > 0 || !children.isEmpty
                HStack(spacing: 8) {
                    KButton(used ? L.settings_cat_merge_into_ellipsis() : L.common_delete(), style: .secondary, size: .medium,
                            icon: used ? "arrow-elbow-down-right" : "trash") {
                        if !w.refused() { sheet = used ? .merge : .delete }
                    }
                    KButton(L.settings_cat_archive(), style: .secondary, size: .medium, icon: "archive") {
                        w.send("PATCH", "/api/v1/categories/\(cat.id)", .object(["archived": .bool(true)])) {
                            w.toast(L.settings_cat_archived_toast(name: cat.name))
                            dismiss()
                        }
                    }
                }
            }
            Text(id != nil ? L.settings_cat_autosave() : L.settings_cat_new_hint())
                .kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
        .loadCategories(into: $list)
        .onAppear {
            if id == nil && !routeId.hasPrefix("new") { id = routeId }
            if routeId == "new-income" { income = true }
        }
        .onChange(of: cat?.id) { _, _ in
            // The editor starts from the saved category once it has loaded.
            guard let cat, !filled else { return }
            filled = true
            name = cat.name
            icon = cat.icon ?? "ph:tag"
            income = cat.income
            parentId = cat.parentId
        }
        .task(id: name) {
            // The name saves itself a moment after typing stops.
            let next = name.trimmingCharacters(in: .whitespaces)
            guard !next.isEmpty, next != cat?.name, !(id != nil && cat == nil) else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commit(w, cat, ["name": .string(next)])
        }
        .kSheet(item: $sheet, scrolls: sheet == .parent || sheet == .merge) { s in
            switch s {
            case .parent:
                // A category with subcategories stays top level: categories nest one deep.
                ListPicker(L.settings_cat_inside(),
                           choices: [Choice(id: "", title: L.settings_cat_top_level())]
                               + (children.isEmpty ? parents(all).map { Choice(id: $0.id, title: $0.name) } : []),
                           selected: parentId ?? "", onPick: { v in
                               sheet = nil
                               parentId = v.isEmpty ? nil : v
                               commit(w, cat, ["parentId": v.isEmpty ? .null : .string(v)])
                           }, onClose: { sheet = nil })
            case .merge:
                if let cat {
                    MergeSheet(cat: cat, all: all, hasChildren: !children.isEmpty, close: { sheet = nil }) { into in
                        sheet = nil
                        w.send("POST", "/api/v1/categories/\(cat.id)/merge", .object(["intoId": .string(into.id)])) {
                            w.toast(L.settings_cat_merged(name: cat.name, into: into.name))
                            dismiss()
                        }
                    }
                }
            case .delete:
                if let cat {
                    ConfirmSheet(title: L.settings_cat_delete_title(name: cat.name), text: L.settings_cat_delete_body(),
                                 button: L.common_delete(), action: {
                                     w.send("DELETE", "/api/v1/categories/\(cat.id)") {
                                         w.toast(L.settings_cat_deleted(name: cat.name))
                                         dismiss()
                                     }
                                 }, close: { sheet = nil })
                }
            }
        }
    }

    private func parents(_ all: [Model.Category]) -> [Model.Category] {
        all.filter { !$0.archived && $0.parentId == nil && $0.income == income && $0.id != id && !Categories.isSystem($0.id) }
    }

    private func commit(_ w: Writer, _ cat: Model.Category?, _ patch: [String: JSONValue]) {
        guard let current = id else {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            var body: [String: JSONValue] = ["name": .string(trimmed), "icon": .string(icon), "type": .string(income ? "income" : "expense")]
            if let parentId { body["parentId"] = .string(parentId) }
            w.run({ () async throws -> Model.Category in try await kosha.api.post("/api/v1/categories", JSONValue.object(body)) }, done: { made in
                id = made.id
                w.toast(L.settings_cat_added(name: made.name))
            })
            return
        }
        w.send("PATCH", "/api/v1/categories/\(current)", .object(patch))
    }
}

/// Merge a category into another of the same type, then delete it: what moves, the target, and the button that names it.
/// A category with subcategories merges only into a top-level one (categories.tsx MergeDialog).
private struct MergeSheet: View {
    let cat: Model.Category
    let all: [Model.Category]
    let hasChildren: Bool
    let close: () -> Void
    let onMerge: (Model.Category) -> Void
    @State private var into: Model.Category?
    @Environment(\.kosha) private var theme

    var body: some View {
        let targets = tree(all.filter {
            !$0.archived && $0.id != cat.id && $0.parentId != cat.id && $0.income == cat.income
                && !(hasChildren && $0.parentId != nil) && !Categories.isNeutral($0.id)
        })
        let items = [cat.transactionCount > 0 ? L.settings_cat_count_tx(count: cat.transactionCount) : nil,
                     cat.recurringCount > 0 ? L.settings_cat_merge_item_recurring(count: cat.recurringCount) : nil,
                     cat.ruleCount > 0 ? L.settings_cat_merge_item_rules(count: cat.ruleCount) : nil,
                     hasChildren ? L.settings_cat_merge_item_subcategories() : nil].compactMap { $0 }
        let joined = ListFormatter.localizedString(byJoining: items)
        VStack(alignment: .leading, spacing: 12) {
            ListPicker(L.settings_cat_merge_title(name: cat.name),
                       choices: targets.map { t in Choice(id: t.id, title: t.name, detail: all.first { $0.id == t.parentId }?.name) },
                       selected: into?.id, onPick: { id in into = targets.first { $0.id == id } }, onClose: close)
            Text(L.settings_cat_merge_body(items: joined, name: cat.name)).kFont(.small).foregroundStyle(theme.colors.ink2)
            KButton(into.map { L.settings_cat_merge_into(name: $0.name) } ?? L.settings_cat_merge(), style: .danger) {
                if let into { onMerge(into) }
            }
            .disabled(into == nil)
        }
    }
}

// MARK: Events

/// "12 Oct 2026 – 18 Oct 2026", one end only, or "No dates".
private func eventDates(_ e: KoshaEvent, _ locale: Locale) -> String {
    let s = e.startDay.flatMap(Day.init).map { DayFormat.long($0, locale) }
    let t = e.endDay.flatMap(Day.init).map { DayFormat.long($0, locale) }
    switch (s, t) {
    case let (s?, t?): return "\(s) – \(t)"
    case let (s?, nil): return "\(s) –"
    case let (nil, t?): return "– \(t)"
    default: return L.settings_events_no_dates()
    }
}

/// Events: trips and occasions with their dates and counts; edit the name and dates, see the entries, delete.
struct EventsPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var list: EventList?
    @State private var openId: String?
    @State private var newName: String?

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let events = list?.events ?? []
        Page(L.settings_section_events(), actions: {
            IconButton("plus", label: L.settings_events_new(), solid: true) {
                if !w.refused() {
                    newName = ""
                    openId = nil
                }
            }
        }) {
            Text(L.settings_events_note()).kFont(.small).foregroundStyle(c.ink3)
            if let typed = newName {
                Card {
                    Text(L.settings_events_new()).kFont(.head)
                    KField(L.settings_cat_name(), text: Binding(get: { newName ?? "" }, set: { newName = $0 })).keyboard(.text)
                    HStack(spacing: 8) {
                        KButton(L.common_cancel(), style: .secondary, size: .medium) { newName = nil }
                        KButton(L.common_add(), size: .medium) {
                            w.run({ () async throws -> KoshaEvent in
                                try await kosha.api.post("/api/v1/events", JSONValue.object(["name": .string(typed.trimmingCharacters(in: .whitespaces))]))
                            }, done: { made in
                                newName = nil
                                openId = made.id
                            })
                        }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.ink))
            }
            if let e = events.first(where: { $0.id == openId }) {
                EventEditor(event: e) { openId = nil }.id(e.id)
            }
            if list == nil {
                LoadingNote()
            } else if events.isEmpty {
                Text(L.settings_events_empty()).foregroundStyle(c.ink3)
            }
            if !events.isEmpty {
                Rows {
                    ForEach(events.indices, id: \.self) { i in
                        let e = events[i]
                        if i > 0 { Hairline() }
                        SRow(e.name, description: eventDates(e, theme.locale), icon: "calendar-star",
                             action: { openId = openId == e.id ? nil : e.id }) {
                            Text("\(e.transactionCount)").kFont(.figure(12, .regular)).foregroundStyle(c.ink3)
                            PhIcon(openId == e.id ? "caret-up" : "caret-right", size: 16, color: c.ink3)
                        }
                    }
                }
            }
        }
        .load("events", into: $list) { try await $0.get("/api/v1/events") }
    }
}

private struct EventEditor: View {
    let event: KoshaEvent
    let onClosed: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var name = ""
    @State private var picking: String?
    @State private var day = Day(2026, 1, 1)
    @State private var confirm = false

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let patch = { (body: [String: JSONValue]) in w.send("PATCH", "/api/v1/events/\(event.id)", .object(body)) }
        Card {
            HStack {
                Text(event.name).kFont(.head)
                Spacer()
                Text(L.settings_events_transactions(count: event.transactionCount)).kFont(.xs).foregroundStyle(c.ink3)
            }
            KField("", text: $name).keyboard(.text)
            HStack(spacing: 8) {
                ForEach([("start", L.tx_from(), event.startDay), ("end", L.tx_to(), event.endDay)], id: \.0) { which, label, value in
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(label)
                        HStack(spacing: 8) {
                            Button {
                                day = value.flatMap(Day.init) ?? kosha.today
                                picking = which
                            } label: {
                                HStack(spacing: 8) {
                                    PhIcon("calendar-blank", size: 18, color: c.ink3)
                                    Text(value.flatMap(Day.init).map { DayFormat.short($0, theme.locale) } ?? "–").lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            if value != nil {
                                Button { patch([which == "start" ? "startDay" : "endDay": .null]) } label: {
                                    PhIcon("x", size: 14, color: c.ink3).frame(width: 32, height: 44)
                                }
                                .buttonStyle(PressStyle())
                                .accessibilityLabel(L.tx_clear())
                            }
                        }
                        .padding(.leading, 12).frame(minHeight: 48)
                        .background(c.surface, in: .rect(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                    }
                }
            }
            HStack(spacing: 8) {
                KButton(L.settings_events_see_transactions(), style: .secondary, size: .small) {
                    nav.push(.tagView(tag: nil, eventId: event.id))
                }
                KButton(L.common_delete(), style: .danger, size: .small) { if !w.refused() { confirm = true } }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.ink))
        .onAppear { name = event.name }
        .task(id: name) {
            let next = name.trimmingCharacters(in: .whitespaces)
            guard !next.isEmpty, next != event.name else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            patch(["name": .string(next)])
        }
        .kSheet(item: Binding(get: { picking.map { IdentifiedString(id: $0) } }, set: { picking = $0?.id })) { which in
            DateSheet(title: which.id == "start" ? L.tx_from() : L.tx_to(), day: $day) {
                picking = nil
                let key = which.id == "start" ? "startDay" : "endDay"
                if day.text != (which.id == "start" ? event.startDay : event.endDay) { patch([key: .string(day.text)]) }
            }
        }
        .kSheet(isPresented: $confirm) {
            ConfirmSheet(title: L.settings_events_delete_title(name: event.name), text: L.settings_events_delete_body(count: event.transactionCount),
                         button: L.common_delete(), action: {
                             w.send("DELETE", "/api/v1/events/\(event.id)") {
                                 w.toast(L.settings_events_deleted(name: event.name))
                                 onClosed()
                             }
                         }, close: { confirm = false })
        }
    }
}

/// A string that can drive `sheet(item:)`.
struct IdentifiedString: Identifiable { let id: String }

// MARK: Payee rules

/// Categories a rule can set: not archived and not one of Kosha's own.
@MainActor private func ruleCategoryChoices(_ kosha: Kosha) -> [Choice<String>] {
    let cats = kosha.meta?.categories.filter { !$0.isArchived && !Categories.isSystem($0.id) } ?? []
    return cats.sorted { $0.name.lowercased() < $1.name.lowercased() }.map { cat in
        Choice(id: cat.id, title: cat.name, detail: cats.first { $0.id == cat.parentId }?.name)
    }
}

/// Payee rules: Learn from my edits, a new rule (payee contains or is exactly → category), search, and the list.
struct RulesPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var query = ""
    @State private var searched = ""
    @State private var first: PayeeRules?
    @State private var more: [PayeeRule] = []
    @State private var next: Int?
    @State private var newPayee = ""
    @State private var newExact = false
    @State private var newCategory: String?
    @State private var picking = false
    @State private var editing: PayeeRule?

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let rules = (first?.rules ?? []) + more
        let catName = { (id: String) in kosha.meta?.categories.first { $0.id == id } }
        Page(L.settings_section_rules()) {
            Text(L.settings_section_rules_desc()).kFont(.small).foregroundStyle(c.ink3)
            Rows {
                SwitchRow(L.settings_rules_learn_title(), description: L.settings_rules_learn_description(),
                          isOn: prefBinding(kosha, w, "learn_rules"))
            }
            Card {
                Text(L.settings_rules_new()).kFont(.head)
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(L.settings_rules_payee())
                    KField(L.settings_rules_payee_placeholder(), text: $newPayee).keyboard(.text)
                }
                Segmented([(false, L.settings_rules_contains()), (true, L.settings_rules_is_exactly())], selection: $newExact, small: true)
                PickField("squares-four", newCategory.flatMap { catName($0)?.name } ?? L.settings_rules_pick_category(),
                          placeholder: newCategory == nil) { if !w.refused() { picking = true } }
                Text(L.settings_rules_new_hint()).kFont(.xs).foregroundStyle(c.ink3)
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.ink))

            KField(L.common_search(), text: $query, icon: "magnifying-glass").keyboard(.search)
            if first == nil {
                LoadingNote()
            } else if rules.isEmpty {
                Text(searched.isEmpty ? L.settings_rules_empty() : L.settings_rules_no_match(query: searched)).foregroundStyle(c.ink3)
            }
            if !rules.isEmpty {
                Rows {
                    ForEach(rules.indices, id: \.self) { i in
                        if i > 0 { Hairline() }
                        RuleRow(rule: rules[i], category: catName(rules[i].categoryId)) { editing = rules[i] }
                    }
                    if let offset = next {
                        Hairline()
                        Button {
                            w.run({ () async throws -> PayeeRules in
                                try await kosha.api.get("/api/v1/payee-rules", query: ["query": searched, "limit": "50", "offset": "\(offset)"])
                            }, done: { page in
                                more += page.rules
                                next = page.nextOffset
                            })
                        } label: {
                            HStack {
                                Text(L.settings_rules_show_more()).kFont(.small).foregroundStyle(c.ink2)
                                Spacer()
                                PhIcon("caret-down", size: 16, color: c.ink3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
        }
        .load("rules?\(searched)", into: $first) { [searched] in
            try await $0.get("/api/v1/payee-rules", query: ["query": searched, "limit": "50"])
        }
        .onChange(of: searched) { _, _ in
            more = []
            next = nil
        }
        .onChange(of: first?.nextOffset) { _, offset in if more.isEmpty { next = offset } }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { searched = query.trimmingCharacters(in: .whitespaces) }
        }
        .task(id: "\(newPayee)|\(newCategory ?? "")|\(newExact)") {
            // A new rule saves once it has both a payee and a category.
            guard !newPayee.trimmingCharacters(in: .whitespaces).isEmpty, let cat = newCategory else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            let rule: JSONValue = .object(["payee": .string(newPayee.trimmingCharacters(in: .whitespaces)), "categoryId": .string(cat),
                                           "match": .string(newExact ? "exact" : "contains")])
            w.send("PUT", "/api/v1/payee-rules", .object(["rules": .array([rule])])) {
                newPayee = ""
                newCategory = nil
                w.toast(L.common_saved())
            }
        }
        .kSheet(isPresented: $picking, scrolls: true) {
            ListPicker(L.settings_rules_pick_category(), choices: ruleCategoryChoices(kosha), selected: newCategory,
                       onPick: { picking = false; newCategory = $0 }, onClose: { picking = false })
        }
        .kSheet(item: Binding(get: { editing.map { IdentifiedString(id: $0.payee) } }, set: { if $0 == nil { editing = nil } })) { _ in
            if let r = editing { RuleSheet(rule: r) { editing = nil } }
        }
    }
}

/// One rule: "Payee contains ⟨REWE⟩", its category, how often it's used and where it came from.
private struct RuleRow: View {
    let rule: PayeeRule
    let category: MetaCategory?
    let action: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let text = rule.match == "exact" ? L.settings_rules_payee_is(title: rule.payee) : L.settings_rules_payee_contains(title: rule.payee)
        let source = rule.source == "learned" ? L.settings_rules_source_learned() : L.settings_rules_source_manual()
        let detail = [category?.name ?? L.settings_rules_deleted_category(), L.app_set_rule_used(count: rule.matches), source]
            .joined(separator: " · ")
        return Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).kFont(.small)
                    HStack(spacing: 4) {
                        PhIcon(categoryIconName(category?.icon), size: 14, color: c.ink3)
                        Text(detail).kFont(.xs).foregroundStyle(c.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 16, color: c.ink3)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: theme.dims.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Change one rule's text, match or category, or delete it.
private struct RuleSheet: View {
    let rule: PayeeRule
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @State private var payee = ""
    @State private var exact = false
    @State private var category = ""
    @State private var picking = false

    var body: some View {
        let w = Writer(kosha: kosha, toasts: toasts)
        if picking {
            ListPicker(L.settings_rules_pick_category(), choices: ruleCategoryChoices(kosha), selected: category,
                       onPick: { picking = false; category = $0 }, onClose: { picking = false })
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(L.settings_section_rules(), onClose: close)
                FieldLabel(L.settings_rules_payee())
                KField("", text: $payee).keyboard(.text)
                Segmented([(false, L.settings_rules_contains()), (true, L.settings_rules_is_exactly())], selection: $exact, small: true)
                PickField("squares-four", kosha.meta?.categories.first { $0.id == category }?.name ?? L.settings_rules_deleted_category()) {
                    picking = true
                }
                HStack(spacing: 8) {
                    KButton(L.common_delete(), style: .danger, size: .medium) {
                        w.send("POST", "/api/v1/payee-rules/delete", .object(["payees": .array([.string(rule.payee)])])) {
                            w.toast(L.settings_rules_deleted())
                            close()
                        }
                    }
                    .frame(width: 120)
                    KButton(L.common_save(), size: .medium) {
                        let trimmed = payee.trimmingCharacters(in: .whitespaces)
                        var r: [String: JSONValue] = ["payee": .string(trimmed), "categoryId": .string(category),
                                                      "match": .string(exact ? "exact" : "contains")]
                        if trimmed != rule.payee { r["previousPayee"] = .string(rule.payee) }
                        w.send("PUT", "/api/v1/payee-rules", .object(["rules": .array([.object(r)])])) { close() }
                    }
                    .disabled(payee.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            }
            .onAppear {
                if payee.isEmpty {
                    payee = rule.payee
                    exact = rule.match == "exact"
                    category = rule.categoryId
                }
            }
        }
    }
}
