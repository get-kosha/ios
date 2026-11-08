import SwiftUI
import Model
import API
import Store
import Design

// Import & export, API & MCP, and Delete & reset.

/// A file this app wrote, for the share sheet.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

#if os(iOS)
/// The system share sheet for files or text.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

extension View {
    /// Shows the share sheet for a file when one is set.
    func shareSheet(_ file: Binding<SharedFile?>) -> some View {
        #if os(iOS)
        sheet(item: file) { f in ShareSheet(items: [f.url]).presentationDetents([.medium, .large]) }
        #else
        self
        #endif
    }
}

/// Import & export: Import statements, and Transactions (CSV) and Everything (JSON) through the share sheet.
struct DataExportPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        Page(L.settings_section_data()) {
            GroupCaption(L.settings_data_import())
            Card {
                HStack(spacing: 12) {
                    IconTile("file-arrow-up")
                    Text(L.settings_row_statements()).kFont(.head)
                }
                Text(kosha.meta?.aiFlags.statements == true ? L.settings_data_statements_desc_pdf() : L.settings_data_statements_desc())
                    .kFont(.small).foregroundStyle(c.ink2)
                KButton(L.settings_data_import_statements(), size: .medium) { nav.push(.importStatements) }
            }
            GroupCaption(L.settings_row_export())
            Rows {
                ExportRow(icon: "file-csv", title: L.settings_data_transactions(), sub: L.settings_data_transactions_sub(),
                          path: "/api/app/export/transactions.csv", fileName: "kosha-transactions.csv")
                Hairline()
                ExportRow(icon: "file-code", title: L.settings_data_everything(), sub: L.settings_data_everything_sub(),
                          path: "/api/app/export/kosha.json", fileName: "kosha.json")
            }
            Hint(L.app_set_export_note())
        }
    }
}

/// One export: Download fetches it with the session, writes it to a temporary file and opens the share sheet.
private struct ExportRow: View {
    let icon: String
    let title: String
    let sub: String
    let path: String
    let fileName: String
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @State private var state = "idle"
    @State private var shared: SharedFile?

    var body: some View {
        SRow(title, description: sub, icon: icon) {
            KButton(state == "busy" ? L.settings_data_preparing() : state == "done" ? L.settings_data_downloaded() : L.settings_data_download(),
                    style: .secondary, size: .small, icon: state == "idle" ? "export" : nil) { download() }
                .disabled(state == "busy")
        }
        .shareSheet($shared)
    }

    private func download() {
        state = "busy"
        Task {
            do {
                let data = try await kosha.api.bytes(path)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)
                state = "done"
                shared = SharedFile(url: url)
            } catch {
                state = "idle"
                toasts.show(L.settings_data_export_failed(status: (error as? KoshaError)?.errorDescription ?? "\(error)"), warning: true)
            }
        }
    }
}

