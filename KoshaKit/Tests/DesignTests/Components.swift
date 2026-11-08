import Foundation
import SwiftUI
import Testing
import Model
@testable import Design

struct DesignContracts {
    @Test func selectionAcrossThemes() {
        let accents: [(Accent, UInt32, UInt32)] = [
            (.teal, 0x0F766E, 0x2DD4BF), (.blue, 0x2563EB, 0x60A5FA),
            (.amber, 0xB45309, 0xFBBF24), (.rose, 0xBE123C, 0xFB7185),
            (.graphite, 0x27272A, 0xE4E4E7),
        ]
        for dark in [false, true] {
            for (accent, light, night) in accents {
                #expect(KColors.of(dark: dark, accent: accent).brand == Color(hex: dark ? night : light))
                for neutral in [false, true] {
                    let colors = KColors.of(dark: dark, accent: accent, neutral: neutral)
                    #expect(colors.selection == (neutral ? colors.ink : colors.brand))
                    #expect(colors.onSelection == (neutral ? colors.onInk : colors.onBrand))
                    #expect(colors.accountColours == !neutral)
                    #expect(colors.account(-1) == colors.series[5])
                    #expect(colors.account(6) == colors.series[0])
                }
            }
        }
        #expect(KColors.of(dark: false).bg == Color(hex: 0xF6F6F4))
        #expect(KColors.of(dark: true).bg == Color(hex: 0x0B0B0C))
    }

    @Test func figureTracking() {
        let mono = KTheme()
        let proportional = KTheme(figures: .proportional)
        #expect(KFont.num.tracking(mono) == -0.3)
        #expect(KFont.num.tracking(proportional) == -0.15)
        #expect(KFont.key.tracking(proportional) == -0.28)
        #expect(KFont.amount.tracking(proportional) == -2.4)
        #expect(KFont.hero.tracking(mono).isApproximately(-1.4))
        #expect(KFont.caption.tracking(KTheme(language: "hi")) == 0)
    }

    @Test func amountStates() {
        let locale = Money.locale("en")
        #expect(amountText("", currency: "eur", kind: .expense, locale: locale) == "€0")
        #expect(amountText("1204.5", currency: "eur", kind: .expense, locale: locale) == "−€1,204.5")
        #expect(amountText("12.50+4", currency: "eur", kind: .income, locale: locale) == "+€16.50")
        #expect(amountText("1-4", currency: "eur", kind: .transfer, locale: locale) == "−€3.00")
        #expect(amountText("4-4", currency: "eur", kind: .expense, locale: locale) == "€0")
        #expect(amountText("4/0", currency: "eur", kind: .expense, locale: locale) == "…")
        #expect(amountText("12+3", currency: "jpy", kind: .transfer, locale: locale) == Money.format(1_500, "jpy", locale))
        #expect(amountText("1204.5", currency: "eur", kind: .expense, locale: Money.locale("de")) == "−1.204,5 €")
    }

    @Test func datesFollowLanguage() {
        #expect(!DayFormat.uses12Hour(Money.locale("en")))
        #expect(DayFormat.uses12Hour(Locale(identifier: "en_US")))
        #expect(!DayFormat.uses12Hour(Money.locale("de")))
        #expect(DayFormat.label(Day(2026, 11, 5), today: Day(2026, 11, 7), Money.locale("en")) == "Thu 5")
        #expect(DayFormat.label(Day(2025, 11, 5), today: Day(2026, 11, 7), Money.locale("en")).contains("2025"))
        #expect(DayFormat.time("25:00", Money.locale("en")) == "25:00")
    }

    @MainActor @Test func wheelBounds() {
        #expect(Wheel.adjusted(59, by: 1, count: 60, loop: true) == 0)
        #expect(Wheel.adjusted(0, by: -1, count: 60, loop: true) == 59)
        #expect(Wheel.adjusted(1, by: 1, count: 2, loop: false) == 1)
        #expect(Wheel.adjusted(0, by: -1, count: 2, loop: false) == 0)
    }

    @MainActor @Test func viewClosuresAreNotActions() {
        let header = SheetHeader("Month") { Text("This month") }
        let chip = Chip("Today") { PhIcon("calendar-blank") }
        #expect(type(of: header) == SheetHeader<Text>.self)
        #expect(type(of: chip) == Chip<PhIcon>.self)
        var tapped = false
        let actionChip = Chip("Today") { tapped = true }
        #expect(actionChip.action != nil)
        actionChip.action?()
        #expect(tapped)
    }

    @Test func iconsUsePhosphor() {
        #expect(categoryIconName("ph:coffee") == "coffee")
        #expect(categoryIconName("☕️") == "coffee")
        #expect(categoryIconName("ph:missing") == "tag")
        #expect(PhosphorCodes.has("backspace"))
        #expect(PhosphorCodes.has("sparkle"))
    }

    @MainActor @Test func labelsWrapAtLargeText() throws {
        let categories = [CategoryTile(id: "one", icon: "coffee", label: "A long category name that must wrap")]
        let normal = CategoryGrid(categories, picked: "one") { _ in }
            .koshaTheme().environment(\.dynamicTypeSize, .large).frame(width: 358)
        let large = CategoryGrid(categories, picked: "one") { _ in }
            .koshaTheme().environment(\.dynamicTypeSize, .accessibility5).frame(width: 358)
        let normalImage = try #require(ImageRenderer(content: normal).cgImage)
        let largeImage = try #require(ImageRenderer(content: large).cgImage)
        #expect(normalImage.width == 358)
        #expect(largeImage.width == 358)
        #expect(largeImage.height > normalImage.height)

        let field = KField("Payee", text: .constant("Bonanza Coffee"))
            .koshaTheme().environment(\.dynamicTypeSize, .accessibility5).frame(width: 358)
        // AppKit does not apply iOS Dynamic Type to native text fields in ImageRenderer.
        #expect(try #require(ImageRenderer(content: field).cgImage).height >= 48)

        let amount = AmountDisplay(input: "99999999.99+1", currency: "eur", kind: .expense)
            .koshaTheme().environment(\.dynamicTypeSize, .accessibility5).frame(width: 320)
        #expect(try #require(ImageRenderer(content: amount).cgImage).width == 320)
    }
}

private extension CGFloat {
    func isApproximately(_ other: CGFloat) -> Bool { abs(self - other) < 0.0001 }
}
