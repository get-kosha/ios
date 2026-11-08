import SwiftUI
import Model
import API
import Store
import Design

// Settings › AI: the master switch, providers, features, what AI can see and the request log. All optional; with AI
// off nothing below the switch shows, and nothing is sent.

let aiProviders = ["anthropic", "openai", "gemini", "openrouter", "ollama", "compatible"]

/// Ollama and OpenAI-compatible endpoints are reached at a URL the person gives, with an optional key.
func usesBaseUrl(_ id: String) -> Bool { id == "ollama" || id == "compatible" }

private func providerKind(_ id: String) -> String {
    switch id {
    case "anthropic": L.settings_ai_kind_anthropic()
    case "openai": L.settings_ai_kind_openai()
    case "gemini": L.settings_ai_kind_gemini()
    case "openrouter": L.settings_ai_kind_openrouter()
    case "ollama": L.settings_ai_kind_ollama()
    default: L.settings_ai_kind_compatible()
    }
}

private func keyPlaceholder(_ id: String) -> String {
    switch id {
    case "anthropic": "sk-ant-…"
    case "openai": "sk-…"
    case "gemini": "AIza…"
    case "openrouter": "sk-or-…"
    case "ollama": "https://ollama.example.com"
    default: "https://…/v1"
    }
}

func featureTitle(_ f: AiFeature) -> String {
    switch f {
    case .categorise: L.settings_ai_categorise_title()
    case .quick_add: L.settings_ai_quick_add_title()
    case .receipts: L.settings_ai_receipts_title()
    case .recap: L.settings_ai_recap_title()
    case .ask: L.settings_ai_ask_title()
    case .statements: L.settings_ai_statements_title()
    }
}

private func featureDescription(_ f: AiFeature) -> String {
    switch f {
    case .categorise: L.settings_ai_categorise_description()
    case .quick_add: L.settings_ai_quick_add_description()
    case .receipts: L.settings_ai_receipts_description()
    case .recap: L.settings_ai_recap_description()
    case .ask: L.settings_ai_ask_description()
    case .statements: L.settings_ai_statements_description()
    }
}

private func featureSends(_ f: AiFeature) -> String {
    switch f {
    case .categorise: L.settings_ai_categorise_sends()
    case .quick_add: L.settings_ai_quick_add_sends()
    case .receipts: L.settings_ai_receipts_sends()
    case .recap: L.settings_ai_recap_sends()
    case .ask: L.settings_ai_ask_sends()
    case .statements: L.settings_ai_statements_sends()
    }
}

private func shares() -> [(pref: String, title: String, description: String)] {
    [("ai_share_amount", L.settings_ai_share_amount(), L.settings_ai_share_amount_description()),
     ("ai_share_payee", L.settings_ai_share_payee(), L.settings_ai_share_payee_description()),
     ("ai_share_date", L.settings_ai_share_date(), L.settings_ai_share_date_description()),
     ("ai_share_note", L.settings_ai_share_note(), L.settings_ai_share_note_description()),
     ("ai_share_account", L.settings_ai_share_account(), L.settings_ai_share_account_description())]
}

extension View {
    func loadProviders(into value: Binding<[AiProvider]?>) -> some View {
        load("ai-providers", into: value) { try await $0.get("/api/app/ai/providers") }
    }
}

