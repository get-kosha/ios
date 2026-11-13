import SwiftUI
import Model
import API
import Store
import Design

private struct Ids: Encodable { let ids: [String] }
private struct NewTransactions: Encodable { let transactions: [NewTransaction] }

/// Search and quick add from one field, full screen over Overview: "12.50 rewe yesterday" becomes a Quick add row
/// (saved through create_transactions with its own id, or queued offline), then payees, categories, accounts and pages to
/// go to, "Search activity for …", and "Ask …" when Ask Kosha is on. Ported from SearchSheet.kt (search-palette.tsx).
struct SearchSheet: View {
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var q = ""
    @State private var payees: [Payee] = []
    @FocusState private var focused: Bool

    private var text: String { q.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 10) {
                    PhIcon("magnifying-glass", size: 18, color: c.ink3)
                    TextField("", text: $q, prompt: Text(L.shell_search_placeholder()).foregroundStyle(c.ink3))
                        .kFont(.sans(16, .regular))
                        .focused($focused)
                        .submitLabel(.go)
                        .keyboard(.search)
                        .onSubmit { if let quick { save(quick) } }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(c.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? c.ink : c.line, lineWidth: focused ? 2 : 1))
                Button(L.common_cancel(), action: close)
                    .kFont(.body).foregroundStyle(c.ink2).padding(.horizontal, 10).frame(minHeight: 48)
                    .buttonStyle(PressStyle())
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { results }.padding(.horizontal, 8).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(c.surface)
        .onAppear { focused = true }
        .task(id: text) {
            guard !text.isEmpty else { payees = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if let p: Payees = try? await kosha.api.get("/api/v1/payees", query: ["query": String(text.prefix(40)), "limit": "5"]) {
                payees = p.payees
            }
        }
    }

    /// What the line would add, when it has an amount and an account to put it in.
    private struct Quick {
        let entry: NewTransaction
        let account: Wallet
        let category: MetaCategory?
        let day: Day
        let amountText: String
        let tags: [String]
    }

    private var quick: Quick? {
        guard let m = kosha.meta, !text.isEmpty else { return nil }
        let wallets = kosha.activeWallets
        let cats = m.categories.filter { !$0.isArchived && !Categories.isSystem($0.id) }
        let p = QuickAdd.parse(text, wallets: wallets.map { Named(id: $0.id, name: $0.name) },
                               categories: cats.map { Named(id: $0.id, name: $0.name) }, locale: L.language)
        guard let amount = p.amount, let account = wallets.first(where: { $0.id == p.walletId }) ?? defaultAccount() else { return nil }
        let categoryId = p.categoryId ?? guessCategory(p.payee, m.payeeMatches)
            ?? payees.first { $0.payee.lowercased() == p.payee.lowercased() }?.categoryId
        let day = p.date == .yesterday ? kosha.today.adding(days: -1) : kosha.today
        let signed = p.income ? amount : -amount
        let entry = NewTransaction(accountId: account.id, payee: p.payee, amount: signed, categoryId: categoryId, day: day.text, tags: p.tags)
        return Quick(entry: entry, account: account, category: kosha.category(categoryId), day: day,
                     amountText: Money.format(signed, account.currency, theme.locale, sign: .always), tags: p.tags)
    }

    /// The account a quick add uses when the line names none: Settings › General › Default account, else the last used.
    private func defaultAccount() -> Wallet? {
        let list = kosha.activeWallets
        let pick = kosha.meta?.pref("default_wallet", "last") ?? "last"
        let id = pick == "last" ? kosha.local.lastAccount : pick
        return list.first { $0.id == id } ?? list.first
    }

