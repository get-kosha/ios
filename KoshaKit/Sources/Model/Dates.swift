import Foundation

/// A calendar day as Kosha stores it, "YYYY-MM-DD", in the user's time zone from settings (core.ts dayOf).
public struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ text: String) {
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        self.init(p[0], p[1], p[2])
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var text: String { description }
    public var monthOf: Month { Month(year, month) }

    public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    /// Calendar maths happens in UTC on the day itself, so a time zone's offset never moves it.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Noon UTC of this day, for calendar maths and for formatting as a date with a UTC formatter.
    public var date: Date { Day.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }

    public init(date: Date) {
        let c = Day.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(c.year!, c.month!, c.day!)
    }

    public func adding(days: Int) -> Day { Day(date: Day.calendar.date(byAdding: .day, value: days, to: date)!) }
    public func adding(months: Int) -> Day { Day(date: Day.calendar.date(byAdding: .month, value: months, to: date)!) }
    public func adding(years: Int) -> Day { Day(date: Day.calendar.date(byAdding: .year, value: years, to: date)!) }

    /// 1 is Sunday … 7 is Saturday, as Calendar counts.
    public var weekday: Int { Day.calendar.component(.weekday, from: date) }

    public func days(to other: Day) -> Int { Day.calendar.dateComponents([.day], from: date, to: other.date).day! }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a day: \(text)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// A month as Kosha stores it, "YYYY-MM", in the user's time zone (core.ts monthOf).
public struct Month: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int, month: Int

    public init(_ year: Int, _ month: Int) {
        self.year = year
        self.month = month
    }

    public init?(_ text: String) {
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2, (1...12).contains(p[1]) else { return nil }
        self.init(p[0], p[1])
    }

    public var description: String { String(format: "%04d-%02d", year, month) }
    public var text: String { description }
    public var first: Day { Day(year, month, 1) }
    public var last: Day { first.adding(months: 1).adding(days: -1) }
    public var dayCount: Int { last.day }

    public func adding(_ months: Int) -> Month { first.adding(months: months).monthOf }

    public static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let m = Month(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a month: \(text)"))
        }
        self = m
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// Days and months in the user's time zone from settings, never the phone's (core.ts dayOf, monthOf).
public enum Dates {
    static func zone(_ tz: String) -> TimeZone { TimeZone(identifier: tz) ?? TimeZone(identifier: "UTC")! }

    public static func today(_ tz: String, now: Date = Date()) -> Day {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone(tz)
        let p = c.dateComponents([.year, .month, .day], from: now)
        return Day(p.year!, p.month!, p.day!)
    }

    public static func month(_ tz: String, now: Date = Date()) -> Month { today(tz, now: now).monthOf }

    /// "HH:mm", 24-hour, as the API writes times.
    public static func time(_ tz: String, now: Date = Date()) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone(tz)
        let p = c.dateComponents([.hour, .minute], from: now)
        return String(format: "%02d:%02d", p.hour!, p.minute!)
    }
}
