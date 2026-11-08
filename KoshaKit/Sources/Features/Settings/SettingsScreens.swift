import SwiftUI
import Model
import API
import Store
import Design

/// Settings. `page` picks the section (see `Route.settings`); "" is the list.
struct SettingsScreen: View {
    let page: String
    let id: String?

    var body: some View {
        switch page {
        case "profile": ProfilePage()
        case "security": SecurityPage()
        case "general": GeneralPage()
        case "appearance": AppearancePage()
        case "currencies": CurrenciesPage()
        case "categories": CategoriesPage()
        case "category": CategoryEditPage(routeId: id ?? "new")
        case "events": EventsPage()
        case "rules": RulesPage()
        case "recurring": RecurringDefaultsPage()
        case "ai": AiSettingsPage()
        case "ai-provider": AiProviderPage(id: id ?? "anthropic")
        case "ai-privacy": AiPrivacyPage()
        case "ai-log": AiLogPage()
        case "data": DataExportPage()
        case "api": ApiMcpPage()
        case "delete": DeleteResetPage()
        default: SettingsList()
        }
    }
}

/// One searchable row of a section (registry.tsx): its title, description and extra search words.
private struct Searchable {
    let title: String, description: String, keywords: String
}

private struct Section {
    let page: String, title: String, icon: String, rows: [Searchable]
}

private func s(_ t: String, _ d: String, _ k: String) -> Searchable { Searchable(title: t, description: d, keywords: k) }

