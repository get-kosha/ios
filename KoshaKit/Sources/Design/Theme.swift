import SwiftUI
import Model

// Every colour, size and type style Kosha uses. Values come from ../kosha-android/design/source/k.css; CSS px are
// used as points 1:1.

public enum Accent: String, CaseIterable, Sendable, Codable { case teal, blue, amber, rose, graphite }

public enum Density: String, CaseIterable, Sendable, Codable { case comfortable, compact }

/// Settings › Appearance › Number font: Geist Mono, or Geist with tabular figures.
public enum Figures: String, CaseIterable, Sendable, Codable { case mono, proportional }

/// Settings › Appearance › Animations. The system's Reduce Motion counts as reduced.
public enum Motion: String, CaseIterable, Sendable, Codable { case on, reduced, off }

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

public struct KColors: Sendable {
    public var bg, surface, soft, sel, line, ink, ink2, ink3, onInk, pos, warn, bad, brand, onBrand, bar, bar2,
        scrim, glass: Color
    /// Account colours, s1 to s6, given out in account order.
    public var series: [Color]
    public var dark: Bool
    /// Account colours off: selections take ink instead of the accent, and account squares hide.
    public var neutral: Bool

    /// What a picked tile, day, radio or tab takes.
    public var selection: Color { neutral ? ink : brand }
    public var onSelection: Color { neutral ? onInk : onBrand }
    public var accountColours: Bool { !neutral }

    /// The colour of the account at this position in the user's account order.
    public func account(_ index: Int) -> Color { series[((index % series.count) + series.count) % series.count] }

    public static func of(dark: Bool, accent: Accent = .teal, neutral: Bool = false) -> KColors {
        var c = dark ? darkColors : lightColors
        c.brand = accentColor(accent, dark: dark)
        c.neutral = neutral
        return c
    }

    static func accentColor(_ accent: Accent, dark: Bool) -> Color {
        switch accent {
        case .teal: Color(hex: dark ? 0x2DD4BF : 0x0F766E)
        case .blue: Color(hex: dark ? 0x60A5FA : 0x2563EB)
        case .amber: Color(hex: dark ? 0xFBBF24 : 0xB45309)
        case .rose: Color(hex: dark ? 0xFB7185 : 0xBE123C)
        case .graphite: Color(hex: dark ? 0xE4E4E7 : 0x27272A)
        }
    }

    static let lightColors = KColors(
        bg: Color(hex: 0xF6F6F4), surface: Color(hex: 0xFFFFFF), soft: Color(hex: 0xF0F0ED), sel: Color(hex: 0xEBEBE7),
        line: Color(hex: 0xE4E4E0), ink: Color(hex: 0x111113), ink2: Color(hex: 0x46464D), ink3: Color(hex: 0x6B6B73),
        onInk: Color(hex: 0xF6F6F4), pos: Color(hex: 0x0F766E), warn: Color(hex: 0xB45309), bad: Color(hex: 0xB42318),
        brand: Color(hex: 0x0F766E), onBrand: Color(hex: 0xFFFFFF), bar: Color(hex: 0x1C1C1F), bar2: Color(hex: 0xCFCFCA),
        scrim: Color(hex: 0x111113, alpha: 0.34), glass: Color(hex: 0xFFFFFF, alpha: 0.94),
        series: [0x2A78D6, 0xE87BA4, 0xEDA100, 0x6250D6, 0xEB6834, 0x1BAF7A].map { Color(hex: $0) },
        dark: false, neutral: false
    )

    static let darkColors = KColors(
        bg: Color(hex: 0x0B0B0C), surface: Color(hex: 0x131315), soft: Color(hex: 0x1C1C1F), sel: Color(hex: 0x232327),
        line: Color(hex: 0x27272B), ink: Color(hex: 0xF3F3F4), ink2: Color(hex: 0xBDBDC4), ink3: Color(hex: 0x90909A),
        onInk: Color(hex: 0x0B0B0C), pos: Color(hex: 0x2DD4BF), warn: Color(hex: 0xF59E0B), bad: Color(hex: 0xF87171),
        brand: Color(hex: 0x2DD4BF), onBrand: Color(hex: 0x0B0B0C), bar: Color(hex: 0xECECEE), bar2: Color(hex: 0x3B3B41),
        scrim: Color(hex: 0x000000, alpha: 0.55), glass: Color(hex: 0x131315, alpha: 0.94),
        series: [0x3987E5, 0xD55181, 0xC98500, 0x9085E9, 0xD95926, 0x199E70].map { Color(hex: $0) },
        dark: true, neutral: false
    )
}