/// API & MCP: the MCP server URL with Copy, apps connected through OAuth (with Disconnect), API keys (a new key is shown
/// once, with Copy and Share), and the API reference.
struct ApiMcpPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var access: ApiAccess?
    @State private var creating = false
    @State private var made: (name: String, key: NewKey)?
    @State private var confirm: Confirm?

    struct Confirm: Identifiable {
        let kind: String
        let id: String
        let name: String
    }

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let tz = kosha.tz
        Page(L.settings_section_api()) {
            Text(L.settings_section_api_desc()).kFont(.small).foregroundStyle(c.ink3)
            GroupCaption(L.settings_api_assistants())
            Card {
                Text(L.settings_api_mcp_title()).kFont(.head)
                let url = access?.mcpUrl.nilIfEmpty ?? ((kosha.server ?? defaultServer) + "/mcp")
                HStack(spacing: 8) {
                    Text(url).kFont(.figure(14, .regular)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(c.soft, in: .rect(cornerRadius: 12))
                        .textSelection(.enabled)
                    KButton(L.settings_sec_copy(), style: .secondary, size: .small, icon: "copy") {
                        copyText(url)
                        w.toast(L.settings_api_url_copied())
                    }
                }
                Text(L.settings_api_assistants_note()).kFont(.xs).foregroundStyle(c.ink3)
            }

            GroupCaption(L.settings_api_connected_apps())
            let apps = access?.apps ?? []
            if access != nil && apps.isEmpty { Hint(L.settings_api_none()) }
            if !apps.isEmpty {
                Rows {
                    ForEach(apps.indices, id: \.self) { i in
                        let a = apps[i]
                        if i > 0 { Hairline() }
                        SRow(a.name, description: [a.write ? L.settings_api_can_write() : L.settings_api_app_read_only(),
                                                   L.settings_api_connected_on(date: shortDate(a.connectedAt / 1000, tz: tz, locale: theme.locale)),
                                                   a.host.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")) {
                            KButton(L.settings_api_disconnect(), style: .secondary, size: .small) {
                                if !w.refused() { confirm = Confirm(kind: "app", id: a.clientId, name: a.name) }
                            }
                        }
                    }
                }
            }

            GroupCaption(L.settings_api_keys()) {
                KButton(L.settings_api_new_key(), style: .soft, size: .small, icon: "plus") { if !w.refused() { creating = true } }
            }
            let keys = access?.keys ?? []
            if access != nil && keys.isEmpty && made == nil { Hint(L.settings_api_no_keys()) }
            if !keys.isEmpty || made != nil {
                Rows {
                    ForEach(keys.indices, id: \.self) { i in
                        let k = keys[i]
                        if i > 0 { Hairline() }
                        SRow(k.name, description: [k.scope == "write" ? L.settings_api_read_write() : L.settings_api_read_only(),
                                                   L.settings_api_made_on(date: shortDate(k.created_at, tz: tz, locale: theme.locale)),
                                                   k.last_used_at.map { L.settings_api_used_on(date: shortDate($0, tz: tz, locale: theme.locale)) }
                                                       ?? L.settings_api_never_used()].joined(separator: " · ")) {
                            IconButton("trash", label: L.settings_api_delete_key(name: k.name)) {
                                if !w.refused() { confirm = Confirm(kind: "key", id: k.id, name: k.name) }
                            }
                        }
                    }
                    if let made {
                        if !keys.isEmpty { Hairline() }
                        // The key is shown this once; only its hash is kept on the server.
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.settings_api_created(name: made.name)).kFont(.sans(13, .medium))
                            Text(made.key.key).kFont(.figure(13, .regular)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(c.surface, in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.line))
                            HStack(spacing: 8) {
                                KButton(L.settings_sec_copy(), size: .medium, icon: "copy") {
                                    copyText(made.key.key)
                                    w.toast(L.settings_api_key_copied())
                                }
                                ShareLink(item: made.key.key) {
                                    HStack(spacing: 8) {
                                        PhIcon("share-network", size: 18, color: c.ink)
                                        Text(L.app_set_share()).kFont(.sans(15, .medium)).foregroundStyle(c.ink)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(c.surface, in: .rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.line))
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(c.brand.opacity(0.06))
                    }
                }
            }
            Text(L.settings_api_keys_note()).kFont(.xs).foregroundStyle(c.ink3).padding(.horizontal, 2)
            Rows {
                NavRow(L.settings_api_docs_title(), description: L.settings_api_docs_description(), icon: "book-open", external: true) {
                    let docs = access?.docsUrl.nilIfEmpty ?? ((kosha.server ?? defaultServer) + "/api/v1/docs")
                    if let url = URL(string: docs) { nav.openWeb?(url) }
                }
            }
        }
        .load("api-access", into: $access) { try await $0.get("/api/app/api-access") }
        .kSheet(isPresented: $creating) {
            NewKeySheet(close: { creating = false }) { name, key in
                creating = false
                made = (name, key)
            }
        }
        .kSheet(item: $confirm) { x in
            let isKey = x.kind == "key"
            ConfirmSheet(title: isKey ? L.settings_api_delete_title(name: x.name) : L.settings_api_disconnect_title(name: x.name),
                         text: isKey ? L.settings_api_delete_body() : L.settings_api_disconnect_body(),
                         button: isKey ? L.common_delete() : L.settings_api_disconnect(), action: {
                             w.send("DELETE", isKey ? "/api/app/api-keys/\(x.id)" : "/api/app/connected-apps/\(x.id)") {
                                 w.toast(isKey ? L.settings_api_key_deleted(name: x.name) : L.settings_api_app_disconnected(name: x.name))
                             }
                         }, close: { confirm = nil })
        }
    }
}

/// New key: a name and read-only or read & write.
private struct NewKeySheet: View {
    let close: () -> Void
    let onMade: (String, NewKey) -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @State private var name = ""
    @State private var scope = "read"
    @State private var busy = false

    var body: some View {
        let w = Writer(kosha: kosha, toasts: toasts)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(L.settings_api_new_key(), onClose: close)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.settings_api_name())
                KField(L.settings_api_name_placeholder(), text: $name).keyboard(.text)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.settings_api_scope())
                Segmented([("read", L.settings_api_read_only()), ("write", L.settings_api_read_write())], selection: $scope)
            }
            KButton(L.settings_api_create()) {
                busy = true
                let body = JSONValue.object(["name": .string(trimmed), "scope": .string(scope)])
                w.run({ () async throws -> NewKey in try await kosha.api.post("/api/app/api-keys", body) },
                      always: { busy = false }, done: { onMade(trimmed, $0) })
            }
            .disabled(trimmed.isEmpty || busy)
        }
    }
}