/// AI: Use AI features, then (when on) the providers, each feature's switch, What AI can see and the request log.
struct AiSettingsPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var providers: [AiProvider]?
    @State private var adding = false

    var body: some View {
        let c = theme.colors
        let m = kosha.meta
        let w = Writer(kosha: kosha, toasts: toasts)
        let on = m.prefOf("ai_enabled") == "1"
        let connected = (providers ?? []).filter(\.connected).sorted { $0.isDefault && !$1.isDefault }
        Page(L.settings_section_ai(), actions: { Pill(L.settings_badge_beta()).padding(.trailing, 12) }) {
            Text(L.app_set_ai_intro()).kFont(.small).foregroundStyle(c.ink3)
            Rows {
                SettingsSwitchRow(L.settings_ai_enabled_title(), description: L.settings_ai_enabled_description(),
                          isOn: prefBinding(kosha, w, "ai_enabled"))
            }
            if on {
                GroupCaption(L.settings_ai_providers())
                if providers == nil { LoadingNote() }
                Rows {
                    ForEach(connected) { p in
                        NavRow(providerName(p.id), description: L.settings_ai_connected(model: p.model), icon: "plug",
                               titleExtra: { if p.isDefault { Pill(L.settings_ai_default(), color: c.brand) } }) {
                            nav.push(.settings(page: "ai-provider", id: p.id))
                        }
                        Hairline()
                    }
                    NavRow(L.app_set_ai_add_provider(), description: L.app_set_ai_add_provider_desc(), icon: "plus") { adding = true }
                }
                if providers != nil && !connected.contains(where: \.isDefault) { SettingsHint(L.settings_ai_features_note()) }

                GroupCaption(L.settings_ai_features())
                Rows {
                    ForEach(AiFeature.allCases.indices, id: \.self) { i in
                        let f = AiFeature.allCases[i]
                        if i > 0 { Hairline() }
                        let value = m.prefOf(f.pref) == "1"
                        let blocked = f.needs.filter { m.prefOf($0) != "1" }.map(needLabel)
                        SettingsSwitchRow(featureTitle(f), description: featureDescription(f), isOn: prefBinding(kosha, w, f.pref)) {
                            if value && !blocked.isEmpty {
                                Text(blocked.joined(separator: " ")).kFont(.xs).foregroundStyle(c.warn).padding(.top, 4)
                            }
                        }
                    }
                }
                let shared = shares().filter { m.prefOf($0.pref) == "1" }.map(\.title)
                Rows {
                    NavRow(L.settings_ai_visibility(), description: shared.joined(separator: ", ").nilIfEmpty, icon: "eye") {
                        nav.push(.settings(page: "ai-privacy"))
                    }
                    Hairline()
                    NavRow(L.settings_ai_log_dialog_title(), description: L.settings_ai_log_dialog_description(), icon: "list-magnifying-glass") {
                        nav.push(.settings(page: "ai-log"))
                    }
                }
            }
        }
        .loadProviders(into: $providers)
        .kSheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(L.app_set_ai_add_provider()) { adding = false }
                let list = aiProviders.filter { id in providers?.first { $0.id == id }?.connected != true }
                Rows {
                    ForEach(list.indices, id: \.self) { i in
                        if i > 0 { Hairline() }
                        NavRow(providerName(list[i]), description: providerKind(list[i])) {
                            adding = false
                            nav.push(.settings(page: "ai-provider", id: list[i]))
                        }
                    }
                }
            }
        }
    }

    private func needLabel(_ pref: String) -> String {
        switch pref {
        case "ai_share_payee": L.settings_ai_needs_payee()
        case "ai_share_amount": L.settings_ai_needs_amount()
        default: L.settings_ai_needs_suggest()
        }
    }
}

