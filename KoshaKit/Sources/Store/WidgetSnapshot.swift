import Foundation
import Model

/// What the home-screen widget shows, written by the app after each refresh into the app group's cache. The widget
/// never calls the server: it reads this, so it works offline and costs no requests.
public struct WidgetSnapshot: Codable, Sendable {
    public var month: String
    public var currency: String
    /// Money spent so far this month, positive, in `currency`.
    public var spending: Int64
    public var language: String
    public var hideAmounts: Bool
    /// Receipt scanning is on (AI), so the widget may offer it; off, it leaves no trace.
    public var receipts: Bool
    public var updated: Date

    public init(month: String, currency: String, spending: Int64, language: String, hideAmounts: Bool, receipts: Bool, updated: Date = Date()) {
        self.month = month
        self.currency = currency
        self.spending = spending
        self.language = language
        self.hideAmounts = hideAmounts
        self.receipts = receipts
        self.updated = updated
    }

    public static let key = "widget"
    public static func read() -> WidgetSnapshot? { Cache().read(key) }
}

/// The month report's figures the widget needs (get_month_overview).
struct MonthFigures: Codable, Sendable {
    var month: String
    var currency: String
    @Rounded var spending: Int64
}

extension Kosha {
    /// Writes the widget's snapshot from this month's report. Called after a refresh; offline it keeps the last one.
    public func updateWidget(language: String) async {
        guard signedIn else { return }
        let version = sessionVersion
        let month = Dates.month(tz).text
        guard let r: MonthFigures = try? await api.get("/api/v1/reports/month", query: ["month": month, "currency": primary])
        else { return }
        guard signedIn, sessionVersion == version else { return }
        cache.write(WidgetSnapshot.key, WidgetSnapshot(
            month: r.month, currency: r.currency, spending: r.spending, language: language,
            hideAmounts: meta?.pref("hide_amounts", "0") == "1", receipts: meta?.aiFlags.receipts ?? false
        ))
        widgetChanged?()
    }
}
