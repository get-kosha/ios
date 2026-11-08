import Foundation
import CryptoKit
import Model

/// Kosha's public OAuth client for iOS on every server (migrations/0009_app_clients.sql in the web repo).
public let clientId = "kosha-ios"
/// The sign-in hand-back on every Kosha server; the only redirect that skips consent. The app claims it on
/// getkosha.app through apple-app-site-association (webcredentials), so ASWebAuthenticationSession can finish on it.
public let callbackPath = "/app/oauth/callback"
/// Where the server's "Open Kosha" button sends the same answer when the session can't finish on the HTTPS page
/// (a self-hosted server, or a local one in development).
public let fallbackScheme = "app.getkosha"
public let defaultServer = "https://getkosha.app"
/// Hosts whose callback the app may claim: the ones in Kosha.entitlements.
public let associatedHosts: Set<String> = ["getkosha.app"]
private let scopes = "openid profile email offline_access kosha:read kosha:write"

/// The redirect sent in both the authorize and token requests, whichever way the answer reaches the app.
public func redirectUri(_ server: String) -> String { server + callbackPath }

/// What the browser must open, and what the app keeps to finish the sign-in when the browser comes back.
public struct PendingSignIn: Codable, Sendable {
    public var server: String
    public var url: String
    public var state: String
    public var verifier: String
    public var tokenUrl: String
    public var revokeUrl: String?
    public var issuer: String

    /// Whether ASWebAuthenticationSession can finish on the server's HTTPS callback (an associated domain), or must
    /// wait for the app.getkosha: scheme from the callback page's Open Kosha button.
    public var httpsCallback: Bool {
        guard let url = URLComponents(string: server) else { return false }
        return url.scheme == "https" && associatedHosts.contains(url.host ?? "") && (url.port ?? 443) == 443
    }
}

private struct Discovery: Decodable {
    var issuer: String?
    var authorization_endpoint: String
    var token_endpoint: String
    var revocation_endpoint: String?
}

private struct TokenResponse: Decodable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Int64?
}

/// What can go wrong talking to Kosha.
public enum KoshaError: Error, Sendable, LocalizedError {
    /// The server answered with an error; its message is written for people.
    case api(status: Int, error: ApiError)
    /// No session, or the server refused it for good: sign in again.
    case signedOut
    /// The sign-in was refused or came back wrong.
    case auth(String)
    /// The token endpoint is busy (429) or failing (5xx): keep the session and try again, after `seconds` when given.
    case retryLater(seconds: Int?)
    /// No connection.
    case offline

    public var errorDescription: String? {
        switch self {
        case .api(_, let e): e.message
        case .auth(let m): m
        case .signedOut: "Signed out"
        case .retryLater: "Busy"
        case .offline: "Offline"
        }
    }

    /// The demo account or a read-only token.
    public var readOnly: Bool { if case .api(403, _) = self { true } else { false } }
    /// Busy (429) or failing (5xx): the same request may pass later.
    public var retryable: Bool {
        switch self {
        case .api(let s, _): s == 429 || s >= 500
        case .retryLater, .offline: true
        default: false
        }
    }
}

