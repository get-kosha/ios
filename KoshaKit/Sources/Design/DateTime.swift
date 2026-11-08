import SwiftUI
import Model

/// Dates as the person reads them, in the app's language. Days are formatted in UTC because `Day.date` is noon UTC.
public enum DayFormat {
    private static func formatter(_ template: String, _ locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// "Thu 5 Nov".
    public static func short(_ day: Day, _ locale: Locale) -> String { formatter("EEEdMMM", locale).string(from: day.date) }
    /// "Fri 6".
    public static func weekdayDay(_ day: Day, _ locale: Locale) -> String { formatter("EEEd", locale).string(from: day.date) }
    /// "5 November 2026".
    public static func long(_ day: Day, _ locale: Locale) -> String { formatter("dMMMMy", locale).string(from: day.date) }
    /// "7 Nov".
    public static func dayMonth(_ day: Day, _ locale: Locale) -> String { formatter("dMMM", locale).string(from: day.date) }
    /// "November 2026".
    public static func month(_ month: Month, _ locale: Locale) -> String { formatter("MMMMy", locale).string(from: month.first.date) }
    /// "November".
    public static func monthName(_ month: Month, _ locale: Locale) -> String { formatter("MMMM", locale).string(from: month.first.date) }
    /// "Nov".
    public static func monthShort(_ month: Month, _ locale: Locale) -> String { formatter("MMM", locale).string(from: month.first.date) }

    /// Today, Yesterday, or the weekday and date ("Fri 6").
    public static func label(_ day: Day, today: Day, _ locale: Locale) -> String {
        if day == today { return L.add_today() }
        if day == today.adding(days: -1) { return L.add_yesterday() }
        return short(day, locale)
    }

    /// Whether the language writes 12-hour time.
    public static func uses12Hour(_ locale: Locale) -> Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
    }

    /// "13:05" or "1:05 PM", from the API's "HH:mm".
    public static func time(_ hhmm: String, _ locale: Locale) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return hhmm }
        let f = formatter("jmm", locale)
        let date = Day.calendarUTC.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: p[0], minute: p[1]))!
        return f.string(from: date)
    }
}

extension Day {
    static var calendarUTC: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}

/// A month of days: weeks start on the language's first weekday, today is outlined, the picked day is filled in the
/// selection colour, and a dot marks days that already have entries. Future days stay pickable for planned payments.
/// `today` comes from the user's time zone, not the phone's.
public struct MonthGrid: View {
    let month: Month
    let selected: Day?
    let today: Day
    let dots: Set<Day>
    let onPick: (Day) -> Void
    @Environment(\.kosha) private var theme

    public init(month: Month, selected: Day?, today: Day, dots: Set<Day> = [], onPick: @escaping (Day) -> Void) {
        self.month = month
        self.selected = selected
        self.today = today
        self.dots = dots
        self.onPick = onPick
    }