/// One provider: whether it's connected, the API key (masked, with Replace; the server never sends it back), the base
/// URL for self-hosted endpoints, the model from the provider's own list, Test connection, Make default and Disconnect.
/// A test that works saves the key and model, so there is no Save button.
struct AiProviderPage: View {
    let id: String
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [AiProvider]?
    @State private var key = ""
    @State private var replacing = false
    @State private var baseUrl = ""
    @State private var test: AiTest?
    @State private var testing = false
    @State private var picking = false

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let p = providers?.first { $0.id == id } ?? AiProvider(id: id)
        let name = providerName(id)
        let models = test.map(\.models).flatMap { $0.isEmpty ? nil : $0 } ?? (p.model.isEmpty ? [] : [p.model])
        Page(name, subtitle: p.isDefault ? L.settings_ai_default() : nil, footer: {
            if p.connected {
                KButton(L.app_set_ai_disconnect_named(name: name), style: .danger) {
                    w.send("DELETE", "/api/app/ai/providers/\(id)") {
                        w.toast(L.settings_ai_disconnected(name: name))
                        dismiss()
                    }
                }
            }
        }) {
            Group {
                if let t = test, t.ok {
                    Pill(L.settings_ai_reached(name: name) + " · \(t.ms) ms", color: c.pos)
                } else if let t = test {
                    Text(t.error ?? "").kFont(.small).foregroundStyle(c.bad)
                } else if p.connected {
                    Pill(L.settings_ai_connected(model: p.model), color: c.pos)
                } else {
                    Pill(L.settings_ai_not_connected())
                }
            }
            Text(providerKind(id)).kFont(.small).foregroundStyle(c.ink3)
            if usesBaseUrl(id) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(L.settings_ai_base_url())
                    KField(keyPlaceholder(id), text: $baseUrl).keyboard(.url)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(usesBaseUrl(id) ? L.settings_ai_api_key_optional() : L.settings_ai_api_key())
                if let hint = p.keyHint, !replacing {
                    HStack(spacing: 10) {
                        PhIcon("key", size: 18, color: c.ink3)
                        Text("…\(hint)").kFont(.num).foregroundStyle(c.ink3).frame(maxWidth: .infinity, alignment: .leading)
                        KButton(L.app_set_ai_replace(), style: .soft, size: .small) { if !w.refused() { replacing = true } }
                    }
                    .padding(.leading, 14).padding(.trailing, 6).frame(minHeight: 48)
                    .background(c.surface, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                } else {
                    KField(usesBaseUrl(id) ? "" : keyPlaceholder(id), text: $key, icon: "key", secure: true).keyboard(.url)
                }
                SettingsHint(usesBaseUrl(id) ? L.settings_ai_url_note() : L.app_set_ai_key_stored())
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.settings_ai_model())
                SettingsPickField(nil, p.model.isEmpty ? (models.isEmpty ? L.settings_ai_test_to_load() : L.settings_ai_pick_model()) : p.model,
                          placeholder: p.model.isEmpty) {
                    if !models.isEmpty && !w.refused() { picking = true }
                }
            }
            KButton(testing ? L.settings_ai_testing() : test?.ok == true ? L.settings_ai_test_again() : L.settings_ai_test(),
                    style: .secondary, size: .medium, icon: "plugs-connected") { runTest(w, p) }
                .disabled(testing || !(p.connected || !key.isEmpty || (usesBaseUrl(id) && !baseUrl.isEmpty)))
            if p.connected && !p.isDefault {
                KButton(L.settings_ai_make_default(), style: .soft, size: .medium) { w.send("POST", "/api/app/ai/providers/\(id)/default") }
            }
        }
        .loadProviders(into: $providers)
        .onChange(of: p.baseUrl) { _, v in if baseUrl.isEmpty { baseUrl = v ?? "" } }
        .kSheet(isPresented: $picking, scrolls: true) {
            ListPicker(L.settings_ai_model(), choices: models.map { Choice(id: $0, title: $0) }, selected: p.model,
                       onPick: { model in
                           picking = false
                           save(w, model)
                       }, onClose: { picking = false })
        }
    }

    private func requestBody(_ model: String?) -> JSONValue {
        var out: [String: JSONValue] = [:]
        if !key.trimmingCharacters(in: .whitespaces).isEmpty { out["key"] = .string(key.trimmingCharacters(in: .whitespaces)) }
        if usesBaseUrl(id), !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty { out["baseUrl"] = .string(baseUrl.trimmingCharacters(in: .whitespaces)) }
        if let model { out["model"] = .string(model) }
        return .object(out)
    }

    private func save(_ w: Writer, _ model: String) {
        w.send("PUT", "/api/app/ai/providers/\(id)", requestBody(model)) {
            key = ""
            replacing = false
            w.toast(L.common_saved())
        }
    }

    private func runTest(_ w: Writer, _ p: AiProvider) {
        if w.refused() { return }
        testing = true
        let request = requestBody(nil)
        w.run({ () async throws -> AiTest in try await kosha.api.post("/api/app/ai/providers/\(id)/test", request) },
              always: { testing = false }, done: { r in
                  test = r
                  // A working connection saves what was typed, keeping the model (or taking the provider's first one).
                  let model = (!p.model.isEmpty && r.models.contains(p.model)) ? p.model : r.models.first
                  if r.ok, let model, !p.connected || !key.isEmpty || (usesBaseUrl(id) && baseUrl != (p.baseUrl ?? "")) || model != p.model {
                      save(w, model)
                  }
              })
    }
}

/// What AI can see: the five fields Kosha may send, a live example of one transaction as it would go, what each feature
/// sends, and the request log switch.
struct AiPrivacyPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let m = kosha.meta
        let w = Writer(kosha: kosha, toasts: toasts)
        let on = Dictionary(uniqueKeysWithValues: ["amount", "payee", "date", "note", "account"].map { ($0, m.prefOf("ai_share_\($0)") == "1") })
        let sample = SampleTx(payee: "Pizza Hut", amount: -2957, currency: kosha.primary, day: "2026-11-04",
                              note: L.settings_ai_sample_note(), account: m?.wallets.first?.name ?? "Visa Card")
        let lines = samplePayload(sample, shares: on, uid: m?.user?.id ?? "")
        Page(L.settings_ai_visibility()) {
            Text(L.app_set_ai_privacy_intro()).kFont(.small).foregroundStyle(c.ink3)
            Rows {
                ForEach(shares().indices, id: \.self) { i in
                    let s = shares()[i]
                    if i > 0 { Hairline() }
                    SettingsSwitchRow(s.title, description: s.description, isOn: prefBinding(kosha, w, s.pref))
                }
            }
            GroupCaption(L.settings_ai_example())
            Card {
                VStack(alignment: .leading, spacing: 2) {
                    Text("{").kFont(.figure(12.5, .regular))
                    ForEach(lines.indices, id: \.self) { i in
                        let line = lines[i]
                        HStack(alignment: .top, spacing: 0) {
                            Text("\"\(line.field)\": ").foregroundStyle(c.ink3)
                            Text(line.value + (i < lines.count - 1 ? "," : ""))
                                .strikethrough(line.shown == .off)
                                .foregroundStyle(line.shown == .on ? c.pos : line.shown == .masked ? c.brand : c.ink3)
                            if line.shown == .off { Text("  " + L.settings_ai_not_sent()).foregroundStyle(c.ink3) }
                        }
                        .kFont(.figure(12.5, .regular))
                        .padding(.leading, 14)
                    }
                    Text("}").kFont(.figure(12.5, .regular))
                }
            }
            SoftNote("mask-happy", L.settings_ai_masked_note())
            GroupCaption(L.app_set_ai_each_sends())
            Rows {
                ForEach(AiFeature.allCases.indices, id: \.self) { i in
                    let f = AiFeature.allCases[i]
                    if i > 0 { Hairline() }
                    HStack(alignment: .top, spacing: 12) {
                        Text(featureTitle(f)).kFont(.small).frame(width: 120, alignment: .leading)
                        Text(featureSends(f)).kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: theme.dims.settingsRow)
                }
            }
            Rows {
                SettingsSwitchRow(L.settings_ai_log_title(), description: L.settings_ai_log_description(), isOn: prefBinding(kosha, w, "ai_log_enabled"))
            }
        }
    }
}