/// The sections in the list's order, with the rows search finds (registry.tsx GROUPS; page width is web-only).
@MainActor private func groups() -> [(String, [Section])] {
    [
        (L.settings_group_you(), [
            Section(page: "profile", title: L.settings_section_profile(), icon: "user", rows: [
                s(L.settings_row_photo(), L.settings_row_photo_desc(), L.settings_row_photo_kw()),
                s(L.settings_row_name(), L.settings_row_name_desc(), L.settings_row_name_kw()),
                s(L.settings_row_email(), L.settings_row_email_desc(), L.settings_row_email_kw()),
            ]),
            Section(page: "security", title: L.settings_section_security(), icon: "shield-check", rows: [
                s(L.settings_row_password(), L.settings_row_password_desc(), L.settings_row_password_kw()),
                s(L.settings_row_passkeys(), L.settings_row_passkeys_desc(), L.settings_row_passkeys_kw()),
                s(L.settings_row_google(), L.settings_row_google_desc(), L.settings_row_google_kw()),
                s(L.settings_row_two_factor(), L.settings_row_two_factor_desc(), L.settings_row_two_factor_kw()),
                s(L.settings_row_devices(), L.settings_row_devices_desc(), L.settings_row_devices_kw()),
                s(L.app_set_unlock(), L.app_set_unlock_desc(), L.app_set_unlock_kw()),
            ]),
        ]),
        (L.settings_group_preferences(), [
            Section(page: "general", title: L.settings_section_general(), icon: "sliders-horizontal", rows: [
                s(L.settings_row_language(), L.settings_row_language_desc(), L.settings_row_language_kw()),
                s(L.settings_row_time_zone(), L.settings_row_time_zone_desc(), L.settings_row_time_zone_kw()),
                s(L.settings_row_round_amounts(), L.settings_row_round_amounts_desc(), L.settings_row_round_amounts_kw()),
                s(L.settings_row_default_account(), L.settings_row_default_account_desc(), L.settings_row_default_account_kw()),
                s(L.settings_row_add_kind(), L.settings_row_add_kind_desc(), L.settings_row_add_kind_kw()),
                s(L.settings_row_suggest_category(), L.settings_row_suggest_category_desc(), L.settings_row_suggest_category_kw()),
            ]),
            Section(page: "appearance", title: L.settings_section_appearance(), icon: "paint-brush", rows: [
                s(L.settings_row_theme(), L.settings_row_theme_desc(), L.settings_row_theme_kw()),
                s(L.settings_row_accent(), L.settings_row_accent_desc(), L.settings_row_accent_kw()),
                s(L.settings_row_density(), L.settings_row_density_desc(), L.settings_row_density_kw()),
                s(L.settings_row_number_font(), L.settings_row_number_font_desc(), L.settings_row_number_font_kw()),
                s(L.settings_row_hide_amounts(), L.settings_row_hide_amounts_desc(), L.settings_row_hide_amounts_kw()),
                s(L.settings_row_animations(), L.settings_row_animations_desc(), L.settings_row_animations_kw()),
            ]),
        ]),
        (L.settings_group_money(), [
            Section(page: "currencies", title: L.settings_section_currencies(), icon: "currency-circle-dollar", rows: [
                s(L.settings_row_currencies(), L.settings_row_currencies_desc(), L.settings_row_currencies_kw()),
                s(L.settings_row_rates_source(), L.settings_row_rates_source_desc(), L.settings_row_rates_source_kw()),
            ]),
            Section(page: "categories", title: L.settings_section_categories(), icon: "tag", rows: [
                s(L.settings_row_categories(), L.settings_row_categories_desc(), L.settings_row_categories_kw()),
            ]),
            Section(page: "events", title: L.settings_section_events(), icon: "calendar-star", rows: [
                s(L.settings_row_events(), L.settings_row_events_desc(), L.settings_row_events_kw()),
            ]),
            Section(page: "rules", title: L.settings_section_rules(), icon: "funnel", rows: [
                s(L.settings_row_learn_rules(), L.settings_row_learn_rules_desc(), L.settings_row_learn_rules_kw()),
                s(L.settings_row_rules(), L.settings_row_rules_desc(), L.settings_row_rules_kw()),
            ]),
            Section(page: "recurring", title: L.settings_section_recurring(), icon: "arrows-clockwise", rows: [
                s(L.settings_row_auto_record(), L.settings_row_auto_record_desc(), L.settings_row_auto_record_kw()),
                s(L.settings_row_coming_up(), L.settings_row_coming_up_desc(), L.settings_row_coming_up_kw()),
            ]),
        ]),
        (L.settings_group_intelligence(), [
            Section(page: "ai", title: L.settings_section_ai(), icon: "sparkle", rows: [
                s(L.settings_row_ai_enabled(), L.settings_row_ai_enabled_desc(), L.settings_row_ai_enabled_kw()),
                s(L.settings_row_ai_providers(), L.settings_row_ai_providers_desc(), L.settings_row_ai_providers_kw()),
                s(L.settings_row_ai_features(), L.settings_row_ai_features_desc(), L.settings_row_ai_features_kw()),
                s(L.settings_row_ai_categorise(), L.settings_row_ai_categorise_desc(), L.settings_row_ai_categorise_kw()),
                s(L.settings_row_ai_quick_add(), L.settings_row_ai_quick_add_desc(), L.settings_row_ai_quick_add_kw()),
                s(L.settings_row_ai_receipts(), L.settings_row_ai_receipts_desc(), L.settings_row_ai_receipts_kw()),
                s(L.settings_row_ai_recap(), L.settings_row_ai_recap_desc(), L.settings_row_ai_recap_kw()),
                s(L.settings_row_ai_ask(), L.settings_row_ai_ask_desc(), L.settings_row_ai_ask_kw()),
                s(L.settings_row_ai_statements(), L.settings_row_ai_statements_desc(), L.settings_row_ai_statements_kw()),
                s(L.settings_row_ai_privacy(), L.settings_row_ai_privacy_desc(), L.settings_row_ai_privacy_kw()),
                s(L.settings_row_ai_log(), L.settings_row_ai_log_desc(), L.settings_row_ai_log_kw()),
                s(L.settings_row_ai_usage(), L.settings_row_ai_usage_desc(), L.settings_row_ai_usage_kw()),
            ]),
        ]),
        (L.settings_group_data(), [
            Section(page: "data", title: L.settings_section_data(), icon: "download-simple", rows: [
                s(L.settings_row_statements(), L.settings_row_statements_desc(), L.settings_row_statements_kw()),
                s(L.settings_row_export(), L.settings_row_export_desc(), L.settings_row_export_kw()),
            ]),
            Section(page: "api", title: L.settings_section_api(), icon: "plugs-connected", rows: [
                s(L.settings_row_mcp_url(), L.settings_row_mcp_url_desc(), L.settings_row_mcp_url_kw()),
                s(L.settings_row_connected_apps(), L.settings_row_connected_apps_desc(), L.settings_row_connected_apps_kw()),
                s(L.settings_row_api_keys(), L.settings_row_api_keys_desc(), L.settings_row_api_keys_kw()),
                s(L.settings_row_api_docs(), L.settings_row_api_docs_desc(), L.settings_row_api_docs_kw()),
            ]),
            Section(page: "delete", title: L.settings_section_delete(), icon: "warning", rows: [
                s(L.settings_row_delete_transactions(), L.settings_row_delete_transactions_desc(), L.settings_row_delete_transactions_kw()),
                s(L.settings_row_delete_account(), L.settings_row_delete_account_desc(), L.settings_row_delete_account_kw()),
            ]),
        ]),
    ]
}

/// The provider names, as the web writes them; the self-hosted kind is a translated phrase.
func providerName(_ id: String) -> String {
    switch id {
    case "anthropic": "Anthropic"
    case "openai": "OpenAI"
    case "gemini": "Google Gemini"
    case "openrouter": "OpenRouter"
    case "ollama": "Ollama"
    default: L.settings_ai_compatible_name()
    }
}