    public var body: some View {
        let c = theme.colors
        var cal = Calendar(identifier: .gregorian)
        cal.locale = theme.locale
        let firstWeekday = cal.firstWeekday // 1 = Sunday
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let lead = ((month.first.weekday - firstWeekday) % 7 + 7) % 7
        let start = month.first.adding(days: -lead)
        let weeks = (lead + month.dayCount + 6) / 7
        return Grid(horizontalSpacing: 0, verticalSpacing: 2) {
            GridRow {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(firstWeekday - 1 + i) % 7]).kFont(.xs).foregroundStyle(c.ink3)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .accessibilityHidden(true)
                }
            }
            ForEach(0..<weeks, id: \.self) { w in
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        cell(start.adding(days: w * 7 + i))
                    }
                }
            }
        }
    }

    private func cell(_ day: Day) -> some View {
        let c = theme.colors
        let inMonth = day.monthOf == month
        let on = day == selected
        let has = dots.contains(day)
        return Button { onPick(day) } label: {
            Text("\(day.day)")
                .kFont(.figure(15, on ? .medium : .regular))
                .foregroundStyle(on ? c.onSelection : !inMonth ? c.ink3.opacity(0.5) : day > today ? c.ink3 : c.ink)
                .frame(width: 38, height: 38)
                .background(on ? c.selection : .clear, in: .circle)
                .overlay { if day == today && !on { Circle().strokeBorder(c.line) } }
                .frame(maxWidth: .infinity, minHeight: 42)
                .overlay(alignment: .bottom) {
                    if has && !on { Circle().fill(c.ink3).frame(width: 4, height: 4).padding(.bottom, 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(DayFormat.long(day, theme.locale))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The month and its arrows above a `MonthGrid`.
public struct MonthHeader: View {
    let month: Month
    let onMove: (Int) -> Void
    @Environment(\.kosha) private var theme

    public init(month: Month, onMove: @escaping (Int) -> Void) {
        self.month = month
        self.onMove = onMove
    }

    public var body: some View {
        HStack {
            Text(DayFormat.month(month, theme.locale)).kFont(.sans(17, .medium))
            Spacer()
            IconButton("caret-left", label: L.shell_previous_month()) { onMove(-1) }
            IconButton("caret-right", label: L.shell_next_month()) { onMove(1) }
        }
    }
}

/// One wheel of the time picker, in the style of iOS: the value under the band is picked; rows fade and tilt away
/// from it. Flick, drag, or tap a row. VoiceOver steps it up and down.
struct Wheel: View {
    let values: [String]
    @Binding var selected: Int
    let label: String
    let loop: Bool
    @State private var position: Int?
    @Environment(\.kosha) private var theme

    private static let row: CGFloat = 44
    private var laps: Int { loop ? 60 : 1 }

    var body: some View {
        let c = theme.colors
        let count = values.count * laps
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    Text(values[i % values.count])
                        .kFont(.figure(26, .medium))
                        .foregroundStyle(c.ink)
                        .frame(maxWidth: .infinity, minHeight: Wheel.row, maxHeight: Wheel.row)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(theme.animation()) { position = i } }
                        .visualEffect { content, proxy in
                            let frame = proxy.frame(in: .scrollView(axis: .vertical))
                            let centre = Wheel.row * 2.5
                            let distance = (frame.midY - centre) / Wheel.row
                            let d = min(abs(distance), 3)
                            return content
                                .scaleEffect(1 - d * 0.12)
                                .opacity(d < 0.5 ? 1 : d < 1.5 ? 0.5 : d < 2.5 ? 0.22 : 0)
                                .rotation3DEffect(.degrees(Double(-distance) * 18), axis: (1, 0, 0), perspective: 0.5)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $position, anchor: .center)
        .contentMargins(.vertical, Wheel.row * 2, for: .scrollContent)
        .frame(width: 96, height: Wheel.row * 5)
        .onAppear { position = (laps / 2) * values.count + selected }
        .onChange(of: position) { _, p in if let p { selected = p % values.count } }
        .onChange(of: selected) { _, s in
            if let p = position, p % values.count != s { position = (p / values.count) * values.count + s }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(values[selected])
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: selected = (selected + 1) % values.count
            case .decrement: selected = (selected - 1 + values.count) % values.count
            @unknown default: break
            }
        }
    }
}

/// Hours and minutes on two wheels, with an AM/PM wheel when the language writes 12-hour time. A highlighted band marks
/// the picked time. `time` is "HH:mm", 24-hour, as the API writes it.
public struct TimeWheel: View {
    @Binding var time: String
    @Environment(\.kosha) private var theme

    public init(time: Binding<String>) { _time = time }

    private var parts: (h: Int, m: Int) {
        let p = time.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (12, 0)
    }

    private func set(h: Int? = nil, m: Int? = nil) {
        time = String(format: "%02d:%02d", h ?? parts.h, m ?? parts.m)
    }

    public var body: some View {
        let c = theme.colors
        let twelve = DayFormat.uses12Hour(theme.locale)
        let minutes = (0...59).map { String(format: "%02d", $0) }
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(c.soft).frame(height: 44)
            HStack(spacing: 4) {
                if twelve {
                    Wheel(values: (1...12).map(String.init), selected: Binding(
                        get: { (parts.h + 11) % 12 },
                        set: { set(h: ($0 + 1) % 12 + (parts.h >= 12 ? 12 : 0)) }
                    ), label: L.app_time_hours(), loop: true)
                } else {
                    Wheel(values: (0...23).map { String(format: "%02d", $0) }, selected: Binding(
                        get: { parts.h }, set: { set(h: $0) }
                    ), label: L.app_time_hours(), loop: true)
                }
                Text(":").kFont(.figure(26, .regular)).foregroundStyle(c.ink3).accessibilityHidden(true)
                Wheel(values: minutes, selected: Binding(get: { parts.m }, set: { set(m: $0) }),
                      label: L.app_time_minutes(), loop: true)
                if twelve {
                    let f = DateFormatter()
                    let _ = f.locale = theme.locale
                    Wheel(values: [f.amSymbol, f.pmSymbol], selected: Binding(
                        get: { parts.h >= 12 ? 1 : 0 },
                        set: { set(h: parts.h % 12 + ($0 == 1 ? 12 : 0)) }
                    ), label: L.app_time_period(), loop: false)
                }
            }
            VStack {
                LinearGradient(colors: [c.surface, c.surface.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 60)
                Spacer()
                LinearGradient(colors: [c.surface.opacity(0), c.surface], startPoint: .top, endPoint: .bottom).frame(height: 60)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 220)
    }
}