private func featureIcon(_ feature: String) -> String {
    switch feature {
    case "ask": "chat-circle-text"
    case "categorise": "tag"
    case "receipts": "receipt"
    case "quick_add": "text-aa"
    case "recap": "article"
    default: "file-text"
    }
}

/// Request log: this month's usage, then every request of the last 30 days; open one to see exactly what went and came
/// back.
struct AiLogPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var usage: AiUsage?
    @State private var open: String?

    var body: some View {
        let c = theme.colors
        let number = NumberFormatter()
        let _ = { number.locale = theme.locale; number.numberStyle = .decimal }()
        let n = { (v: Int64) in number.string(from: NSNumber(value: v)) ?? "\(v)" }
        Page(L.settings_ai_log_dialog_title(), subtitle: L.settings_ai_log_dialog_description()) {
            if let usage {
                Card {
                    Text(L.settings_ai_usage()).kFont(.caption).foregroundStyle(c.ink3)
                    HStack {
                        stat(L.settings_ai_requests(), n(Int64(usage.requests)))
                        stat(L.settings_ai_tokens(), n(usage.tokens))
                    }
                }
                if usage.log.isEmpty { Text(L.settings_ai_log_empty()).foregroundStyle(c.ink3) }
                if !usage.log.isEmpty {
                    Rows {
                        ForEach(usage.log.indices, id: \.self) { i in
                            if i > 0 { Hairline() }
                            entry(usage.log[i], n)
                        }
                    }
                }
            } else {
                LoadingNote()
            }
        }
        .load("ai-log", into: $usage) { try await $0.get("/api/app/ai/log") }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).kFont(.xs).foregroundStyle(theme.colors.ink3)
            Text(value).kFont(.figure(20, .regular))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entry(_ e: AiUsage.Entry, _ n: (Int64) -> String) -> some View {
        let c = theme.colors
        let expanded = open == e.id
        let date = Date(timeIntervalSince1970: TimeInterval(e.at))
        let day = Dates.today(kosha.tz, now: date)
        let time = DayFormat.time(Dates.time(kosha.tz, now: date), theme.locale)
        let title = AiFeature(rawValue: e.feature).map(featureTitle) ?? e.feature
        return VStack(alignment: .leading, spacing: 0) {
            Button { open = expanded ? nil : e.id } label: {
                HStack(spacing: 12) {
                    PhIcon(featureIcon(e.feature), size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).kFont(.small)
                        Text([DayFormat.label(day, today: kosha.today, theme.locale) + " " + time, providerName(e.provider), e.model]
                            .joined(separator: " · ")).kFont(.xs).foregroundStyle(c.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(n(e.tokens_in + e.tokens_out)).kFont(.figure(12, .regular)).foregroundStyle(c.ink3)
                    PhIcon(expanded ? "caret-up" : "caret-down", size: 16, color: c.ink3)
                }
                .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: theme.dims.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    exchange(L.app_set_ai_sent(), e.request)
                    exchange(L.app_set_ai_returned(), e.response)
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
    }

    /// One side of a request, word for word, in a soft box.
    private func exchange(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).kFont(.caption).foregroundStyle(theme.colors.ink3)
            Text(text).kFont(.figure(12, .regular)).foregroundStyle(theme.colors.ink2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(theme.colors.soft, in: .rect(cornerRadius: 10))
        }
    }
}
