import SwiftUI
import CoreText

/// Registers Geist, Geist Mono and Phosphor from the package once, so `Font.custom` finds them in the app, its
/// widgets and previews alike.
public enum Fonts {
    private static let once: Void = {
        let urls = ["geist_regular", "geist_medium", "geist_semibold", "geist_mono_regular", "geist_mono_medium",
                    "phosphor", "phosphor_fill"]
            .compactMap { Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: $0, withExtension: "ttf") }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }()

    public static func register() { _ = once }
}

public enum Weight: Sendable { case regular, medium, semibold }

/// Kosha's type scale (k.css). Figures (`num`, `amount`, `key`, `expr`) follow Settings › Appearance › Number font.
/// Every style scales with Dynamic Type, relative to the closest system style.
public enum KFont: Sendable {
    /// Big money: 40/600, tabular; cents in ink3.
    case hero
    case page, title, sheetTitle, head, body, small, xs
    /// Uppercase section captions in ink3.
    case caption
    case button
    /// Figures in lists and cards.
    case num
    /// The amount on Add: 60, or 46 for long amounts (`amountLong`).
    case amount, amountLong
    /// The keypad's digits.
    case key
    /// The expression above the amount.
    case expr
    /// Anything else: Geist at a size and weight.
    case sans(CGFloat, Weight)
    /// A figure at a size and weight.
    case figure(CGFloat, Weight)

    var spec: (size: CGFloat, weight: Weight, figure: Bool, tracking: CGFloat, style: Font.TextStyle) {
        switch self {
        case .hero: (40, .semibold, false, -0.035, .largeTitle)
        case .page: (34, .semibold, false, -0.03, .largeTitle)
        case .title: (22, .semibold, false, -0.02, .title2)
        case .sheetTitle: (17, .semibold, false, -0.01, .headline)
        case .head: (15, .medium, false, 0, .body)
        case .body: (15, .regular, false, 0, .body)
        case .small: (13, .regular, false, 0, .footnote)
        case .xs: (12, .regular, false, 0, .caption)
        case .caption: (12, .medium, false, 0.06, .caption)
        case .button: (16, .medium, false, 0, .body)
        case .num: (15, .regular, true, -0.02, .body)
        case .amount: (60, .medium, true, -0.04, .largeTitle)
        case .amountLong: (46, .medium, true, -0.04, .largeTitle)
        case .key: (28, .regular, true, -0.02, .title)
        case .expr: (16, .regular, true, -0.01, .callout)
        case .sans(let s, let w): (s, w, false, 0, s >= 20 ? .title2 : .body)
        case .figure(let s, let w): (s, w, true, -0.02, s >= 20 ? .title2 : .body)
        }
    }

    public func font(_ theme: KTheme) -> Font {
        let s = spec
        let mono = s.figure && theme.figures == .mono
        let name: String
        switch (mono, s.weight) {
        case (true, .regular): name = "GeistMono-Regular"
        case (true, _): name = "GeistMono-Medium"
        case (false, .regular): name = "Geist-Regular"
        case (false, .medium): name = "Geist-Medium"
        case (false, .semibold): name = "Geist-SemiBold"
        }
        let font = Font.custom(name, size: s.size, relativeTo: s.style)
        // Proportional figures and the hero keep columns of numbers aligned with tabular digits.
        return s.figure || self == .hero ? font.monospacedDigit() : font
    }

    public func tracking(_ theme: KTheme) -> CGFloat {
        // Devanagari breaks with tight tracking.
        theme.locale.language.languageCode?.identifier == "hi" ? 0 : spec.size * spec.tracking
    }

    static func == (a: KFont, b: KFont) -> Bool { "\(a)" == "\(b)" }
}

private struct KStyle: ViewModifier {
    let font: KFont
    @Environment(\.kosha) private var theme

    func body(content: Content) -> some View {
        let text = content.font(font.font(theme)).tracking(font.tracking(theme))
        if case .caption = font { text.textCase(.uppercase) } else { text }
    }
}

extension View {
    /// Sets a Kosha type style: font, tracking and, for captions, upper case.
    public func kFont(_ font: KFont) -> some View { modifier(KStyle(font: font)) }
}