/// Brand colours: only on Launch, the sign-in panel and the app icon.
public enum Brand {
    public static let peacock = Color(hex: 0x0F524E)
    public static let marigold = Color(hex: 0xF4A62A)
    public static let paper = Color(hex: 0xF3F5F0)
}

/// Sizes that change with Settings › Appearance › Density. Compact rows never go below the 44pt touch target.
public struct KDims: Sendable {
    public var row: CGFloat, settingsRow: CGFloat, cardPadding: CGFloat

    public static func of(_ density: Density) -> KDims {
        switch density {
        case .comfortable: KDims(row: 52, settingsRow: 56, cardPadding: 16)
        case .compact: KDims(row: 48, settingsRow: 48, cardPadding: 14)
        }
    }
}

/// Everything a view needs to draw itself the Kosha way, from the environment (`@Environment(\.kosha)`).
public struct KTheme: Sendable {
    public var colors: KColors
    public var figures: Figures
    public var dims: KDims
    /// The app's language as a locale: how money, dates and numbers are written.
    public var locale: Locale
    public var motion: Motion
    /// Settings › Appearance › Hide amounts.
    public var hideAmounts: Bool

    public init(
        dark: Bool = false, accent: Accent = .teal, neutral: Bool = false, density: Density = .comfortable,
        figures: Figures = .mono, language: String = "en", motion: Motion = .on, hideAmounts: Bool = false
    ) {
        colors = .of(dark: dark, accent: accent, neutral: neutral)
        self.figures = figures
        dims = .of(density)
        locale = Money.locale(language)
        self.motion = motion
        self.hideAmounts = hideAmounts
    }

    /// An animation that follows Settings › Animations: none when off, a short fade when reduced.
    public func animation(_ full: Animation = .snappy(duration: 0.25)) -> Animation? {
        switch motion {
        case .on: full
        case .reduced: .easeInOut(duration: 0.15)
        case .off: nil
        }
    }
}

private struct KThemeKey: EnvironmentKey {
    static let defaultValue = KTheme()
}

extension EnvironmentValues {
    public var kosha: KTheme {
        get { self[KThemeKey.self] }
        set { self[KThemeKey.self] = newValue }
    }
}

/// The theme settings a screen tree draws with. The colour scheme comes from the system or Settings › Theme.
public struct ThemeSettings: Equatable, Sendable {
    public var accent: Accent = .teal
    public var neutral = false
    public var density: Density = .comfortable
    public var figures: Figures = .mono
    public var language = "en"
    public var motion: Motion = .on
    public var hideAmounts = false

    public init(
        accent: Accent = .teal, neutral: Bool = false, density: Density = .comfortable, figures: Figures = .mono,
        language: String = "en", motion: Motion = .on, hideAmounts: Bool = false
    ) {
        self.accent = accent
        self.neutral = neutral
        self.density = density
        self.figures = figures
        self.language = language
        self.motion = motion
        self.hideAmounts = hideAmounts
    }
}

private struct KoshaThemed: ViewModifier {
    let settings: ThemeSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let motion: Motion = reduceMotion && settings.motion == .on ? .reduced : settings.motion
        let theme = KTheme(
            dark: scheme == .dark, accent: settings.accent, neutral: settings.neutral, density: settings.density,
            figures: settings.figures, language: settings.language, motion: motion, hideAmounts: settings.hideAmounts
        )
        content
            .environment(\.kosha, theme)
            .environment(\.locale, theme.locale)
            .tint(theme.colors.selection)
            .font(KFont.body.font(theme))
            .foregroundStyle(theme.colors.ink)
    }
}

extension View {
    /// Draws this tree with Kosha's tokens for the current colour scheme.
    public func koshaTheme(_ settings: ThemeSettings = ThemeSettings()) -> some View {
        Fonts.register()
        return modifier(KoshaThemed(settings: settings))
    }
}
