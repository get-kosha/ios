import Foundation
import Testing
@testable import Model

// The same cases as the Android app's KeypadTest.kt and DatesTest.kt.

private func type(_ keys: String, decimals: Int = 2) -> String {
    keys.reduce("") { acc, c in
        let key: Keypad.Key = switch c {
        case ".": .dot
        case "<": .delete
        case "+": .op(.add)
        case "-": .op(.subtract)
        case "*": .op(.multiply)
        case "/": .op(.divide)
        default: .digit(c.wholeNumberValue!)
        }
        return Keypad.press(acc, key, decimals: decimals)
    }
}

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Test func digits() {
    #expect(type("12") == "12")
    #expect(type("05") == "5")
    #expect(type("0") == "0")
    #expect(type("00") == "0")
    #expect(type("100") == "100")
    #expect(type("123456789") == "12345678")
}

@Test func decimals() {
    #expect(type(".") == "0.")
    #expect(type("12.5.") == "12.5")
    #expect(type("12.50") == "12.50")
    #expect(type("12.057") == "12.05")
    #expect(type("12.", decimals: 0) == "12")
    #expect(type(".0") == "0.0")
}

@Test func operators() {
    #expect(type("+") == "")
    #expect(type("12-+") == "12+")
    #expect(type("12.*") == "12*")
    #expect(type("24.07+5.5") == "24.07+5.5")
    #expect(type("24.07+.") == "24.07+0.")
    #expect(type("1+00+<") == "1+0")
    #expect(type("12<") == "1")
    #expect(Keypad.pendingOperator("12+") == .add)
    #expect(Keypad.pendingOperator("12+3") == nil)
    #expect(Keypad.press("12+3", .clear) == "")
    #expect(Keypad.press("12+3", .delete) == "12+")
}

@Test func evaluates() {
    #expect(Keypad.evaluate("24.07+5.5") == dec("29.57"))
    #expect(Keypad.evaluate("2+3*4") == dec("14"))
    #expect(Keypad.evaluate("12.50+4") == dec("16.5"))
    #expect(Keypad.evaluate("10/3*3") == dec("10"))
    #expect(Keypad.evaluate("10/3") == dec("3.33"))
    #expect(Keypad.evaluate("12+") == dec("12"))
    #expect(Keypad.evaluate("") == 0)
    #expect(Keypad.evaluate("1199.6", decimals: 0) == dec("1200"))
    #expect(Keypad.evaluate("5/0") == nil)
    #expect(Keypad.evaluate("5/0.0+1") == nil)
}

@Test func minorUnits() {
    #expect(Keypad.minorUnits("24.07+5.5") == 2957)
    // Every currency is stored ×100: ¥1,200 is 120000.
    #expect(Keypad.minorUnits("1200", decimals: 0) == 120_000)
    #expect(Keypad.minorUnits("99999999.99") == 9_999_999_999)
    #expect(Keypad.minorUnits("") == nil)
    #expect(Keypad.minorUnits("5-10") == nil)
    #expect(Keypad.minorUnits("4-4") == nil)
    #expect(Keypad.minorUnits("1/0") == nil)
    #expect(Keypad.minorUnits("99999999*99999999*99999999") == nil)
    #expect(Keypad.minorUnits("99999999*99999999") == nil)
    #expect(Keypad.evaluate(Array(repeating: "99999999", count: 30).joined(separator: "*")) == nil)
}

@Test func display() {
    #expect(Keypad.group("1204.5") == "1,204.5")
    #expect(Keypad.group("") == "0")
    #expect(Keypad.group("1204.5", grouping: ".", decimal: ",") == "1.204,5")
    #expect(Keypad.pretty("24.07+5.50") == "24.07 + 5.50")
    #expect(Keypad.pretty("1000*3/2-1+") == "1,000 × 3 ÷ 2 − 1 +")
}

@Test func money() {
    let uk = Money.locale("en")
    let de = Locale(identifier: "de_DE")
    #expect(Money.format(-2957, "eur", uk) == "−€29.57")
    #expect(Money.format(324_000, "EUR", uk, sign: .always) == "+€3,240.00")
    #expect(Money.format(-20000, "eur", uk, sign: .none) == "€200.00")
    // CLDR British English writes yen as JP¥, like the web's Intl.NumberFormat.
    #expect(Money.format(120_000, "jpy", uk) == "JP¥1,200")
    #expect(Money.decimals("jpy") == 0)
    #expect(Money.format(-131_240, "eur", de) == "−1.312,40\u{a0}€")
    #expect(Money.separators(de) == (".", ","))
    #expect(Money.affixes("eur", uk) == ("€", ""))
    #expect(Money.affixes("eur", de) == ("", "\u{a0}€"))
}

@Test func datesInTheUsersZone() {
    // 23:30 UTC on 31 Oct is already 1 Nov in Berlin: days follow the user's zone, not the phone's.
    let now = ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z")!
    #expect(Dates.month("UTC", now: now) == Month(2026, 10))
    #expect(Dates.month("Europe/Berlin", now: now) == Month(2026, 11))
    #expect(Dates.today("Europe/Berlin", now: now) == Day(2026, 11, 1))
    #expect(Dates.month("Not/AZone", now: now) == Month(2026, 10))
}

@Test func datesParse() {
    #expect(Month("2026-11") == Month(2026, 11))
    #expect(Day("2026-11-07") == Day(2026, 11, 7))
    #expect(Day(2026, 11, 7).text == "2026-11-07")
    #expect(Month(2026, 2).last == Day(2026, 2, 28))
    #expect(Day(2026, 11, 5).weekday == 5) // a Thursday
}

@Test func tags() {
    #expect(cleanTag("#Trip!") == "trip")
    #expect(parseTags("#trip, food rome trip") == ["trip", "food", "rome"])
}