/// Settings: search across every section's rows, the profile card, then the sections grouped You, Preferences, Money,
/// Intelligence and Data, each with a line about where it stands. Footer: version and server.
struct SettingsList: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var query = ""
    @State private var account: AccountSummary?
    @State private var access: ApiAccess?

    var body: some View {
        let c = theme.colors
        Page(L.settings_title()) {
            KField(L.settings_search_placeholder(), text: $query, icon: "magnifying-glass").keyboard(.search)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                Card(tight: true) {
                    Button { nav.push(.settings(page: "profile")) } label: {
                        HStack(spacing: 12) {
                            ProfileAvatar(size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kosha.meta?.user?.name ?? "").kFont(.head)
                                Text(kosha.meta?.user?.email ?? "").kFont(.xs).foregroundStyle(c.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            PhIcon("caret-right", size: 16, color: c.ink3)
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
                ForEach(groups(), id: \.0) { group, sections in
                    VStack(alignment: .leading, spacing: 6) {
                        GroupCaption(group)
                        Rows {
                            ForEach(sections.indices, id: \.self) { i in
                                if i > 0 { Hairline() }
                                sectionRow(sections[i])
                            }
                        }
                    }
                }
                Text(L.app_set_footer(version: version.0, build: version.1, server: serverHost(kosha.server)))
                    .kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity).padding(.top, 6)
            }
        }
        .load("account", into: $account) { try await $0.get("/api/app/account") }
        .load("api-access", into: $access) { try await $0.get("/api/app/api-access") }
    }

    private var version: (String, String) {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "", info?["CFBundleVersion"] as? String ?? "")
    }

    @ViewBuilder private var searchResults: some View {
        let hits = groups().flatMap(\.1).flatMap { section -> [(Section, Searchable?)] in
            let own: [(Section, Searchable?)] = matchesAll(query, section.title) ? [(section, nil)] : []
            return own + section.rows.filter { matchesAll(query, $0.title, $0.description, $0.keywords, section.title) }
                .map { (section, $0) }
        }
        if hits.isEmpty {
            Text(L.settings_no_match(query: query.trimmingCharacters(in: .whitespaces)))
                .foregroundStyle(theme.colors.ink3).frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            Hint(L.settings_results(count: hits.count))
            Rows {
                ForEach(hits.indices, id: \.self) { i in
                    if i > 0 { Hairline() }
                    let (section, row) = hits[i]
                    NavRow(row?.title ?? section.title, description: row != nil ? section.title : nil, icon: section.icon) {
                        nav.push(.settings(page: section.page))
                    }
                }
            }
        }
    }

    private func sectionRow(_ section: Section) -> some View {
        let m = kosha.meta
        let open = account.map { a in securitySteps(a, backupCodesSaved: !m.prefOf("backup_codes_saved_at").isEmpty).filter { !$0.done }.count } ?? 0
        let description: String? = switch section.page {
        case "profile": L.app_set_profile_desc()
        case "security": L.app_set_security_desc()
        case "general": L.app_set_general_desc()
        case "appearance": L.app_set_appearance_desc()
        case "currencies":
            m.map { currencyOrder(primary: $0.primaryCurrency, order: $0.order, used: $0.wallets.filter { !$0.isArchived }.map(\.currency)) }?
                .map { $0.uppercased() }.joined(separator: " · ")
        case "categories": L.app_set_categories_desc()
        case "events": L.app_set_events_desc()
        case "rules":
            [account.map { L.settings_rules_count(count: $0.rules) }, m.prefOf("learn_rules") == "1" ? L.app_set_rules_learning() : nil]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "recurring": L.app_set_recurring_desc()
        case "ai":
            m.prefOf("ai_enabled") != "1" ? L.settings_appearance_off()
                : [L.settings_appearance_on(), m?.aiModel.map { providerName($0.provider) },
                   L.app_set_ai_features_on(count: AiFeature.allCases.filter { m.prefOf($0.pref) == "1" }.count)]
                .compactMap { $0 }.joined(separator: " · ")
        case "data": L.app_set_data_desc()
        case "api": access.map { L.app_set_apps_count(count: $0.apps.count) + " · " + L.app_set_keys_count(count: $0.keys.count) }
        case "delete": L.app_set_delete_desc()
        default: nil
        }
        return NavRow(section.title, description: description, icon: section.icon, badge: section.page == "security" ? open : 0,
                      titleExtra: { if section.page == "ai" { Pill(L.settings_badge_beta()) } }) {
            nav.push(.settings(page: section.page))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
