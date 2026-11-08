#if DEBUG
import Foundation
import SwiftUI
import Model
import API
import Store

/// Debug only: what the screenshot tour (KoshaUITests/TourTests.swift) asks the app to do through launch arguments.
/// UI tests run in their own process, so the app signs itself in and opens the screen:
///
///   -TourServer http://localhost:3000   sign in there as the read-only demo account, without a browser
///   -TourScreen account-detail          open this screen (names as in Android's TourTest)
///   -TourDark YES                       draw it dark
public enum Tour {
    public static var server: String? { UserDefaults.standard.string(forKey: "TourServer") }
    public static var screen: String? { UserDefaults.standard.string(forKey: "TourScreen") }
    public static var dark: Bool? {
        UserDefaults.standard.object(forKey: "TourDark") == nil ? nil : UserDefaults.standard.bool(forKey: "TourDark")
    }

    /// The tab and the route for a screen name.
    @MainActor
    static func open(_ name: String, kosha: Kosha, nav: Navigator) {
        let wallets = kosha.meta?.wallets ?? []
        switch name {
        case "overview": nav.tab = .overview
        case "activity": nav.tab = .activity
        case "recurring": nav.tab = .recurring
        case "accounts": nav.tab = .accounts
        case "add": nav.openAdd()
        case "add-transfer": nav.openAdd(AddRequest(kind: .transfer))
        case "account-detail":
            nav.tab = .accounts
            if let w = wallets.first { nav.push(.accountDetail(id: w.id)) }
        case "investment-detail":
            nav.tab = .accounts
            if let w = wallets.first(where: { $0.kind == .investment }) { nav.push(.investmentDetail(id: w.id)) }
        case "account-form": nav.tab = .accounts; nav.push(.accountForm())
        case "exchanges": nav.tab = .accounts; nav.push(.exchanges)
        case "reconcile": nav.tab = .accounts; nav.push(.reconcile())
        case "import": nav.tab = .accounts; nav.push(.importStatements)
        case "recurring-form": nav.tab = .recurring; nav.push(.recurringForm())
        case "ask": nav.push(.ask())
        case let s where s.hasPrefix("settings-"):
            let page = String(s.dropFirst("settings-".count))
            nav.push(.settings(page: page == "list" ? "" : page))
        default: break
        }
    }

    /// Signs in to the dev server as the demo account: the same PKCE authorize, sign-in and token requests the browser
    /// makes, with the demo's published password (../kosha-web/CLAUDE.md). Never in release builds.
    @MainActor
    static func signIn(_ server: String, kosha: Kosha) async {
        guard kosha.tokens.read() == nil else { return }
        let http = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let verifier = UUID().uuidString + UUID().uuidString
        let challenge = Data(SHA256Digest.hash(verifier)).base64URL
        var c = URLComponents(string: "\(server)/api/auth/oauth2/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectUri(server)),
            .init(name: "scope", value: "openid profile email offline_access kosha:read kosha:write"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: "tour"), .init(name: "resource", value: "\(server)/api/v1"),
            .init(name: "login_hint", value: "demo"), .init(name: "prompt", value: "login"),
        ]
        var cookies: [String] = []
        func browser(_ url: String, body: String? = nil) async -> (Data, HTTPURLResponse)? {
            guard let u = URL(string: url.hasPrefix("http") ? url : server + url) else { return nil }
            var r = URLRequest(url: u)
            r.setValue(body == nil ? "text/html" : "application/json", forHTTPHeaderField: "accept")
            r.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
            r.setValue(server, forHTTPHeaderField: "origin")
            if !cookies.isEmpty { r.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "cookie") }
            if let body {
                r.httpMethod = "POST"
                r.httpBody = Data(body.utf8)
                r.setValue("application/json", forHTTPHeaderField: "content-type")
            }
            guard let (data, res) = try? await http.data(for: r), let h = res as? HTTPURLResponse else { return nil }
            for (k, v) in h.allHeaderFields where (k as? String)?.lowercased() == "set-cookie" {
                for part in String(describing: v).components(separatedBy: ", ") {
                    if let kv = part.split(separator: ";").first, kv.contains("=") { cookies.append(String(kv)) }
                }
            }
            return (data, h)
        }
        func url(_ data: Data, _ h: HTTPURLResponse) -> String? {
            h.value(forHTTPHeaderField: "location") ?? (try? KoshaJSON.decode(JSONValue.self, data))?["url"]?.string
        }
        guard let (d1, h1) = await browser(c.url!.absoluteString), let login = url(d1, h1) else {
            return print("Tour: authorize gave no login URL")
        }
        let query = login.components(separatedBy: "?").dropFirst().joined(separator: "?")
        let body = String(data: try! KoshaJSON.encode(["email": "demo@kosha.local", "password": "kosha-demo-2026", "oauth_query": query]),
                          encoding: .utf8)!
        guard let (d2, h2) = await browser("/api/auth/sign-in/email", body: body) else {
            return print("Tour: sign-in request failed")
        }
        var next = url(d2, h2)
        for _ in 0..<5 {
            guard let n = next, !n.contains(callbackPath) else { break }
            guard let (d, h) = await browser(n) else { break }
            next = url(d, h)
        }
        guard let n = next, let code = URLComponents(string: n.hasPrefix("http") ? n : server + n)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            return print("Tour: no code in \(next ?? "nil")")
        }
        var t = URLRequest(url: URL(string: "\(server)/api/auth/oauth2/token")!)
        t.httpMethod = "POST"
        // As the app does: no browser cookies on the token request, or the server's CSRF check refuses it.
        t.httpShouldHandleCookies = false
        t.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectUri(server), "client_id": clientId,
                    "code_verifier": verifier, "resource": "\(server)/api/v1"]
        t.httpBody = Data(form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $1)" }
            .joined(separator: "&").utf8)
        let data = (try? await http.data(for: t))?.0 ?? Data()
        guard let json = try? KoshaJSON.decode(JSONValue.self, data),
              let access = json["access_token"]?.string, let refresh = json["refresh_token"]?.string else {
            return print("Tour: token exchange failed: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        kosha.tokens.write(Tokens(server: server, clientId: clientId, access: access, refresh: refresh,
                                  expiresAt: Int64(Date().timeIntervalSince1970) + 3600))
        print("Tour: signed in, stored: \(kosha.tokens.read() != nil)")
        kosha.didSignIn()
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

import CryptoKit

private enum SHA256Digest {
    static func hash(_ s: String) -> [UInt8] { Array(SHA256.hash(data: Data(s.utf8))) }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
