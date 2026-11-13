import SwiftUI
import Model
import Store
import Design

// The loan pieces other screens show: Overview's Loans card, Accounts' link row and switch, and the totals and due
// lines the Loans pages share. Ported from the Android app's LoanSummary.kt and the web's components/loans.tsx.

/// A loan's day as "20 Nov 2026", in the language's own order.
func loanDay(_ day: String, _ locale: Locale) -> String { fmtDay(day, "dMMMy", locale) }

/// "Owed to you" or "You owe".
func loanSide(_ lent: Bool) -> String { lent ? L.loans_owed_to_you() : L.loans_you_owe() }

/// The label of a "… · optional" field, without the "· optional".
func loanFieldLabel(_ text: String) -> String {
    text.components(separatedBy: " · ").first ?? text
}

/// "Due 20 Nov 2026", or "Overdue · 2 Nov 2026" in the warning colour, while money is still owed.
struct LoanDueText: View {
    let loan: Loan
    let today: String
    @Environment(\.kosha) private var theme

    var body: some View {
        if let due = loan.dueDay, loan.open {
            let late = due < today
            let date = loanDay(due, theme.locale)
            Text(late ? L.loans_overdue(date: date) : L.loans_due_on(date: date))
                .kFont(.xs)
                .foregroundStyle(late ? theme.colors.warn : theme.colors.ink3)
        }
    }
}

/// Owed to you | You owe, side by side with a divider, in the display currency at today's rates, and the caption that
/// they're current balances across all dates.
struct LoanTotals: View {
    let loans: [Loan]
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let currency = kosha.display
        let totals = LoanMath.totals(loans, to: currency, perUsd: kosha.meta?.rates ?? [:])
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                side(L.loans_owed_to_you(), totals.lent, currency)
                c.line.frame(width: 1).frame(maxHeight: .infinity)
                side(L.loans_you_owe(), totals.borrowed, currency)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(L.loans_current()).kFont(.xs).foregroundStyle(c.ink3)
        }
    }

    private func side(_ label: String, _ minor: Int64, _ currency: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).kFont(.small).foregroundStyle(theme.colors.ink3)
            HeroMoney(minor, currency, size: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Overview's Loans card, after Where it went: the all-date totals and loans due within a week (overdue ones in the
/// warning colour). Hidden while nothing is owed either way.
struct OverviewLoansCard: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let loans = kosha.meta?.loans ?? []
        if loans.contains(where: \.open) {
            let today = kosha.today
            let week = today.adding(days: 7).text
            let due = loans.filter { $0.open && ($0.dueDay.map { $0 <= week } ?? false) }
                .sorted { ($0.dueDay ?? "") < ($1.dueDay ?? "") }
                .prefix(3)
            Card(tight: true) {
                Button { nav.push(.loans) } label: {
                    HStack(spacing: 8) {
                        PhIcon("hand-coins", color: c.ink2)
                        Text(L.loans_title()).kFont(.head).frame(maxWidth: .infinity, alignment: .leading)
                        PhIcon("caret-right", size: 16, color: c.ink3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(.isHeader)
                LoanTotals(loans: loans).padding(.horizontal, 16).padding(.bottom, 16)
                ForEach(Array(due)) { loan in
                    Hairline()
                    ListRow(action: { nav.push(.loanDetail(id: loan.id)) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loan.person).lineLimit(1)
                            LoanDueText(loan: loan, today: today.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 2) {
                            MoneyText(loan.remaining, loan.currency)
                            Text(loanSide(loan.lent)).kFont(.xs).foregroundStyle(c.ink3)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Accounts' one link row to Loans, after net worth: "Owed to you €3,000.00 · You owe €120.00". Hidden while nothing
/// is owed either way.
struct AccountsLoansLink: View {
    let lent: Int64
    let borrowed: Int64
    let currency: String
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        if lent > 0 || borrowed > 0 {
            let owed = inText(lent, currency, theme)
            let owe = inText(borrowed, currency, theme)
            Card(tight: true) {
                LinkRow(icon: "hand-coins", title: L.loans_title(),
                        detail: L.loans_owed_to_you() + " " + owed + " · " + L.loans_you_owe() + " " + owe,
                        figures: [owed, owe]) { nav.push(.loans) }
            }
        }
    }
}

/// Accounts | Loans, at the top of both pages, as the web's account tabs.
struct AccountLoansSwitch: View {
    let loans: Bool
    @Environment(Navigator.self) private var nav

    var body: some View {
        Segmented([(false, L.accounts_title()), (true, L.loans_title())], selection: Binding(get: { loans }, set: { picked in
            guard picked != loans else { return }
            if picked {
                nav.push(.loans)
            } else {
                nav.pop()
                nav.open(.accounts)
            }
        }), small: true)
    }
}
