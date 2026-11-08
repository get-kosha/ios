import SwiftUI
import WidgetKit
import Model
import Store
import Design

/// The Home Screen widgets: quick add (Add expense, Add income, Scan a receipt) and this month's spending so far. They
/// read the snapshot the app writes after each refresh and never call the server.
@main
struct KoshaWidgets: WidgetBundle {
    var body: some Widget { QuickAddWidget() }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads the timeline when it writes a new snapshot; refresh hourly in case it hasn't run.
        completion(Timeline(entries: [Entry(date: Date(), snapshot: WidgetSnapshot.read())],
                            policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct QuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "quick-add", provider: Provider()) { entry in
            QuickAddView(entry: entry)
        }
        .configurationDisplayName(L.app_widget_name())
        .description(L.app_widget_description())
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickAddView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let language = L.resolve(entry.snapshot?.language)
        let _ = L.use(language: language)
        Content(entry: entry, medium: family == .systemMedium)
            .koshaTheme(ThemeSettings(language: language, hideAmounts: entry.snapshot?.hideAmounts ?? false))
    }
}

private struct Content: View {
    let entry: Entry
    let medium: Bool
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.overview_pace_spent_so_far()).kFont(.small).foregroundStyle(c.ink3)
                if let s = entry.snapshot {
                    Text(Money.format(s.spending, s.currency, theme.locale))
                        .font(.custom("Geist-SemiBold", size: 26, relativeTo: .title).monospacedDigit())
                        .foregroundStyle(c.ink)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .blur(radius: s.hideAmounts ? 7 : 0)
                    if let m = Month(s.month) {
                        Text(DayFormat.month(m, theme.locale)).kFont(.xs).foregroundStyle(c.ink3)
                    }
                } else {
                    Text("—").kFont(.title).foregroundStyle(c.ink3)
                }
                Spacer(minLength: 0)
                Link(destination: URL(string: "app.getkosha://add?kind=expense")!) {
                    Label { Text(L.add_add_expense()) } icon: { PhIcon("plus", size: 16, color: c.onInk) }
                        .kFont(.sans(14, .medium))
                        .foregroundStyle(c.onInk)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(c.ink, in: .rect(cornerRadius: 12))
                }
            }
            if medium {
                VStack(spacing: 8) {
                    link(L.add_add_income(), icon: "arrow-down-left", url: "app.getkosha://add?kind=income")
                    if entry.snapshot?.receipts == true {
                        link(L.add_scan_receipt(), icon: "camera", url: "app.getkosha://add?kind=expense&scan=1")
                    }
                    link(L.add_kind_transfer(), icon: "arrows-left-right", url: "app.getkosha://add?kind=transfer")
                }
            }
        }
        .containerBackground(c.bg, for: .widget)
    }

    private func link(_ title: String, icon: String, url: String) -> some View {
        let c = theme.colors
        return Link(destination: URL(string: url)!) {
            HStack(spacing: 8) {
                PhIcon(icon, size: 16)
                Text(title).kFont(.sans(13, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(c.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.line))
        }
    }
}
