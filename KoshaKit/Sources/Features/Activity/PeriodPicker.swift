import SwiftUI
import Model
import Store
import Design

// Activity's own dates (transactions.tsx PeriodPicker). Ported from PeriodPicker.kt.

/// Activity's dates in the header: the label opens the picker, and a month or a year steps back and on.
@MainActor
func periodHeader(_ shown: Period, current: Month, locale: Locale, open: @escaping () -> Void,
                  pick: @escaping (Period) -> Void) -> HeaderPeriod {
    let label = periodLabel(shown, current: current, locale: locale)
    let full: String = if case .month(let m) = shown { DayFormat.month(m, locale) } else { label }
    let year: Bool = if case .year = shown { true } else { false }
    return HeaderPeriod(
        label: label,
        spoken: L.tx_period_label(period: full),
        open: open,
        previous: shown.shift(-1).map { p in (year ? L.tx_previous_year() : L.shell_previous_month(), { pick(p) }) },
        next: shown.shift(1).map { p in (year ? L.tx_next_year() : L.shell_next_month(), { pick(p) }) }
    )
}

/// "November", "March 2025", "2025", "All time" or "5 Jan 2026 – 10 Feb 2026".
@MainActor
func periodLabel(_ p: Period, current: Month, locale: Locale) -> String {
    switch p {
    case .month(let m):
        DayFormat.monthName(m, locale).capitalized(with: locale) + (m.year != current.year ? " \(m.year)" : "")
    case .year(let y): String(y)
    case .all: L.tx_period_all()
    case .range(let from, let to): dayText(from, locale, year: true) + " – " + dayText(to, locale, year: true)
    }
}

/// Picks Activity's dates: a month on the month sheet, one of the last 20 years, every date, or chosen days. Switching
/// to a month keeps where you are, but never moves past now.
struct PeriodSheet: View {
    let shown: Period
    let current: Month
    let onPick: (Period) -> Void
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @State private var step = Step.kind

    enum Step { case kind, month, year, range }

    var body: some View {
        switch step {
        case .kind:
            VStack(alignment: .leading, spacing: 8) {
                SheetHeader(L.tx_period_custom_title(), onClose: close)
                Card(tight: true) {
                    choice(L.tx_period_month(), on: isMonth) { step = .month }
                    Hairline()
                    choice(L.tx_period_year(), on: isYear) { step = .year }
                    Hairline()
                    choice(L.tx_period_all(), on: shown == .all) { onPick(.all) }
                    Hairline()
                    choice(L.tx_period_custom(), on: isRange) { step = .range }
                }
            }
        case .month:
            MonthSheet(month: monthShown, onPick: { onPick(.month($0)) }, close: close)
        case .year:
            VStack(alignment: .leading, spacing: 8) {
                SheetHeader(L.tx_period_year(), onClose: close)
                Card(tight: true) {
                    ForEach(Array((current.year - 19...current.year).reversed().enumerated()), id: \.element) { i, y in
                        if i > 0 { Hairline() }
                        choice(String(y), on: shown == .year(y)) { onPick(.year(y)) }
                    }
                }
            }
        case .range:
            RangeSheet(from: shown.days?.lowerBound ?? current.first, to: shown.days?.upperBound ?? kosha.today,
                       today: kosha.today, close: close) { onPick(.range($0, $1)) }
        }
    }

    private var isMonth: Bool { if case .month = shown { true } else { false } }
    private var isYear: Bool { if case .year = shown { true } else { false } }
    private var isRange: Bool { if case .range = shown { true } else { false } }

    /// The month the month sheet opens on: the one shown, else the month the dates end in, but never past now.
    private var monthShown: Month {
        if case .month(let m) = shown { return m }
        return shown.days.map { min($0.upperBound.monthOf, current) } ?? current
    }

    private func choice(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        ListRow(action: action) {
            Text(label).kFont(on ? .head : .body).frame(maxWidth: .infinity, alignment: .leading)
            Radio(on)
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// From and Until on one month grid: tap a field, then a day. Until is never before From.
private struct RangeSheet: View {
    let today: Day
    let close: () -> Void
    let onPick: (Day, Day) -> Void
    @Environment(\.kosha) private var theme
    @State private var from: Day
    @State private var to: Day
    @State private var editingFrom = true
    @State private var month: Month

    init(from: Day, to: Day, today: Day, close: @escaping () -> Void, onPick: @escaping (Day, Day) -> Void) {
        self.today = today
        self.close = close
        self.onPick = onPick
        _from = State(initialValue: from)
        _to = State(initialValue: max(from, to))
        _month = State(initialValue: from.monthOf)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetHeader(L.tx_period_custom_title(), onClose: close)
            Card(tight: true) {
                field(L.tx_date_from(), from, editing: editingFrom) { editingFrom = true; month = from.monthOf }
                Hairline()
                field(L.tx_until(), to, editing: !editingFrom) { editingFrom = false; month = to.monthOf }
            }
            MonthHeader(month: month) { month = month.adding($0) }
            MonthGrid(month: month, selected: editingFrom ? from : to, today: today) { day in
                if editingFrom {
                    from = day
                    if to < day { to = day }
                    editingFrom = false
                } else if day < from {
                    from = day
                } else {
                    to = day
                }
            }
            KButton(L.tx_show()) { onPick(from, to) }.padding(.top, 4)
        }
    }

    private func field(_ label: String, _ day: Day, editing: Bool, action: @escaping () -> Void) -> some View {
        let c = theme.colors
        return ListRow(action: action) {
            Text(label).kFont(.small).foregroundStyle(c.ink3).frame(maxWidth: .infinity, alignment: .leading)
            Text(dayText(day, theme.locale, year: true)).foregroundStyle(editing ? c.ink : c.ink2)
            if editing { PhIcon("caret-down", size: 14, color: c.ink3) }
        }
        .accessibilityAddTraits(editing ? .isSelected : [])
    }
}