/// Sign-in through the system browser: OAuth 2.1 authorization code with PKCE (RFC 7636, RFC 8252). The app never
/// shows a password form. Refreshes happen one at a time (this is an actor), and each rotated refresh token is stored
/// before use.
public actor Auth {
    let store: TokenStore
    let session: URLSession
    private var refreshing: (id: UUID, tokens: Tokens, task: Task<Tokens?, Error>)?
    private var signInVersion = 0

    public init(store: TokenStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// A server's address as typed, as an origin: "kosha.example.com" becomes "https://kosha.example.com". Plain http
    /// only for this computer's own server, which the simulator reaches as localhost.
    public nonisolated static func normalise(_ address: String) -> String? {
        var raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.isEmpty { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let c = URLComponents(string: withScheme), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              !host.isEmpty, !host.contains(where: \.isWhitespace), c.user == nil, c.password == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || scheme == "http" else { return nil }
        if scheme == "http" && !["localhost", "127.0.0.1"].contains(host) { return nil }
        let port = c.port.map { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// Reads the server's OAuth discovery document, which also proves it is a Kosha server.
    public func discover(_ server: String) async throws -> PendingSignIn {
        guard let url = URL(string: "\(server)/.well-known/oauth-authorization-server") else { throw KoshaError.auth(server) }
        let (data, res) = try await fetch(URLRequest(url: url))
        guard (res as? HTTPURLResponse)?.statusCode == 200, let doc = try? KoshaJSON.decode(Discovery.self, data),
              let issuer = doc.issuer, !issuer.isEmpty,
              [issuer, doc.authorization_endpoint, doc.token_endpoint].allSatisfy({ Self.normalise($0) == server }),
              doc.revocation_endpoint.map({ Self.normalise($0) == server }) ?? true else {
            throw KoshaError.auth("No Kosha server at \(server)")
        }
        return PendingSignIn(
            server: server, url: doc.authorization_endpoint, state: "", verifier: "", tokenUrl: doc.token_endpoint,
            revokeUrl: doc.revocation_endpoint, issuer: issuer
        )
    }

    /// The browser URL for a sign-in, with a fresh PKCE verifier and state. `demo` opens the demo account.
    public nonisolated func start(_ found: PendingSignIn, demo: Bool = false) -> PendingSignIn {
        let verifier = Auth.token(32)
        let state = Auth.token(16)
        let challenge = Auth.b64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: found.url)!
        var items = c.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri(found.server)),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: "\(found.server)/api/v1"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if demo {
            items += [URLQueryItem(name: "login_hint", value: "demo"), URLQueryItem(name: "prompt", value: "login")]
        }
        c.queryItems = items
        var out = found
        out.url = c.url!.absoluteString
        out.state = state
        out.verifier = verifier
        return out
    }

    /// The answer as query items when it came where this sign-in sent it: the server's own callback, or the app's
    /// scheme from the callback page's button.
    public nonisolated static func callback(server: String, redirect: URL) -> [String: String]? {
        guard let c = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        if c.scheme == fallbackScheme {
            guard c.path == "/oauth/callback", c.host == nil, c.port == nil else { return nil }
        } else {
            guard let expected = URLComponents(string: redirectUri(server)), c.scheme == expected.scheme,
                  c.host == expected.host, Self.port(c) == Self.port(expected), c.path == expected.path else { return nil }
        }
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard out[item.name] == nil else { return nil }
            out[item.name] = item.value ?? ""
        }
        return out
    }

    private nonisolated static func port(_ url: URLComponents) -> Int? {
        url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
    }

    /// Finishes a sign-in from the answer the browser handed back, and stores the tokens. The code is exchanged with
    /// the HTTPS redirect whichever way the answer came.
    public func finish(_ pending: PendingSignIn, redirect: URL) async throws -> Tokens {
        guard let q = Auth.callback(server: pending.server, redirect: redirect) else {
            throw KoshaError.auth("The sign-in came back somewhere unexpected.")
        }
        if let e = q["error"] { throw KoshaError.auth(q["error_description"] ?? e) }
        guard !pending.state.isEmpty, q["state"] == pending.state else { throw KoshaError.auth("The sign-in didn't match. Try again.") }
        // RFC 9207: an answer from another server than the one asked is refused.
        if pending.issuer.isEmpty || q["iss"] != pending.issuer {
            throw KoshaError.auth("The sign-in came back from another server.")
        }
        guard let code = q["code"], !code.isEmpty else { throw KoshaError.auth("The sign-in came back without a code.") }
        signInVersion += 1
        let version = signInVersion
        let tokens = try await exchange(pending.server, pending.tokenUrl, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectUri(pending.server),
            "client_id": clientId, "code_verifier": pending.verifier, "resource": "\(pending.server)/api/v1",
        ], previousRefresh: nil)
        guard version == signInVersion else { throw KoshaError.signedOut }
        try store.save(tokens)
        return tokens
    }

    /// A fresh access token. Callers that saw a 401 pass the token that failed: if another caller already refreshed it,
    /// they get the new one without a second refresh, so a rotated token is never replayed.
    public func refresh(failed: String?) async throws -> Tokens? {
        guard let current = store.read() else { return nil }
        if let failed, current.access != failed { return current }
        if let refreshing, refreshing.tokens == current { return try await refreshing.task.value }
        // Actors are reentrant across HTTP awaits: share the whole rotation, including its Keychain write.
        let id = UUID()
        let task = Task { try await self.rotate(current) }
        refreshing = (id, current, task)
        defer { if refreshing?.id == id { refreshing = nil } }
        return try await task.value
    }

    private func rotate(_ current: Tokens) async throws -> Tokens? {
        do {
            let next = try await exchange(current.server, "\(current.server)/api/auth/oauth2/token", [
                "grant_type": "refresh_token", "refresh_token": current.refresh, "client_id": clientId,
                "resource": "\(current.server)/api/v1",
            ], previousRefresh: current.refresh)
            guard store.read() == current else { return nil }
            try store.save(next, rotating: true)
            return next
        } catch KoshaError.auth(let m) {
            // A refused refresh means the session is over. No signal, 429 or 5xx keep the session: the next try sends
            // the same refresh token, and the server repeats a lost reply until the new token is used.
            if store.read() == current { store.clear() }
            throw KoshaError.auth(m)
        }
    }

    /// Signs out: revokes the refresh token on the server once (best effort when offline) and forgets the session.
    /// Never retried: revoking a revoked token ends every sign-in of this account on this client.
    public func signOut() async {
        signInVersion += 1
        guard let current = store.read() else { return }
        // Forget before awaiting HTTP: a second sign-out cannot revoke twice, and a late refresh cannot restore it.
        store.clear()
        if let url = URL(string: "\(current.server)/api/auth/oauth2/revoke") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Auth.form(["token": current.refresh, "token_type_hint": "refresh_token", "client_id": clientId])
            _ = try? await session.data(for: req)
        }
    }

    private func exchange(_ server: String, _ url: String, _ body: [String: String], previousRefresh: String?) async throws -> Tokens {
        guard let u = URL(string: url) else { throw KoshaError.auth(url) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Auth.form(body)
        let (data, res) = try await fetch(req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        // 429 and 5xx pass, so try again later; Better Auth's limiter sends X-Retry-After. Any other 4xx is the server
        // saying no (an expired or reused code or token).
        if status == 429 || status == 408 || status >= 500 {
            let h = res as? HTTPURLResponse
            let wait = (h?.value(forHTTPHeaderField: "Retry-After") ?? h?.value(forHTTPHeaderField: "X-Retry-After"))
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            throw KoshaError.retryLater(seconds: wait)
        }
        if (400..<500).contains(status) {
            let text = String(decoding: data, as: UTF8.self)
            throw KoshaError.auth(text.isEmpty ? "Sign-in failed (\(status))" : text)
        }
        guard status == 200, let t = try? KoshaJSON.decode(TokenResponse.self, data) else {
            throw KoshaError.retryLater(seconds: nil)
        }
        guard let refresh = t.refresh_token ?? previousRefresh else { throw KoshaError.auth("No refresh token") }
        let lifetime = t.expires_in ?? 3600
        let (expiresAt, overflow) = Int64(Date().timeIntervalSince1970).addingReportingOverflow(lifetime)
        guard !t.access_token.isEmpty, !refresh.isEmpty, lifetime >= 0, !overflow else {
            throw KoshaError.retryLater(seconds: nil)
        }
        return Tokens(
            server: server, clientId: clientId, access: t.access_token, refresh: refresh,
            expiresAt: expiresAt
        )
    }

    private func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) } catch let e as URLError where e.code != .cancelled {
            throw KoshaError.offline
        }
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
    }

    static func token(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return b64(data)
    }

    static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