/// Delete & reset: Delete all transactions after typing DELETE (with the count and what stays), and Delete account,
/// which opens the server's page, where the person confirms with their email and password.
struct DeleteResetPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var account: AccountSummary?
    @State private var typed = ""
    @State private var busy = false

    var body: some View {
        let c = theme.colors
        let w = Writer(kosha: kosha, toasts: toasts)
        let count = account?.transactions ?? 0
        let f = NumberFormatter()
        let _ = { f.locale = theme.locale; f.numberStyle = .decimal }()
        let n = f.string(from: NSNumber(value: count)) ?? "\(count)"
        Page(L.settings_section_delete()) {
            Text(L.app_set_delete_intro()).kFont(.small).foregroundStyle(c.ink3)
            Card {
                Text(L.settings_danger_reset_title()).kFont(.head)
                Text(account != nil ? L.settings_danger_reset_body(count: count, n: n) : L.settings_danger_transactions_desc())
                    .kFont(.small).foregroundStyle(c.ink2)
                VStack(alignment: .leading, spacing: 6) {
                    // The word stays DELETE in every language, as on the web.
                    Text(L.settings_danger_type_to_confirm(word: "DELETE")).kFont(.small).foregroundStyle(c.ink3)
                    KField("", text: $typed).keyboard(.text, capitalise: false)
                }
                HStack(spacing: 8) {
                    KButton(L.common_cancel(), style: .secondary, size: .medium) { typed = "" }.frame(width: 110)
                    KButton(busy ? L.settings_danger_deleting() : L.settings_danger_reset_button(count: count, n: n), style: .danger, size: .medium) {
                        busy = true
                        w.run({ try await kosha.api.send("DELETE", "/api/app/transactions") }, always: { busy = false }, done: { _ in
                            typed = ""
                            w.toast(L.settings_danger_reset_done(count: count, n: n))
                        })
                    }
                    .disabled(typed != "DELETE" || busy || count == 0)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.bad.opacity(0.4)))
            Card {
                Text(L.settings_row_delete_account()).kFont(.head)
                Text(L.settings_danger_account_desc()).kFont(.small).foregroundStyle(c.ink2)
                KButton(L.settings_danger_account_button(), style: .danger, size: .medium, icon: "arrow-square-out") {
                    if !w.refused(), let url = URL(string: (kosha.server ?? defaultServer) + "/settings/delete#delete-account") {
                        nav.openWeb?(url)
                    }
                }
                Text(L.app_set_delete_account_note(host: serverHost(kosha.server))).kFont(.xs).foregroundStyle(c.ink3)
            }
        }
        .load("account", into: $account) { try await $0.get("/api/app/account") }
    }
}
