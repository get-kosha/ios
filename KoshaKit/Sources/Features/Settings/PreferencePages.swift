import SwiftUI
import Model
import API
import Store
import Design

// General, Appearance and Recurring: preferences that save as they change.

/// General: language, time zone, round amounts, and what Add starts with.
struct GeneralPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var sheet: Pick?

    enum Pick: String, Identifiable {
        case language, zone, wallet
        var id: String { rawValue }
    }

    var body: some View {
        let m = kosha.meta
        let w = Writer(kosha: kosha, toasts: toasts)
        let language = L.resolve(m?.prefs["language"]?.string)
        let walletPref = m.prefOf("default_wallet")
        let full = Money.format(143_600, kosha.primary, theme.locale)
        Page(L.settings_section_general()) {
            GroupCaption(L.settings_general_region())
            Rows {
                NavRow(L.settings_row_language(), description: L.settings_general_language_desc(), value: languageName(language)) {
                    sheet = .language
                }
                Hairline()
                NavRow(L.settings_row_time_zone(), description: L.settings_general_time_zone_desc(), value: zoneCity(kosha.tz)) {
                    sheet = .zone
                }
            }
            GroupCaption(L.settings_general_month())
            Rows {
                SettingsSwitchRow(L.settings_row_round_amounts(),
                          description: L.settings_general_round_desc(rounded: wholeMoney(143_600, kosha.primary, theme.locale), full: full),
                          isOn: prefBinding(kosha, w, "round_hero"))
            }
            GroupCaption(L.settings_general_adding())
            Rows {
                NavRow(L.settings_row_default_account(), description: L.settings_general_default_account_desc(),
                       value: kosha.activeWallets.first { $0.id == walletPref }?.name ?? L.settings_general_last_used()) {
                    sheet = .wallet
                }
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.settings_row_add_kind()).kFont(.head)
                    Text(L.settings_general_add_kind_desc()).kFont(.small).foregroundStyle(theme.colors.ink3)
                    Segmented([("expense", L.settings_general_expense()), ("income", L.settings_general_income())],
                              selection: Binding(get: { m.prefOf("add_kind") }, set: { w.pref("add_kind", $0) }), small: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Hairline()
                SettingsSwitchRow(L.settings_row_suggest_category(), description: L.settings_general_suggest_desc(),
                          isOn: prefBinding(kosha, w, "suggest_category"))
            }
        }
        .kSheet(item: $sheet, scrolls: true) { s in
            switch s {
            case .language:
                ListPicker(L.settings_row_language(), choices: L.languages.map { Choice(id: $0, title: languageName($0)) },
                           selected: language, onPick: { code in
                               sheet = nil
                               w.pref("language", code)
                           }, onClose: { sheet = nil })
            case .zone:
                ListPicker(L.settings_row_time_zone(), choices: zoneChoices(), selected: kosha.tz, onPick: { zone in
                    sheet = nil
                    w.send("PATCH", "/api/v1/settings", .object(["timeZone": .string(zone)]))
                }, onClose: { sheet = nil })
            case .wallet:
                ListPicker(L.settings_row_default_account(),
                           choices: [Choice(id: "last", title: L.settings_general_last_used())]
                               + kosha.activeWallets.map { Choice(id: $0.id, title: $0.name, detail: $0.currency.uppercased()) },
                           selected: walletPref, onPick: { id in
                               sheet = nil
                               w.pref("default_wallet", id)
                           }, onClose: { sheet = nil })
            }
        }
    }
}