    @ViewBuilder
    private var results: some View {
        let c = theme.colors
        let low = text.lowercased()
        if let qk = quick {
            group(L.shell_search_quick_add())
            Button { save(qk) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PhIcon("plus", size: 18).frame(width: 36, height: 36).background(c.surface, in: .rect(cornerRadius: 10))
                        Text(L.app_ov_quick_add_row(amount: qk.amountText, payee: qk.entry.payee.isEmpty ? qk.category?.name ?? "" : qk.entry.payee))
                            .kFont(.head).money().frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            PhIcon("key-return", size: 16, color: c.ink3)
                            Text(L.app_ios_ov_go()).kFont(.small).foregroundStyle(c.ink3)
                        }
                        .accessibilityHidden(true)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if let cat = qk.category { tag(cat.name) { PhIcon(categoryIconName(cat.icon), size: 14) } }
                            tag(qk.account.name) { AccountDot(c.account(kosha.colorIndex(qk.account.id))) }
                            tag(DayFormat.label(qk.day, today: kosha.today, theme.locale)) { PhIcon("calendar-blank", size: 14) }
                            ForEach(qk.tags, id: \.self) { t in tag("#\(t)") { EmptyView() } }
                        }
                    }
                    .padding(.leading, 44)
                }
                .padding(12)
                .background(c.soft, in: .rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(PressStyle())
        }
        if !payees.isEmpty {
            group(L.shell_search_payees())
            ForEach(payees, id: \.payee) { py in
                let cat = kosha.category(py.categoryId)
                result(icon: { IconTile(categoryIconName(cat?.icon)) }, title: py.payee,
                       sub: py.averageAmount.map { avg in
                           L.shell_search_payee_usually(count: "\(py.count)",
                                                        amount: Money.format(abs(avg), py.currency ?? kosha.primary, theme.locale))
                       },
                       end: "arrow-up-right") { go { nav.openActivity(ActivitySearch(query: py.payee)) } }
            }
        }
        let cats = low.isEmpty ? [] : Array((kosha.meta?.categories ?? [])
            .filter { !$0.isArchived && !Categories.isSystem($0.id) && $0.name.lowercased().contains(low) }.prefix(4))
        let accounts = low.isEmpty ? [] : Array(kosha.activeWallets.filter { $0.name.lowercased().contains(low) }.prefix(3))
        let loans = low.isEmpty ? [] : Array((kosha.meta?.loans ?? [])
            .filter { "\($0.person) \($0.purpose)".lowercased().contains(low) }.prefix(5))
        let pages: [(String, String, () -> Void)] = [
            ("arrows-clockwise", L.shell_nav_recurring(), { nav.open(.recurring) }),
            ("bank", L.shell_nav_accounts(), { nav.open(.accounts) }),
            ("hand-coins", L.loans_title(), { nav.push(.loans) }),
            ("tray-arrow-down", L.shell_page_import(), { nav.push(.importStatements) }),
            ("scales", L.shell_page_reconcile(), { nav.push(.reconcile()) }),
            ("gear", L.shell_settings(), { nav.push(.settings()) }),
        ].filter { low.isEmpty || $0.1.lowercased().contains(low) }
        if !loans.isEmpty {
            group(L.loans_title())
            ForEach(loans) { loan in
                result(icon: { IconTile("hand-coins") }, title: loan.person,
                       sub: [loan.purpose, Money.format(loan.remaining, loan.currency, theme.locale)].filter { !$0.isEmpty }
                           .joined(separator: " · "),
                       end: "arrow-right") { go { nav.push(.loanDetail(id: loan.id)) } }
            }
        }
        if !cats.isEmpty || !accounts.isEmpty || !pages.isEmpty || !text.isEmpty { group(L.shell_search_go_to()) }
        if !text.isEmpty {
            result(icon: { IconTile("magnifying-glass") }, title: L.shell_search_activity(text: text)) {
                go { nav.openActivity(ActivitySearch(query: String(text.prefix(40)))) }
            }
        }
        ForEach(cats) { cat in
            result(icon: { IconTile(categoryIconName(cat.icon)) }, title: cat.name, sub: L.shell_nav_activity()) {
                go { nav.openActivity(ActivitySearch(categoryId: cat.id)) }
            }
        }
        ForEach(accounts) { a in
            result(icon: { IconTile("wallet") }, title: a.name, sub: L.shell_nav_activity()) {
                go { nav.openActivity(ActivitySearch(accountId: a.id)) }
            }
        }
        ForEach(pages.indices, id: \.self) { i in
            let page = pages[i]
            result(icon: { IconTile(page.0) }, title: page.1, end: "arrow-right") { go(page.2) }
        }
        if !text.isEmpty && kosha.meta?.aiFlags.ask == true {
            result(icon: {
                Sparkle(size: 18).frame(width: 36, height: 36).background(c.soft, in: .rect(cornerRadius: 10))
            }, title: L.shell_search_ask(text: text), sub: L.shell_search_ask_hint()) {
                go { nav.push(.ask(question: text)) }
            }
        }
    }

    private func go(_ route: () -> Void) {
        close()
        route()
    }

    private func save(_ qk: Quick) {
        guard kosha.canWrite else {
            toasts.show(L.common_demo_read_only(), warning: true)
            return
        }
        let entry = qk.entry
        let name = entry.payee
        Task {
            do {
                let _: Transactions = try await kosha.api.post("/api/v1/transactions", NewTransactions(transactions: [entry]))
                kosha.local.lastAccount = qk.account.id
                kosha.changed()
                toasts.show(L.tx_added_toast(amount: qk.amountText, name: name)) {
                    Task {
                        try? await kosha.api.send("POST", "/api/v1/transactions/delete", body: Ids(ids: [entry.id]))
                        kosha.changed()
                    }
                }
                close()
            } catch let e as KoshaError where e.retryable {
                // Offline, busy or failing: the outbox sends it later with the same id.
                await kosha.outbox.add(Queued(entry: entry, currency: qk.account.currency, accountName: qk.account.name,
                                              categoryName: qk.category?.name ?? ""))
                kosha.sendOutbox()
                toasts.show(L.app_ov_saved_offline(amount: qk.amountText, payee: name)) {
                    Task { await kosha.outbox.remove(entry.id) }
                }
                close()
            } catch let e as KoshaError {
                toasts.show(e.errorDescription ?? "", warning: true)
            } catch {}
        }
    }

    private func group(_ label: String) -> some View {
        Text(label).kFont(.caption).foregroundStyle(theme.colors.ink3)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func result<Icon: View>(
        @ViewBuilder icon: () -> Icon, title: String, sub: String? = nil, end: String? = nil, action: @escaping () -> Void
    ) -> some View {
        let c = theme.colors
        return Button(action: action) {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(2).multilineTextAlignment(.leading)
                    if let sub { Text(sub).kFont(.xs).foregroundStyle(c.ink3).money() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let end { PhIcon(end, size: 16, color: c.ink3) }
            }
            .padding(8)
            .frame(minHeight: 52)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
    }

    private func tag<Leading: View>(_ text: String, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 4) {
            leading()
            Text(text).kFont(.xs).foregroundStyle(theme.colors.ink2).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(theme.colors.surface, in: .capsule)
    }
}