/// Appearance: a live preview, then theme, accent, density, account colours, number font, hide amounts, animations.
struct AppearancePage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let m = kosha.meta
        let w = Writer(kosha: kosha, toasts: toasts)
        let primary = kosha.primary
        let pick = { (key: String) in Binding(get: { m.prefOf(key) }, set: { w.pref(key, $0) }) }
        Page(L.settings_section_appearance()) {
            Card {
                HStack {
                    Text(L.settings_appearance_preview()).kFont(.small).foregroundStyle(c.ink3)
                    Spacer()
                    Text(L.settings_appearance_preview_hint()).kFont(.xs).foregroundStyle(c.ink3)
                }
                HStack {
                    Text(L.settings_appearance_net_worth())
                    Spacer()
                    MoneyText(2_829_692, primary)
                }
                HStack(spacing: 10) {
                    AccountDot(c.account(0))
                    Text(L.settings_appearance_salary()).frame(maxWidth: .infinity, alignment: .leading)
                    MoneyText(324_000, primary, sign: .always, color: c.pos)
                    KSwitch(L.settings_appearance_sample(), isOn: .constant(true)).allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain)

            GroupCaption(L.settings_appearance_look())
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    ChoiceRow(title: L.settings_row_theme(), description: L.settings_appearance_theme_desc(),
                              options: [("light", L.settings_appearance_light()), ("dark", L.settings_appearance_dark()),
                                        ("system", L.settings_appearance_system())], selection: pick("theme"))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.settings_row_accent()).kFont(.head)
                        AccentPicker(selected: m.prefOf("accent")) { w.pref("accent", $0) }
                        Text(L.settings_appearance_accent_desc()).kFont(.xs).foregroundStyle(c.ink3)
                    }
                    ChoiceRow(title: L.settings_row_density(), description: L.settings_appearance_density_desc(),
                              options: [("comfortable", L.settings_appearance_comfortable()), ("compact", L.settings_appearance_compact())],
                              selection: pick("density"))
                    InlineSwitch(title: L.app_set_account_colours(), description: L.app_set_account_colours_desc(),
                                 isOn: prefBinding(kosha, w, "account_colours"))
                }
            }

            GroupCaption(L.settings_appearance_behaviour())
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    ChoiceRow(title: L.settings_row_number_font(), description: L.settings_appearance_figures_desc(),
                              options: [("mono", L.settings_appearance_mono()), ("proportional", L.settings_appearance_proportional())],
                              selection: pick("figures"))
                    InlineSwitch(title: L.settings_row_hide_amounts(), description: L.app_set_hide_desc(),
                                 isOn: prefBinding(kosha, w, "hide_amounts"))
                    ChoiceRow(title: L.settings_row_animations(), description: L.settings_appearance_motion_desc(),
                              options: [("on", L.settings_appearance_on()), ("reduced", L.settings_appearance_reduced()),
                                        ("off", L.settings_appearance_off())], selection: pick("motion"))
                }
            }
        }
    }
}

/// The five accents as swatches in their own colour for the current theme, the picked one ringed.
private struct AccentPicker: View {
    let selected: String
    let onPick: (String) -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Accent.allCases, id: \.self) { accent in
                let on = accent.rawValue == selected
                let color = KColors.of(dark: theme.colors.dark, accent: accent).brand
                Button { onPick(accent.rawValue) } label: {
                    Circle().fill(color).frame(width: 24, height: 24)
                        .padding(3)
                        .overlay { if on { Circle().strokeBorder(color, lineWidth: 1.5) } }
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(accentName(accent))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func accentName(_ a: Accent) -> String {
        switch a {
        case .teal: L.settings_appearance_teal()
        case .blue: L.settings_appearance_blue()
        case .amber: L.settings_appearance_amber()
        case .rose: L.settings_appearance_rose()
        case .graphite: L.settings_appearance_graphite()
        }
    }
}

/// Recurring: record payments automatically by default, and how far ahead Coming up looks.
struct RecurringDefaultsPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme

    var body: some View {
        let m = kosha.meta
        let w = Writer(kosha: kosha, toasts: toasts)
        Page(L.settings_section_recurring()) {
            GroupCaption(L.settings_rec_group())
            Rows {
                SettingsSwitchRow(L.settings_rec_auto_title(), description: L.settings_rec_auto_description(),
                          isOn: prefBinding(kosha, w, "default_auto_pay"))
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.settings_rec_coming_up_title()).kFont(.head)
                    Text(L.settings_rec_coming_up_description()).kFont(.small).foregroundStyle(theme.colors.ink3)
                }
                Segmented([("month", L.settings_rec_until_month_end()), ("30d", L.settings_rec_next_30_days())],
                          selection: Binding(get: { m.prefOf("upcoming_horizon") }, set: { w.pref("upcoming_horizon", $0) }),
                          small: true)
            }
        }
    }
}
